#!/usr/bin/env python3
"""Read the `node` target's link command and split it into the bundle's link groups.

    parse_node_link.py --commands FILE --whole OUT --plain OUT --system OUT
                       [--out-dir DIR]
    parse_node_link.py --tokens FILE --whole OUT --plain OUT --system OUT

`--commands` takes the output of `ninja -C <out> -t commands node` (several
command lines, one per line) and uses the last line that looks like a link of the
Node archives. `--tokens` takes a file that already holds one token per line and
treats all of it as a single command.

The three output files list, one per line: the archives that have to be
force-loaded, the archives that are linked normally, and the system libraries and
linker flags an embedder has to repeat. `package_node.sh` writes those into
`link.txt`, so whatever shows up here is what the engine will use.

Why the three linkers are handled separately: GNU ld takes a group
(-Wl,--whole-archive ... -Wl,--no-whole-archive), ld64 (macOS) takes
-Wl,-force_load,<archive> per archive, and the MSVC linker takes
/WHOLEARCHIVE:<archive> per archive and usually gets its arguments through a
response file (@file), which is why response files are expanded here.

    python3 parse_node_link.py --selftest
runs the three shapes against built-in expectations.
"""

import argparse
import os
import sys
import tempfile

# Archives Node has to force-load even when the link line carries no marker for it
# (builtins and snapshot data live in objects nothing else references). Only used
# when the command itself revealed no force-loaded archive at all.
FALLBACK_WHOLE = [
    'libnode_base.a',
    'libv8_base_without_compiler.a',
    'libzlib.a',
    'libuv.a',
    'libv8_snapshot.a',
    'libopenssl.a',
]


def tokenize(text):
    """Split a command line (or a response file's content) into tokens.

    Written by hand instead of using shlex: Windows paths are full of backslashes and
    MSVC response files quote only the entries with spaces, and shlex handles those two
    in ways that lose path characters. Quotes are removed, backslashes are kept.
    """
    tokens = []
    current = ''
    inside = False
    for char in text:
        if char == '"':
            inside = not inside
            continue
        if char.isspace() and not inside:
            if current:
                tokens.append(current)
                current = ''
            continue
        current += char
    if current:
        tokens.append(current)
    return tokens


def is_our_archive(token):
    """An archive this build produced comes with a path; a toolchain library is a
    bare name (ws2_32.lib, or -lws2_32 on Linux)."""
    return (token.endswith('.a') or token.endswith('.lib')) and (
        '/' in token or '\\' in token)


def archive_name(token):
    return token.replace('\\', '/').rsplit('/', 1)[-1]


def expand_response_files(tokens, out_dir):
    """Replace `@file` with the tokens it holds.

    gyp's ninja generator writes a response file for the MSVC toolchain (the
    command line would be longer than the limit), so without this the archives are
    invisible on Windows: the command is just `link.exe @node.rsp`.
    """
    expanded = []
    for token in tokens:
        if not token.startswith('@'):
            expanded.append(token)
            continue
        path = token[1:]
        if out_dir and not os.path.isabs(path):
            path = os.path.join(out_dir, path.replace('\\', os.sep))
        try:
            with open(path, encoding='utf-8', errors='replace') as handle:
                content = handle.read()
        except OSError:
            expanded.append(token)
            continue
        # Line by line: a response file may hold several lines, and a quote pairing
        # must not leak from one line into the next.
        for line in content.splitlines():
            expanded.extend(tokenize(line))
    return expanded


def parse_command_line(command, out_dir=None):
    tokens = expand_response_files(tokenize(command), out_dir)
    return tokens, classify(tokens)


def unquote(token):
    """A response file quotes entries that contain spaces: /WHOLEARCHIVE:"a b\\x.lib".
    Quotes only surround the path part here, so take them off before testing the
    extension."""
    if len(token) >= 2 and token[0] == token[-1] and token[0] in ('"', "'"):
        return token[1:-1]
    return token


def classify(tokens):
    whole, plain, system = [], [], []
    group_is_whole = False
    seen = set()
    expect_framework = False
    force_next = False

    def add(token, force):
        name = archive_name(unquote(token))
        if name in seen:
            return
        seen.add(name)
        (whole if force else plain).append(name)

    for token in tokens:
        if token == '-Wl,--whole-archive':
            group_is_whole = True
            continue
        if token == '-Wl,--no-whole-archive':
            group_is_whole = False
            continue
        if token.startswith('/WHOLEARCHIVE:'):
            add(token.split(':', 1)[1], True)
            continue
        if token.startswith('-Wl,-force_load,'):
            add(token.split(',', 1)[1], True)
            continue
        if token == '-force_load':
            force_next = True
            continue
        if force_next:
            force_next = False
            if is_our_archive(unquote(token)):
                add(token, True)
                continue
        if token == '-framework':
            expect_framework = True
            continue
        if expect_framework:
            system.append('-framework ' + token)
            expect_framework = False
            continue
        if is_our_archive(token):
            add(token, group_is_whole)
            continue
        if token.endswith('.lib'):
            system.append(token)
            continue
        if token.startswith('-l') and not token.startswith('-labi'):
            system.append(token)
            continue
        if token in ('-pthread', '-lm', '-ld64', '-Objc', '-ObjC'):
            system.append(token)
    return whole, plain, sorted(set(system))


def choose_command(lines, out_dir):
    """Pick the line that actually links Node.

    `ninja -t commands` prints one command per build edge leading to `node`, so the
    last line is normally it - but a generator step or an archiving step can sit at
    the end, and on Windows the interesting tokens are inside a response file. So
    take the last line that yields a plausible number of archives.
    """
    best = None
    for line in reversed(lines):
        if not line.strip():
            continue
        tokens = expand_response_files(tokenize(line), out_dir)
        whole, plain, system = classify(tokens)
        count = len(whole) + len(plain)
        if count >= 3:
            return tokens, (whole, plain, system), line
        if best is None:
            best = (tokens, (whole, plain, system), line)
    return best


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--commands', help='file with `ninja -t commands node` output')
    parser.add_argument('--tokens', help='file with one link-command token per line')
    parser.add_argument('--whole')
    parser.add_argument('--plain')
    parser.add_argument('--system')
    parser.add_argument('--out-dir', default=None,
                        help='directory response files (@file) are relative to')
    parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()
    if not ((args.commands or args.tokens) and args.whole and args.plain and args.system):
        parser.error('need --commands or --tokens, plus --whole/--plain/--system')

    if args.tokens:
        tokens = []
        with open(args.tokens, encoding='utf-8', errors='replace') as handle:
            for line in handle:
                tokens.extend(tokenize(line))
        tokens = expand_response_files(tokens, args.out_dir)
        result = classify(tokens)
        used = ' '.join(tokens)[:200]
    else:
        with open(args.commands, encoding='utf-8', errors='replace') as handle:
            lines = handle.read().splitlines()
        chosen = choose_command(lines, args.out_dir)
        if chosen is None:
            sys.exit('parse_node_link: no command found in ' + args.commands)
        tokens, result, used = chosen

    whole, plain, system = result
    if not whole:
        moved = [name for name in FALLBACK_WHOLE if name in plain]
        for name in moved:
            plain.remove(name)
        whole = moved
        if moved:
            print('package_node: the link line carries no whole-archive group (the macOS '
                  'and Windows linkers are told per archive), so these archives were '
                  'marked force-load from the fallback list: ' + ', '.join(moved))
    if not (whole or plain):
        print('parse_node_link: no archive was found in the link command.', file=sys.stderr)
        print('  command read: ' + used, file=sys.stderr)
        print('  is this the node target, and did the build use --ninja?', file=sys.stderr)
        sys.exit(1)

    for path, names in ((args.whole, whole), (args.plain, plain), (args.system, system)):
        with open(path, 'w', encoding='utf-8') as handle:
            for name in names:
                handle.write(name + '\n')
    print(f'package_node: {len(whole)} archive(s) whole-archive, {len(plain)} plain, '
          f'{len(system)} system flags')
    print('package_node: whole: ' + ', '.join(whole))
    print('package_node: plain: ' + ', '.join(plain))
    return 0


def selftest():
    failures = []

    def expect(label, command, want_whole, want_plain, want_system, out_dir=None):
        tokens = expand_response_files(tokenize(command), out_dir)
        whole, plain, system = classify(tokens)
        if whole != want_whole:
            failures.append(f'{label}: whole is {whole}, want {want_whole}')
        if plain != want_plain:
            failures.append(f'{label}: plain is {plain}, want {want_plain}')
        for flag in want_system:
            if flag not in system:
                failures.append(f'{label}: system is missing {flag} (got {system})')

    expect('GNU ld (Linux)',
           'g++ -o ./node -pthread -Wl,--whole-archive obj/libnode_base.a '
           'obj/libv8_base_without_compiler.a obj/libuv.a -Wl,--no-whole-archive '
           'obj/libzlib.a obj/libada.a -lz -lm',
           ['libnode_base.a', 'libv8_base_without_compiler.a', 'libuv.a'],
           ['libzlib.a', 'libada.a'],
           ['-lz', '-lm', '-pthread'])

    expect('ld64 (macOS)',
           'clang++ -Wl,-search_paths_first -o out/Release/node -pthread '
           '-Wl,-force_load,out/Release/libnode_base.a '
           '-Wl,-force_load,out/Release/libv8_base_without_compiler.a '
           'out/Release/libnode_crates.a -lz -lm -framework CoreFoundation '
           '-framework Foundation -framework Security',
           ['libnode_base.a', 'libv8_base_without_compiler.a'],
           ['libnode_crates.a'],
           ['-framework CoreFoundation', '-framework Foundation', '-framework Security',
            '-lz', '-lm', '-pthread'])

    expect('ld64 two-token form',
           'clang++ -o node -force_load out/Release/libnode_base.a out/Release/libuv.a',
           ['libnode_base.a'], ['libuv.a'], [])

    with tempfile.TemporaryDirectory() as work:
        rsp = os.path.join(work, 'obj', 'node.node.rsp')
        os.makedirs(os.path.dirname(rsp))
        with open(rsp, 'w', encoding='utf-8') as handle:
            handle.write('/OUT:node.exe /WHOLEARCHIVE:obj\\Release\\libnode_base.lib '
                         '"obj\\Release\\libuv.lib" obj\\Release\\libada.lib '
                         '/WHOLEARCHIVE:"obj\\Release With Space\\libv8_snapshot.lib" '
                         'ws2_32.lib dbghelp.lib /LIBPATH:lib\n')
        expect('MSVC with response file',
               'link.exe /nologo @obj\\node.node.rsp',
               ['libnode_base.lib', 'libv8_snapshot.lib'], ['libuv.lib', 'libada.lib'],
               ['ws2_32.lib', 'dbghelp.lib'],
               out_dir=work)

    if failures:
        for line in failures:
            print('FAIL ' + line)
        print(f'parse_node_link --selftest: {len(failures)} problem(s)')
        return 1
    print('parse_node_link --selftest: PASS (GNU ld, ld64, ld64 two-token, MSVC + rsp)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
