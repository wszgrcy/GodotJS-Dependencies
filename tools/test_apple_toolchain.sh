#!/usr/bin/env bash
#
# Check tools/apple_toolchain.sh on any machine, without Xcode.
#
#   bash tools/test_apple_toolchain.sh
#
# The Apple builds run on macOS runners, which cannot be used from a Linux machine, so
# the part that keeps breaking - the wrapper compilers that carry the SDK path and the
# target triple - is exercised here against a stand-in SDK and a stand-in xcrun. The
# stand-in xcrun does not compile; it writes the command line it was given to a log,
# which is what makes it possible to assert what the real compiler would have received.
#
# What is checked, and why each one has earned its place:
#   - the wrapper bakes in -target and, for iOS, -isysroot: without them the build
#     silently compiles for the runner's own platform;
#   - the device and simulator SDKs, and the -simulator suffix in the triple: a
#     simulator binary built with the device triple links device-only libraries;
#   - CC_host: the build-time programs (mksnapshot, torque) must run on the runner;
#   - -std=gnu++20 and -fno-exceptions on iOS only: gyp takes Node's C++ standard from
#     xcode_settings for the mac flavour, so with --dest-os=ios nothing else in the
#     build names a C++ standard and V8's own header stops the compile;
#   - cargo's CC_<target> variables: a -sys crate in the Temporal tree would otherwise
#     be compiled against the host's SDK;
#   - argument passthrough, because gyp adds its own flags after these ones.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo/tools/apple_toolchain.sh"
[ -f "$script" ] || { echo "no such script: $script" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stand-in SDKs. The directories are the ones Node's build and clang look for; the
# files inside only have to exist, because nothing is compiled.
make_sdk() {
  mkdir -p "$1/usr/include" "$1/usr/lib" "$1/System/Library/Frameworks"
  printf 'stand-in sdk\n' > "$1/usr/include/stand-in.h"
}
fake_ios="$tmp/iPhoneOS.sdk"
fake_sim="$tmp/iPhoneSimulator.sdk"
fake_mac="$tmp/MacOSX.sdk"
make_sdk "$fake_ios"
make_sdk "$fake_sim"
make_sdk "$fake_mac"

fake_xcrun="$tmp/xcrun"
cat > "$fake_xcrun" <<'SH'
#!/usr/bin/env bash
# Stand-in xcrun: answers the SDK queries from environment variables and records every
# tool invocation so the test can read it back.
set -euo pipefail
sdk=""
rest=()
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --sdk) sdk="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    *) rest+=("${args[$i]}"); i=$((i + 1)) ;;
  esac
done
case "${rest[0]}" in
  --show-sdk-path)
    case "$sdk" in
      iphoneos)        printf '%s\n' "$FAKE_IPHONEOS_SDK" ;;
      iphonesimulator) printf '%s\n' "$FAKE_IPHONESIMULATOR_SDK" ;;
      macosx)          printf '%s\n' "$FAKE_MACOSX_SDK" ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
  --show-sdk-version) printf '18.2\n'; exit 0 ;;
esac
printf '%s\n' "${rest[*]}" >> "$FAKE_XCRUN_LOG"
SH
chmod +x "$fake_xcrun"

export FAKE_IPHONEOS_SDK="$fake_ios"
export FAKE_IPHONESIMULATOR_SDK="$fake_sim"
export FAKE_MACOSX_SDK="$fake_mac"

fails=0
ok() { echo "ok - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
contains() { # contains <label> <file> <fixed-string>
  if grep -qF -- "$3" "$2"; then ok "$1"; else
    bad "$1"
    echo "       wanted [$3] in $2, which says:"
    sed 's/^/       | /' "$2" | head -6
  fi
}
absent() { # absent <label> <file> <fixed-string>
  if grep -qF -- "$3" "$2"; then
    bad "$1"
  else
    ok "$1"
  fi
}
is_exec() {
  if [ -x "$2" ]; then ok "$1"; else bad "$1 ($2 is not executable)"; fi
}

outdir_of() { printf '%s' "$tmp/bin-$1"; }
run_case() { # run_case <label> <args...>
  local label="$1"; shift
  : > "$tmp/xcrun-log-$label"
  # Exported, not just prefixed, because the test also calls the generated wrappers
  # directly afterwards, and those have to log to the same place.
  export FAKE_XCRUN_LOG="$tmp/xcrun-log-$label"
  bash "$script" --xcrun "$fake_xcrun" --out-dir "$(outdir_of "$label")" "$@" \
    > "$tmp/env-$label" 2> "$tmp/err-$label"
}

# ---------------------------------------------------------------- iPhoneOS device
run_case ios --platform ios --arch arm64 --sdk-path "$fake_ios" \
  --rust-triple aarch64-apple-ios
d="$(outdir_of ios)"
is_exec "cc wrapper" "$d/cc"
is_exec "cxx wrapper" "$d/cxx"
is_exec "ar wrapper" "$d/ar"
is_exec "libtool wrapper" "$d/libtool"
is_exec "strip wrapper" "$d/strip"
contains "device triple with deployment target" "$d/cxx" "-target arm64-apple-ios16.0"
contains "iPhoneOS sysroot" "$d/cxx" "-isysroot $fake_ios"
# Without these two the compile never gets past v8config.h ("C++20 or later required."),
# because gyp only turns Node's xcode_settings into flags for the mac flavour.
contains "iOS C++ names the standard Node asks for" "$d/cxx" "-std=gnu++20"
contains "iOS C++ is built without exceptions, like the other platforms" "$d/cxx" "-fno-exceptions"
contains "host C++ goes through a wrapper on iOS" "$tmp/env-ios" "CXX_host=$d/host_cxx"
is_exec "host cxx wrapper" "$d/host_cxx"
contains "host C++ gets the same standard" "$d/host_cxx" "-std=gnu++20"
absent "host C++ stays off the iOS SDK" "$d/host_cxx" "-isysroot"
absent "host C++ keeps the runner's own platform" "$d/host_cxx" "-target"
contains "host C stays the runner's plain cc" "$tmp/env-ios" "CC_host=cc"

# Call the wrapper and look at what the real compiler would have been given.
"$d/cc" -c some.c
contains "the compiler is called through xcrun" "$tmp/xcrun-log-ios" "clang -target arm64-apple-ios16.0"
contains "the compiler gets the sysroot" "$tmp/xcrun-log-ios" "-isysroot $fake_ios"
contains "the compiler gets the caller's own flags" "$tmp/xcrun-log-ios" "-c some.c"

contains "CC_target points at the wrapper" "$tmp/env-ios" "CC_target=$d/cc"
contains "CXX_target points at the wrapper" "$tmp/env-ios" "CXX_target=$d/cxx"
contains "host tools stay on the runner's own compiler" "$tmp/env-ios" "CC_host=cc"
contains "the bundle check links through the wrapper" "$tmp/env-ios" "NODE_VERIFY_CXX=$d/cxx"
contains "Foundation is part of the link" "$tmp/env-ios" "NODE_VERIFY_EXTRA_LINK=-framework Foundation"
contains "cargo's C compiler for the rust target" "$tmp/env-ios" "CC_aarch64_apple_ios=$d/cc"
contains "cargo's C++ compiler for the rust target" "$tmp/env-ios" "CXX_aarch64_apple_ios=$d/cxx"

# ---------------------------------------------------------------- iPhone Simulator
run_case sim --platform ios --arch arm64 --simulator --sdk-path "$fake_sim"
d="$(outdir_of sim)"
contains "simulator triple says -simulator" "$d/cxx" "-target arm64-apple-ios16.0-simulator"
contains "simulator uses the simulator SDK" "$d/cxx" "-isysroot $fake_sim"
contains "simulator C++ also names the standard" "$d/cxx" "-std=gnu++20"

run_case sim15 --platform ios --arch arm64 --simulator --sdk-path "$fake_sim" \
  --deployment-target 15.0
contains "an older deployment target reaches the triple" "$(outdir_of sim15)/cxx" \
  "arm64-apple-ios15.0-simulator"

# The target the engine asks for by the name ios.x86_64: Godot builds the simulator as
# `arch=x86_64 simulator=yes`, so this is the shape the workflow actually runs.
run_case simx64 --platform ios --arch x86_64 --simulator --sdk-path "$tmp/iPhoneSimulator.sdk" \
  --rust-triple x86_64-apple-ios-sim
d="$(outdir_of simx64)"
contains "x86_64 simulator triple" "$d/cxx" "-target x86_64-apple-ios16.0-simulator"
contains "x86_64 simulator arch reaches the compile line" "$d/cxx" "x86_64"
contains "cargo's triple for the simulator" "$tmp/env-simx64" "CC_x86_64_apple_ios_sim=$d/cc"

# aarch64 is the name a Linux machine uses for the same architecture, and the workflow
# passes the engine's arch names through, so both spellings have to work.
run_case alias --platform ios --arch aarch64 --sdk-path "$fake_ios"
contains "aarch64 is read as arm64" "$(outdir_of alias)/cxx" "-target arm64-apple-ios16.0"

# The SDK is asked for by name when no path is given, so a runner needs no extra setup.
run_case iosquery --platform ios --arch arm64
contains "xcrun is asked for the iphoneos SDK" "$(outdir_of iosquery)/cxx" "-isysroot $fake_ios"
run_case simquery --platform ios --arch arm64 --simulator
contains "xcrun is asked for the simulator SDK" "$(outdir_of simquery)/cxx" "-isysroot $fake_sim"

# ---------------------------------------------------------------- macOS x86_64
# The shape a macOS runner uses when it builds the other architecture. Here the SDK is
# found by the toolchain itself, so only -arch is missing - that is the whole wrapper.
run_case macos --platform macos --arch x86_64
run_case macos13 --platform macos --arch x86_64 --deployment-target 13.0
contains "an explicit macOS deployment target reaches the triple" \
  "$(outdir_of macos13)/cxx" "x86_64-apple-macosx13.0"
d="$(outdir_of macos)"
contains "macos arch flag" "$d/cxx" "-arch x86_64"
contains "macos triple names the platform" "$d/cxx" "-target x86_64-apple-macosx"
absent "macos wrapper does not force a sysroot" "$d/cxx" "-isysroot"
# The mac flavour is handled by gyp itself, so the wrapper must not duplicate it.
absent "macos C++ standard comes from gyp, not the wrapper" "$d/cxx" "-std="
contains "macos host compiler stays plain" "$tmp/env-macos" "CXX_host=c++"
absent "no host wrapper for macOS" "$tmp/env-macos" "host_cxx"
absent "no Foundation on macOS" "$tmp/env-macos" "NODE_VERIFY_EXTRA_LINK"
contains "macos asks xcrun for the macOS SDK" "$d/cc" "--sdk macosx"

echo
if [ "$fails" -eq 0 ]; then
  echo "apple_toolchain check passed"
else
  echo "apple_toolchain check failed: $fails assertion(s)"
  exit 1
fi
