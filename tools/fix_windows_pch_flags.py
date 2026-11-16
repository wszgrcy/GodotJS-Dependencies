#!/usr/bin/env python3
"""Make the precompiled header flags in the generated ninja files usable.

Why this exists: clang-cl compares the header named by /Yc (create the precompiled
header from it) with the header named by /Yu (use the precompiled header) as plain
strings. If the two differ it drops both flags after one warning, so the .pch is
never written and every later compile of that target fails with "unable to read PCH
file ... no such file or directory". gyp hands these strings to the compiler
unchanged, which is only correct for the generator that runs the compiler from the
project directory (MSBuild). ninja runs the compiler from the build directory, so a
path written relative to the repository root - which is what node.gypi and
common.gypi contain - names nothing there, and the two flags can come out spelled
differently because gyp produces them in two different places.

patches/godotjs-gyp-win-pch-path.patch fixes the generator. This script applies the
same rule to whatever ninja files came out, so a mismatch is repaired and named in
the build log instead of showing up two thousand compiles later:

  * a /Yu, /FI or /Yc whose value does not already start with "../" is rewritten to
    the build-directory spelling, and only if that path really exists;
  * afterwards, in every step that builds a precompiled header, /Yc and /Yu have to
    read exactly the same, which is what clang-cl checks.

--check reports what it would rewrite and exits non-zero without writing.

Usage: python3 fix_windows_pch_flags.py <build directory> [--check]
       (the build directory is the one holding build.ninja, e.g. out/Release)
"""

import argparse
import pathlib
import re
import sys

# "/Yu<file>", "/Yu:<file>", and the same for /Yc and /FI. A value containing a ninja
# variable, such as "${pchprefix}.node_pch.h.pch", is left alone.
FLAG_RE = re.compile(r"/(Yu|Yc|FI):?([^\s$]+)")
PCH_STEP_RE = re.compile(r"^build [^:\n]*_pch\.obj:\s*(?:cxx|cc)\s", re.M)
# A ninja line that ends in "$" continues on the next line.
CONTINUATION_RE = re.compile(r"\$\s*\n\s*")


def read(path):
    # newline="" keeps the file's own line endings instead of converting them.
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def rewrite_paths(build_dir, files, check_only):
    """Rewrite header paths written from the repository root.

    Returns (list of (file, old flag, new flag), number of flags looked at,
    list of flags left alone because no path fits).
    """
    rewritten = []
    looked_at = 0
    skipped = []

    for path in files:
        text = read(path)

        def replace(match):
            nonlocal looked_at
            name, value = match.group(1), match.group(2)
            looked_at += 1
            if value.startswith("../"):
                return match.group(0)
            # Climb out of the build directory until the name resolves to a file.
            for depth in range(1, 5):
                guess = "../" * depth + value
                if (build_dir / guess).exists():
                    return f"/{name}{guess}"
            skipped.append(f"/{name}{value}")
            return match.group(0)

        changed = FLAG_RE.sub(replace, text)
        if changed == text:
            continue
        before = FLAG_RE.findall(text)
        after = FLAG_RE.findall(changed)
        for old, new in zip(before, after):
            if old != new:
                rewritten.append((path, f"/{old[0]}{old[1]}", f"/{new[0]}{new[1]}"))
        if not check_only:
            write(path, changed)
    return rewritten, looked_at, skipped


def check_pch_steps(build_dir, files):
    """Each step that builds a precompiled header must name one header twice."""
    problems = []
    steps = 0
    for path in files:
        text = CONTINUATION_RE.sub(" ", read(path))
        for match in PCH_STEP_RE.finditer(text):
            steps += 1
            after = text[match.end() :]
            stop = after.find("\nbuild ")
            flags = after if stop < 0 else after[:stop]
            yu = re.findall(r"/Yu:?([^\n ]+)", flags)
            yc = re.findall(r"/Yc:?([^\n ]+)", flags)
            if not yu or not yc:
                problems.append(f"{path}: its step has no /Yu or no /Yc")
            elif yu[0] != yc[0]:
                problems.append(f"{path}: /Yu{yu[0]} but /Yc{yc[0]}")
    return steps, problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("build_dir", type=pathlib.Path)
    parser.add_argument(
        "--check",
        action="store_true",
        help="report what would be rewritten and exit non-zero, change nothing",
    )
    args = parser.parse_args()

    build_dir = args.build_dir.resolve()
    ninja_files = sorted(build_dir.glob("**/*.ninja"))
    if not ninja_files:
        print(f"fix_windows_pch_flags: no .ninja files under {build_dir}", file=sys.stderr)
        return 1

    rewritten, looked_at, skipped = rewrite_paths(build_dir, ninja_files, args.check)
    verb = "would rewrite" if args.check else "rewrote"
    print(
        f"fix_windows_pch_flags: {verb} {len(rewritten)} of {looked_at} precompiled "
        f"header path flag(s) in {len(ninja_files)} ninja file(s)"
    )
    for path, old, new in rewritten[:10]:
        print(f"  {path.relative_to(build_dir)}: {old} -> {new}")
    if len(rewritten) > 10:
        print(f"  ... and {len(rewritten) - 10} more")
    for name in sorted(set(skipped)):
        print(f"fix_windows_pch_flags: left alone, no file behind it: {name}")

    steps, problems = check_pch_steps(build_dir, ninja_files)
    for line in problems:
        print(f"fix_windows_pch_flags: {line}", file=sys.stderr)
    if problems:
        return 1
    print(
        f"fix_windows_pch_flags: {steps} step(s) that build a precompiled header "
        "checked, /Yc and /Yu name the same header in every one"
    )
    return 1 if (args.check and rewritten) else 0


if __name__ == "__main__":
    sys.exit(main())
