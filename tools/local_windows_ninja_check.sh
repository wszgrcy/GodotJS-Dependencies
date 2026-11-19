#!/usr/bin/env bash
#
# Generate Node's Windows ninja files on this machine, and check the two Windows
# build facts that a CI round would otherwise take 40 minutes to reveal.
#
#   bash tools/local_windows_ninja_check.sh --tarball /path/to/node-v26.13.1.tar.xz
#   bash tools/local_windows_ninja_check.sh --arch arm64 --tarball ... --work /work/winarm
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
# With --arch arm64 the same rehearsal also checks the three things that break when an
# x64 machine builds Windows arm64: the host tools have to keep the machine's own
# toolchain, clang-cl has to be told which architecture it is compiling, and the Rust
# archive must not be produced twice with two different toolchains (see the checks
# under "cross-building" below).
#
# Nothing here runs a compiler: no cl.exe, no link.exe, no nasm. It checks what the
# build is about to do, not what it produced.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tarball=""
work="${TMPDIR:-/tmp}/node-win-ninja-check"
skip_prepare=0
arch=x86_64

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) tarball="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --skip-prepare) skip_prepare=1; shift ;;
    --arch) arch="$2"; shift 2 ;;
    *) echo "local_windows_ninja_check: unknown argument $1" >&2; exit 2 ;;
  esac
done

case "$arch" in
  x86_64) target_arch=x64 ;;
  arm64) target_arch=arm64 ;;
  *) fail "--arch is '$arch', expected x86_64 or arm64" ;;
esac
# The toolchain of the machine running this script; the host toolset has to keep it.
host_arch=x64

node_src="$work/node"
fake_vs="$work/fake-vs"
args_file="$repo/node.windows_${arch}.configure.txt"

say() { echo "local_windows_ninja_check: $*"; }
fail() { echo "local_windows_ninja_check: FAIL - $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. The Visual Studio that gyp believes it found
# ---------------------------------------------------------------------------
make_fake_vs() {
  local vs="$1"
  local msvc="$vs/VC/Tools/MSVC/14.40.33807"
  mkdir -p "$msvc/include" "$msvc/lib/$target_arch" "$vs/VC/Auxiliary/Build" "$vs/bin"
  : > "$msvc/include/stdio.h"   # gyp checks that the include dir is a real dir
  # gyp runs this and parses the variables out of it. SYSTEMROOT, TEMP and TMP are
  # required by _ExtractImportantEnvironment; the rest feed INCLUDE/LIB/PATH.
  cat > "$vs/VC/Auxiliary/Build/vcvarsall.bat" <<EOF
#!/bin/sh
V="$msvc"
echo "INCLUDE=\$V/include"
echo "LIB=\$V/lib/$target_arch"
echo "LIBPATH=\$V/lib/$target_arch"
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

# ninja writes a link's response file just before running the link and deletes it
# afterwards, and tools/parse_node_link.py rebuilds its content from the ninja files
# (the rule says `rspfile_content = $in_newline $libs $ldflags`, the edge carries the
# variables). Nothing here creates a response file: a leftover one would make the
# rehearsal read a file the real build does not leave behind.


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
rust_windows_target="${target_arch/x64/x86_64}-pc-windows-msvc"
if [ "${NODE_TEMPORAL:-}" = "" ]; then
  if ! rustc --print target-list 2>/dev/null | grep -qx "$rust_windows_target" || \
     ! ls "$(rustc --print sysroot)/lib/rustlib" 2>/dev/null | grep -qx "$rust_windows_target"; then
    export NODE_TEMPORAL=off
    say "the Rust target $rust_windows_target is not installed, so Temporal is off"
    say "  for this rehearsal; node_crates.lib will be missing from the archive list"
  fi
fi

# An x64 machine building arm64 has to tell clang-cl which architecture it wants:
# clang-cl picks the target from --target and defaults to the architecture clang itself
# was built for. The triple goes in through CFLAGS/CXXFLAGS, which gyp appends to the
# target toolset's command line only (generator/ninja.py reads CFLAGS_host/CXXFLAGS_host
# for the host toolset), which is exactly where it belongs: putting it on the host
# toolset would compile mksnapshot for the target and this machine could not run it.
if [ "$arch" != x86_64 ]; then
  case "$target_arch" in
    arm64) triple="--target=aarch64-windows-msvc" ;;
    x64) triple="--target=x86_64-windows-msvc" ;;
  esac
  export CFLAGS="$triple" CXXFLAGS="$triple"
  say "target toolset flags from the environment: $triple"
fi

# This machine is not an arm64 machine, so the arm64 rehearsal reproduces the cross
# shape: host x64, target arm64. That is what asks for the toolset split, and the split
# is what the cross-build checks below look at. A native arm64 runner has no split, and
# its argument file node.windows_arm64.configure.txt does not pass this flag.
if [ "$arch" != x86_64 ]; then
  printf -- '--cross-compiling\n' >> "$work/args.txt.cross"
fi

if [ "$skip_prepare" -eq 0 ]; then
  say "prepare_node_build.sh with the windows $arch arguments"
  cp "$args_file" "$work/args.txt"
  [ -f "$work/args.txt.cross" ] && cat "$work/args.txt.cross" >> "$work/args.txt"
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
# The repair script carries its own cases, including the Windows spellings this
# machine cannot otherwise produce.
if python3 "$repo/tools/fix_windows_pch_flags.py" --selftest; then
  say "OK: the precompiled header repair rules pass their own cases"
else
  say "  FAIL: the precompiled header repair rules do not behave"
  problems=$((problems + 1))
fi
# The generator's own rule, tested with a path function that spells the way Windows
# does. A value that is already build-relative must not be translated a second time,
# and "already build-relative" has to be recognised with both separators: on Windows
# the translated value reads "..\tools\...", and translating that again is what put
# four "../" on /Yu while /Yc had two, which clang-cl refuses.
if python3 - "$node_src/tools/gyp/pylib" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
import gyp.generator.ninja as ninja


class Writer:
    PCH_PATH_FLAGS = ninja.NinjaWriter.PCH_PATH_FLAGS
    translate = ninja.NinjaWriter.PchFlagsRelativeToBuildDir

    def __init__(self):
        self.translated = []

    def GypPathToNinja(self, path):
        # What the real one returns on Windows: build-relative, backslashes.
        self.translated.append(path)
        return "..\\" + path.replace("/", "\\")


cases = [
    ("a path from the repository root is translated", ["/Yutools/msvs/pch/node_pch.h"],
     ["/Yu..\\tools\\msvs\\pch\\node_pch.h"], 1),
    ("a value already spelled with backslashes is left alone",
     ["/Yu..\\..\\tools\\msvs\\pch\\node_pch.h"],
     ["/Yu..\\..\\tools\\msvs\\pch\\node_pch.h"], 0),
    ("a value already spelled with slashes is left alone",
     ["/Yu../../tools/msvs/pch/node_pch.h"],
     ["/Yu../../tools/msvs/pch/node_pch.h"], 0),
    ("the same holds for /Yc", ["/Yc..\\..\\tools\\msvs\\pch\\node_pch.h"],
     ["/Yc..\\..\\tools\\msvs\\pch\\node_pch.h"], 0),
]

failures = 0
for title, flags, expected, calls in cases:
    writer = Writer()
    got = writer.translate(flags)
    if got != expected or len(writer.translated) != calls:
        failures += 1
        print(f"  FAIL: {title}: got {got} after {len(writer.translated)} translation(s), "
              f"expected {expected} after {calls}")
print("local_windows_ninja_check: OK: the generator does not translate a build-relative "
      "header path twice" if failures == 0 else
      "local_windows_ninja_check: the generator's precompiled header rule is wrong")
sys.exit(1 if failures else 0)
PY
then
  :
else
  problems=$((problems + 1))
fi
# clang-cl compares the /Yc and /Yu header names as plain strings and drops both
# flags when they differ, so in every target the step that creates the .pch and the
# compiles that use it have to name the header identically. The same check the build
# runs, in report-only mode: it looks at every ninja file, not just these two.
if python3 "$repo/tools/fix_windows_pch_flags.py" "$node_src/out/Release" --check; then
  say "OK: the generated ninja files agree on the precompiled header everywhere"
else
  say "  FAIL: the generated ninja files disagree about the precompiled header"
  problems=$((problems + 1))
fi
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

# /WHOLEARCHIVE has to name a file the linker can actually open. node.gyp writes those
# libraries where MSBuild puts them (lib/); ninja puts them under obj/, and the link then
# dies with LNK1356 on a file nothing creates. This reads every generated ninja file, so
# it catches the mismatch in seconds instead of at [4222/4233].
if python3 "$repo/tools/check_wholearchive_paths.py" "$node_src/out/Release"; then
  say "OK: every /WHOLEARCHIVE flag names a library this build produces"
else
  say "  FAIL: a /WHOLEARCHIVE flag names a library nothing produces; that link fails"
  say "  with LNK1356. Check that"
  say "  patches/godotjs-node-win-ninja-wholearchive-obj-paths.patch applied."
  problems=$((problems + 1))
fi

# ninja -t commands needs to load every subninja, which is also the check that no
# MSBuild-only syntax like $(Platform) survived into a ninja file.
if ! ( cd "$node_src" && ninja -C out/Release -t commands node > "$work/node-commands.txt" 2>"$work/ninja-commands.err" ); then
  say "  FAIL: ninja could not read its own files:"
  sed 's/^/local_windows_ninja_check:   /' "$work/ninja-commands.err"
  problems=$((problems + 1))
else
  # No response file is written here on purpose - see the note near the top of this
  # script: ninja does not leave one behind, and the tool rebuilds its content.
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

# ---------------------------------------------------------------------------
# 4. Cross-building arm64 on an x64 machine: the three things that break
# ---------------------------------------------------------------------------
# These only apply to the arm64 rehearsal, where the machine's own architecture is not
# the architecture being built. Every one of them is checked in the generated files,
# because each one has cost a full CI round to find.
if [ "$arch" = arm64 ]; then
  # 1. The snapshot tools run on the build machine, so they belong to the host toolset
  #    and have to keep this machine's toolchain. patches/godotjs-gyp-win-clang-cl.patch
  #    makes that happen; without it the host objects name the arm64 compiler and the
  #    build then cannot start the mksnapshot.exe it just produced.
  host_ninja="$node_src/out/Release/obj/tools/v8_gypfiles/v8_snapshot.host.ninja"
  [ -f "$host_ninja" ] || fail "no host-toolset ninja file was generated ($host_ninja)"
  check_present "$host_ninja" "arch = environment.$host_arch" \
    "the host toolset keeps this machine's toolchain (mksnapshot has to run here)"
  check_absent "$host_ninja" "arch = environment.$target_arch" \
    "the host toolset is not built with the target's toolchain"
  check_present "$node_src/out/Release/obj/node_base.ninja" \
    "arch = environment.$target_arch" \
    "the target toolset uses the architecture being built"

  # 2. clang-cl is one compiler for every architecture and picks the one it compiles
  #    from --target; its default is the architecture clang itself was built for. So a
  #    cross build needs the triple in the flags, or every arm64 object is x86_64 and
  #    the link dies on the first ARM64-only symbol (or worse, silently ships the wrong
  #    architecture). The path Node hands clang-cl carries no triple, so it comes in
  #    through CFLAGS/CXXFLAGS - gyp appends them to the target toolset only
  #    (generator/ninja.py reads CFLAGS/CXXFLAGS for the target and *_host for host),
  #    which is what the next two checks prove: the triple is on the target's command
  #    line and absent from the host's, where it would break mksnapshot.
  triple=""
  case "$target_arch" in
    arm64) triple="--target=aarch64-windows-msvc" ;;
    x64) triple="--target=x86_64-windows-msvc" ;;
  esac
  if [ -n "$triple" ] && [ "${NODE_TARGET_TRIPLE:-on}" != off ]; then
    check_present "$node_src/out/Release/obj/node_base.ninja" "$triple" \
      "clang-cl is told which architecture to compile (target toolset)"
    check_absent "$host_ninja" "$triple" \
      "the host toolset keeps clang's own default target"
  fi

  # 3. Temporal is Rust, and cargo writes its archive to a path taken from
  #    target/$(host triple)/release, which gyp makes absolute with abspath() - a path
  #    with no toolset in it. A build with two toolsets therefore has two rules
  #    producing one file, which ninja refuses before it compiles anything.
  #    patches/node-66823-rust-host-target.patch skips Windows on purpose, so the build
  #    is configured with --without-snapshot-temporal instead; these two checks show the
  #    collision is really gone rather than merely untested.
  crates_rules="$(grep -lE '^build [^:]*node_crates\.lib' \
    $(find "$node_src/out/Release/obj" -name '*.ninja') 2>&1 || true)"
  crates_files="$(grep -hoE 'node_crates\.lib' $(find "$node_src/out/Release/obj" -name '*.ninja') 2>&1 | wc -l || true)"
  say "node_crates.lib appears in $(printf '%s\n' "$crates_rules" | grep -c . ) rule(s) and $crates_files place(s) in total"
  if [ "${NODE_TEMPORAL:-on}" = on ]; then
    if [ "$(printf '%s\n' "$crates_rules" | grep -c .)" -gt 1 ]; then
      say "  FAIL: more than one rule generates node_crates.lib; ninja stops with"
      say "  'multiple rules generate'. This is the upstream bug, not ours:"
      say "  node-66823-rust-host-target.patch skips Windows, so Temporal has to stay"
      say "  off for a Windows cross build (the workflow says so out loud)."
      problems=$((problems + 1))
    else
      say "OK: node_crates.lib has exactly one producing rule"
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
