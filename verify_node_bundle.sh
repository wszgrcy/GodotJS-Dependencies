#!/usr/bin/env bash
#
# Build and run tools/node_link_probe.cc against a packaged Node bundle.
#
#   bash verify_node_bundle.sh <bundle_dir> [extra compiler flags...]
#
#     <bundle_dir>  a directory that contains node/include and
#                   node/<platform>.<arch>.release/ - that is, the inside of
#                   node_<version>....zip, or the staging directory that produced it.
#
# What it proves, in one pass:
#
#   * link.txt describes a link line that actually works (the archives, their
#     order, and the --whole-archive grouping are read from that file, nothing is
#     hard-coded here);
#   * the headers in the bundle compile against a plain C++20 program, with RTTI
#     on and exceptions off, which is how Godot compiles its modules, and with no
#     V8_* macros defined (Node's own sources are compiled that way too);
#   * the resulting program runs: built-in modules, ICU, and a host-driven libuv
#     loop (see the probe source for the exact list).
#
# Environment:
#   NODE_VERIFY_CXX        compiler to use (default: c++)
#   NODE_VERIFY_LINK_ONLY  compile and link, do not run (cross-built bundles)
#   NODE_VERIFY_EXTRA_LINK extra linker flags, appended after the archives
#   NODE_VERIFY_KEEP       leave the temporary build directory in place
#   NODE_PROBE_TIMEOUT     seconds before the probe is killed (default: 180)
#
# POSIX toolchains only; Windows needs lib.exe/link.exe and is left to a local run.
# A bundle built for another platform (Android, iOS) is checked with
# NODE_VERIFY_CXX pointing at that toolchain and NODE_VERIFY_LINK_ONLY=1: linking
# the probe there still proves the archives are complete, in the right order, and
# for that ABI, even though the program cannot be executed.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <bundle_dir> [extra compiler flags...]" >&2
  exit 2
fi

BUNDLE="$(cd "$1" && pwd)"; shift || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLATFORM_DIR="$(find "$BUNDLE/node" -maxdepth 1 -type d -name '*release' | sort | head -1)"
if [ -z "$PLATFORM_DIR" ]; then
  echo "verify_node_bundle: no <platform>.<arch>.release directory under $BUNDLE/node" >&2
  exit 1
fi
LIBDIR="$(basename "$PLATFORM_DIR")"
echo "verify_node_bundle: using $LIBDIR"

for required in "$BUNDLE/node/include/node/node.h" "$BUNDLE/node/include/node/v8.h" \
                "$BUNDLE/node/include/node/uv.h" "$PLATFORM_DIR/link.txt" \
                "$PLATFORM_DIR/manifest.json" "$PLATFORM_DIR/config.gypi"; do
  if [ ! -f "$required" ]; then
    echo "verify_node_bundle: $required is missing - run package_node.sh first" >&2
    exit 1
  fi
done

# Turn link.txt into a link line: consecutive 'whole' entries are wrapped in one
# whole-archive group, everything else keeps the recorded order. This is the one
# place the two linker families really differ: GNU ld opens a group with
# --whole-archive and closes it with --no-whole-archive, while Apple's ld64 has no
# group at all and takes -force_load once per archive. The archives, their order
# and everything else are the same either way.
LINK_ARGS=()
WHOLE=()
CPPFLAGS_EXTRA=()
case "$(uname -s)" in
  Darwin) LINK_STYLE=apple ;;
  *) LINK_STYLE=gnu ;;
esac
flush_whole() {
  if [ "${#WHOLE[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "$LINK_STYLE" = apple ]; then
    for file in "${WHOLE[@]}"; do
      LINK_ARGS+=("-Wl,-force_load,$PLATFORM_DIR/$file")
    done
  else
    LINK_ARGS+=(-Wl,--whole-archive)
    for file in "${WHOLE[@]}"; do
      LINK_ARGS+=("$PLATFORM_DIR/$file")
    done
    LINK_ARGS+=(-Wl,--no-whole-archive)
  fi
  WHOLE=()
}
while read -r kind arg _; do
  case "$kind" in
    ''|\#*) continue ;;
    whole) WHOLE+=("$arg") ;;
    plain) flush_whole; LINK_ARGS+=("$PLATFORM_DIR/$arg") ;;
    system) flush_whole; LINK_ARGS+=("$arg") ;;
    define) CPPFLAGS_EXTRA+=("-D${arg}") ;;
    feature)
      # Not a link input. These record build settings that change the ABI without
      # leaving a trace in V8's public headers; the engine has to match them. Pointer
      # compression is the one that matters - it resizes every V8 pointer - so it is
      # printed here to make an eyeballed log say it out loud.
      case "$arg" in
        v8_enable_pointer_compression=*)
          echo "verify_node_bundle: bundle was built with pointer compression = ${arg#*=}"
          ;;
      esac
      continue ;;
    *) echo "verify_node_bundle: unknown link.txt directive '$kind'" >&2; exit 1 ;;
  esac
done < <(grep -vE '^\s*(#|$)' "$PLATFORM_DIR/link.txt")
flush_whole

WORK="$(mktemp -d "${TMPDIR:-/tmp}/node-verify.XXXXXX")"
# NODE_VERIFY_KEEP=1 leaves the compiled probe behind, so it can be re-run under
# a debugger or inspected with nm/ldd after the check.
if [ -n "${NODE_VERIFY_KEEP:-}" ]; then
  echo "verify_node_bundle: keeping $WORK"
else
  trap 'rm -rf "$WORK"' EXIT
fi

cxx="${NODE_VERIFY_CXX:-c++}"
if [ -n "${NODE_VERIFY_LINK_ONLY:-}" ]; then
  echo "verify_node_bundle: link-only mode (this bundle was built for another target)"
fi

echo "verify_node_bundle: compiling the probe with $cxx (C++20, RTTI on, exceptions off)"
"$cxx" -std=gnu++20 -O1 -g0 -Wall -fno-exceptions \
  -pthread \
  -I "$BUNDLE/node/include/node" \
  "${CPPFLAGS_EXTRA[@]+"${CPPFLAGS_EXTRA[@]}"}" \
  "$SCRIPT_DIR/tools/node_link_probe.cc" \
  -o "$WORK/node_link_probe" \
  "${LINK_ARGS[@]}" ${NODE_VERIFY_EXTRA_LINK:-} "$@"

if [ -n "${NODE_VERIFY_LINK_ONLY:-}" ]; then
  echo "verify_node_bundle: PASS - $LIBDIR archives compile and link with $cxx"
  echo "  (not executed: the bundle targets another platform)"
  exit 0
fi

echo "verify_node_bundle: running the probe"
# The probe must finish on its own; if it hangs, that is a failure, not a reason to
# wait. UV_RUN_NOWAIT is used everywhere for exactly that reason.
if command -v timeout >/dev/null; then
  timeout "${NODE_PROBE_TIMEOUT:-180}" "$WORK/node_link_probe"
else
  "$WORK/node_link_probe"
fi
