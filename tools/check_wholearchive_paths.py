#!/usr/bin/env python3
"""Check every /WHOLEARCHIVE flag in a generated ninja build names a library that build produces.

Usage: python3 check_wholearchive_paths.py <build_dir>

MSVC keeps the contents of a library named by /WHOLEARCHIVE:<file>, so the file has to
exist when the linker runs. node.gyp writes those flags as <(PRODUCT_DIR)/lib/<name>.lib,
which is the MSBuild location; under ninja the same libraries land in obj/<its directory>/,
and a link then dies with "LNK1356: cannot find library". A ninja file is plain text, so
this reads the generated ones, collects what each edge outputs, and checks each flag names
one of those outputs (or a file that is already on disk).

Exits 1 and lists the offenders when a flag names nothing the build produces.
"""

import pathlib
import re
import sys

BUILD_RE = re.compile(r"^build [^:]+:")
WHOLE_RE = re.compile(r"/WHOLEARCHIVE:([^\s$]+)", re.IGNORECASE)


def normalize(path):
    return path.replace("\\", "/").lstrip("./")


def ninja_blocks(text):
    """Yield (line_number, statement) for each ninja statement, joined across $ continuations."""
    # ninja continues a statement with a trailing "$"; a literal "$" is written "$$".
    joined = re.sub(r"(?<!\$)\$\s*\r?\n\s*", " ", text)
    for number, line in enumerate(joined.splitlines(), 1):
        yield number, line


def build_outputs(text):
    outputs = set()
    for _, line in ninja_blocks(text):
        if not BUILD_RE.match(line):
            continue
        left = line[len("build "):].split(":", 1)[0]
        # "|" and "||" separate implicit and order-only dependencies from outputs.
        left = re.split(r"\s\|\|?\s", left)[0]
        for token in left.split():
            if token != "|":
                outputs.add(normalize(token))
    return outputs


def main(build_dir):
    root = pathlib.Path(build_dir)
    if not root.is_dir():
        print(f"check_wholearchive_paths: {root} is not a directory", file=sys.stderr)
        return 1

    ninja_files = sorted(root.rglob("*.ninja"))
    if not ninja_files:
        print(f"check_wholearchive_paths: no .ninja files under {root}", file=sys.stderr)
        return 1

    outputs = set()
    for path in ninja_files:
        outputs |= build_outputs(path.read_text(encoding="utf-8", errors="replace", newline=""))

    checked = 0
    offenders = []
    for path in ninja_files:
        text = path.read_text(encoding="utf-8", errors="replace", newline="")
        for _, line in ninja_blocks(text):
            for match in WHOLE_RE.finditer(line):
                checked += 1
                named = normalize(match.group(1))
                if named in outputs or (root / named).exists():
                    continue
                offenders.append((path.relative_to(root), match.group(1)))

    print(
        f"check_wholearchive_paths: {checked} /WHOLEARCHIVE flag(s) in "
        f"{len(ninja_files)} ninja file(s); "
        f"{checked - len(offenders)} name a library this build produces"
    )
    for where, flag in offenders:
        print(f"  {where}: /WHOLEARCHIVE:{flag} is not produced by any edge")
    if offenders:
        print(
            "check_wholearchive_paths: the linker cannot open the flags above "
            "(LNK1356 when that link runs)",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
