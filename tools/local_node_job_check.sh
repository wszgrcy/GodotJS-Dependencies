#!/usr/bin/env bash
#
# Run one desktop job of .github/workflows/build_node.yml on this machine.
#
#   bash tools/local_node_job_check.sh --tarball /path/to/node-v26.13.1.tar.xz
#   bash tools/local_job_check.sh --tarball ... --platform linux_arm64
#   bash tools/local_node_job_check.sh --tarball ... --reuse-build   # repackage and re-verify only
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

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) tarball="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --reuse-build) reuse_build=1; shift ;;
    -h|--help) sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
  # itself (today: the Temporal switch). A flag nobody wrote down would otherwise ride
  # into the published bundle unnoticed.
  cp "$args_file" "$build/args.txt"
  cp "$args_file" "$build/args.committed.txt"
  ( cd "$build" && bash "$repo/prepare_node_build.sh" . args.txt "$version" )
  expected="$( { flags "$build/args.committed.txt" || true; flags "$extra" || true; } | sort -u)"
  actual="$(flags "$build/args.txt" | sort -u)"
  extra_flags="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") \
    | grep -vE '^--v8-(enable|disable)-temporal-support$' || true)"
  if [ -n "$extra_flags" ]; then
    echo "local_node_job_check: prepare_node_build.sh put flags in the args file that are" >&2
    echo "  in neither the committed args file nor the extras file:" >&2
    printf '  %s\n' $extra_flags >&2
    exit 1
  fi
  echo "local_node_job_check: args file = committed + extras (+ the Temporal switch prepare adds)"
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
