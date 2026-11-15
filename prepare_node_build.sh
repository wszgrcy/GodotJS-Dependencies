#!/usr/bin/env bash
#
# Adjust a Node.js checkout before building the static libraries GodotJS links.
#
#   bash prepare_node_build.sh <node_source_dir> <configure_args_file> <node_version>
#
#     <node_source_dir>       the unpacked Node source (the directory with configure.py)
#     <configure_args_file>   the node.<platform>_<arch>.configure.txt copy that will
#                             be handed to ./configure; version-specific args are
#                             appended to it here
#     <node_version>          the Node version being built, e.g. 26.13.1
#
# What it changes, and why:
#
#   1. Appends node.extra_<major>.x.configure.txt to the args file, when that file
#      exists. Node's configure is plain argparse: an option an older version does
#      not declare makes configure fail, so options newer than the oldest version we
#      build cannot live in the per-platform files. Same reason as
#      v8.extra_15.x.args.gn.
#
#   2. Turns C++ RTTI back on (Node builds with -fno-rtti). Godot is compiled with
#      RTTI on, and an embedder that derives from a Node or V8 class with virtual
#      functions needs that class's typeinfo to exist, or the link fails with
#      "undefined reference to typeinfo for node::IsolatePlatformDelegate" (V8 has
#      the same problem: GodotJS already hit it with v8::ArrayBuffer::Allocator).
#      The flag lives in common.gypi, which gyp applies to Node, to the V8 copy in
#      deps/v8, and to the deps that sit under the same directory.
#
#   3. Removes -rdynamic from the link flags. Node passes it so that a native addon
#      loaded with process.dlopen can find Node's own symbols; a game engine does
#      not want to export its whole symbol table for that. Set NODE_KEEP_RDYNAMIC=1
#      if loading prebuilt .node addons matters more than symbol hygiene.
#
#   4. Applies nodejs/node#66804 ("build: use a single producer for shared generated
#      files") unless the source already carries it. Without it a cross build cannot
#      produce a ninja graph at all - the host toolset and the target toolset both
#      claim the same generated file, and ninja refuses before compiling anything.
#      Merged upstream on 2026-11-05 but not in any release through 26.13.1, so the
#      patch is carried under patches/. Native builds are unaffected either way.
#
# Environment:
#   NODE_KEEP_NO_RTTI=1    leave -fno-rtti alone
#   NODE_KEEP_RDYNAMIC=1   leave -rdynamic alone

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <node_source_dir> <configure_args_file> <node_version>" >&2
  exit 2
fi

NODE_SRC="$1"
ARGS_FILE="$2"
NODE_VERSION="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_MAJOR="${NODE_VERSION%%.*}"
case "$NODE_MAJOR" in
  ''|*[!0-9]*)
    echo "prepare_node_build: cannot read a major version out of '$NODE_VERSION'" >&2
    exit 2
    ;;
esac

if [ ! -d "$NODE_SRC" ]; then
  echo "prepare_node_build: no such Node source directory: $NODE_SRC" >&2
  exit 1
fi
if [ ! -f "$NODE_SRC/configure.py" ]; then
  echo "prepare_node_build: $NODE_SRC has no configure.py, is that a Node source tree?" >&2
  exit 1
fi
if [ ! -f "$ARGS_FILE" ]; then
  echo "prepare_node_build: $ARGS_FILE does not exist" >&2
  exit 1
fi

# --- the V8 that ships with this Node source -----------------------------------
# GodotJS compiles against these headers, so print them: they are what
# package_node.sh later compares against the manifest.
V8_VERSION="$(python3 - "$NODE_SRC/deps/v8/include/v8-version.h" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
keys = ('MAJOR_VERSION', 'MINOR_VERSION', 'BUILD_NUMBER', 'PATCH_LEVEL')
nums = dict(re.findall(r'#define V8_(MAJOR_VERSION|MINOR_VERSION|BUILD_NUMBER|PATCH_LEVEL)\s+(\d+)', text))
missing = [key for key in keys if key not in nums]
if missing:
    raise SystemExit(f'v8-version.h: missing {missing}')
print('.'.join(nums[key] for key in keys))
PY
)"
echo "prepare_node_build: Node $NODE_VERSION bundles V8 $V8_VERSION"

# --- version-specific configure args ------------------------------------------
# The append below writes into the file it was given, so it must not be a repository
# file. The CI job copies first (cp Scripts/node.<...>.configure.txt args.txt);
# running it by hand with the original path is how a tracked file ends up dirty.
case "$(basename "$ARGS_FILE")" in
  node.*.configure.txt)
    echo "prepare_node_build: '$ARGS_FILE' is one of this repository's args files." >&2
    echo "  The version-specific arguments are appended to the file you pass, so pass a" >&2
    echo "  copy instead:  cp $ARGS_FILE args.txt && bash $0 <node_src> args.txt $NODE_VERSION" >&2
    exit 2
    ;;
esac

EXTRA="$SCRIPT_DIR/node.extra_${NODE_MAJOR}.x.configure.txt"
if [ -f "$EXTRA" ]; then
  MARKER="# appended by prepare_node_build.sh from $(basename "$EXTRA")"
  if grep -qF "$MARKER" "$ARGS_FILE"; then
    echo "prepare_node_build: $(basename "$EXTRA") already appended, skipping"
  else
    echo "prepare_node_build: appending $(basename "$EXTRA")"
    printf '\n%s\n' "$MARKER" >> "$ARGS_FILE"
    cat "$EXTRA" >> "$ARGS_FILE"
  fi
else
  echo "prepare_node_build: no node.extra_${NODE_MAJOR}.x.configure.txt, using the file as is"
fi

# --- ICU data has to be in the tree for full-icu -------------------------------
# full-icu is Node's default, and it is the only ICU mode whose data has to come
# with the source tree, so that is the case worth checking up front: a build that
# gets to the ICU step and then finds no data file wastes the whole compile first.
intl_arg="$(grep -oE '^[[:space:]]*--with-intl=[a-z-]+' "$ARGS_FILE" | head -1 | tr -d '[:space:]')"
case "${intl_arg:---with-intl=full-icu}" in
  --with-intl=full-icu)
    if ! ls "$NODE_SRC"/deps/icu-small/source/data/in/icudt*l.dat* >/dev/null 2>&1; then
      echo "prepare_node_build: no ICU data file under deps/icu-small/source/data/in/." >&2
      echo "  full-icu needs it. Use the official source tarball (it ships" >&2
      echo "  icudt<l>.dat.bz2) or add --download=icu to the configure args." >&2
      exit 1
    fi
    echo "prepare_node_build: full-icu data found"
    ;;
  *)
    echo "prepare_node_build: $intl_arg, no ICU data file needed"
    ;;
esac

# --- cross builds: the compiler comes from the environment ----------------------
# ./configure has no option for "use this compiler"; gyp's ninja generator reads
# CC_target / CXX_target / AR_target / NM_target / READELF_target from the
# environment (tools/gyp/pylib/gyp/generator/ninja.py, GetEnvironFallback). If they
# are not set, nothing fails: the build quietly compiles host-architecture objects
# into an archive named after the target platform, which only shows up when the
# engine tries to link it. So check before a long build starts.
dest_os="$(grep -oE '^[[:space:]]*--dest-os=[a-z]+' "$ARGS_FILE" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
dest_cpu="$(grep -oE '^[[:space:]]*--dest-cpu=[a-z0-9]+' "$ARGS_FILE" | head -1 | cut -d= -f2 | tr -d '[:space:]')"

require_cross_toolchain() {
  # $1 = label, $2 = hint shown on failure, $3 = which variables must be set.
  # READELF_target is only needed where gyp's readelf rules apply; the Apple SDK has
  # no readelf at all, so an iOS cross build legitimately leaves it unset.
  # Each X_target may also be given as plain X: gyp reads them in that order, and
  # Node's ./android-configure sets the plain form.
  local label="$1" hint="$2" vars="$3"
  local missing=() cross_var cross_value base_var
  for cross_var in $vars; do
    base_var="${cross_var%_target}"
    cross_value="${!cross_var:-}"
    if [ -z "$cross_value" ]; then
      cross_value="${!base_var:-}"
    fi
    if [ -z "$cross_value" ]; then
      missing+=("$cross_var (or $base_var)")
    elif ! command -v "$cross_value" >/dev/null 2>&1 && [ ! -x "$cross_value" ]; then
      missing+=("$cross_var (set but not runnable: $cross_value)")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "prepare_node_build: $label cross build is missing ${missing[*]}" >&2
    echo "  $hint" >&2
    exit 1
  fi
  echo "prepare_node_build: $label/$dest_cpu with ${CXX_target:-${CXX:-the default compiler}}"
}

case "${dest_os:-linux}" in
  android)
    require_cross_toolchain android \
"Point them at the Android NDK wrapper compilers in \$NDK/toolchains/llvm/prebuilt/<host>/bin/, named after the target and API level, for example aarch64-linux-android28-clang and -clang++. Node's own ./android-configure <NDK> <API> <arch> sets the same compilers (as plain CC/CXX) and then runs ./configure with --dest-os=android --openssl-no-asm --cross-compiling; either route works, this script only needs the variables." \
"CC_target CXX_target AR_target NM_target READELF_target"

    # OpenSSL's generated configurations in the source tree cover linux, macOS,
    # Windows and friends (deps/openssl/config/archs/), but there is no android-*
    # directory there. Until an Android build is run end to end, that is the most
    # likely place for it to stop; saying it here beats discovering it at 90% of a
    # two-hour compile.
    if ! ls "$NODE_SRC"/deps/openssl/config/archs/android* >/dev/null 2>&1; then
      echo "prepare_node_build: note - deps/openssl/config/archs has no android entry,"
      echo "  so OpenSSL's configuration for this target is not pre-generated. If the"
      echo "  build stops inside deps/openssl, that is the place to look first."
    fi
    ;;
  ios)
    require_cross_toolchain ios \
"gyp has no ios flavour, so nothing derives an Apple toolchain for you: point these at wrapper compilers that bake in -target arm64-apple-ios<version> and -isysroot \$(xcrun --sdk iphoneos --show-sdk-path). build_node.yml writes those wrappers." \
"CC_target CXX_target AR_target NM_target"

    # iOS cannot allocate executable memory, so V8 has to run without a JIT. The
    # archives themselves cannot record that; it is decided by the flags the engine
    # passes when it starts Node. Recorded here because an iOS bundle that was never
    # started jitless is a runtime failure, not a link failure.
    echo "prepare_node_build: note - iOS forbids JIT, so an embedder must start Node"
    echo "  with JIT disabled for this bundle to be usable."
    if ! ls "$NODE_SRC"/deps/openssl/config/archs/ios* >/dev/null 2>&1; then
      echo "prepare_node_build: note - deps/openssl/config/archs has no ios entry"
      echo "  (gode links its iOS libnode against -framework Foundation; link.txt has"
      echo "  to carry the same frameworks)."
    fi
    ;;
  ''|linux|mac|win)
    ;;
  *)
    echo "prepare_node_build: --dest-os=$dest_os is not set up here (linux, mac, win, android, ios)." >&2
    exit 1
    ;;
esac

# --- one build fix no released Node has yet ------------------------------------
# nodejs/node#66804: in a cross build the host toolset and the target toolset each
# register the shared generated files, so ninja sees two producers for one output
# and refuses before compiling anything:
#
#   ninja: error: obj.host/tools/v8_gypfiles/v8_inspector_headers.ninja:26:
#   multiple rules generate gen/inspector-generated-output-root/src/js_protocol.stamp
#
# Verified on 26.13.1 with a same-OS cross configure (linux x86_64 host,
# --dest-cpu=arm64): without the patch ninja refuses, with it the graph parses
# (6523 targets), and a native configure still parses afterwards.
CROSS_PATCH="$SCRIPT_DIR/patches/node-66804-single-producer.patch"
if [ -f "$CROSS_PATCH" ]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "prepare_node_build: git is needed to apply $CROSS_PATCH" >&2
    exit 1
  fi
  host_cpu="$(uname -m)"
  case "$host_cpu" in x86_64|amd64) host_cpu=x64 ;; aarch64|arm64) host_cpu=arm64 ;; esac
  host_os="$(uname -s)"
  case "$host_os" in
    Linux) host_os=linux ;;
    Darwin) host_os=mac ;;
    MINGW*|MSYS*|CYGWIN*) host_os=win ;;
  esac
  cross_build=0
  if { [ -n "$dest_cpu" ] && [ "$dest_cpu" != "$host_cpu" ]; } ||
     { [ -n "$dest_os" ] && [ "$dest_os" != "$host_os" ]; }; then
    cross_build=1
  fi
  if ( cd "$NODE_SRC" && git apply --check -p1 "$CROSS_PATCH" ) >/dev/null 2>&1; then
    ( cd "$NODE_SRC" && git apply -p1 "$CROSS_PATCH" )
    echo "prepare_node_build: applied nodejs/node#66804 (single producer for shared generated files)"
  elif ( cd "$NODE_SRC" && git apply --reverse --check -p1 "$CROSS_PATCH" ) >/dev/null 2>&1; then
    echo "prepare_node_build: nodejs/node#66804 is already in this Node source"
  elif [ "$cross_build" = 1 ]; then
    echo "prepare_node_build: this is a cross build ($host_os/$host_cpu -> ${dest_os:-same os}/${dest_cpu:-same cpu})" >&2
    echo "  and $CROSS_PATCH fits neither forward nor in reverse, so ninja would stop" >&2
    echo "  with 'multiple rules generate ...'. Either this Node version already" >&2
    echo "  carries nodejs/node#66804 in a changed form, or the patch needs updating." >&2
    exit 1
  else
    echo "prepare_node_build: nodejs/node#66804 fits neither way; a native build does"
    echo "  not need it, so continuing."
  fi
fi

# --- RTTI and -rdynamic in common.gypi -----------------------------------------
python3 - "$NODE_SRC/common.gypi" "${NODE_KEEP_NO_RTTI:-0}" "${NODE_KEEP_RDYNAMIC:-0}" <<'PY'
import re, sys

path, keep_rtti, keep_rdynamic = sys.argv[1:4]

with open(path, encoding='utf-8') as handle:
    text = handle.read()
original = text
changes = []

if keep_rtti != '1':
    # gcc/clang: the flag sits in a cflags_cc list.
    stripped, count = re.subn(r"^[ \t]*'-fno-rtti',\n", '', text, flags=re.M)
    if count:
        text = stripped
        changes.append(f'{count} x -fno-rtti removed')
    # Xcode: the equivalent is a setting. The trailing comment names the flag the
    # setting controls, so it is rewritten too - a stale "# -fno-rtti" next to 'YES'
    # reads like the patch did not apply.
    flipped, count = re.subn(
        r"('GCC_ENABLE_CPP_RTTI': )'NO'([ \t]*,[ \t]*# -fno-rtti)?",
        r"\1'YES'\2", text)
    if count:
        text = flipped
        text = re.sub(
            r"('GCC_ENABLE_CPP_RTTI': 'YES'[ \t]*,[ \t]*# )-fno-rtti", r"\1-frtti", text)
        changes.append(f'{count} x GCC_ENABLE_CPP_RTTI set to YES')
elif '-fno-rtti' not in text:
    changes.append('RTTI already on')

if keep_rdynamic != '1':
    # Only the assignments; the 'ldflags!': [ '-rdynamic' ] removals stay.
    stripped, count = re.subn(
        r"^[ \t]*'ldflags':\s*\[\s*'-rdynamic',?\s*\],?[ \t]*\n",
        '', text, flags=re.M)
    if count:
        text = stripped
        changes.append(f'{count} x -rdynamic link flag removed')

if changes:
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print('prepare_node_build: patched common.gypi: ' + ', '.join(changes))
else:
    print('prepare_node_build: common.gypi already patched, nothing to do')
PY

# V8's own toolchain file adds -rdynamic for the host tools on some platforms.
if [ "${NODE_KEEP_RDYNAMIC:-0}" != "1" ] && [ -f "$NODE_SRC/tools/v8_gypfiles/toolchain.gypi" ]; then
  python3 - "$NODE_SRC/tools/v8_gypfiles/toolchain.gypi" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
new, count = re.subn(
    r"^[ \t]*'ldflags':\s*\[\s*'-rdynamic',?\s*\],?[ \t]*\n", '', text, flags=re.M)
if count:
    open(path, 'w', encoding='utf-8').write(new)
    print(f'prepare_node_build: patched toolchain.gypi: {count} x -rdynamic removed')
else:
    print('prepare_node_build: toolchain.gypi needs no -rdynamic patch')
PY
fi

echo "prepare_node_build: done"
