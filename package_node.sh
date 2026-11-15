#!/usr/bin/env bash
#
# Turn a Node.js build tree into the prebuilt bundle GodotJS links against.
#
#   bash package_node.sh <node_source_dir> <node_out_dir> <staging_dir> <platform> <arch>
#
#     <node_source_dir>  the Node source that was built (configure.py lives there)
#     <node_out_dir>     the build output, i.e. out/Release
#     <staging_dir>      the directory that later becomes node_<version>....zip
#     <platform>         linux | macos | windows
#     <arch>             x86_64 | arm64 | ...
#
# Environment:
#   NODE_LINK_LIST   file holding the tokens of the `node` target's link command,
#                    one per line. The CI jobs build it with
#                    `ninja -C out/Release -t commands node | tail -1 | tr ' ' '\n'`.
#                    If it is not set, this script runs ninja itself.
#   NODE_CONFIG_ARGS file holding the ./configure arguments the build used, so
#                    they can be recorded in manifest.json.
#
# Output, inside <staging_dir>/node/:
#
#   include/v8/                  deps/v8/include (v8.h, libplatform/, cppgc/)
#   include/uv/                  deps/uv/include (uv.h)
#   include/node/                Node's own header install: node.h, v8.h, uv.h,
#                                cppgc/, openssl/, js_native_api.h, ...
#   <platform>.<arch>.release/*.a|*.lib
#                                one archive per Node archive, same names
#   <platform>.<arch>.release/config.gypi, common.gypi
#                                the defines and flags this platform's archives
#                                were built with
#   <platform>.<arch>.release/link.txt
#                                what an embedder links, in order, one directive
#                                per line (see the header written into the file)
#   <platform>.<arch>.release/manifest.json
#                                versions, configure args, sha256, sizes
#
# Two things this fixes about the raw build output:
#
#   * GNU ar writes *thin* archives: the file only stores paths to the object
#     files, so the copy on another machine cannot be linked. Any thin archive is
#     rewritten as a normal one here. Apple (libtool) and MSVC (lib.exe) archives
#     are already normal and are copied unchanged.
#   * The --whole-archive grouping is part of the build, not something an
#     embedder should have to know by heart: dropping libnode_base.a out of it
#     loses the built-in JS modules and the binding registrations, and Node then
#     fails at run time with "Missing internal module 'node:crypto'". link.txt
#     records the grouping and the order.

set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 <node_source_dir> <node_out_dir> <staging_dir> <platform> <arch>" >&2
  exit 2
fi

NODE_SRC="$(cd "$1" && pwd)"
NODE_OUT="$(cd "$2" && pwd)"
STAGING="$(mkdir -p "$3" && cd "$3" && pwd)"
PLATFORM="$4"
ARCH="$5"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$PLATFORM" in
  windows) SEP=_ ;;
  *)       SEP=. ;;
esac
PLATFORM_DIR="${PLATFORM}${SEP}${ARCH}${SEP}release"
OUT_DIR="$STAGING/node/$PLATFORM_DIR"
INCLUDE_DIR="$STAGING/node/include/node"

NODE_VERSION="$(python3 - "$NODE_SRC/src/node_version.h" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
get = lambda name: re.search(rf'#define\s+NODE_{name}_VERSION\s+(\d+)', text).group(1)
print(f"{get('MAJOR')}.{get('MINOR')}.{get('PATCH')}")
PY
)"

echo "package_node: Node $NODE_VERSION, $PLATFORM/$ARCH -> node/$PLATFORM_DIR"

# ---------------------------------------------------------------------------
# 1. Which archives, in which order, and which ones need --whole-archive
# ---------------------------------------------------------------------------
LINK_LIST_SRC="${NODE_LINK_LIST:-}"
if [ -z "$LINK_LIST_SRC" ]; then
  if [ ! -f "$NODE_OUT/build.ninja" ]; then
    echo "package_node: $NODE_OUT has no build.ninja and NODE_LINK_LIST is not set." >&2
    echo "  Build with ./configure --ninja, or write the tokenised link command of" >&2
    echo "  the 'node' target to a file and pass it as NODE_LINK_LIST." >&2
    exit 1
  fi
  LINK_LIST_SRC="$STAGING/.node-link-tokens"
  ninja -C "$NODE_OUT" -t commands node | tail -1 | tr ' ' '\n' > "$LINK_LIST_SRC"
fi

WHOLE_FILE="$STAGING/.node-whole"
PLAIN_FILE="$STAGING/.node-plain"
SYSTEM_FILE="$STAGING/.node-system"
: > "$WHOLE_FILE"; : > "$PLAIN_FILE"; : > "$SYSTEM_FILE"

python3 - "$LINK_LIST_SRC" "$WHOLE_FILE" "$PLAIN_FILE" "$SYSTEM_FILE" <<'PY'
import sys

tokens_path, whole_path, plain_path, system_path = sys.argv[1:5]
tokens = [line.strip() for line in open(tokens_path, encoding='utf-8') if line.strip()]

whole, plain, system = [], [], set()
group = plain         # archives before any marker are ordinary archives
seen_whole, seen_plain = set(), set()
expect_framework = False

# Without a marker in the link line, these are the archives to force-load. The
# requirement comes from Node's own build (builtins, snapshot, zlib and libuv
# initializers live in objects nothing else references), not from the linker - but
# only GNU ld spells it as a group. ld64 uses -force_load per archive and MSVC
# uses /WHOLEARCHIVE:, so the token list can arrive with no group marker at all,
# and then an embedder would silently get a bundle missing its initializers.
FALLBACK_WHOLE = ['libnode_base.a', 'libv8_base_without_compiler.a', 'libzlib.a',
                  'libuv.a', 'libv8_snapshot.a', 'libopenssl.a']

def is_our_archive(token):
    # Our archives come with a path (obj/deps/uv/libuv.a); a toolchain library is
    # a bare name (ws2_32.lib, and on Linux those arrive as -lws2_32 instead).
    return (token.endswith('.a') or token.endswith('.lib')) and ('/' in token or '\\' in token)

def add_archive(token, target=None):
    name = token.replace('\\', '/').rsplit('/', 1)[-1]
    where = group if target is None else target
    if name in seen_whole or name in seen_plain:
        return          # already recorded, whichever group it went to
    if where is plain:
        seen_plain.add(name)
    else:
        seen_whole.add(name)
    where.append(name)

for token in tokens:
    if token == '-Wl,--whole-archive':
        group = whole
        continue
    if token == '-Wl,--no-whole-archive':
        group = plain
        continue
    if token.startswith('/WHOLEARCHIVE:'):
        # MSVC's spelling (not yet exercised on a runner): the archive follows the
        # colon, and it is force-loaded on its own.
        add_archive(token.split(':', 1)[1], whole)
        continue
    if token == '-framework':
        expect_framework = True
        continue
    if expect_framework:
        system.add('-framework ' + token)
        expect_framework = False
        continue
    if is_our_archive(token):
        add_archive(token)
    elif token == '-pthread' or token.startswith('-l') and not token.startswith('-labi') or token == '-lm':
        system.add(token)
    else:
        # Bare *.lib names are Windows system libraries (ws2_32.lib, dbghelp.lib).
        if token.endswith('.lib') and not is_our_archive(token):
            system.add(token)

if not whole:
    moved = [name for name in FALLBACK_WHOLE if name in seen_plain]
    for name in moved:
        plain.remove(name)
        seen_plain.discard(name)
        seen_whole.add(name)
    whole.extend(moved)
    print('package_node: the link line carries no whole-archive group (the macOS and '
          'Windows linkers are told per archive), so these archives were marked '
          'force-load from the fallback list: ' + ', '.join(moved))

# Order within each group is kept; system flags are order-insensitive.
open(whole_path, 'w').write(''.join(name + '\n' for name in whole))
open(plain_path, 'w').write(''.join(name + '\n' for name in plain))
open(system_path, 'w').write(''.join(flag + '\n' for flag in sorted(system)))
print(f'package_node: {len(whole)} archive(s) whole-archive, {len(plain)} plain, '
      f'{len(system)} system flags')
print('package_node: whole: ' + ', '.join(whole))
print('package_node: plain: ' + ', '.join(plain))
if not whole:
    raise SystemExit('package_node: no archives in the link command - is this the node target?')
PY

# ---------------------------------------------------------------------------
# 2. Copy the archives, rewriting the thin ones
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/node-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

copy_fat() {
  # $1 = archive name inside $NODE_OUT (searched recursively), $2 = destination dir
  local name="$1" dest="$2" src=""
  if [ -f "$NODE_OUT/$name" ]; then
    src="$NODE_OUT/$name"
  else
    # ninja nests archives (obj/deps/uv/libuv.a); find them without a hard-coded
    # layout so a change in Node's build does not silently drop an archive.
    src="$(find "$NODE_OUT" -name "$name" -type f -print -quit)"
  fi
  if [ -z "$src" ]; then
    echo "package_node: $name is not in $NODE_OUT - was the node target built?" >&2
    exit 1
  fi
  if [ "$(head -c 8 "$src")" != "!"'<thin>' ]; then
    # Already a normal archive (Apple's libtool, MSVC's lib.exe): copy as is.
    cp "$src" "$dest/$name"
    return
  fi

  # Un-thin it. GNU ar refuses to extract from a thin archive ("'x' cannot be
  # used on thin archives"), but the list it prints for one is the path of each
  # object file relative to the build directory, so the members can be archived
  # straight from there.
  local list="$WORK/$name.members"
  if ! ar t "$src" > "$list"; then
    # ar names the archive here, not the missing member, because listing a thin
    # archive means opening every object file it points at. The usual reason for
    # that to fail is that the object files were deleted before packaging.
    echo "package_node: cannot list $src." >&2
    echo "  It is a thin archive: it holds the paths of its object files instead of" >&2
    echo "  their contents, so every one of them has to still exist under $NODE_OUT." >&2
    echo "  Removing *.o from the build directory before this step breaks packaging." >&2
    exit 1
  fi
  # What 'ar t' prints for a thin archive is whatever path was handed to ar when
  # the member was added: usually relative to the build directory, sometimes
  # absolute, and relative to the archive for some generators. All three have to
  # resolve, or an archive silently loses members. One prefix is worked out per
  # archive (from its first entry) and absolute entries are used as they are.
  local prefix="" first
  first="$(head -n 1 "$list")"
  case "$first" in
    /*) prefix="" ;;
    *)
      if [ -e "$NODE_OUT/$first" ]; then
        prefix="$NODE_OUT/"
      else
        prefix="$(dirname "$src")/"
      fi
      ;;
  esac

  # Member names have to be made unique before archiving. ar stores a member under
  # its file name, not its path, and 'ar r' replaces whatever already sits under
  # that name, so two objects with the same file name in different directories
  # overwrite each other. Whether they do depends on the ar in use and on how many
  # names fit into one xargs batch: binutils 2.42 replaces inside a single run, 2.46
  # only replaces against members that were already in the archive. V8 does have
  # such pairs - libv8_base_without_compiler.a holds seven (v8_base_without_compiler.
  # heap.o and friends, each built from two different directories) - so this must
  # not be left to whichever binutils a runner happens to ship.
  #
  # Each object is copied to a staging directory under a name no other member of
  # this archive uses: the plain file name first, then name.2.o, name.3.o (the .o
  # stays last so the archive still reads normally). Nothing outside the archive
  # cares about member names; symbols are what the linker matches on, and
  # verify_node_bundle.sh links the whole set to prove that.
  local stage="$WORK/$name.stage"
  rm -rf "$stage"; mkdir -p "$stage"
  local entry path target stem suffix staged=0 renamed=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      /*) path="$entry" ;;
      *) path="$prefix$entry" ;;
    esac
    if [ ! -f "$path" ]; then
      echo "package_node: $name: member '$entry' is not readable at $path" >&2
      echo "  A thin archive points at object files instead of holding them; every" >&2
      echo "  one of them has to still exist when this step runs (the build dir was" >&2
      echo "  $NODE_OUT)." >&2
      exit 1
    fi
    stem="$(basename "$entry")"
    target="$stem"
    suffix=2
    while [ -e "$stage/$target" ]; do
      if [ "${stem%.o}" != "$stem" ]; then
        target="${stem%.o}.${suffix}.o"
      else
        target="$stem.$suffix"
      fi
      suffix=$((suffix + 1))
    done
    if [ "$target" != "$stem" ]; then
      renamed=$((renamed + 1))
      echo "package_node: $name: two objects are named $stem, keeping the second as $target"
    fi
    cp "$path" "$stage/$target"
    staged=$((staged + 1))
  done < "$list"

  # All names in the staging directory are unique, so one ar invocation cannot
  # replace anything. find keeps the command line short if an archive ever grows.
  ( cd "$stage" && find . -maxdepth 1 -type f -print0 | xargs -0 ar rcs "$dest/$name" )
  command -v ranlib >/dev/null && ranlib "$dest/$name"
  rm -rf "$stage"

  local want got dup
  # `|| true` on each: these are measurements for the assertions below, and a failing
  # grep or ar would otherwise end the script before any of those messages is printed.
  want="$(grep -c . "$list" || true)"
  got="$(ar t "$dest/$name" | wc -l || true)"
  dup="$(ar t "$dest/$name" | sort | uniq -d | wc -l || true)"
  if [ "$staged" != "$want" ]; then
    echo "package_node: $name: the thin archive lists $want members but only $staged could be read." >&2
    exit 1
  fi
  if [ "$want" != "$got" ] || [ "$dup" != "0" ]; then
    echo "package_node: $name came out wrong: $got members, expected $want, $dup name(s) used twice." >&2
    echo "  Every member of the thin archive has to end up in the bundle exactly" >&2
    echo "  once and under its own name. The staging directory was $stage (removed)." >&2
    exit 1
  fi
  echo "package_node: $(basename "$src") -> $name ($got object files${renamed:+, $renamed kept under a second name})"
}

while IFS= read -r name; do
  [ -n "$name" ] && copy_fat "$name" "$OUT_DIR"
done < <(cat "$WHOLE_FILE" "$PLAIN_FILE")

# ---------------------------------------------------------------------------
# 3. Headers
# ---------------------------------------------------------------------------
# Node already knows which headers an embedder needs: tools/install.py is what
# builds the official node-vX-headers.tar.gz, so the bundle uses it instead of
# guessing a header list. The result is the same layout, one directory:
#   include/node/node.h, v8.h, uv.h, cppgc/, openssl/, js_native_api.h, ...
# That single directory is the only -I an embedder needs.
# (The header set Node installs is the public one on purpose. node_internals.h,
# env-inl.h and friends are left out by Node; a binding layer that includes them
# has to copy src/ itself and accept that they change without warning.)
rm -rf "$STAGING/node/include"
mkdir -p "$STAGING"
install_args=()
if [ "$PLATFORM" = windows ]; then
  install_args+=(--is-win)
fi
(
  cd "$NODE_SRC" &&
  python3 tools/install.py install --headers-only \
    --dest-dir "$STAGING/node" --prefix / \
    --root-dir "$NODE_SRC" --build-dir "$NODE_OUT" \
    --config-gypi-path "$NODE_SRC/config.gypi" "${install_args[@]}"
) >/dev/null
if [ ! -f "$INCLUDE_DIR/node.h" ] || [ ! -f "$INCLUDE_DIR/v8.h" ] || [ ! -f "$INCLUDE_DIR/uv.h" ]; then
  echo "package_node: tools/install.py did not produce include/node/node.h, v8.h, uv.h." >&2
  echo "  Node changed which headers it installs; check tools/install.py." >&2
  exit 1
fi

# Node's installer ships what an addon needs, which is not quite what an engine
# embedding Node needs: these V8 headers live in deps/v8/include but are not
# installed, and GodotJS includes them directly (impl/v8/jsb_v8_pch.h).
# A missing one is an error rather than a warning, so the surprise happens here
# instead of in the first engine compile.
#   v8-inspector.h       the inspector channel
#   v8-version-string.h  V8's version string, used in diagnostics
# Both only include headers installed above, so copying them is enough.
for v8_extra in v8-inspector.h v8-version-string.h; do
  if [ ! -f "$NODE_SRC/deps/v8/include/$v8_extra" ]; then
    echo "package_node: $NODE_SRC/deps/v8/include/$v8_extra is missing." >&2
    echo "  Node moved or dropped a header the engine includes; update this list." >&2
    exit 1
  fi
  cp "$NODE_SRC/deps/v8/include/$v8_extra" "$INCLUDE_DIR/$v8_extra"
done
echo "package_node: added v8-inspector.h and v8-version-string.h to include/node"

# OpenSSL's per-platform configure output ships next to its headers (Node does the
# same in its own headers tarball). The tarball covers every platform, a bundle
# covers one, so the other directories are dropped: 20 of them are 66 MB of the
# 67 MB the header tree weighs.
case "$PLATFORM/$ARCH" in
  linux/x86_64)  openssl_arch=linux-x86_64 ;;
  linux/arm64)   openssl_arch=linux-aarch64 ;;
  macos/arm64)   openssl_arch=darwin64-arm64-cc ;;
  macos/x86_64)  openssl_arch=darwin64-x86_64-cc ;;
  windows/x86_64) openssl_arch=VC-WIN64A ;;
  windows/arm64)  openssl_arch=VC-WIN64-ARM ;;
  # Nothing to trim on Android or iOS: deps/openssl/config/archs in the Node source
  # ships no android-* or ios* directory, so there is no matching folder to keep and
  # the whole pre-generated set stays in the bundle (about 60 MB of headers nobody
  # includes). Revisit after the first mobile build, when it is visible which
  # configuration that target actually ends up using.
  android/*|ios/*) openssl_arch="" ;;
  *) openssl_arch="" ;;
esac
if [ -n "$openssl_arch" ] && [ -d "$INCLUDE_DIR/openssl/archs/$openssl_arch" ]; then
  find "$INCLUDE_DIR/openssl/archs" -mindepth 1 -maxdepth 1 -type d \
    ! -name "$openssl_arch" -exec rm -rf {} +
  echo "package_node: kept openssl/archs/$openssl_arch only"
fi

# config.gypi and common.gypi describe the defines and flags this platform's
# archives were built with, and install.py puts them next to the headers. They are
# per-platform, so they move next to the archives instead: several platform jobs
# write into one staging tree before the bundle is zipped, and a shared copy would
# silently end up being whichever job finished last.
mv "$INCLUDE_DIR/config.gypi" "$OUT_DIR/config.gypi"
mv "$INCLUDE_DIR/common.gypi" "$OUT_DIR/common.gypi"

# ---------------------------------------------------------------------------
# 4. link.txt
# ---------------------------------------------------------------------------
V8_VERSION="$(python3 - "$INCLUDE_DIR/v8-version.h" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
print('.'.join(re.findall(r'#define V8_(?:MAJOR_VERSION|MINOR_VERSION|BUILD_NUMBER|PATCH_LEVEL)\s+(\d+)', text)))
PY
)"
{
  echo "# Generated by package_node.sh - read by GodotJS's SCsub, do not edit."
  echo "# node=$NODE_VERSION v8=$V8_VERSION"
  echo "# whole <file>   archive linked with --whole-archive"
  echo "# plain <file>   archive linked normally; the order of these lines matters"
  echo "# system <flag>  extra linker flag or library"
  echo "# define <NAME>[=<value>]  macro an embedder compiles with, from config.gypi"
  echo "# feature <name>=<value>   build setting that changes the ABI but is not a"
  echo "#                          macro the public headers record; an embedder has"
  echo "#                          to match it, not guess it"
  while IFS= read -r name; do [ -n "$name" ] && echo "whole $name"; done < "$WHOLE_FILE"
  while IFS= read -r name; do [ -n "$name" ] && echo "plain $name"; done < "$PLAIN_FILE"
  while IFS= read -r flag; do [ -n "$flag" ] && echo "system $flag"; done < "$SYSTEM_FILE"
# The macros config.gypi tells node-gyp to use. They are what Node's own sources
# were compiled with for the parts that matter to an embedder (V8's own build flags
# are not here: Node's public headers are compiled without any V8_* -D, which the
# verification program in tools/ checks by compiling the same way).
python3 - "$OUT_DIR/config.gypi" <<'PY'
import ast, sys
config = ast.literal_eval(open(sys.argv[1], encoding='utf-8', errors='replace').read())
for define in config.get('target_defaults', {}).get('defines', []):
    print('define', define)

# Pointer compression changes the size of every v8 handle and object pointer, and
# V8's public headers do not record whether it was on: it is a -D the embedder has
# to pass. GodotJS's SCsub hard-codes V8_COMPRESS_POINTERS on desktop, which matches
# a standalone V8 build but silently mismatches a Node build built with it off -
# wrong sizes link fine and corrupt at runtime. Recording it here is what lets the
# engine read the truth off the bundle instead of guessing.
variables = config.get('variables', {})
for key in ('v8_enable_pointer_compression', 'v8_enable_pointer_compression_shared_cage'):
    value = str(variables.get(key, '0'))
    enabled = value in ('1', 'true', 'True')
    print(f'feature {key}={1 if enabled else 0}')
    if key == 'v8_enable_pointer_compression' and enabled:
        print('define V8_COMPRESS_POINTERS')
PY
} > "$OUT_DIR/link.txt"

# ---------------------------------------------------------------------------
# 5. manifest.json
# ---------------------------------------------------------------------------
python3 - "$OUT_DIR/manifest.json" "$NODE_VERSION" "$V8_VERSION" "$PLATFORM" "$ARCH" \
  "$OUT_DIR/config.gypi" "${NODE_CONFIG_ARGS:-}" <<'PY'
import hashlib, json, os, re, sys

out_path, node_version, v8_version, platform, arch, config_path, args_path = sys.argv[1:8]
out_dir = os.path.dirname(out_path)

def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()

config = open(config_path, encoding='utf-8', errors='replace').read()
def variable(name, default=None):
    match = re.search(r"['\"]%s['\"]:\s*['\"]?([^,'\"\n]*)" % re.escape(name), config)
    return match.group(1).strip() if match else default

archives = sorted(name for name in os.listdir(out_dir)
                  if name.endswith('.a') or name.endswith('.lib'))
manifest = {
    'node_version': node_version,
    'v8_version': v8_version,
    'platform': platform,
    'arch': arch,
    # ICU data is compiled into the ICU archives, so - unlike the V8-only bundle -
    # there is no icudtl.dat to ship next to the executable.
    'icu_version': variable('icu_ver_major'),
    'icu_data': 'compiled-in',
    'pointer_compression': variable('v8_enable_pointer_compression', '0'),
    # Temporal is built from Rust in deps/crates and ./configure drops it quietly when
    # cargo is missing, so the bundle states which way it went. Absent on older Node
    # versions that never had it.
    'temporal_support': variable('v8_enable_temporal_support', '0') == '1',
    'configure_args': [],
    'archives': {name: sha256(os.path.join(out_dir, name)) for name in archives},
    'sizes': {name: os.path.getsize(os.path.join(out_dir, name)) for name in archives},
}
if args_path and os.path.isfile(args_path):
    manifest['configure_args'] = [line.strip() for line in open(args_path, encoding='utf-8')
                                  if line.strip() and not line.lstrip().startswith('#')]

with open(out_path, 'w', encoding='utf-8') as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write('\n')
print(f"package_node: manifest v8={v8_version} icu={manifest['icu_version']} "
      f"pointer_compression={manifest['pointer_compression']} "
      f"temporal={manifest['temporal_support']} "
      f"archives={len(archives)}")
PY

# The manifest has to describe the headers shipped next to it: 14.6 headers over
# a 13.6 library links fine and crashes at run time.
python3 - "$OUT_DIR/manifest.json" "$INCLUDE_DIR/v8-version.h" <<'PY'
import json, re, sys
manifest = json.load(open(sys.argv[1], encoding='utf-8'))
text = open(sys.argv[2], encoding='utf-8').read()
v8 = '.'.join(re.findall(r'#define V8_(?:MAJOR_VERSION|MINOR_VERSION|BUILD_NUMBER|PATCH_LEVEL)\s+(\d+)', text))
if manifest['v8_version'] != v8:
    raise SystemExit(f"package_node: manifest v8_version={manifest['v8_version']} "
                     f"does not match the shipped headers {v8}")
print(f'package_node: manifest and headers agree on V8 {v8}')
PY

rm -f "$STAGING/.node-link-tokens" "$WHOLE_FILE" "$PLAIN_FILE" "$SYSTEM_FILE"
echo "package_node: done -> node/$PLATFORM_DIR"
