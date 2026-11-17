#!/usr/bin/env bash
# Get zstd onto this machine and use it to pack/unpack a release bundle.
#
# The runner images are not trusted to have zstd: the Windows ones do not have it
# at all, and a bundle that only fails to compress at the end of a 40-minute build
# costs a whole round. So the workflow calls "ensure" early (which installs what
# is missing and is a no-op when zstd is already there), then packs with the same
# script it just tested.
#
# Where zstd comes from on each runner:
#   already on PATH   - Ubuntu images have it, and so do the macOS ones today
#   Windows           - the official win64 zip from the zstd release page: there is
#                       no package manager to blame for a pinned version there
#   Linux without it  - apt
#   macOS without it  - brew
#
# The archive is a plain tar piped through zstd, so any `tar` can read it:
#   tar --zstd -xf file.tar.zst      (GNU tar with zstd on PATH)
#   tar -xf file.tar.zst             (bsdtar)
#   zstd -dc file.tar.zst | tar -xf -
set -euo pipefail

# Pinned because the Windows download names this in the file name; a release page
# that stops carrying that file would otherwise fail with a 404 in the middle of a
# build. A zstd already on PATH may be another version, which is fine.
ZSTD_VERSION="${ZSTD_VERSION:-1.5.7}"
ZSTD_TOOL_DIR="${ZSTD_TOOL_DIR:-$PWD/.zstd-tool}"

say() { echo "zstd_tool: $*"; }

# Which zstd to run, once found or installed. A path rather than the bare name, so
# the download on Windows does not depend on PATH being updated in the same shell
# that downloaded it (GITHUB_PATH only takes effect in the next step).
ZSTD_BIN=""

zstd_version_of() {
    "$1" --version 2>&1 | head -1 || echo "(this machine cannot run it)"
}

use_zstd() {
    ZSTD_BIN="$1"
    # So that a tar which shells out to `zstd` (GNU tar's --zstd) finds it in this
    # shell too, not only in the next step.
    PATH="$PATH:$(dirname "$ZSTD_BIN")"
    say "using $(zstd_version_of "$ZSTD_BIN")"
}

apt_run() {
    if [ "$(id -u)" -eq 0 ]; then
        apt-get "$@"
    else
        sudo apt-get "$@"
    fi
}

ensure_zstd() {
    if [ -n "$ZSTD_BIN" ]; then
        return 0
    fi
    if command -v zstd > /dev/null 2>&1; then
        use_zstd "$(command -v zstd)"
        return 0
    fi
    local os
    os="${RUNNER_OS:-$(uname -s)}"
    case "$os" in
        Windows)
            local url="https://github.com/meta/zstd/releases/download/v${ZSTD_VERSION}/zstd-v${ZSTD_VERSION}-win64.zip"
            mkdir -p "$ZSTD_TOOL_DIR"
            say "downloading $url"
            curl -fsSL --retry 3 -o "$ZSTD_TOOL_DIR/zstd-win.zip" "$url"
            # unzip exists in the Git Bash that runs these steps; System32's tar is
            # bsdtar and reads zips too, so there is a way even without unzip.
            if command -v unzip > /dev/null 2>&1; then
                unzip -q -o "$ZSTD_TOOL_DIR/zstd-win.zip" -d "$ZSTD_TOOL_DIR"
            else
                /c/Windows/System32/tar.exe -xf "$ZSTD_TOOL_DIR/zstd-win.zip" -C "$ZSTD_TOOL_DIR"
            fi
            local exe="$ZSTD_TOOL_DIR/zstd-v${ZSTD_VERSION}-win64/zstd.exe"
            [ -f "$exe" ] || { say "no zstd.exe after extracting"; exit 1; }
            chmod +x "$exe"
            # Later steps are separate shells, so they need it on PATH as well; and
            # zstd.exe is what they find under the name zstd.
            if [ -n "${GITHUB_PATH:-}" ]; then
                echo "$(dirname "$exe")" >> "$GITHUB_PATH"
            fi
            use_zstd "$exe"
            ;;
        macOS)
            say "brew install zstd"
            brew install zstd
            command -v zstd > /dev/null 2>&1 || { say "zstd still not on PATH after brew"; exit 1; }
            use_zstd "$(command -v zstd)"
            ;;
        Linux | *)
            # Runner images ship apt lists that are often too old to resolve the
            # package, so update only when the first attempt fails.
            apt_run install -y --no-install-recommends zstd || {
                apt_run update -y > /dev/null
                apt_run install -y --no-install-recommends zstd
            }
            command -v zstd > /dev/null 2>&1 || { say "zstd still not on PATH after apt"; exit 1; }
            use_zstd "$(command -v zstd)"
            ;;
    esac
}

# Sizes only matter for the log, so a missing du must not break packaging.
human() { du -sh "$1" 2> /dev/null | cut -f1 || echo "?"; }

pack() {
    local directory="" name="" out="" level=15
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --directory) directory="$2"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            --out) out="$2"; shift 2 ;;
            --level) level="$2"; shift 2 ;;
            *) say "pack: unknown argument $1"; exit 1 ;;
        esac
    done
    [ -n "$directory" ] && [ -n "$name" ] && [ -n "$out" ] || {
        say "pack needs --directory, --name and --out"
        exit 1
    }
    [ -d "$directory/$name" ] || { say "$directory/$name is not a directory; nothing to pack"; exit 1; }
    ensure_zstd
    say "packing $name/ from $directory with level $level"
    ( cd "$directory" && tar -cf - "$name" ) | "$ZSTD_BIN" -q "-$level" -T0 > "$out"
    # An empty or truncated archive would sit on the release page looking fine
    # until someone tried to link against it, so check it like anything else that
    # arrives over a network.
    [ -s "$out" ] || { say "$out was written empty"; exit 1; }
    "$ZSTD_BIN" -t "$out" || { say "$out does not pass zstd's own integrity check"; exit 1; }
    say "$(human "$directory/$name") -> $(human "$out") -> $out"
}

unpack() {
    local archive="" into=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --archive) archive="$2"; shift 2 ;;
            --into) into="$2"; shift 2 ;;
            *) say "unpack: unknown argument $1"; exit 1 ;;
        esac
    done
    [ -f "$archive" ] && [ -n "$into" ] || { say "unpack needs --archive and --into"; exit 1; }
    ensure_zstd
    mkdir -p "$into"
    "$ZSTD_BIN" -dc "$archive" | tar -xf - -C "$into"
    say "$archive unpacked into $into"
}

# What the beginning of a build job runs: install, then do the real thing on a
# throwaway bundle and compare bytes. Compression is not the risky part; reading
# it back on the same machine is what a consumer would do first.
roundtrip() {
    local level=15
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --level) level="$2"; shift 2 ;;
            *) say "roundtrip: unknown argument $1"; exit 1 ;;
        esac
    done
    # Not local: the EXIT trap runs after this function is gone, and a local would
    # have been unbound by then.
    RT_WORK="$(mktemp -d)"
    trap 'rm -rf "${RT_WORK:-}"' EXIT
    local work="$RT_WORK"
    mkdir -p "$work/sample/node/include"
    # Compressible payload on purpose: the real bundle is static archives full of
    # symbol and debug records, not random bytes.
    python3 -c 'import sys; open(sys.argv[1], "wb").write(b"node archive stand-in " * 400000)' \
        "$work/sample/node/include/sample.bin"
    pack --directory "$work/sample" --name node --out "$work/out.tar.zst" --level "$level"
    unpack --archive "$work/out.tar.zst" --into "$work/back"
    cmp "$work/sample/node/include/sample.bin" "$work/back/node/include/sample.bin"
    # Not the point of the check, but worth knowing: a tar that can shell out to
    # zstd reads the file directly. bsdtar has no --zstd option, so this is a note
    # and never a failure.
    if tar --zstd -tf "$work/out.tar.zst" > /dev/null 2>&1; then
        say "tar --zstd can list it directly too"
    else
        say "this tar has no --zstd option; zstd -dc file | tar -xf - still works"
    fi
    say "round trip good at level $level"
}

case "${1:-}" in
    ensure) ensure_zstd ;;
    pack) shift; pack "$@" ;;
    unpack) shift; unpack "$@" ;;
    roundtrip) shift; roundtrip "$@" ;;
    *)
        cat <<'USAGE'
usage: zstd_tool.sh ensure
       zstd_tool.sh pack --directory DIR --name NAME --out FILE [--level N]
       zstd_tool.sh unpack --archive FILE --into DIR
       zstd_tool.sh roundtrip [--level N]
USAGE
        exit 1
        ;;
esac
