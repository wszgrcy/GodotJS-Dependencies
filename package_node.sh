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
#   NODE_LINK_LIST   optional file with the tokens of the `node` target's link
#                    command, one per line; used instead of running ninja. Either
#                    way tools/parse_node_link.py does the reading.
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
LINK_LIST="${NODE_LINK_LIST:-}"
LINK_CMD_SRC=""
if [ -z "$LINK_LIST" ]; then
  if [ ! -f "$NODE_OUT/build.ninja" ]; then
    echo "package_node: $NODE_OUT has no build.ninja and NODE_LINK_LIST is not set." >&2
    echo "  Build with ./configure --ninja, or write the link command of the 'node'" >&2
    echo "  target to a file and pass it as NODE_LINK_LIST." >&2
    exit 1
  fi
  # Every command line that leads to `node`, not just the last one: which line is the
  # real link is decided by tools/parse_node_link.py, because on Windows the archives
  # sit in a response file and a generator step can end up at the bottom.
  LINK_CMD_SRC="$STAGING/.node-commands"
  ninja -C "$NODE_OUT" -t commands node > "$LINK_CMD_SRC"
fi

WHOLE_FILE="$STAGING/.node-whole"
PLAIN_FILE="$STAGING/.node-plain"
SYSTEM_FILE="$STAGING/.node-system"
: > "$WHOLE_FILE"; : > "$PLAIN_FILE"; : > "$SYSTEM_FILE"

if [ -n "$LINK_LIST" ]; then
  python3 "$SCRIPT_DIR/tools/parse_node_link.py" --tokens "$LINK_LIST" \
    --out-dir "$NODE_OUT" \
    --whole "$WHOLE_FILE" --plain "$PLAIN_FILE" --system "$SYSTEM_FILE"
else
  python3 "$SCRIPT_DIR/tools/parse_node_link.py" --commands "$LINK_CMD_SRC" \
    --out-dir "$NODE_OUT" \
    --whole "$WHOLE_FILE" --plain "$PLAIN_FILE" --system "$SYSTEM_FILE"
fi

# A carriage return in one of these lists is read as part of the archive name, and
# "zlib.lib\r is not in out/Release" is a confusing thing to be told about a file
# that plainly exists. Nothing written here should produce one (both writers open
# their output with newline='\n'), but a list handed in through NODE_LINK_LIST can
# come from anywhere, so trailing CR is dropped before anything reads the lists.
for list in "$WHOLE_FILE" "$PLAIN_FILE" "$SYSTEM_FILE"; do
  if grep -q $'\r' "$list"; then
    tr -d '\r' < "$list" > "$list.lf" && mv "$list.lf" "$list"
    echo "package_node: dropped carriage returns from $(basename "$list")"
  fi
done

# ---------------------------------------------------------------------------
# 2. Copy the archives, rewriting the thin ones
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/node-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Which CPU an archive was built for, when this machine can tell.
#
# This script prints the path on stdout, so the answer comes back in the exit
# status: 0 = holds the architecture being packaged, 1 = holds another one,
# 2 = cannot tell (no lipo, which means not macOS, or an archive lipo cannot read).
# Only macOS reports this; the Linux and Windows bundles are left alone.
arch_state() {
  local path="$1" expected="" info archs
  case "$ARCH" in
    x86_64 | amd64) expected=x86_64 ;;
    arm64 | aarch64) expected=arm64 ;;
    *) return 2 ;;
  esac
  command -v lipo > /dev/null 2>&1 || return 2
  info="$(lipo -info "$path" 2> /dev/null)" || return 2
  case "$info" in
    *"architecture: "*) archs="${info##*architecture: }" ;;
    *" are: "*) archs="${info##* are: }" ;;
    *) return 2 ;;
  esac
  # Only the architecture part is looked at: the path itself usually contains the
  # platform directory (macos.x86_64.release), so matching the whole line would
  # call an arm64 archive correct. A case with no match would report success, so
  # the mismatch has to be returned by name.
  case " $archs " in
    *" $expected "*) return 0 ;;
  esac
  return 1
}

# Full path of the archive to copy, left in ARCHIVE_SRC. When the build tree holds
# more than one file with that name, the copy holding the packaged architecture wins.
#
# A cross build does hold several. Building x86_64 macOS on an arm64 machine, the
# Rust Temporal crate is built once per toolset, and host-toolset output in general
# sits under gen.host / obj.host / cargo/host. The first match used to win, which
# put arm64 objects into the macos.x86_64 directory; the first link against that
# bundle then failed with "found architecture 'arm64', required architecture
# 'x86_64'" a few steps later, in a step that gave no hint about packaging.
locate_archive() {
  local name="$1" list="$WORK/locate.all" ordered="$WORK/locate.ordered" path
  local count state
  ARCHIVE_SRC=""
  if [ -f "$NODE_OUT/$name" ]; then
    ARCHIVE_SRC="$NODE_OUT/$name"
    return 0
  fi
  # ninja nests archives (obj/deps/uv/libuv.a); search without a hard-coded layout
  # so a change in Node's build does not silently drop an archive.
  find "$NODE_OUT" -name "$name" -type f -print > "$list"
  count="$(wc -l < "$list" | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    return 1
  fi
  # Host-toolset paths last, so that a tree which can only be judged by its file
  # names is judged in the order that is usually right; where the machine can read
  # the architecture, arch_state overrules this order.
  grep -vE '(^|/)(gen|obj)\.host/|/cargo/host/' "$list" > "$ordered" || true
  grep -E '(^|/)(gen|obj)\.host/|/cargo/host/' "$list" >> "$ordered" || true
  if [ "$count" -gt 1 ]; then
    # Say what was found and what won: this line is read from a CI log afterwards,
    # when the build directory is long gone.
    echo "package_node: $name has $count copies under $NODE_OUT:"
    while IFS= read -r path; do echo "    $path"; done < "$list"
  fi
  while IFS= read -r path; do
    state=0
    arch_state "$path" || state=$?
    if [ "$state" -eq 0 ]; then
      ARCHIVE_SRC="$path"
      break
    fi
    # Nothing better yet: keep the first one this machine could not judge.
    if [ "$state" -eq 2 ] && [ -z "$ARCHIVE_SRC" ]; then
      ARCHIVE_SRC="$path"
    fi
  done < "$ordered"
  [ -n "$ARCHIVE_SRC" ] || ARCHIVE_SRC="$(head -n 1 "$ordered")"
  if [ "$count" -gt 1 ]; then
    echo "package_node:    using $ARCHIVE_SRC"
  fi
}

# Last line of defence: the archive that ended up in the bundle has to hold the
# architecture the bundle is named after.
check_arch() {
  local path="$1" rc=0
  arch_state "$path" || rc=$?
  [ "$rc" -eq 1 ] || return 0
  echo "package_node: $path does not hold objects for $PLATFORM/$ARCH:" >&2
  lipo -info "$path" >&2 || true
  echo "  The build tree keeps a copy per toolset; the 'using' line above says which"
  echo "  copy was taken and the list above it shows what the build left behind." >&2
  exit 1
}

copy_fat() {
  # $1 = archive name inside $NODE_OUT, $2 = destination dir
  local name="$1" dest="$2" src=""
  locate_archive "$name" || {
    echo "package_node: $name is not in $NODE_OUT - was the node target built?" >&2
    exit 1
  }
  src="$ARCHIVE_SRC"
  if [ "$(head -c 8 "$src")" != "!"'<thin>' ]; then
    # Already a normal archive (Apple's libtool, MSVC's lib.exe): copy as is.
    cp "$src" "$dest/$name"
    check_arch "$dest/$name"
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
  check_arch "$dest/$name"
  echo "package_node: $src -> $name ($got object files${renamed:+, $renamed kept under a second name})"
}

while IFS= read -r name; do
  [ -n "$name" ] && copy_fat "$name" "$OUT_DIR"
done < <(cat "$WHOLE_FILE" "$PLAIN_FILE")

# ---------------------------------------------------------------------------
# 3. Headers
# ---------------------------------------------------------------------------
# The same call CI makes before the long build, so a broken header install is
# found in seconds there instead of after 40 minutes of compiling here.
bash "$SCRIPT_DIR/tools/install_node_headers.sh" \
  "$NODE_SRC" "$NODE_OUT" "$STAGING/node" "$PLATFORM" "$ARCH"

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
  echo "# system <flag...> extra linker flag or library; one line can hold more"
  echo "#                          than one word, macOS names a library as"
  echo "#                          -framework CoreFoundation"
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

# Every archive link.txt names has to be sitting next to it. A name that made it
# into the list without being copied shows up, far from here, as a missing library
# for whoever links the bundle - so it is checked here, where the cause is visible.
missing_archives=()
while read -r kind name _rest; do
  case "$kind" in
    whole | plain) [ -f "$OUT_DIR/$name" ] || missing_archives+=("$name") ;;
  esac
done < <(grep -vE '^\s*(#|$)' "$OUT_DIR/link.txt")
if [ "${#missing_archives[@]}" -ne 0 ]; then
  echo "package_node: link.txt names archives that are not in $OUT_DIR:" >&2
  printf '  %s\n' "${missing_archives[@]}" >&2
  exit 1
fi
listed_archives="$(grep -cE '^(whole|plain) ' "$OUT_DIR/link.txt" || true)"
echo "package_node: link.txt names ${listed_archives:-0} archives, all present in node/$PLATFORM_DIR"

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

with open(out_path, 'w', encoding='utf-8', newline='\n') as handle:
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
