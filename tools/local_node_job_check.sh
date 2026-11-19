#!/usr/bin/env bash
#
# Run one job of .github/workflows/build_node.yml on this machine.
#
#   bash tools/local_node_job_check.sh --tarball /path/to/node-v26.13.1.tar.xz
#   bash tools/local_node_job_check.sh --tarball ... --platform linux_arm64
#   bash tools/local_node_job_check.sh --tarball ... --platform android_arm64 \
#        --android-ndk /workspace/tools/android-ndk-r29 --android-api 28
#   bash tools/local_node_job_check.sh --tarball ... --reuse-build   # repackage and re-verify only
#
# <platform> is one of linux|macos|windows|android|ios with an arch, and it names the
# node.<platform>.<arch>.configure.txt to use. An Android target also needs the NDK
# (--android-ndk, or ANDROID_NDK_PATH); everything else about the toolchain is taken
# from the environment, like the job does.
#
# It does the same steps in the same order as the job: unpack the release tarball,
# hand the committed node.<platform>.<arch>.configure.txt to
# prepare_node_build.sh, configure, ninja, package_node.sh, verify_node_bundle.sh.
# The one thing it cannot copy is the compiler: the jobs pin their own toolchain,
# so a machine with a different GCC proves the scripts and the bundle, not the pin.
# Expect about 25 minutes for a full build on 16 cores and roughly 300 MB out.
#
# Two checks run before anything compiles, because they cost seconds and each one
# has already caught a real mistake:
#
#   - the argument list configure will receive equals the committed args file plus
#     the version-specific extras (someone edited one of the two and not the other);
#   - every platform's argument file actually parses (./configure --help), which is
#     how a Windows file with an option missing its value used to reach CI.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tarball=""
platform=linux_x86_64
version=""
work=""
reuse_build=0
# The Android job reads both of these from repository variables; same defaults here.
android_ndk="${ANDROID_NDK_PATH:-}"
android_api="${NODE_ANDROID_API:-28}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) tarball="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --android-ndk) android_ndk="$2"; shift 2 ;;
    --android-api) android_api="$2"; shift 2 ;;
    --reuse-build) reuse_build=1; shift ;;
    -h|--help) sed -n '3,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "local_node_job_check: unknown argument $1" >&2; exit 1 ;;
  esac
done

platform_only="${platform%%_*}"
arch="${platform#*_}"
[ -n "$tarball" ] || { echo "local_node_job_check: --tarball is required" >&2; exit 1; }
[ -f "$tarball" ] || { echo "local_node_job_check: no such tarball: $tarball" >&2; exit 1; }
if [ -z "$version" ]; then
  version="$(basename "$tarball")"
  case "$version" in
    node-v*.tar.*) version="${version#node-v}"; version="${version%.tar*}" ;;
    *) echo "local_node_job_check: cannot read a version out of $(basename "$tarball"), pass --version" >&2; exit 1 ;;
  esac
fi
[ -n "$work" ] || work="$repo/.local/node-job-check"
args_file="$repo/node.$platform.configure.txt"
[ -f "$args_file" ] || { echo "local_node_job_check: no such args file: $args_file" >&2; exit 1; }

# An Android build takes its compiler from the NDK, exactly as the job does: the
# target tools are the NDK wrappers, the host toolset stays on this machine's own
# compiler so mksnapshot and torque can be run during the build, and the bundle check
# stops after the link because the result cannot be executed here.
if [ "$platform_only" = android ]; then
  if [ -z "$android_ndk" ]; then
    echo "local_node_job_check: an Android platform needs the NDK: pass --android-ndk <dir>" >&2
    echo "  (or set ANDROID_NDK_PATH). sdkmanager installs it as <ANDROID_HOME>/ndk/<version>." >&2
    exit 1
  fi
  [ -d "$android_ndk" ] || { echo "local_node_job_check: no such NDK directory: $android_ndk" >&2; exit 1; }
  android_ndk="$(cd "$android_ndk" && pwd)"
  ndk_bin="$android_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
  if [ ! -d "$ndk_bin" ]; then
    echo "local_node_job_check: $ndk_bin does not exist, so $android_ndk is not an NDK." >&2
    exit 1
  fi
  case "$arch" in
    arm64) android_triple=aarch64-linux-android ;;
    arm32) android_triple=armv7a-linux-androideabi ;;
    x86_64) android_triple=x86_64-linux-android ;;
    *)
      echo "local_node_job_check: no Android NDK triple for the arch name '$arch'" >&2
      exit 1
      ;;
  esac
  android_triple="${android_triple}${android_api}"
  for tool in "${android_triple}-clang" "${android_triple}-clang++" llvm-ar llvm-nm llvm-readelf; do
    if [ ! -x "$ndk_bin/$tool" ]; then
      echo "local_node_job_check: the NDK has no $tool (API $android_api not supported by this NDK?)" >&2
      exit 1
    fi
  done
  # The same version gate the job runs: V8 14.6 needs std::atomic_ref, which an older
  # NDK's libc++ does not have, and learning that after twenty minutes of compiling is
  # a waste nobody repeats voluntarily.
  mkdir -p "$work"
  probe="$work/atomic_ref_check.cc"
  printf '#include <atomic>\nint main(){int x=0;std::atomic_ref<int>(x).store(1);return x;}\n' > "$probe"
  if ! "$ndk_bin/${android_triple}-clang++" -std=gnu++20 -fsyntax-only "$probe"; then
    echo "local_node_job_check: $android_ndk is too old for Node 26: its libc++ has no" >&2
    echo "  std::atomic_ref, which V8 14.6 needs. NDK r29 (clang 21) is the first release" >&2
    echo "  that works; r26d and r28c do not." >&2
    exit 1
  fi
  export CC_target="$ndk_bin/${android_triple}-clang"
  export CXX_target="$ndk_bin/${android_triple}-clang++"
  export AR_target="$ndk_bin/llvm-ar"
  export NM_target="$ndk_bin/llvm-nm"
  export READELF_target="$ndk_bin/llvm-readelf"
  export CC_host=cc
  export CXX_host=c++
  export NODE_VERIFY_CXX="$ndk_bin/${android_triple}-clang++"
  export NODE_VERIFY_LINK_ONLY=1
  # Temporal is compiled by cargo for the target architecture, and that needs the
  # target's standard library. Saying so here beats letting cargo build it for the host.
  case "$arch" in
    arm64) cargo_target=aarch64-linux-android ;;
    arm32) cargo_target=armv7-linux-androideabi ;;
    x86_64) cargo_target=x86_64-linux-android ;;
  esac
  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$cargo_target"; then
    echo "local_node_job_check: Temporal needs the Rust standard library for $cargo_target:" >&2
    echo "  rustup target add $cargo_target" >&2
    exit 1
  fi
  export CARGO_BUILD_TARGET="$cargo_target"
  echo "local_node_job_check: NDK $android_ndk, API $android_api, triple $android_triple, cargo target $cargo_target"
fi

mkdir -p "$work"
work="$(cd "$work" && pwd)"
build="$work/node"
stage="$work/stage"
started="$(date +%s)"

# One argument per line, `#` starts a comment: the same rule the args files use.
# Arguments are appended to arrays with a read loop rather than mapfile, and no
# bash nameref is used, so this also runs on the bash 3.2 that macOS ships.
flags() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

extra="$repo/node.extra_${version%%.*}.x.configure.txt"

if [ "$reuse_build" -eq 0 ]; then
  rm -rf "$build"
  mkdir -p "$build"
  tar -xf "$tarball" -C "$build" --strip-components=1

  # What configure is about to receive has to be the committed file plus the
  # version-specific extras, plus only those flags prepare_node_build.sh may add
  # itself: the Temporal switch, and the two gyp defines an Android build needs
  # (-Dandroid_ndk_path, -Dhost_os). A flag nobody wrote down would otherwise ride
  # into the published bundle unnoticed.
  cp "$args_file" "$build/args.txt"
  cp "$args_file" "$build/args.committed.txt"
  ( cd "$build" && bash "$repo/prepare_node_build.sh" . args.txt "$version" )
  expected="$( { flags "$build/args.committed.txt" || true; flags "$extra" || true; } | sort -u)"
  actual="$(flags "$build/args.txt" | sort -u)"
  extra_flags="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") \
    | grep -vE '^--v8-(enable|disable)-temporal-support$|^-(Dandroid_ndk_path|Dhost_os)=' || true)"
  if [ -n "$extra_flags" ]; then
    echo "local_node_job_check: prepare_node_build.sh put flags in the args file that are" >&2
    echo "  in neither the committed args file nor the extras file:" >&2
    printf '  %s\n' $extra_flags >&2
    exit 1
  fi
  echo "local_node_job_check: args file = committed + extras (+ Temporal switch, Android gyp defines)"
elif [ ! -d "$build/out/Release" ]; then
  echo "local_node_job_check: --reuse-build but $build/out/Release does not exist" >&2
  exit 1
fi

# Parse-check every platform's arguments, from this one tree, before compiling:
# ./configure --help exits non-zero when an option is unknown or is missing its
# value, and it configures nothing. The Windows entry is included with the
# --clang-cl=<version> the Windows job appends at runtime (any version parses the
# same way), so the file is tested as it is really used.
for candidate in "$repo"/node.*.configure.txt; do
  name="$(basename "$candidate" .configure.txt)"
  name="${name#node.}"
  case "$name" in
    extra*) continue ;;
  esac
  probe_args=()
  while IFS= read -r line; do
    probe_args+=("$line")
  done < <(flags "$candidate")
  if [ -f "$extra" ]; then
    while IFS= read -r line; do
      probe_args+=("$line")
    done < <(flags "$extra")
  fi
  case "$name" in
    windows_*) probe_args+=("--clang-cl=19.1.5") ;;
  esac
  if ( cd "$build" && python3 ./configure "${probe_args[@]}" --help > /dev/null 2>&1 ); then
    echo "local_node_job_check: arguments parse for $name"
  else
    echo "local_node_job_check: configure rejects the arguments for $name"
    ( cd "$build" && python3 ./configure "${probe_args[@]}" --help 2>&1 | tail -2 )
    exit 1
  fi
done

if [ "$reuse_build" -eq 0 ]; then
  (
    cd "$build"
    node_args=()
    while IFS= read -r node_arg; do
      node_args+=("$node_arg")
    done < <(flags "$build/args.txt")
    printf 'configure %s\n' "${node_args[*]}"
    python3 ./configure "${node_args[@]}"
    ninja -C out/Release node
  )
  echo "local_node_job_check: ninja finished in $(( $(date +%s) - started ))s"
fi

rm -rf "$stage"
bash "$repo/package_node.sh" "$build" "$build/out/Release" "$stage" "$platform_only" "$arch"
bash "$repo/verify_node_bundle.sh" "$stage"
echo "local_node_job_check: OK in $(( $(date +%s) - started ))s -> $stage"
