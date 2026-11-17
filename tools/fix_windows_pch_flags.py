#!/usr/bin/env python3
"""Make the precompiled header flags in the generated ninja files usable.

Two things have to be true for clang-cl to use a precompiled header here, and both are
about strings rather than about files:

  * the header named by /Yc ("create the .pch from this") and the header named by /Yu
    ("use the .pch") have to read exactly the same - clang-cl compares them with
    strcmp and, if they differ, drops both flags after one warning, so no .pch is
    written and every later compile of that target fails with "unable to read PCH
    file ... no such file or directory";
  * the path has to be spelled from the directory ninja runs the compiler in (the
    build directory, out/Release), which is not what Node's gyp files contain.

gyp hands these paths to the compiler unchanged; patches/godotjs-gyp-win-pch-path.patch
makes it translate them. This script applies the same rules to whatever ninja files
came out, so a problem is repaired and named in the build log instead of showing up
two thousand compiles later:

  pass 1 - every /Yu, /FI and /Yc value has to name a real file when read from the
           build directory. A value that does not is re-rooted by climbing a different
           number of directories, and nothing is changed unless the result exists.
  pass 2 - inside a step that builds a precompiled header, /Yu, /FI and /Yc are made
           to read identically, keeping the spelling /Yu has. Two spellings that both
           exist (../x and ..\\x) are still different strings to clang-cl.

--check reports what it would change and exits non-zero without writing.
--selftest runs the rules against a small tree it builds itself, which is the only way
to exercise the backslash spellings on a machine that is not Windows.

Usage: python3 fix_windows_pch_flags.py <build directory> [--check]
       python3 fix_windows_pch_flags.py --selftest
       (the build directory is the one holding build.ninja, e.g. out/Release)
"""

import argparse
import pathlib
import re
import sys
import tempfile

# "/Yu<file>", "/Yu:<file>", and the same for /Yc and /FI. A value holding a ninja
# variable, such as "${pchprefix}.node_pch.h.pch", is not a path and is left alone.
FLAG_RE = re.compile(r"/(Yu|Yc|FI)(:?)([^\s$]+)")
FLAG_NAMES = ("Yu", "Yc", "FI")
# The line that builds a target's precompiled header. The rule name is not required:
# a long statement is wrapped with "$" and the rule can land on the next line.
PCH_STEP_RE = re.compile(r"^build [^:\n]*_pch\.obj:")
UP_RE = re.compile(r"\.\.[\\/]")
MAX_CLIMB = 4


def split_leading_up(value):
    """Split a path into (leading "up" parts, the rest, separator used)."""
    ups = 0
    rest = value
    style = "/"
    while UP_RE.match(rest):
        style = rest[2]
        rest = rest[3:]
        ups += 1
    return ups, rest, style


def variants(value):
    """Spellings to try for a header path, fewest climbs first.

    gyp sometimes hands the value relative to the repository root, sometimes already
    build-relative, and it has also been seen translated twice, so the number of
    leading "up" parts is not to be trusted; the rest of the path is.
    """
    _ups, rest, style = split_leading_up(value)
    up = ".." + style
    for climb in range(0, MAX_CLIMB + 1):
        yield rest if climb == 0 else up * climb + rest


def resolves(build_dir, value):
    """True when the build directory plus this value is a real file.

    Separators are normalised because ninja files written on Windows use backslashes
    and this has to be checkable on any host.
    """
    return (build_dir / value.replace("\\", "/")).is_file()


def repair_line(line, build_dir, changes, where):
    """Pass 1 for one line: make every header path name a real file."""

    def replace(match):
        name, sep, value = match.group(1), match.group(2), match.group(3)
        if resolves(build_dir, value):
            return match.group(0)
        for guess in variants(value):
            if resolves(build_dir, guess):
                changes.append((where, f"/{name}{sep}{value}", f"/{name}{sep}{guess}"))
                return f"/{name}{sep}{guess}"
        changes.append((where, f"/{name}{sep}{value}", "left alone, no file behind it"))
        return match.group(0)

    return FLAG_RE.sub(replace, line)


def pch_step_blocks(lines):
    """Line numbers of each step that builds a precompiled header, with its own
    variable lines (which are indented, and may be continued with a trailing "$")."""
    blocks = []
    current = None
    continued = False
    for number, line in enumerate(lines):
        if PCH_STEP_RE.match(line):
            current = [number]
            blocks.append(current)
        elif current is not None and (line.startswith("  ") or continued):
            current.append(number)
        else:
            current = None
        continued = line.rstrip("\r\n").endswith("$")
    return blocks


def step_flag_values(lines, indices):
    """First value seen for each header flag inside a step."""
    values = {}
    for number in indices:
        for match in FLAG_RE.finditer(lines[number]):
            values.setdefault(match.group(1), (number, match.group(3)))
    return values


def agree_step(lines, indices, build_dir, changes, where):
    """Pass 2 for one step: the header flags have to read identically."""
    values = step_flag_values(lines, indices)
    if "Yc" not in values:
        return "nothing here creates the precompiled header (no /Yc)"
    # Keep /Yu's spelling: that is what every other compile of the target uses.
    wanted = values.get("Yu", values["Yc"])[1]
    if not resolves(build_dir, wanted):
        wanted = next(
            (values[name][1] for name in FLAG_NAMES if name in values and resolves(build_dir, values[name][1])),
            None,
        )
        if wanted is None:
            return "no header flag in this step names a real file"
    for name in FLAG_NAMES:
        if name not in values or values[name][1] == wanted:
            continue
        number, old = values[name]
        # The replacement is a path that can hold backslashes, so it must not be read
        # as a regex replacement template: pass it through a function.
        lines[number] = re.sub(
            rf"/{name}:?[^\s$]+",
            lambda _match, replacement=f"/{name}{wanted}": replacement,
            lines[number],
            count=1,
        )
        changes.append((where, f"/{name}{old}", f"/{name}{wanted}"))
    return None


def check_steps(lines, build_dir):
    """(number of steps found, list of complaints) about /Yc against /Yu."""
    problems = []
    blocks = pch_step_blocks(lines)
    for indices in blocks:
        values = step_flag_values(lines, indices)
        if "Yc" not in values or "Yu" not in values:
            problems.append("no /Yc or no /Yu in a step that builds the header")
        elif values["Yc"][1] != values["Yu"][1]:
            problems.append(f"/Yu{values['Yu'][1]} but /Yc{values['Yc'][1]}")
    return len(blocks), problems


def read(path):
    # newline="" keeps the file's own line endings instead of converting them: ninja
    # files written on Windows are CRLF, and a trailing \r would read as part of a value.
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def process(build_dir, files, check_only):
    """Apply both passes to every file. Returns (changes, problem lines)."""
    changes = []
    problems = []
    for path in files:
        where = path.relative_to(build_dir)
        original = read(path)
        lines = original.splitlines(keepends=True)
        for number, line in enumerate(lines):
            lines[number] = repair_line(line, build_dir, changes, where)
        for indices in pch_step_blocks(lines):
            problem = agree_step(lines, indices, build_dir, changes, where)
            if problem:
                problems.append(f"{where}: {problem}")
        rebuilt = "".join(lines)
        if rebuilt != original and not check_only:
            write(path, rebuilt)
    return changes, problems


def selftest():
    """Run the rules against a small tree built here, Windows spellings included."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "tools/msvs/pch").mkdir(parents=True)
        (root / "tools/msvs/pch/node_pch.h").write_text("// header\n")
        build = root / "out/Release"
        (build / "obj").mkdir(parents=True)
        path = build / "obj/node_base.ninja"
        good = "../../tools/msvs/pch/node_pch.h"
        back = good.replace("/", "\\")
        back_double = ("../../" + good).replace("/", "\\")
        step = "build obj/pch/node_base.node_pch.obj: cxx ../../tools/msvs/pch/node_pch.cc\n"
        cases = [
            (
                "a path written from the repository root is rooted at the build directory",
                step + "  cflags_cc = /TP /Yutools/msvs/pch/node_pch.h /Yctools/msvs/pch/node_pch.h\n",
                [f"/Yu{good}", f"/Yc{good}"],
            ),
            (
                "the Windows spelling of the same path is left as it is",
                step + f"  cflags_cc = /TP /Yu{back} /Yc{back}\n",
                [],
            ),
            (
                "a path translated twice is pulled back inside the repository",
                step + f"  cflags_cc = /TP /Yu../../../../tools/msvs/pch/node_pch.h /Yc{good}\n",
                [f"/Yu{good}"],
            ),
            (
                "two spellings that both exist are made to read the same",
                step + f"  cflags_cc = /TP /Yu{good} /Yc{back}\n",
                [f"/Yc{good}"],
            ),
            (
                "a step whose flags are spread over continued lines is still read",
                step + f"  cflags_cc = /TP /Yu{good} $\n      /Yc{good}\n",
                [],
            ),
            (
                "the shape CI produced: /Yu translated twice, /Yc once, /FI twice",
                step
                + f"  cflags_cc = /TP /Yu{back_double} /FI{back_double} /Yc{back} $\n      "
                + "/Fp${pchprefix}.node_pch.h.pch\n",
                [f"/Yu{back}", f"/FI{back}"],
            ),
            (
                "a build statement wrapped after the colon is still a step, and the "
                "spelling /Yu ends up with is the one the other two take",
                "build obj/pch/node_base.node_pch.obj: $\n"
                "    cxx ../../tools/msvs/pch/node_pch.cc || $\n"
                "    obj/node_base.compile_depends.stamp\n"
                f"  cflags_cc = /TP /Yu{back_double} /FI{good} $\n      /Yc{good}\n",
                [f"/Yu{back}", f"/FI{back}", f"/Yc{back}"],
            ),
        ]
        failures = 0
        for title, text, expected in cases:
            path.write_text(text)
            changes, problems = process(build, [path], False)
            got = sorted(new for _w, _o, new in changes if not new.startswith("left alone"))
            _count, step_problems = check_steps(read(path).splitlines(keepends=True), build)
            ok = got == sorted(expected) and not step_problems and not problems
            print(f"fix_windows_pch_flags selftest: {'ok  ' if ok else 'FAIL'} - {title}")
            if not ok:
                print(f"  expected {expected}, got {got}, step problems {step_problems}, problems {problems}")
                print(f"  file after: {read(path)!r}")
                failures += 1
        print(
            f"fix_windows_pch_flags selftest: "
            f"{'PASS' if failures == 0 else 'FAILED'} ({len(cases)} case(s))"
        )
        return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("build_dir", type=pathlib.Path, nargs="?")
    parser.add_argument(
        "--check",
        action="store_true",
        help="report what would be rewritten and exit non-zero, change nothing",
    )
    parser.add_argument("--selftest", action="store_true", help="run the built-in cases")
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if args.build_dir is None:
        parser.error("a build directory is required unless --selftest is given")

    build_dir = args.build_dir.resolve()
    ninja_files = sorted(build_dir.glob("**/*.ninja"))
    if not ninja_files:
        print(f"fix_windows_pch_flags: no .ninja files under {build_dir}", file=sys.stderr)
        return 1

    changes, problems = process(build_dir, ninja_files, args.check)
    verb = "would rewrite" if args.check else "rewrote"
    print(
        f"fix_windows_pch_flags: {verb} {len(changes)} precompiled header flag(s) "
        f"in {len(ninja_files)} ninja file(s)"
    )
    for where, old, new in changes[:10]:
        print(f"  {where}: {old} -> {new}")
    if len(changes) > 10:
        print(f"  ... and {len(changes) - 10} more")
    for problem in problems:
        print(f"fix_windows_pch_flags: {problem}", file=sys.stderr)

    checked = 0
    for path in ninja_files:
        count, step_problems = check_steps(read(path).splitlines(keepends=True), build_dir)
        checked += count
        for problem in step_problems:
            line = f"{path.relative_to(build_dir)}: {problem}"
            print(f"fix_windows_pch_flags: {line}", file=sys.stderr)
            problems.append(line)
    if problems:
        return 1
    print(
        f"fix_windows_pch_flags: {checked} step(s) that build a precompiled header "
        "checked, /Yc and /Yu name the same header in every one"
    )
    return 1 if (args.check and changes) else 0


if __name__ == "__main__":
    sys.exit(main())
