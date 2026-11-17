#!/usr/bin/env python3
"""Read the `node` target's link command and split it into the bundle's link groups.

    parse_node_link.py --commands FILE --whole OUT --plain OUT --system OUT
                       [--out-dir DIR]
    parse_node_link.py --tokens FILE --whole OUT --plain OUT --system OUT
                       [--out-dir DIR]

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

`--out-dir` does three things: it is the directory response files are read from, the
build tree whose archive names are known, and the ninja tree a deleted response file is
rebuilt from. The second one matters because
gyp writes the link line with paths relative to the build directory, so a macOS
link says `-Wl,-force_load,libnode_base.a libuv.a` rather than a path, and only
the build tree can tell those apart from a system library.

    python3 parse_node_link.py --selftest
runs those shapes against built-in expectations.
"""

import argparse
import os
import re
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


def build_archive_index(out_dir):
    """Names of every static archive under the build directory.

    Used to tell an archive this build produced from a toolchain library when the
    link line gives no directory: gyp rebases the link line against the build
    directory, so a macOS link passes `libuv.a` next to `-L.` while a Windows link
    passes `ws2_32.lib` from the SDK. The link line is still what decides which
    archives belong to the bundle; this only answers "is this name ours?".
    """
    names = set()
    if not out_dir:
        return names
    for root, _dirs, files in os.walk(out_dir):
        for name in files:
            if name.endswith('.a') or name.endswith('.lib'):
                names.add(name)
    return names


def is_our_archive(token, archives=None):
    """True for an archive this build produced.

    A path always counts. A bare name counts when the build directory holds a file
    with that name (see build_archive_index); without an index, a bare name is left
    to the toolchain (ws2_32.lib, or -lws2_32).
    """
    token = unquote(token)
    if not (token.endswith('.a') or token.endswith('.lib')):
        return False
    if '/' in token or '\\' in token:
        return True
    return bool(archives) and archive_name(token) in archives


def archive_name(token):
    return token.replace('\\', '/').rsplit('/', 1)[-1]


# ld64 spells per-archive force-loading as one token `-Wl,-force_load,<archive>`;
# the archive part is everything after this prefix.
FORCE_LOAD_PREFIX = '-Wl,-force_load,'


# A response file named inside a longer string, as it appears when the link command
# is wrapped in one quoted argument.
RSP_INSIDE_TEXT = re.compile(r'@[^\s"]+\.rsp')


# ---------------------------------------------------------------------------
# Response files ninja has already thrown away
#
# ninja writes a response file right before running an edge and deletes it when the
# command finishes (measured with a two-line rule: the command sees the file, it is
# gone afterwards). So on a built Windows tree `node.exe.rsp` does not exist when the
# bundle is packaged, and the archives - which live only inside that file - would be
# invisible here. What ninja wrote can be rebuilt from the ninja files: the rule says
# `rspfile_content = $in_newline $libs $ldflags`, and the edge carries $libs and
# $ldflags, so the text can be produced again without running the linker.
# ---------------------------------------------------------------------------

_NINJA_CACHE = {}


def ninja_statements(path):
    """The statements of a ninja file, with trailing-$ continuations joined.

    ninja continues a statement with a single `$` at the end of the line (a literal
    `$` is written `$$`), so a long `build` line or a multi-line `ldflags` value is
    one statement spread over several lines.
    """
    with open(path, encoding='utf-8', errors='replace', newline='') as handle:
        text = handle.read()
    return re.sub(r'(?<!\$)\$\s*\r?\n[ \t]*', ' ', text).splitlines()


def expand_ninja_vars(value, mapping):
    """Expand `$name`, `${name}` and `$$` the way ninja does. Unknown names stay as written."""
    out = []
    i = 0
    while i < len(value):
        char = value[i]
        if char == '$' and i + 1 < len(value):
            rest = value[i + 1:]
            if rest.startswith('$'):
                out.append('$')
                i += 2
                continue
            match = re.match(r'[A-Za-z_][A-Za-z0-9_]*', rest)
            if match and match.group(0) in mapping:
                out.append(str(mapping[match.group(0)]))
                i += 1 + match.end()
                continue
            if rest.startswith('{'):
                end = rest.find('}')
                key = rest[1:end]
                if end > 0 and key in mapping:
                    out.append(str(mapping[key]))
                    i += 2 + end
                    continue
        out.append(char)
        i += 1
    return ''.join(out)


def read_ninja_tree(out_dir):
    """(rules, edges) of a generated ninja tree: rule name -> variables, and the edges."""
    if out_dir in _NINJA_CACHE:
        return _NINJA_CACHE[out_dir]
    rules = {}
    edges = []
    for root, _dirs, files in os.walk(out_dir):
        for name in sorted(files):
            if not name.endswith('.ninja'):
                continue
            scope = {}
            rule_vars = None
            for line in ninja_statements(os.path.join(root, name)):
                if not line.strip() or line.lstrip().startswith('#'):
                    continue
                if line.startswith('rule '):
                    rule_vars = {}
                    rules[line.split()[1]] = rule_vars
                    continue
                if line.startswith('build '):
                    left, _, right = line[len('build '):].partition(':')
                    tail = right.split()
                    edge = {
                        'tool': tail[0] if tail else '',
                        'inputs': tail[1:],
                        # "|" and "||" separate implicit and order-only dependencies.
                        'outputs': re.split(r'\s*\|\|?\s*', left.strip())[0].split(),
                        'vars': {},
                        'scope': dict(scope),
                    }
                    edges.append(edge)
                    rule_vars = None
                    continue
                match = re.match(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$', line.strip())
                if not match:
                    continue
                if line[:1] in (' ', '\t'):
                    # An indented assignment belongs to the rule or edge above it.
                    if rule_vars is not None:
                        rule_vars[match.group(1)] = match.group(2)
                    elif edges:
                        edges[-1]['vars'][match.group(1)] = match.group(2)
                else:
                    scope[match.group(1)] = match.group(2)
    _NINJA_CACHE[out_dir] = (rules, edges)
    return rules, edges


def edge_variables(edge, rules):
    """The variables ninja would use for an edge: file scope, then rule, then edge."""
    mapping = dict(edge['scope'])
    mapping.update(rules.get(edge['tool'], {}))
    mapping.update(edge['vars'])
    mapping.setdefault('in', ' '.join(edge['inputs']))
    mapping.setdefault('in_newline', '\n'.join(edge['inputs']))
    mapping.setdefault('out', edge['outputs'][0] if edge['outputs'] else '')
    mapping.setdefault('out_newline', '\n'.join(edge['outputs']))
    return mapping


def reconstructed_response_tokens(out_dir, rsp_path):
    """The tokens ninja put in a response file it has deleted, or None if not found."""
    if not out_dir:
        return None
    rules, edges = read_ninja_tree(out_dir)
    wanted = os.path.basename(rsp_path.replace('\\', '/'))
    for edge in edges:
        mapping = edge_variables(edge, rules)
        named = expand_ninja_vars(mapping.get('rspfile', ''), mapping)
        if not named or os.path.basename(named.replace('\\', '/')) != wanted:
            continue
        content = expand_ninja_vars(mapping.get('rspfile_content', ''), mapping)
        if content.strip():
            return tokenize(content)
    return None


def response_file_tokens(path, out_dir):
    """The tokens held by a response file, or None when it cannot be read."""
    if out_dir and not os.path.isabs(path):
        path = os.path.join(out_dir, path.replace('\\', os.sep))
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            content = handle.read()
    except OSError:
        return None
    tokens = []
    # Line by line: a response file may hold several lines, and a quote pairing
    # must not leak from one line into the next.
    for line in content.splitlines():
        tokens.extend(tokenize(line))
    return tokens


def expand_response_files(tokens, out_dir):
    """Replace `@file` with the tokens it holds.

    gyp's ninja generator writes a response file for the MSVC toolchain (the
    command line would be longer than the limit), so without this the archives are
    invisible on Windows: the command is just `link.exe @node.rsp`.

    On Windows the `@file` is usually not a token of its own. The link rule runs
    gyp-win-tool, which keeps the real link inside one quoted argument:

      ... gyp-win-tool link-with-manifests environment.x64 True node.exe
          "... link.exe /nologo /OUT:node.exe @node.exe.rsp" 1 mt.exe rc.exe ...

    and the quoting makes that whole inner command a single token, so the response
    file has to be looked for inside the token as well.
    """
    expanded = []
    for token in tokens:
        if token.startswith('@'):
            paths = [token[1:]]
        elif '@' in token and '.rsp' in token:
            paths = [match.group(0)[1:] for match in RSP_INSIDE_TEXT.finditer(token)]
        else:
            paths = []
        if not paths:
            expanded.append(token)
            continue
        for path in paths:
            content = response_file_tokens(path, out_dir)
            if content is None:
                # ninja deletes the response file when the command it was written for
                # has finished, so on a built tree this is the normal path.
                content = reconstructed_response_tokens(out_dir, path)
            if content is None:
                # Left as a token: a caller who knows better can still see it there.
                expanded.append('@' + path)
            else:
                expanded.extend(content)
    return expanded


def parse_command_line(command, out_dir=None, archives=None):
    tokens = expand_response_files(tokenize(command), out_dir)
    return tokens, classify(tokens, archives)


def unquote(token):
    """A response file quotes entries that contain spaces: /WHOLEARCHIVE:"a b\\x.lib".
    Quotes only surround the path part here, so take them off before testing the
    extension."""
    if len(token) >= 2 and token[0] == token[-1] and token[0] in ('"', "'"):
        return token[1:-1]
    return token


def classify(tokens, archives=None):
    whole, plain, system = [], [], []
    group_is_whole = False
    seen = set()
    expect_framework = False
    force_next = False

    # The archives named here have to be force-loaded wherever the marker sits. GNU
    # ld marks a group, so it is handled by position below; MSVC's /WHOLEARCHIVE: and
    # ld64's -force_load name one archive each, and gyp writes those flags at the
    # end of the Windows link line - after the archives they name were already
    # listed. Reading the names first is what keeps the Windows split right; taking
    # them in command order instead leaves every archive in `plain`, and an embedder
    # then links a Node without its builtins and snapshot data, quietly.
    forced = set()
    pending_force_load = False
    for token in tokens:
        if token.startswith('/WHOLEARCHIVE:'):
            forced.add(archive_name(unquote(token.split(':', 1)[1])))
        elif token.startswith(FORCE_LOAD_PREFIX):
            forced.add(archive_name(unquote(token[len(FORCE_LOAD_PREFIX):])))
        elif token == '-force_load':
            pending_force_load = True
        elif pending_force_load:
            forced.add(archive_name(unquote(token)))
            pending_force_load = False

    def add(token, force):
        name = archive_name(unquote(token))
        if name in seen:
            return
        seen.add(name)
        (whole if (force or name in forced) else plain).append(name)

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
        if token.startswith(FORCE_LOAD_PREFIX):
            add(token[len(FORCE_LOAD_PREFIX):], True)
            continue
        if token == '-force_load':
            force_next = True
            continue
        if force_next:
            force_next = False
            if is_our_archive(token, archives):
                add(token, True)
                continue
        if token == '-framework':
            expect_framework = True
            continue
        if expect_framework:
            system.append('-framework ' + token)
            expect_framework = False
            continue
        if is_our_archive(token, archives):
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


def choose_command(lines, out_dir, archives=None):
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
        whole, plain, system = classify(tokens, archives)
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
                        help='build directory: where response files (@file) are read from '
                             'and where the archive names this build produced are looked up')
    parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()
    if not ((args.commands or args.tokens) and args.whole and args.plain and args.system):
        parser.error('need --commands or --tokens, plus --whole/--plain/--system')

    archives = build_archive_index(args.out_dir)
    if args.tokens:
        tokens = []
        with open(args.tokens, encoding='utf-8', errors='replace') as handle:
            for line in handle:
                tokens.extend(tokenize(line))
        tokens = expand_response_files(tokens, args.out_dir)
        result = classify(tokens, archives)
        used = ' '.join(tokens)[:200]
    else:
        with open(args.commands, encoding='utf-8', errors='replace') as handle:
            lines = handle.read().splitlines()
        chosen = choose_command(lines, args.out_dir, archives)
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
        if args.out_dir:
            print('  no response file was readable and nothing in '
                  f'{args.out_dir}/*.ninja described one either, so the archives inside it '
                  'could not be recovered', file=sys.stderr)
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

    def expect(label, command, want_whole, want_plain, want_system, out_dir=None,
               archives=None):
        tokens = expand_response_files(tokenize(command), out_dir)
        whole, plain, system = classify(tokens, archives)
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

    # What gyp actually emits on macOS: the link line is rebased against the build
    # directory, so the archives arrive as bare names next to `-L.`, and so does the
    # file named after -Wl,-force_load,. A bare libz.a from the SDK must stay a
    # system library, which is what the build directory decides.
    ours = {'libnode_base.a', 'libv8_base_without_compiler.a', 'libuv.a', 'libada.a',
            'libnode_crates.a'}
    expect('ld64 with build-directory names (what macOS produces)',
           'clang++ -o node -L. -Wl,-force_load,libnode_base.a '
           '-Wl,-force_load,libv8_base_without_compiler.a libuv.a gen/cargo/target/'
           'aarch64-apple-darwin/release/libnode_crates.a libada.a libz.a -lz '
           '-framework CoreFoundation',
           ['libnode_base.a', 'libv8_base_without_compiler.a'],
           ['libuv.a', 'libnode_crates.a', 'libada.a'],
           ['-framework CoreFoundation', '-lz'],
           archives=ours)

    # The shape a Windows runner produces: ninja's own command line for the node
    # target, with link.exe and its response file buried inside a quoted argument
    # handed to gyp-win-tool. Read out of `ninja -t commands node` on a real
    # Windows build directory, with the archives of the real link.
    with tempfile.TemporaryDirectory() as work:
        rsp = os.path.join(work, 'node.exe.rsp')
        with open(rsp, 'w', encoding='utf-8') as handle:
            handle.write('obj/libnode.lib\nobj/node_base.lib\n'
                         'obj/deps/uv/libuv.lib\nobj/deps/openssl/openssl.lib\n'
                         'Dbghelp.lib winmm.lib\n'
                         '/WHOLEARCHIVE:lib/node_base.lib '
                         '/WHOLEARCHIVE:lib/libuv.lib\n')
        expect('MSVC through gyp-win-tool (what ninja on Windows produces)',
               'python3 gyp-win-tool link-with-manifests environment.x64 True node.exe '
               '"python3 gyp-win-tool link-wrapper environment.x64 False link.exe '
               '/nologo /OUT:node.exe @node.exe.rsp" 1 mt.exe rc.exe '
               'obj/node.node.exe.intermediate.manifest',
               ['node_base.lib', 'libuv.lib'],
               ['libnode.lib', 'openssl.lib'],
               ['Dbghelp.lib', 'winmm.lib'],
               out_dir=work)

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

        # ninja deletes a response file once the command it was written for has run, so
        # on a tree that has been built the file is gone. Its content has to come back out
        # of the ninja files: the rule names the file and the template that fills it, the
        # edge carries the variables that template needs.
        rebuilt = os.path.join(work, 'rebuilt')
        os.makedirs(os.path.join(rebuilt, 'obj'))
        with open(os.path.join(rebuilt, 'build.ninja'), 'w', encoding='utf-8') as handle:
            handle.write(
                'pool link_pool\n'
                'rule link\n'
                '  command = python3 gyp-win-tool link-with-manifests $arch True $binary '
                '"link.exe /nologo /OUT:$binary @$binary.rsp" 1 $mt $rc\n'
                '  rspfile = $binary.rsp\n'
                '  rspfile_content = $in_newline $libs $ldflags\n')
        with open(os.path.join(rebuilt, 'obj', 'node.ninja'), 'w', encoding='utf-8') as handle:
            handle.write(
                'build node.exe node.exe.pdb: link obj/src/node.node_main.obj '
                'obj/node_base.lib $\n    obj/libuv.lib obj/libada.lib || obj/stamp.stamp\n'
                '  binary = node.exe\n'
                '  arch = environment.x64\n'
                '  mt = mt.exe\n'
                '  rc = rc.exe\n'
                '  libs = ws2_32.lib\n'
                '  ldflags = /WHOLEARCHIVE:obj/node_base.lib /WHOLEARCHIVE:obj/libuv.lib\n')
        expect('MSVC, response file already deleted by ninja',
               'python3 gyp-win-tool link-with-manifests environment.x64 True node.exe '
               '"python3 gyp-win-tool link-wrapper environment.x64 False link.exe /nologo '
               '/OUT:node.exe @node.exe.rsp" 1 mt.exe rc.exe "obj\\node.manifest"',
               ['node_base.lib', 'libuv.lib'], ['libada.lib'], ['ws2_32.lib'],
               out_dir=rebuilt)

    if failures:
        for line in failures:
            print('FAIL ' + line)
        print(f'parse_node_link --selftest: {len(failures)} problem(s)')
        return 1
    print('parse_node_link --selftest: PASS (GNU ld, ld64, ld64 two-token, '
          'ld64 bare names, MSVC + rsp, MSVC through gyp-win-tool, MSVC with the rsp '
          'file already deleted by ninja)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
