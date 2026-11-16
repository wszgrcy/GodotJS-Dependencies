#!/usr/bin/env bash
#
# Generate Node's Windows ninja files on this machine, and check the two Windows
# build facts that a CI round would otherwise take 40 minutes to reveal.
#
#   bash tools/local_windows_ninja_check.sh --tarball /path/to/node-v26.13.1.tar.xz
#   bash tools/local_windows_ninja_check.sh --tarball ... --work /work/winc
#   bash tools/local_windows_ninja_check.sh --work /work/winc --skip-prepare
#
# Why this exists: ninja on Windows is a combination Node's own CI never builds
# (upstream uses vcbuild/MSBuild there), so every Windows problem shows up only on
# a GitHub runner, one per run. The generated ninja files hold almost all of the
# answer, and they can be generated here - only three things get in the way, and
# this script fakes them:
#
#   - gyp asks the registry and vcvarsall.bat where Visual Studio is. A fake VS
#     tree answers both: a shell script named vcvarsall.bat prints the environment
#     gyp parses, and reg.exe is stubbed out.
#   - gyp finds cl.exe with a cmd.exe `for %i in (cl.exe)` loop. That one lookup is
#     replaced with a fixed path; nothing else is patched.
#   - Rust's Windows target is usually not installed here, so Temporal is turned
#     off for the rehearsal. Its absence shows up as node_crates.lib missing from
#     the archive list, which the summary says out loud.
#   - ./configure only records clang-cl in the config when it runs on Windows, so
#     the generated config is edited to say what a Windows runner's would say.
#     Without that, the snapshot blob takes the assembler route instead of the C++
#     route and the rehearsal checks a configuration nobody builds.
#
# What gets checked afterwards:
#
#   1. that OpenSSL's assembled assembly is really inside openssl.lib (the archive
#      edge lists the .obj files nasm produced). If it lists none, the link fails
#      two thousand targets later with unresolved symbols like OPENSSL_cleanse -
#      see patches/godotjs-openssl-win-asm-outputs-as-sources.patch.
#   2. that the packaging parser can read the Windows link line and split the
#      archives into force-loaded and normally linked ones. Packaging reads
#      out/Release/node.exe.rsp, which ninja writes at build time, so this script
#      writes the same content from the ninja files (rspfile_content is
#      "$in_newline $libs $ldflags").
#   3. that the two Windows code paths fixed by patches/godotjs-gyp-win-pch-path.patch
#      and patches/godotjs-v8-snapshot-asm-to-cc.patch look right in the graph.
#
# Nothing here runs a compiler: no cl.exe, no link.exe, no nasm. It checks what the
# build is about to do, not what it produced.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tarball=""
work="${TMPDIR:-/tmp}/node-win-ninja-check"
skip_prepare=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) tarball="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --skip-prepare) skip_prepare=1; shift ;;
    *) echo "local_windows_ninja_check: unknown argument $1" >&2; exit 2 ;;
  esac
done

node_src="$work/node"
fake_vs="$work/fake-vs"
args_file="$repo/node.windows_x86_64.configure.txt"

say() { echo "local_windows_ninja_check: $*"; }
fail() { echo "local_windows_ninja_check: FAIL - $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. The Visual Studio that gyp believes it found
# ---------------------------------------------------------------------------
make_fake_vs() {
  local vs="$1"
  local msvc="$vs/VC/Tools/MSVC/14.40.33807"
  mkdir -p "$msvc/include" "$msvc/lib/x64" "$vs/VC/Auxiliary/Build" "$vs/bin"
  : > "$msvc/include/stdio.h"   # gyp checks that the include dir is a real dir
  # gyp runs this and parses the variables out of it. SYSTEMROOT, TEMP and TMP are
  # required by _ExtractImportantEnvironment; the rest feed INCLUDE/LIB/PATH.
  cat > "$vs/VC/Auxiliary/Build/vcvarsall.bat" <<EOF
#!/bin/sh
V="$msvc"
echo "INCLUDE=\$V/include"
echo "LIB=\$V/lib/x64"
echo "LIBPATH=\$V/lib/x64"
echo "PATH=$vs/bin"
echo "PATHEXT=.COM;.EXE;.BAT"
echo "SYSTEMROOT=$work"
echo "TEMP=$work"
echo "TMP=$work"
EOF
  chmod +x "$vs/VC/Auxiliary/Build/vcvarsall.bat"
  # The tools gyp looks for by name. They are never executed here.
  for tool in cl link lib ml64 ml armasm64 rc midl mt; do
    : > "$vs/bin/$tool.exe"
    chmod +x "$vs/bin/$tool.exe"
  done
  # gyp's MSVS version lookup shells out to reg.exe when there is no registry.
  printf '#!/bin/sh\nexit 0\n' > "$vs/bin/reg.exe"
  chmod +x "$vs/bin/reg.exe"
  # clang-cl, named so it passes prepare_node_build.sh's suffix check.
  : > "$vs/clang-cl"
  chmod +x "$vs/clang-cl"
}

# The gyp call configure.py makes at the end, with only the cl.exe lookup replaced.
write_gyp_driver() {
  cat > "$work/gyp_win.py" <<'PY'
"""Run Node's gyp for the ninja-win flavour on a machine without Visual Studio.

gyp finds cl.exe by asking cmd.exe to expand `for %i in (cl.exe) do
@echo LOC:%~$PATH:i`. That single lookup is replaced; the rest of gyp runs
unmodified, which is what makes the generated ninja files worth reading.
"""
import os
import sys

node = os.path.abspath(sys.argv[1])
os.chdir(node)
# tools/gyp_node.py puts tools/gyp/pylib on the path. Inserting in this order keeps
# `import gyp` away from the tools/gyp directory, which Python would otherwise take
# for the package.
sys.path.insert(0, os.path.join(node, "tools", "v8_gypfiles"))
sys.path.insert(0, os.path.join(node, "tools"))

import gyp_node
import gyp.msvs_emulation

gyp.msvs_emulation._ExtractCLPath = lambda output: os.environ["FAKE_VS"] + "/bin/cl.exe"

sys.exit(gyp_node.run_gyp([
    "--no-parallel",
    "-Dconfiguring_node=1",
    "-Dbuild_type=Release",
    "-Dpython=" + sys.executable,
    "-f",
    "ninja-win",
]))
PY
}

# Write out/Release/<binary>.rsp the way ninja would, from the ninja file:
#   rspfile = $binary.rsp
#   rspfile_content = $in_newline $libs $ldflags
write_link_rsp() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

out_release, binary = sys.argv[1], sys.argv[2]
# The ninja file a target lands in is named after its .gyp file.
lines = open(f"{out_release}/obj/node.ninja").read().split("\n")

i = next(k for k, l in enumerate(lines) if l.startswith(f"build {binary}"))

# A variable at column 0 applies to every build edge below it.
scope, k = {}, 0
while k < i:
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*) = (.*)$", lines[k])
    if m:
        value = m.group(2)
        while lines[k].rstrip().endswith("$") and k + 1 < i:
            k += 1
            value += " " + lines[k].strip()
        scope[m.group(1)] = value
    k += 1

text, j, edge = lines[i], i + 1, {}
while j < len(lines) and lines[j].startswith("  "):
    m = re.match(r"^  ([A-Za-z_][A-Za-z0-9_]*) = (.*)$", lines[j])
    if m:
        edge[m.group(1)] = m.group(2)
    else:
        text += " " + lines[j].strip()
    j += 1

text = re.sub(r"\\\s+", " ", text)
inputs = text.split(":", 1)[1].split("|")[0].split("||")[0].split()
vars_ = dict(scope)
vars_.update(edge)
one = lambda key: re.sub(r"\\\s+", " ", vars_.get(key, ""))

with open(f"{out_release}/{binary}.rsp", "w") as handle:
    handle.write("\n".join(inputs) + "\n" + one("libs") + "\n" + one("ldflags") + "\n")
print(f"{len(inputs)} input lines written to {binary}.rsp")
PY
}

count_asm_in_archive() {
  python3 - "$1" <<'PY'
import re
import sys

lines = open(sys.argv[1]).read().split("\n")
try:
    i = next(k for k, l in enumerate(lines) if l.startswith("build obj/deps/openssl/openssl.lib: alink"))
except StopIteration:
    print("no-archive-edge")
    raise SystemExit
block, j = [], i + 1
while j < len(lines) and lines[j].startswith("    "):
    block.append(lines[j])
    j += 1
print(len(re.findall(r"openssl\.gen/[A-Za-z0-9_.\-]+\.obj", "\n".join(block))))
PY
}

# ---------------------------------------------------------------------------
# 2. Unpack, prepare, configure, generate
# ---------------------------------------------------------------------------
if [ ! -d "$work" ]; then mkdir -p "$work"; fi
make_fake_vs "$fake_vs"
write_gyp_driver

if [ "$skip_prepare" -eq 0 ]; then
  [ -n "$tarball" ] && [ -f "$tarball" ] || \
    fail "--tarball is needed (or --skip-prepare with a --work that already has node/out/Release)"
  say "unpacking $(basename "$tarball")"
  rm -rf "$node_src"
  mkdir -p "$node_src"
  tar -xf "$tarball" -C "$node_src" --strip-components=1
fi

if [ "$skip_prepare" -eq 1 ]; then
  [ -d "$node_src/out/Release" ] || \
    fail "$node_src has no out/Release; --skip-prepare needs a --work that was prepared before"
fi

export GYP_MSVS_VERSION=2022
export GYP_MSVS_OVERRIDE_PATH="$fake_vs"
export GODOTJS_NODE_CLANG_CL="$fake_vs/clang-cl"
export FAKE_VS="$fake_vs"
export PATH="$fake_vs/bin:$PATH"

# Rust's Windows target is rarely installed on a Linux machine. Without it,
# configure would refuse Temporal; rehearsing without Temporal is fine as long as
# the summary says so, because node_crates.lib then leaves the archive list.
if [ "${NODE_TEMPORAL:-}" = "" ]; then
  if ! rustc --print target-list 2>/dev/null | grep -qx x86_64-pc-windows-msvc || \
     ! ls "$(rustc --print sysroot)/lib/rustlib" 2>/dev/null | grep -qx x86_64-pc-windows-msvc; then
    export NODE_TEMPORAL=off
    say "the Rust target x86_64-pc-windows-msvc is not installed, so Temporal is off"
    say "  for this rehearsal; node_crates.lib will be missing from the archive list"
  fi
fi

if [ "$skip_prepare" -eq 0 ]; then
  say "prepare_node_build.sh with the windows x86_64 arguments"
  cp "$args_file" "$work/args.txt"
  bash "$repo/prepare_node_build.sh" "$node_src" "$work/args.txt" 26.13.1

  # The version belongs to the machine, so the workflow appends it at run time.
  # Here any plausible version works: the value only names the toolset.
  printf -- '--clang-cl=19.44.0\n' >> "$work/args.txt"

  say "configure (writes config.gypi)"
  ( cd "$node_src" && python3 ./configure $(grep -vE '^[[:space:]]*(#|$)' "$work/args.txt" | tr '\n' ' ') )
fi

say "gyp -f ninja-win"

# configure.py's check_compiler() sets clang=1 from --clang-cl only when it runs on
# Windows (sys.platform == 'win32'), so here it stays 0 even though args.txt carries
# --clang-cl. A Windows runner therefore generates a different graph: with clang=1,
# V8 converts the snapshot blob's .S into a .cc instead of assembling it. Say what a
# Windows runner's config says, so the rehearsal checks that graph.
python3 - "$node_src/config.gypi" <<'PY'
import sys

path = sys.argv[1]
text = open(path).read()
if '"clang": 1' not in text:
    text = text.replace('"clang": 0,', '"clang": 1,')
    text = text.replace('"llvm_version": "0.0",', '"llvm_version": "19.1.5",')
    open(path, "w").write(text)
    print("local_windows_ninja_check: config.gypi set to clang=1, as a Windows clang-cl build would")
PY

( cd "$node_src" && python3 "$work/gyp_win.py" "$node_src" > "$work/gyp.log" 2>&1 ) || \
  { tail -20 "$work/gyp.log"; fail "gyp failed, full log in $work/gyp.log"; }
[ -f "$node_src/out/Release/build.ninja" ] || fail "no build.ninja was written"
say "ninja files written to $node_src/out/Release"

# ---------------------------------------------------------------------------
# 3. The two checks
# ---------------------------------------------------------------------------
problems=0

check_present() { # <file> <text> <what it proves>
  if grep -qF -- "$2" "$1"; then
    say "OK: $3"
  else
    say "  FAIL: $3"
    say "  looked for: $2"
    say "  in $1"
    problems=$((problems + 1))
  fi
}

check_absent() { # <file> <text> <what its absence proves>
  if grep -qF -- "$2" "$1"; then
    say "  FAIL: $3"
    say "  did not expect: $2"
    say "  in $1"
    problems=$((problems + 1))
  else
    say "OK: $3"
  fi
}

# ninja starts every compile from out/Release, so the header named by /Yu has to be
# spelled from there; node.gypi spells it from the repository root and the patch
# rewrites it. V8 spells its own value build-relative already and must be left alone.
check_present "$node_src/out/Release/obj/node_base.ninja" \
  "/Yu../../tools/msvs/pch/node_pch.h" \
  "the node precompiled header path is spelled for the build directory"
check_present "$node_src/out/Release/obj/tools/v8_gypfiles/v8_base_without_compiler.ninja" \
  "/Yu../../deps/v8/../../tools/msvs/pch/v8_pch.h" \
  "the v8 precompiled header path is untouched"
# With clang-cl, mksnapshot's .S is converted to a .cc and only the .cc is compiled.
# An asm edge here means ml64 gets a file it cannot read, and the blob symbols would
# be defined twice if it could.
check_absent "$node_src/out/Release/obj/tools/v8_gypfiles/v8_snapshot.ninja" \
  "embedded_asm" \
  "the snapshot blob is not also handed to the assembler"
check_present "$node_src/out/Release/obj/tools/v8_gypfiles/v8_snapshot.ninja" \
  "v8_snapshot.embedded.obj" \
  "the snapshot blob reaches v8_snapshot.lib as a C++ object"

asm_count="$(count_asm_in_archive "$node_src/out/Release/obj/deps/openssl/openssl.ninja")"
say "openssl.lib archive edge carries $asm_count assembled .asm objects"
if [ "$asm_count" = "0" ] || [ "$asm_count" = "no-archive-edge" ]; then
  say "  FAIL: none of OpenSSL's assembled assembly reaches the archive. The link"
  say "  fails later with unresolved symbols (OPENSSL_cleanse, aesni_encrypt, ...)."
  say "  Check that patches/godotjs-openssl-win-asm-outputs-as-sources.patch applied."
  problems=$((problems + 1))
fi

# ninja -t commands needs to load every subninja, which is also the check that no
# MSBuild-only syntax like $(Platform) survived into a ninja file.
if ! ( cd "$node_src" && ninja -C out/Release -t commands node > "$work/node-commands.txt" 2>"$work/ninja-commands.err" ); then
  say "  FAIL: ninja could not read its own files:"
  sed 's/^/local_windows_ninja_check:   /' "$work/ninja-commands.err"
  problems=$((problems + 1))
else
  write_link_rsp "$node_src/out/Release" node.exe
  if ! python3 "$repo/tools/parse_node_link.py" --commands "$work/node-commands.txt" \
       --out-dir "$node_src/out/Release" \
       --whole "$work/whole.txt" --plain "$work/plain.txt" --system "$work/system.txt"; then
    say "  FAIL: package_node.sh could not read the Windows link line"
    problems=$((problems + 1))
  else
    whole_n="$(grep -c '' "$work/whole.txt")"
    plain_n="$(grep -c '' "$work/plain.txt")"
    say "link groups: $whole_n force-loaded, $plain_n normal, $(grep -c '' "$work/system.txt") system flags"
    if [ "$whole_n" -lt 4 ]; then
      say "  FAIL: nothing much is force-loaded; an embedder would lose builtins and"
      say "  snapshot data silently."
      problems=$((problems + 1))
    fi
    if [ "${NODE_TEMPORAL:-on}" = off ] && grep -qx node_crates.lib "$work/plain.txt"; then
      say "  note: node_crates.lib is listed although Temporal was turned off"
    fi
    if [ "${NODE_TEMPORAL:-on}" = off ] && ! grep -qx node_crates.lib "$work/plain.txt"; then
      say "  as expected without Temporal: node_crates.lib is not in the list"
    fi
  fi
fi

# A dry run loads every subninja and needs a producing rule for every input, so it
# finds a missing edge (a generated file nothing writes) without compiling anything.
for target in node openssl-cli.exe; do
  if dry_out="$( ( cd "$node_src" && ninja -C out/Release -n "$target" ) 2>&1)"; then
    say "dry run for $target plans $(printf '%s\n' "$dry_out" | grep -c '') commands"
  else
    say "  FAIL: ninja cannot plan $target - an input has no rule and is not on disk"
    printf '%s\n' "$dry_out" | grep -iE "error|no rule" | head -10 | sed 's/^/local_windows_ninja_check:   /'
    problems=$((problems + 1))
  fi
done

if [ "$problems" -eq 0 ]; then
  say "OK - the Windows ninja files carry the assembled OpenSSL objects and the"
  say "  bundle's link groups read out of them. Nothing was compiled."
  say "build directory: $node_src/out/Release"
fi
exit "$problems"
