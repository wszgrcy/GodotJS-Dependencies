#!/usr/bin/env bash
#
# Write the compiler wrappers an Apple-targeted Node build needs, and print the
# environment variables that point Node's ./configure at them.
#
#   bash tools/apple_toolchain.sh --platform ios --arch arm64 --out-dir "$RUNNER_TEMP/xc"
#   eval "$(bash tools/apple_toolchain.sh --platform macos --arch x86_64 --out-dir ...)"
#
# Why wrappers at all: gyp takes the target compiler as one program path (CC_target),
# never as a path plus flags, so the flags that pick the platform - the SDK path and
# the target triple - have to live inside a program. CI writes these into the runner's
# temp directory and puts the printed lines into $GITHUB_ENV.
#
# The flags are not decoration. Without -target, a build of the same macOS clang is
# used for the host's architecture; without -isysroot, the SDK's headers and libraries
# are not found at all. For iOS the deployment target has to be part of the triple
# (-ios16.0), because -mmacosx-version-min means macOS there, and iOS also gets
# -std=gnu++20 and -fno-exceptions in its C++ wrappers, because gyp reads Node's
# C++ standard from xcode_settings for the mac flavour only - see the comment by
# cxx_flags below.
#
# Options:
#   --platform ios|macos        which Apple platform the bundle is for
#   --arch arm64|x86_64         the target architecture (aarch64 is read as arm64)
#   --out-dir DIR               where the wrapper scripts are written (required)
#   --xcrun PATH                the xcrun to use (default: $GODOTJS_XCRUN, then xcrun on PATH)
#   --sdk-path PATH             SDK directory; skips the xcrun query (used by the fake-SDK test)
#   --sdk-name NAME             SDK name to ask xcrun for (default: iphoneos, or
#                               iphonesimulator with --simulator, or macosx)
#   --simulator                 iOS simulator: iphonesimulator SDK and a -simulator triple
#   --deployment-target V       e.g. 16.0. iOS defaults to 16.0; on macOS nothing is
#                               added unless this is given, so the SDK's own default
#                               and MACOSX_DEPLOYMENT_TARGET keep working.
#   --rust-triple TRIPLE        cargo target triple, when the build has Temporal; a
#                               CC_<triple> line is printed for each so cargo and rustc's
#                               build scripts use the same wrapper as Node
#
# Every printed line is KEY=value and goes to stdout; explanations go to stderr.
set -euo pipefail

platform=""
arch=""
out_dir=""
xcrun="${GODOTJS_XCRUN:-xcrun}"
sdk_path=""
sdk_name=""
simulator=0
deployment=""
rust_triple=""

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="$2"; shift 2 ;;
    --arch) arch="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --xcrun) xcrun="$2"; shift 2 ;;
    --sdk-path) sdk_path="$2"; shift 2 ;;
    --sdk-name) sdk_name="$2"; shift 2 ;;
    --simulator) simulator=1; shift ;;
    --deployment-target) deployment="$2"; shift 2 ;;
    --rust-triple) rust_triple="$2"; shift 2 ;;
    -h|--help) sed -n '3,35p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)
      echo "apple_toolchain: unknown argument $1" >&2
      exit 1
      ;;
  esac
done

[ -n "$platform" ] || { echo "apple_toolchain: --platform is required" >&2; exit 1; }
[ -n "$arch" ] || { echo "apple_toolchain: --arch is required" >&2; exit 1; }
[ -n "$out_dir" ] || { echo "apple_toolchain: --out-dir is required" >&2; exit 1; }

apple_arch="$arch"
case "$apple_arch" in
  aarch64) apple_arch=arm64 ;;
  arm64|x86_64) ;;
  *)
    echo "apple_toolchain: no Apple architecture name for '$arch'." >&2
    echo "  Apple builds are arm64 or x86_64; 32-bit iOS is not supported by Node 26." >&2
    exit 1
    ;;
esac

case "$platform" in
  ios)
    if [ "$simulator" -eq 1 ]; then
      [ -n "$sdk_name" ] || sdk_name=iphonesimulator
    else
      [ -n "$sdk_name" ] || sdk_name=iphoneos
    fi
    [ -n "$deployment" ] || deployment=16.0
    triple="$apple_arch-apple-ios$deployment"
    # The simulator's binaries carry a -simulator system in their triple; without it
    # clang builds a device binary and the linker then pulls device-only libraries.
    [ "$simulator" -eq 1 ] && triple="$triple-simulator"
    framework_link="-framework Foundation"
    ;;
  macos)
    [ -n "$sdk_name" ] || sdk_name=macosx
    # macOS picks its SDK up on its own, so a plain -arch is all the wrapper needs -
    # exactly what the build did before this script existed. The deployment target
    # comes from MACOSX_DEPLOYMENT_TARGET in the job's environment, unless
    # --deployment-target is given here, which then sets it explicitly.
    triple="$apple_arch-apple-macosx"
    [ -n "$deployment" ] && triple="$triple$deployment"
    framework_link=""
    ;;
  *)
    echo "apple_toolchain: --platform must be ios or macos, got '$platform'." >&2
    exit 1
    ;;
esac

# Apple's toolchain only exists on a macOS runner. Say so here instead of letting the
# build fail on the first compile line.
if ! command -v "$xcrun" >/dev/null 2>&1; then
  echo "apple_toolchain: '$xcrun' was not found." >&2
  echo "  xcrun ships with Xcode's command line tools, so an Apple build can only run" >&2
  echo "  on a macOS runner (macos-latest / macos-26 / macos-15...). There is no way" >&2
  echo "  to produce a Mach-O bundle from Linux: the SDKs are not redistributable" >&2
  echo "  outside Xcode, and no Linux compiler targets Apple's ABI by default." >&2
  exit 1
fi

if [ -z "$sdk_path" ]; then
  sdk_path="$("$xcrun" --sdk "$sdk_name" --show-sdk-path 2>/dev/null || true)"
  if [ -z "$sdk_path" ]; then
    echo "apple_toolchain: xcrun has no SDK named '$sdk_name'." >&2
    echo "  Available: $(xcrun --show-sdk-path 2>&1 || true)" >&2
    echo "  On a runner this usually means the Xcode version or the license consent is" >&2
    echo "  wrong: run 'sudo xcodebuild -license accept' and 'sudo xcode-select -s'." >&2
    exit 1
  fi
fi
if [ ! -d "$sdk_path" ]; then
  echo "apple_toolchain: SDK directory does not exist: $sdk_path" >&2
  exit 1
fi

mkdir -p "$out_dir"

# The toolchain wrappers. Each one is three lines and bakes in only what identifies
# the platform; everything else is passed through untouched, so gyp's own flags -
# -arch, -isysroot from xcode_emulation, -target triplets it writes itself - still
# reach the compiler and can override these if they are later on the command line.
write_wrapper() {
  name="$1"; shift
  {
    printf '#!/bin/sh\n'
    printf '# Generated by tools/apple_toolchain.sh - edit the script, not this file.\n'
    printf 'exec'
    for word in "$@"; do printf ' %s' "$word"; done
    printf ' "$@"\n'
  } > "$out_dir/$name"
  chmod +x "$out_dir/$name"
}

# For iOS the SDK has to be named: gyp has no ios flavour at all, so nothing else in
# the build knows where the headers are. For macOS the SDK is found on its own and
# only -arch is missing, so passing -isysroot here would only pin a path the toolchain
# already picks correctly.
platform_flags=( -target "$triple" )
if [ "$platform" = ios ]; then
  platform_flags+=( -isysroot "$sdk_path" )
else
  # -target already picks the architecture, but the build worked with -arch before
  # this script existed and gyp leaves -arch out of its own flags when it thinks it
  # is cross-compiling, so name it explicitly rather than rely on the triple alone.
  platform_flags+=( -arch "$apple_arch" )
fi

# Node does not say which C++ standard to use with a compiler flag: it says it through
# gyp's xcode_settings (common.gypi, in the mac block: CLANG_CXX_LANGUAGE_STANDARD =
# gnu++20 and GCC_ENABLE_CPP_EXCEPTIONS = NO), and gyp's ninja generator reads those
# settings only for the mac flavour (tools/gyp/pylib/gyp/generator/ninja.py, the line
# `if self.flavor == "mac"`). --dest-os=ios makes the flavour "ios", so no -std= ever
# reaches the compiler and the first C++ file stops in deps/v8/include/v8config.h with
# "C++20 or later required." - on the host toolset too, because those settings belong to
# the target, not to the toolset. The wrappers are the only way in for iOS, so the C++
# ones carry both flags. macOS needs nothing here: its flavour is mac and gyp adds them.
cxx_flags=()
if [ "$platform" = ios ]; then
  cxx_flags=( -std=gnu++20 -fno-exceptions )
fi

write_wrapper cc   "$xcrun" --sdk "$sdk_name" clang "${platform_flags[@]}"
write_wrapper cxx  "$xcrun" --sdk "$sdk_name" clang++ "${platform_flags[@]}" ${cxx_flags[@]+"${cxx_flags[@]}"}
write_wrapper ar   "$xcrun" --sdk "$sdk_name" ar
write_wrapper nm   "$xcrun" --sdk "$sdk_name" nm
write_wrapper libtool "$xcrun" --sdk "$sdk_name" libtool
write_wrapper lipo "$xcrun" --sdk "$sdk_name" lipo
write_wrapper strip "$xcrun" --sdk "$sdk_name" strip
write_wrapper otool "$xcrun" --sdk "$sdk_name" otool

# The host toolset keeps the runner's own compiler (it has to produce programs that run
# here), but on iOS it still needs the C++ standard above, and gyp would call a bare
# `c++` with nothing in front of it. Same reason as the target wrapper: flags first, so
# anything gyp adds later still wins.
if [ "$platform" = ios ]; then
  write_wrapper host_cxx c++ ${cxx_flags[@]+"${cxx_flags[@]}"}
fi

echo "apple_toolchain: $platform $apple_arch, triple $triple, SDK $sdk_path" >&2

{
  printf 'CC_target=%s\n' "$out_dir/cc"
  printf 'CXX_target=%s\n' "$out_dir/cxx"
  printf 'AR_target=%s\n' "$out_dir/ar"
  printf 'NM_target=%s\n' "$out_dir/nm"
  printf 'LIBTOOL=%s\n' "$out_dir/libtool"
  printf 'LIPO=%s\n' "$out_dir/lipo"
  printf 'STRIP=%s\n' "$out_dir/strip"
  # The host toolset - mksnapshot, torque, the programs the build runs on the runner
  # itself - has to be built by the runner's own compiler, or none of them can start.
  # For iOS that compiler still needs the C++ standard, so it goes through host_cxx,
  # which only adds those flags and nothing that would aim it at the SDK.
  printf 'CC_host=cc\n'
  if [ "$platform" = ios ]; then
    printf 'CXX_host=%s\n' "$out_dir/host_cxx"
  else
    printf 'CXX_host=c++\n'
  fi
  printf 'NODE_VERIFY_CXX=%s\n' "$out_dir/cxx"
  if [ -n "$framework_link" ]; then
    printf 'NODE_VERIFY_EXTRA_LINK=%s\n' "$framework_link"
  fi
  if [ -n "$rust_triple" ]; then
    # Cargo's build scripts look up CC_<target with dashes as underscores> first and
    # only then CC, so name it: otherwise a -sys crate in the Temporal tree compiles
    # with the plain host compiler and the host's SDK.
    underline="${rust_triple//-/_}"
    printf 'CC_%s=%s\n' "$underline" "$out_dir/cc"
    printf 'CXX_%s=%s\n' "$underline" "$out_dir/cxx"
    printf 'AR_%s=%s\n' "$underline" "$out_dir/ar"
  fi
}
