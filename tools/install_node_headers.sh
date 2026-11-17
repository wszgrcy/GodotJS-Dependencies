#!/usr/bin/env bash
#
# Put the headers an embedder of Node needs into one directory, using Node's own
# installer.
#
#   bash tools/install_node_headers.sh <node_src> <node_out> <node_dir> <platform> <arch>
#
# Everything lands in <node_dir>/include/node: node.h, v8.h, uv.h, cppgc/,
# openssl/, js_native_api.h, plus config.gypi and common.gypi. That single
# directory is the only -I an embedder needs.
#
# <node_dir> is the directory that becomes node/ inside the bundle: package_node.sh
# passes its staging directory's node/, and CI passes a throwaway directory before
# the long build to find out about a broken install in seconds instead of after
# 40 minutes.
#
# It is Node's tools/install.py that builds the official node-vX-headers.tar.gz,
# so the bundle uses it instead of guessing a header list. (The set it installs is
# the public one on purpose: node_internals.h, env-inl.h and friends are left out
# by Node, and a binding layer that includes them has to copy src/ itself.)
#
# Needs ./configure to have run, because config.gypi is what install.py reads.
# Needs nothing from the build itself, so this works before anything is compiled.

set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 <node_src> <node_out> <node_dir> <platform> <arch>" >&2
  exit 2
fi

NODE_SRC="$(cd "$1" && pwd)"
NODE_OUT="$(cd "$2" 2>/dev/null && pwd || echo "$2")"
NODE_DIR="$3"
PLATFORM="$4"
ARCH="$5"
INCLUDE_DIR="$NODE_DIR/include/node"

rm -rf "$NODE_DIR/include"
mkdir -p "$NODE_DIR"

install_args=()
if [ "$PLATFORM" = windows ]; then
  install_args+=(--is-win)
fi

# --prefix '' rather than --prefix /: install.py builds its target directory with a
# plain concatenation (dest_dir + prefix), and the bash on the Windows runners
# rewrites a bare "/" argument into a drive letter, which produced
# "...\staging\nodeC:" and died in os.makedirs. An empty prefix is the same thing
# semantically here and is not something the shell rewrites.
(
  cd "$NODE_SRC" &&
  python3 tools/install.py install --headers-only \
    --dest-dir "$NODE_DIR" --prefix '' \
    --root-dir "$NODE_SRC" --build-dir "$NODE_OUT" \
    --config-gypi-path "$NODE_SRC/config.gypi" "${install_args[@]}"
) >/dev/null

for header in node.h v8.h uv.h; do
  if [ ! -f "$INCLUDE_DIR/$header" ]; then
    echo "install_node_headers: include/node/$header was not installed." >&2
    echo "  Node changed which headers it installs; check tools/install.py." >&2
    exit 1
  fi
done

# Node's installer ships what an addon needs, which is not quite what an engine
# embedding Node needs: these V8 headers live in deps/v8/include but are not
# installed, and GodotJS includes them directly (impl/v8/jsb_v8_pch.h).
# A missing one is an error rather than a warning, so the surprise happens here
# instead of in the first engine compile.
#   v8-inspector.h       the inspector channel
#   v8-version-string.h  V8's version string, used in diagnostics
# Both only include headers installed above, so copying them is enough.
for v8_extra in v8-inspector.h v8-version-string.h; do
  if [ ! -f "$NODE_SRC/deps/v8/include/$v8_extra" ]; then
    echo "install_node_headers: $NODE_SRC/deps/v8/include/$v8_extra is missing." >&2
    echo "  Node moved or dropped a header the engine includes; update this list." >&2
    exit 1
  fi
  cp "$NODE_SRC/deps/v8/include/$v8_extra" "$INCLUDE_DIR/$v8_extra"
done

# OpenSSL's per-platform configure output ships next to its headers (Node does the
# same in its own headers tarball). A bundle covers one platform, so the other
# directories are dropped: 20 of them are 66 MB of the 67 MB the header tree
# weighs. Left alone on a pre-check (nothing is trimmed there) only if the platform
# has no matching directory.
case "$PLATFORM/$ARCH" in
  linux/x86_64)   openssl_arch=linux-x86_64 ;;
  linux/arm64)    openssl_arch=linux-aarch64 ;;
  macos/arm64)    openssl_arch=darwin64-arm64-cc ;;
  macos/x86_64)   openssl_arch=darwin64-x86_64-cc ;;
  windows/x86_64) openssl_arch=VC-WIN64A ;;
  windows/arm64)  openssl_arch=VC-WIN64-ARM ;;
  # Nothing to trim on Android or iOS: deps/openssl/config/archs in the Node source
  # ships no android-* or ios* directory, so there is no matching folder to keep and
  # the whole pre-generated set stays in the bundle (about 60 MB of headers nobody
  # includes). Revisit after the first mobile build, when it is visible which
  # configuration that target actually ends up using.
  android/*|ios/*) openssl_arch="" ;;
  *) openssl_arch="" ;;
esac
if [ -n "$openssl_arch" ] && [ -d "$INCLUDE_DIR/openssl/archs/$openssl_arch" ]; then
  find "$INCLUDE_DIR/openssl/archs" -mindepth 1 -maxdepth 1 -type d \
    ! -name "$openssl_arch" -exec rm -rf {} +
  echo "install_node_headers: kept openssl/archs/$openssl_arch only"
elif [ -n "$openssl_arch" ]; then
  echo "install_node_headers: deps/openssl/config/archs/$openssl_arch does not exist;"
  echo "  the pre-generated OpenSSL configurations are kept as they are"
fi

echo "install_node_headers: $(find "$NODE_DIR/include" -type f | wc -l) files under include/"
