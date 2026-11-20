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
#   1. Appends node.extra_<major>.x.configure.txt, and node.extra_<major>.x.<dest-os>
#      .configure.txt when that platform has its own file, to the args file. Node's
#      configure is plain argparse: an option an older version does not declare makes
#      configure fail, so options newer than the oldest version we build cannot live
#      in the per-platform files - and an option only one platform should carry cannot
#      live in the version file either. Same reason as v8.extra_15.x.args.gn.
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
#   4. Applies two upstream build fixes that no released Node has yet (the block that
#      applies them says what each one is for). Both only matter for cross builds;
#      native builds are unaffected either way.
#
#   5. Replaces MSBuild's $(Platform) in deps/crates/crates.gyp with a gyp variable.
#      Node's own Windows build runs through gyp's MSVS generator, which expands
#      $(Platform); this build uses ninja, and ninja reads '$' as an escape character,
#      so it refuses the generated file before compiling anything.
#
#   6. Turns Temporal (the JS Temporal API, implemented in Rust under deps/crates)
#      into an explicit decision. ./configure enables it by default and, when cargo or
#      rustc is missing or too old, prints one warning line and builds a runtime
#      without it - so a bundle built on the wrong machine silently behaves differently
#      from Node's. Here it either fails the build or says out loud that it is off.
#
# Environment:
#   NODE_KEEP_NO_RTTI=1    leave -fno-rtti alone
#   NODE_KEEP_RDYNAMIC=1   leave -rdynamic alone
#   NODE_TEMPORAL=off      build without Temporal. Only for a platform whose Rust
#                          target cannot be built on this machine (for example before
#                          cargo has an Android NDK linker configured).
#   NODE_HOST_CPU=x64|arm64
#                          say what machine this build runs on, for the cases where
#                          `uname -m` lies: Git Bash on a Windows-on-ARM runner reports
#                          x86_64 on an arm64 machine. When this is unset, the script
#                          reads VSCMD_ARG_HOST_ARCH from Visual Studio's environment,
#                          which names it correctly, and only then falls back to uname.


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

# Version-specific arguments live in files next to this script, and both of these
# names are honoured:
#   node.extra_<major>.x.configure.txt            that major, every platform
#   node.extra_<major>.x.<dest-os>.configure.txt   that major, one platform
# The platform comes from the --dest-os= line in the args file: the file the job
# passes is a copy named args.txt, so that line is the only place the platform is
# still written.
DEST_OS="$(sed -n 's/^--dest-os=\(.*\)$/\1/p' "$ARGS_FILE" | head -n 1)"
extras=("node.extra_${NODE_MAJOR}.x.configure.txt")
if [ -n "$DEST_OS" ]; then
  extras+=("node.extra_${NODE_MAJOR}.x.${DEST_OS}.configure.txt")
fi
for name in "${extras[@]}"; do
  EXTRA="$SCRIPT_DIR/$name"
  if [ ! -f "$EXTRA" ]; then
    echo "prepare_node_build: no $name"
    continue
  fi
  MARKER="# appended by prepare_node_build.sh from $name"
  if grep -qF "$MARKER" "$ARGS_FILE"; then
    echo "prepare_node_build: $name already appended, skipping"
  else
    echo "prepare_node_build: appending $name"
    printf '\n%s\n' "$MARKER" >> "$ARGS_FILE"
    cat "$EXTRA" >> "$ARGS_FILE"
  fi
done

# --- ICU data has to be in the tree for full-icu -------------------------------
# full-icu is Node's default, and it is the only ICU mode whose data has to come
# with the source tree, so that is the case worth checking up front: a build that
# gets to the ICU step and then finds no data file wastes the whole compile first.
# These three greps look for arguments that the args file may legitimately not
# contain (defaults are applied below them). With `set -o pipefail`, a grep that
# matches nothing would otherwise end the script on its own, silently - and the
# script would die before printing anything useful.
intl_arg="$(grep -oE '^[[:space:]]*--with-intl=[a-z-]+' "$ARGS_FILE" | head -1 | tr -d '[:space:]' || true)"
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
dest_os="$(grep -oE '^[[:space:]]*--dest-os=[a-z]+' "$ARGS_FILE" | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)"
dest_cpu="$(grep -oE '^[[:space:]]*--dest-cpu=[a-z0-9]+' "$ARGS_FILE" | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)"

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

    # Two gyp variables only an Android build needs, handed to ./configure as extra
    # -D arguments (configure.py forwards unknown arguments straight to gyp). Both
    # come from upstream's own ./android-configure, which puts them in GYP_DEFINES;
    # they are not optional - without them gyp stops before writing anything:
    #
    #   android_ndk_path  common.gypi's OS=="android" branch adds
    #                     -I<(android_ndk_path)/sources/android/cpufeatures, and an
    #                     undefined variable is a hard gyp error:
    #                       gyp: Undefined variable android_ndk_path in node.gyp
    #   host_os           tools/v8_gypfiles/v8.gyp asks `_toolset=="host" and
    #                     host_os=="linux"` for the host toolset's linker flags, and
    #                     nothing else in the tree defines host_os:
    #                       gyp: name 'host_os' is not defined while evaluating
    #                       condition '_toolset=="host" and host_os=="linux"'
    #
    # The NDK path is read back out of the compiler this script already checked: the
    # wrapper compilers live in <ndk>/toolchains/llvm/prebuilt/<host>/bin/, so four
    # path components up is the NDK. That keeps one source of truth; the CI job and a
    # local run only have to say which compilers to use.
    ndk_compiler="${CC_target:-${CC:-}}"
    ndk_root=""
    case "$ndk_compiler" in
      */toolchains/llvm/prebuilt/*/bin/*)
        ndk_root="${ndk_compiler%/toolchains/llvm/prebuilt/*/bin/*}" ;;
    esac
    if [ -z "$ndk_root" ]; then
      echo "prepare_node_build: cannot work out the NDK root from the compiler:" >&2
      echo "  $ndk_compiler" >&2
      echo "  gyp needs the NDK path (common.gypi adds an include directory from it)," >&2
      echo "  and the wrapper compilers are expected at" >&2
      echo "  <ndk>/toolchains/llvm/prebuilt/<host>/bin/<triple><api>-clang." >&2
      exit 1
    fi
    if [ ! -d "$ndk_root/sources/android/cpufeatures" ]; then
      echo "prepare_node_build: $ndk_root/sources/android/cpufeatures does not exist." >&2
      echo "  common.gypi compiles against that header directory; the NDK at" >&2
      echo "  $ndk_root looks incomplete." >&2
      exit 1
    fi
    # host_os is the machine running the build, not the target: gyp's own name for
    # Linux is "linux" and for macOS "darwin" (the same pair android-configure sets).
    # This runs before the block below works out the host, so it is read here.
    case "$(uname -s)" in
      Linux)  android_host_os=linux ;;
      Darwin) android_host_os=darwin ;;
      *)
        echo "prepare_node_build: no gyp host_os name for $(uname -s)" >&2
        exit 1
        ;;
    esac
    printf -- '-Dandroid_ndk_path=%s\n' "$ndk_root" >> "$ARGS_FILE"
    printf -- '-Dhost_os=%s\n' "$android_host_os" >> "$ARGS_FILE"
    echo "prepare_node_build: gyp gets android_ndk_path=$ndk_root host_os=$android_host_os"

    # zlib's ARM feature probe calls android_getCpuFeatures(), and the NDK only ships
    # that as a source file (sources/android/cpufeatures/Android.mk builds it into a
    # module), so patches/godotjs-zlib-android-cpufeatures.patch adds it to the zlib
    # target. gyp cannot be handed an absolute source path, so the NDK's own file -
    # license header and all - is linked in beside the code that calls it.
    cpufeatures_link="$NODE_SRC/deps/zlib/android_cpu_features.c"
    rm -f "$cpufeatures_link"
    ln -s "$ndk_root/sources/android/cpufeatures/cpu-features.c" "$cpufeatures_link"
    echo "prepare_node_build: zlib's android_cpu_features.c -> $cpufeatures_link"

    # The NDK has to be new enough, and "which NDK" is the one question this script
    # cannot answer from the args file. V8 14.6 (what Node 26.13.1 embeds) uses
    # std::atomic_ref in deps/v8/src/base/memcopy.h, and the NDK's libc++ only
    # implements it from r29 (clang 21): with r26d (clang 17) and r28c (clang 19)
    # the C++20 <atomic> header has __cpp_lib_atomic_ref commented out, and every
    # V8 compile that reaches that header stops with
    #   error: no member named 'atomic_ref' in namespace 'std'
    # which is twenty minutes into a build and says nothing about the NDK. So ask
    # the compiler now: it costs about a second.
    atomic_probe="$(mktemp --suffix=.cc)"
    printf '#include <atomic>\n#include <cstddef>\ntemplate <typename T>\nvoid f(T* p, T v) {\n  std::atomic_ref<T>(*p).store(v, std::memory_order_relaxed);\n}\nint main() { int x = 0; f(&x, 1); return x; }\n' > "$atomic_probe"
    if ! probe_out="$("${CXX_target:-${CXX:-c++}}" -std=gnu++20 -fsyntax-only "$atomic_probe" 2>&1)"; then
      echo "prepare_node_build: this NDK's C++ standard library has no std::atomic_ref," >&2
      echo "  which V8 14.6 needs (deps/v8/src/base/memcopy.h). The compiler was" >&2
      echo "  ${CXX_target:-${CXX:-c++}} and it said:" >&2
      printf '%s\n' "$probe_out" | sed 's/^/    /' >&2
      echo "  Measured on the NDKs' libc++ headers: r26d (clang 17) and r28c (clang 19)" >&2
      echo "  do not define __cpp_lib_atomic_ref, r29 (clang 21) does. Use NDK r29 or" >&2
      echo "  newer for Android Node."
      rm -f "$atomic_probe"
      exit 1
    fi
    rm -f "$atomic_probe"
    echo "prepare_node_build: this NDK's libc++ has std::atomic_ref (V8 14.6 needs it)"

    # OpenSSL's generated configurations in the source tree cover linux, macOS,
    # Windows and friends (deps/openssl/config/archs/), but there is no android-*
    # directory there. That is what --openssl-no-asm in the args files is for.
    if ! ls "$NODE_SRC"/deps/openssl/config/archs/android* >/dev/null 2>&1; then
      echo "prepare_node_build: note - deps/openssl/config/archs has no android entry,"
      echo "  so OpenSSL's configuration for this target is not pre-generated; the"
      echo "  args file passes --openssl-no-asm for that reason."
    fi
    ;;
  ios)
    require_cross_toolchain ios \
"gyp has no ios flavour, so nothing derives an Apple toolchain for you: point these at wrapper compilers that bake in the SDK and the target triple. tools/apple_toolchain.sh writes them - for a device that is the iphoneos SDK with -target <arch>-apple-ios<version>, for the simulator the iphonesimulator SDK with a triple ending in -simulator - and build_node.yml calls it." \
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

# --- what machine is this, and is it a cross build -----------------------------
# Answering with uname -m is wrong on a Windows-on-ARM runner: Git Bash runs there under
# emulation and reports x86_64 on an arm64 machine. Getting this wrong is not cosmetic -
# a native arm64 build would look like a cross build, and Windows Temporal is refused
# for a cross build because deps/crates/crates.gyp names the Rust archive after the
# target architecture, which would collide between the two toolsets.
host_cpu="${NODE_HOST_CPU:-${VSCMD_ARG_HOST_ARCH:-}}"
case "$host_cpu" in
  x64|amd64|x86_64) host_cpu=x64 ;;
  arm64|aarch64) host_cpu=arm64 ;;
  *)
    host_cpu="$(uname -m)"
    case "$host_cpu" in x86_64|amd64) host_cpu=x64 ;; aarch64|arm64) host_cpu=arm64 ;; esac
    ;;
esac
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

# --- upstream build fixes no released Node has yet ------------------------------
# Both are merged upstream but land after 26.13.1, so they are carried under patches/.
#
#   node-66804-single-producer.patch (nodejs/node#66804) - in a cross build the host
#   toolset and the target toolset each register the shared generated files, so ninja
#   sees two producers for one output and refuses before compiling anything:
#
#     ninja: error: obj.host/tools/v8_gypfiles/v8_inspector_headers.ninja:26:
#     multiple rules generate gen/inspector-generated-output-root/src/js_protocol.stamp
#
#   node-66823-rust-host-target.patch (nodejs/node#66823) - the same duplicate producer
#   problem for the Rust archive Temporal is built from: one cargo action served both
#   toolsets and both wanted the same node_crates path. The fix gives each toolset its
#   own Rust target triple and output directory, and it is why a cross build now has to
#   be told CARGO_BUILD_TARGET (see the Temporal block below).
#
# Both were checked on 26.13.1 with a same-OS cross configure (linux x86_64 host,
# --dest-cpu=arm64): without them ninja refuses, with them the graph parses, and a
# native configure still parses afterwards.
apply_build_patch() {
  # $1 patch file, $2 name used in the log, $3 = cross (needed for cross builds only)
  # or always.
  local patch="$1" label="$2" policy="$3" plain
  if [ ! -f "$patch" ]; then
    echo "prepare_node_build: $label: patch file not found at $patch" >&2
    exit 1
  fi
  # A checkout on Windows converts text files to CRLF (core.autocrlf=true is that
  # platform's default), and git then reads the patch as garbage: neither the forward
  # nor the reverse check fits, which is indistinguishable from an out-of-date patch.
  # Apply a copy with the carriage returns taken out.
  plain="$(mktemp)"
  tr -d '\r' < "$patch" > "$plain"
  if ( cd "$NODE_SRC" && git apply --check -p1 "$plain" ) >/dev/null 2>&1; then
    ( cd "$NODE_SRC" && git apply -p1 "$plain" )
    echo "prepare_node_build: applied $label"
  elif ( cd "$NODE_SRC" && git apply --reverse --check -p1 "$plain" ) >/dev/null 2>&1; then
    echo "prepare_node_build: $label is already in this Node source"
  elif [ "$policy" = always ] || [ "$cross_build" = 1 ]; then
    echo "prepare_node_build: $label fits neither forward nor in reverse." >&2
    echo "  Either this Node version carries it in a changed form, or $patch needs" >&2
    echo "  updating (host $host_os/$host_cpu -> ${dest_os:-same os}/${dest_cpu:-same cpu})." >&2
    rm -f "$plain"
    exit 1
  else
    echo "prepare_node_build: $label does not apply to this Node source; a native build"
    echo "  does not need it, so continuing."
  fi
  rm -f "$plain"
}

# --- Windows: clang-cl has to be named, ninja will not guess it ------------------
# Node 24 and newer are built on Windows with clang-cl, and ./configure --clang-cl=<v>
# only records the toolchain in the generated config; the compiler is chosen by gyp.
# The hook that lets gyp be told (patches/godotjs-gyp-win-clang-cl.patch) reads the
# path from GODOTJS_NODE_CLANG_CL, so stopping here is what keeps a Windows bundle
# from being built with cl.exe - which upstream no longer supports.
if [ "$dest_os" = win ] && [ -z "${GODOTJS_NODE_CLANG_CL:-}" ]; then
  echo "prepare_node_build: --dest-os=win needs GODOTJS_NODE_CLANG_CL set to the" >&2
  echo "  absolute path of clang-cl, for example:" >&2
  echo "    GODOTJS_NODE_CLANG_CL='C:\\Program Files\\Microsoft Visual Studio\\2022\\Enterprise\\VC\\Tools\\Llvm\\x64\\bin\\clang-cl'"
  echo "  Without it gyp keeps using cl.exe, and Node 24 and newer cannot be built"
  echo "  with cl.exe (V8 dropped MSVC support after version 13.0)."
  echo "  The value must end in clang-cl, and .exe has to be left off."
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "prepare_node_build: git is needed to apply the patches under patches/" >&2
  exit 1
fi
apply_build_patch "$SCRIPT_DIR/patches/node-66804-single-producer.patch" \
                  "nodejs/node#66804 (single producer for shared generated files)" cross
apply_build_patch "$SCRIPT_DIR/patches/node-66823-rust-host-target.patch" \
                  "nodejs/node#66823 (per-toolset Rust archives for Temporal cross builds)" cross
apply_build_patch "$SCRIPT_DIR/patches/godotjs-node-crates-win-synchronization.patch" \
                  "our crates fix that names Synchronization.lib for the Rust standard library" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-node-libffi-win-arm64-link-obj.patch" \
                  "our libffi fix that puts the Windows/arm64 assembly object where dependents link it" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-node-abseil-ios-corefoundation.patch" \
                  "our abseil fix that names CoreFoundation for an iOS build" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-node-js2c-ios-frameworks.patch" \
                  "our js2c fix that names the frameworks its objects need on an iOS build" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-gyp-win-clang-cl.patch" \
                  "our gyp hook that lets ninja use clang-cl on Windows" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-gyp-win-host-toolset.patch" \
                  "our gyp fix that keeps the Windows host tools on the build machine" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-zlib-android-cpufeatures.patch" \
                  "our zlib fix that compiles the Android CPU feature probe" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-v8-trap-handler-host-toolset.patch" \
                  "our V8 fix that gives a cross build's host toolset the posix trap handler" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-gyp-win-rsp-path-arg.patch" \
                  "our gyp fix that keeps option values and C-string defines out of path normalization" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-gyp-win-pch-path.patch" \
                  "our gyp fix that spells the Windows precompiled header path for ninja" always
apply_build_patch "$SCRIPT_DIR/patches/godotjs-v8-snapshot-asm-to-cc.patch" \
                  "our V8 fix that stops assembling the snapshot blob twice on clang-cl" always

# --- Windows: torque cannot be handed backslash-separated paths ------------------
# On Windows gyp writes an action's whole command line into a .rsp file, and while
# doing that it rewrites every argument that looks like a path with
# os.path.normpath, so torque is given "src\objects\torque-defined-classes.tq"
# where the build file said "src/objects/torque-defined-classes.tq".
#
# torque identifies source files by those strings and compares them, and two of the
# comparisons are written into torque's own source: the file every non-exported
# Torque class is attributed to, and the "test/" prefix (deps/v8/src/torque/
# types.cc, ClassType::AttributedToFile). The backslash spelling matches neither,
# so the definitions for the non-exported classes are attributed nowhere and
# gen/torque-generated/src/objects/torque-defined-classes-tq.inc is left at 0 bytes
# while torque reports success. Everything that includes that header then fails,
# half an hour later, with "incomplete type" errors about exactly those classes.
#
# Node's own Windows build does not hit this because it uses the MSBuild generator,
# whose action command lines never go through that rewriting; --ninja on Windows is
# the combination that does.
#
# The fix canonicalizes separators at the one place source paths are registered.
# Measured on 26.13.1 (linux x86_64): without the patch, torque given backslash
# spellings cannot even open its inputs; with it, both spellings produce the same
# attribution file the build produces (62651 bytes, 1283 lines, 42 class
# definitions), so normal builds are byte-for-byte unaffected.
apply_build_patch "$SCRIPT_DIR/patches/godotjs-torque-path-separator.patch" \
                  "our torque fix for backslash-separated source paths" always

# --- Windows: the built-in scripts got names that are not valid identifiers ------------
# js2c writes node_javascript.cc, one C array per built-in JavaScript file, and it makes
# each array's name from the file's path: deps/acorn/acorn_walk/dist/walk.mjs becomes
# internal_deps_acorn_acorn_walk_dist_walk_raw. On Windows ninja passes the action's
# arguments through a response file and gyp normalizes separators writing it, so js2c is
# handed deps\acorn\acorn_walk\dist\walk.mjs: the "deps/" prefix is no longer recognised,
# the backslashes are not turned into "_", and the generated C++ reads
# "static const uint8_t deps\acorn\...\walk_raw[]", which clang-cl rejects.
#
# Measured here by rebuilding the tool and running it on the real argument list: with the
# patch, the output is byte-identical to today's (42f5d0c5894c020a) whether the paths are
# given with slashes or with backslashes, so only the broken spelling changes behaviour.
apply_build_patch "$SCRIPT_DIR/patches/godotjs-js2c-win-path-separator.patch" \
                  "our js2c fix for backslash-separated source paths" always

# --- Windows: the assembled OpenSSL assembly never reached the library ----------------
# OpenSSL's fast paths are hand-written assembly. On Windows those .asm files are in
# nasm syntax, so gyp builds them with a rule that runs nasm and writes one .obj per
# file (39 of them for VC-WIN64A). In a ninja file, a rule's output only joins the
# target's objects if the rule declares process_outputs_as_sources, and Node's rules
# do not - so ninja assembled every .asm and then archived openssl.lib without any
# of those objects in it. Nothing warns: on 26.13.1 windows/x86_64 the build reached
# 3829/4234 with all the assembly assembled, and then openssl-cli.exe failed to link
# with 155 unresolved external symbols (OPENSSL_cleanse, aesni_encrypt,
# OPENSSL_ia32cap_P, ChaCha20_ctr32, ...), every one of them defined only in that
# assembly. Node's own Windows build is unaffected because it goes through MSBuild,
# which wires a rule's outputs into the project by a different mechanism.
#
# gyp's ninja generator does accept object files in a target's sources - it has a
# branch for "actions/rules output 'sources' that are already object files" - so
# setting the flag is the intended switch rather than a workaround, and the other
# generators (make, cmake, xcode, msvs) read the same flag.
apply_build_patch "$SCRIPT_DIR/patches/godotjs-openssl-win-asm-outputs-as-sources.patch" \
                  "our gyp fix that puts the assembled OpenSSL objects in the library" always

# --- Windows: /WHOLEARCHIVE named the MSBuild location, ninja writes obj/ ----------
# Four executables link static libraries through MSVC's /WHOLEARCHIVE so their contents
# are kept. node.gyp and node.gypi write those flag strings as
# <(PRODUCT_DIR)/lib/<name>.lib, which is where MSBuild puts a static library; the ninja
# generator puts the same libraries under obj/<its directory>/, and the linker then stops
# with "LNK1356: cannot find library `lib/zlib.lib' specified to be whole archived". The
# rest of that link is fine because the real obj/ libraries are already inputs of the same
# step - only this flag pointed somewhere else. The patch picks the spelling with
# GENERATOR == "ninja", the same test common.gypi uses for obj_dir, so an MSBuild build
# keeps exactly the flags it has today.
apply_build_patch "$SCRIPT_DIR/patches/godotjs-node-win-ninja-wholearchive-obj-paths.patch" \
                  "our fix that points /WHOLEARCHIVE at the ninja output directory" always

# --- MSBuild's $(Platform) cannot survive into a ninja file ---------------------
# deps/crates/crates.gyp builds the Rust side of Temporal. On Windows it names the
# output directory and passes the platform to deps/crates/cargo_build.py with
# $(Platform), which is an MSBuild variable: gyp expands it only for the MSVS
# generator that ./vcbuild.bat uses, and with --ninja it reaches the .ninja file as
# written, where '$' is an escape character:
#
#   ninja: error: obj\deps\crates\node_crates.ninja:19: bad $-escape
#     (literal $ must be written as $$)
#         "cargo_build.py" "$(Platform)" "..\..\out\Release\gen" "--release"...
#
# Node's own Windows CI does not use ninja, which is why this is still upstream's and
# not a fixed thing. gyp's ninja generator even asserts that a path holds no '$'
# (AssertionError: .../gen/$(Platform)/release/node_crates.lib), so the same source
# fails in two places depending on where the '$' lands.
#
# <(target_arch) is 'x64' or 'arm64' on Windows - exactly the two values
# cargo_build.py's platform argument accepts, and the directory it copies
# node_crates.lib into - so the action and the library path stay a matching pair.
python3 - "$NODE_SRC/deps/crates/crates.gyp" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print('prepare_node_build: no deps/crates/crates.gyp here, nothing to patch')
    sys.exit(0)

text = path.read_text(encoding='utf-8')
count = text.count('$(Platform)')
if count == 0:
    print('prepare_node_build: crates.gyp has no MSBuild $(Platform) left, nothing to do')
    sys.exit(0)

path.write_text(text.replace('$(Platform)', '<(target_arch)'), encoding='utf-8')
left = path.read_text(encoding='utf-8').count('$(Platform)')
if left:
    print(f'prepare_node_build: {left} $(Platform) still in crates.gyp after patching',
          file=sys.stderr)
    sys.exit(1)
print(f'prepare_node_build: patched crates.gyp: {count} x $(Platform) -> <(target_arch)')
PY

# --- Temporal: the Rust part of V8 must not be dropped by accident --------------
# Temporal is a JavaScript API, implemented in Rust under deps/crates, and ./configure
# enables it by default. If cargo or rustc is missing it prints one line and carries on
# without it:
#
#   warn: cargo not found! Support for Temporal will be disabled.
#
# The result is a bundle from the same source whose `Temporal` global does not exist,
# which is a runtime discovery rather than a build one, and it is exactly what happens
# on a machine that has no Rust toolchain installed. So the flag is passed explicitly:
# with --v8-enable-temporal-support, configure stops with an error instead of warning.
# A cross build needs CARGO_BUILD_TARGET as well, for the same reason and with the same
# silent default, since nodejs/node#66823.
case "${NODE_TEMPORAL:-on}" in
  on)
    if grep -qE '^[[:space:]]*--v8-disable-temporal-support' "$ARGS_FILE"; then
      echo "prepare_node_build: $ARGS_FILE already passes --v8-disable-temporal-support," >&2
      echo "  which contradicts building with Temporal. Remove that line, or run with" >&2
      echo "  NODE_TEMPORAL=off to build without it on purpose." >&2
      exit 1
    fi
    if ! grep -qE '^[[:space:]]*--v8-enable-temporal-support' "$ARGS_FILE"; then
      printf '%s\n' '--v8-enable-temporal-support' >> "$ARGS_FILE"
    fi

    version_ok() {
      # $1 = command, $2 = minimum as MAJOR.MINOR. Both print "tool 1.93.1 (...)".
      local tool="$1" min="$2" line major minor min_major min_minor
      line="$("$tool" --version 2>/dev/null | head -1 || true)"
      major="$(printf '%s' "$line" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1 || true)"
      minor="$(printf '%s' "$line" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f2 || true)"
      min_major="${min%.*}"
      min_minor="${min#*.}"
      if [ -z "$major" ] || [ -z "$minor" ]; then
        return 1
      fi
      if [ "$major" -gt "$min_major" ] ||
         { [ "$major" -eq "$min_major" ] && [ "$minor" -ge "$min_minor" ]; }; then
        return 0
      fi
      return 1
    }

    cargo_bin="${CARGO:-cargo}"
    rustc_bin="${RUSTC:-rustc}"
    for tool in "$cargo_bin" "$rustc_bin"; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        echo "prepare_node_build: '$tool' is not installed, and Temporal needs it." >&2
        echo "  configure would warn and build a runtime without the Temporal API. Install" >&2
        echo "  a Rust toolchain (cargo and rustc 1.86 or newer, per BUILDING.md), or set" >&2
        echo "  NODE_TEMPORAL=off to build without Temporal on purpose." >&2
        exit 1
      fi
      if ! version_ok "$tool" 1.86; then
        echo "prepare_node_build: $($tool --version 2>/dev/null | head -1) is too old for" >&2
        echo "  Temporal (needs cargo and rustc 1.86 or newer). configure would warn and" >&2
        echo "  build without it; set NODE_TEMPORAL=off if that is what is wanted." >&2
        exit 1
      fi
    done

    cargo_line="$("$cargo_bin" --version 2>/dev/null | head -1 || true)"
    # Windows is the one platform Node's own fix cannot serve. The per-toolset output
    # directories node-66823-rust-host-target.patch adds are skipped for the Windows
    # flavour, and the Windows branch of deps/crates/crates.gyp names its archive
    # after <(target_arch) - the same name in the host and the target toolset - so
    # ninja refuses before compiling anything, with
    #   multiple rules generate gen/arm64/release/node_crates.lib
    # Saying it here costs seconds instead of a configure run. Building Windows on a
    # Windows machine of the same architecture has no split toolset and so no collision.
    if [ "$dest_os" = win ] && [ -n "$dest_cpu" ] && [ "$dest_cpu" != "$host_cpu" ]; then
      echo "prepare_node_build: Temporal cannot be built for a Windows cross build"
      echo "  ($host_cpu machine building --dest-cpu=$dest_cpu)." >&2
      echo "  deps/crates/crates.gyp names the Rust archive after the target"
      echo "  architecture, which is the same path for the host and the target toolset,"
      echo "  so ninja stops with 'multiple rules generate ... node_crates.lib'."
      echo "  The fix this script carries from Node skips Windows on purpose."
      echo "  Either build on a Windows machine of the target architecture, or set"
      echo "  NODE_TEMPORAL=off: the manifest and the bundle check then record and"
      echo "  enforce that this bundle has no Temporal API."
      exit 1
    fi
    if [ "$cross_build" = 1 ]; then
      if [ -z "${CARGO_BUILD_TARGET:-}" ]; then
        echo "prepare_node_build: this is a cross build, so configure needs" >&2
        echo "  CARGO_BUILD_TARGET set to the Rust target triple of the target platform" >&2
        echo "  (for example aarch64-unknown-linux-gnu, x86_64-apple-darwin," >&2
        echo "  aarch64-apple-ios, aarch64-linux-android). Without it, configure warns and" >&2
        echo "  builds without Temporal. Set NODE_TEMPORAL=off to do that on purpose." >&2
        exit 1
      fi
      # rustc happily prints a libdir for a target that is not installed, so the
      # directory has to be looked at; installing it is `rustup target add <triple>`.
      if [ ! -d "$("$rustc_bin" --print target-libdir --target "$CARGO_BUILD_TARGET" 2>/dev/null)" ]; then
        echo "prepare_node_build: the Rust target '$CARGO_BUILD_TARGET' is not installed" >&2
        echo "  for $rustc_bin, so cargo could not build Temporal for it." >&2
        echo "  Install it (rustup target add $CARGO_BUILD_TARGET) or set NODE_TEMPORAL=off." >&2
        exit 1
      fi
      echo "prepare_node_build: Temporal on, $cargo_line, Rust target $CARGO_BUILD_TARGET"
    else
      echo "prepare_node_build: Temporal on, $cargo_line"
    fi

    ;;
  off)
    if grep -qE '^[[:space:]]*--v8-enable-temporal-support' "$ARGS_FILE"; then
      echo "prepare_node_build: $ARGS_FILE passes --v8-enable-temporal-support, which" >&2
      echo "  asks configure to fail when Temporal cannot be built - the opposite of" >&2
      echo "  NODE_TEMPORAL=off. Remove that line, or unset NODE_TEMPORAL." >&2
      exit 1
    fi
    if ! grep -qE '^[[:space:]]*--v8-disable-temporal-support' "$ARGS_FILE"; then
      printf '%s\n' '--v8-disable-temporal-support' >> "$ARGS_FILE"
    fi
    echo "prepare_node_build: NODE_TEMPORAL=off - this bundle has NO JavaScript Temporal"
    echo "  API; the published notes for this bundle have to say so."
    ;;
  *)
    echo "prepare_node_build: NODE_TEMPORAL must be 'off' or unset (got '$NODE_TEMPORAL')." >&2
    exit 2
    ;;
esac

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
