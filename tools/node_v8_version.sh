#!/usr/bin/env bash
#
# Print the V8 version that a given Node version embeds.
#
#   bash tools/node_v8_version.sh <node_version>       # prints e.g. 14.6.202.34
#
# Node carries V8 in deps/v8, and the version it ships is the version tag the V8
# build here should use, so nothing has to be typed by hand: this reads
# deps/v8/include/v8-version.h out of the nodejs/node git tag and prints the same
# four-part number the V8 repository tags itself with (verified for 26.13.1:
# 14.6.202.34 exists as refs/tags/14.6.202.34 in chromium.googlesource.com/v8/v8).
#
# The answer comes from Node's repository, not from a local checkout, so CI can
# ask before it has downloaded anything. Pass NODE_REF_BASE to read a fork or a
# local mirror instead of github.com.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  echo "usage: $0 <node_version>   (no leading v, e.g. 26.13.1)" >&2
  exit 2
fi

node_version="$1"
node_version="${node_version#v}"
ref_base="${NODE_REF_BASE:-https://raw.githubusercontent.com/nodejs/node}"
url="${ref_base}/v${node_version}/deps/v8/include/v8-version.h"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

if ! curl -fsSL --max-time 60 -o "$body" "$url"; then
  echo "node_v8_version: cannot read $url" >&2
  echo "  Is v${node_version} a tag in ${ref_base}? Or pass NODE_REF_BASE to read a mirror." >&2
  exit 1
fi

version="$(
  node_version_body="$body" python3 - <<'PY'
import os
import re

text = open(os.environ['node_version_body'], encoding='utf-8').read()
parts = {}
for key in ('MAJOR_VERSION', 'MINOR_VERSION', 'BUILD_NUMBER', 'PATCH_LEVEL'):
    found = re.search(rf'#define\s+V8_{key}\s+(\d+)', text)
    if found is None:
        raise SystemExit(f'v8-version.h: no #define V8_{key}')
    parts[key] = found.group(1)
print('{}.{}.{}.{}'.format(*(parts[k] for k in
                             ('MAJOR_VERSION', 'MINOR_VERSION', 'BUILD_NUMBER', 'PATCH_LEVEL'))))
PY
)"

# Node's tarball tags its V8 with a "-node.NN" suffix; the V8 repository has no
# such tag, so a four-part number is the only thing worth handing to the build.
if ! printf '%s\n' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "node_v8_version: '$version' does not look like a V8 version tag" >&2
  exit 1
fi

printf '%s\n' "$version"
