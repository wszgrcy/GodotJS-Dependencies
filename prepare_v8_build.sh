#!/usr/bin/env bash
#
# Adjust a V8 checkout before building the prebuilt monolith.
#
#   bash prepare_v8_build.sh <v8_source_dir> <args_gn_path> <v8_version>
#
#     <v8_source_dir>  the V8 checkout (the directory that contains build/)
#     <args_gn_path>   the args.gn that ninja will use
#     <v8_version>     the version tag being built, e.g. 15.6.75.19
#
# Everything here only applies to V8 15 and newer:
#
#   1. v8.extra_15.x.args.gn is appended to args.gn.
#   2. ELF CREL relocations are switched off in //build. Since V8 15 the build
#      asks the assembler for CREL whenever lld is used, but only lld can read
#      them back. A libv8_monolith.a built that way cannot be linked with GNU
#      binutils: g++ fails with
#        error in libv8_monolith.a(...)(.eh_frame);
#        no .eh_frame_hdr table will be created
#      Set V8_KEEP_CREL=1 to skip this and keep CREL. Then whatever links the
#      library has to use lld (-fuse-ld=lld), and GNU nm/objdump/ar cannot read
#      the archive.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <v8_source_dir> <args_gn_path> <v8_version>" >&2
  exit 2
fi

V8_SRC="$1"
ARGS_GN="$2"
V8_VERSION="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

V8_MAJOR="${V8_VERSION%%.*}"
case "$V8_MAJOR" in
  ''|*[!0-9]*)
    echo "prepare_v8_build: cannot read a major version out of '$V8_VERSION'" >&2
    exit 2
    ;;
esac

if [ "$V8_MAJOR" -lt 15 ]; then
  echo "prepare_v8_build: V8 $V8_VERSION needs no adjustments"
  exit 0
fi

echo "prepare_v8_build: applying V8 15.x adjustments for $V8_VERSION"

if [ ! -f "$ARGS_GN" ]; then
  echo "prepare_v8_build: $ARGS_GN does not exist" >&2
  exit 1
fi
cat "$SCRIPT_DIR/v8.extra_15.x.args.gn" >> "$ARGS_GN"

if [ "${V8_KEEP_CREL:-0}" = "1" ]; then
  echo "prepare_v8_build: V8_KEEP_CREL=1, ELF CREL stays on (link the result with lld)"
  exit 0
fi

python3 - "$V8_SRC/build/config/compiler/BUILD.gn" <<'PY'
import sys

path = sys.argv[1]

with open(path, encoding='utf-8') as handle:
    lines = handle.readlines()

# Find the one line that asks the assembler for CREL, then the "if (" line that
# guards it. The condition is matched by prefix because gn format may have
# wrapped it over several lines.
flags = [i for i, line in enumerate(lines) if '--crel' in line and 'cflags' in line]
if len(flags) != 1:
    sys.exit(f'prepare_v8_build: expected one CREL cflags line in {path}, found {len(flags)}')

condition = None
for i in range(flags[0], -1, -1):
    if lines[i].lstrip().startswith('if ('):
        condition = i
        break
if condition is None:
    sys.exit(f'prepare_v8_build: no "if (" guard found above the CREL line in {path}')

if 'false &&' in lines[condition]:
    print(f'prepare_v8_build: ELF CREL already disabled in {path}')
    raise SystemExit(0)

lines.insert(condition, '# GodotJS-Dependencies: CREL is only understood by lld, so the library\n'
                        '# could not be linked with GNU binutils. See prepare_v8_build.sh.\n')
lines[condition + 1] = lines[condition + 1].replace('if (', 'if (false && ', 1)

with open(path, 'w', encoding='utf-8') as handle:
    handle.writelines(lines)
print(f'prepare_v8_build: ELF CREL disabled in {path}')
PY
