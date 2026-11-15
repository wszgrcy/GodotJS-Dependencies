# Building Node 26.x for GodotJS

This file is the reference for the Node part of the build: what has to change in
Node's source before it is built, what the packaged bundle contains, what an
embedder has to do in which order, and what has not been verified.

The short version: Node is built from the official source tarball with two source
patches (RTTI on, no `-rdynamic`), and the package step turns the build output
into one archive set plus one header tree per platform. Node ships its V8 inside
itself, so a Node bundle and a V8 bundle are two alternative runtimes, not two
layers. Everything below was measured on Linux x86_64 with Node 26.13.1; the
macOS and Windows paths follow the same scripts but were not run.

---

## 1. What the bundle is, and what it replaces

GodotJS today links one V8: `v8_<version>.zip` gives `v8/include/` plus a
`v8_monolith` archive per platform. A Node bundle replaces that whole layer,
because Node embeds V8 itself:

| | V8 bundle (`v8_*.zip`) | Node bundle (`node_*.zip`) |
|---|---|---|
| JavaScript engine | V8, version chosen here | whichever V8 that Node release ships |
| Libraries to link | 1 (`libv8_monolith.a`) | 36, of which 6 need `--whole-archive` |
| ICU data | separate `icudtl.dat` next to the executable | compiled into `libicudata.a`, nothing to ship |
| npm, `require`, Node builtins, `Intl` via full ICU | no | yes |
| Android | default: `libv8_monolith.a` | cross-built with the NDK; job exists, off until green (`NODE_ANDROID`) |
| iOS | default: `libv8_monolith.a` | cross-built against the iPhoneOS SDK; job exists, off until green (`NODE_IOS`) |
| Size, compressed | `v8_15.7.112.12.zip` is 19 MB with every platform inside | ~67 MB for one platform |

Node 26.13.1 is Active LTS and reports:

| | |
|---|---|
| `process.versions.node` | `26.13.1` |
| `process.versions.v8` | `14.6.202.34-node.40` |
| `process.versions.icu` | `78.3` |
| `process.versions.uv` | `1.52.1` |
| `process.versions.modules` (addon ABI) | `147` |
| C++ standard | `gnu++20` (same as V8 15.x) |
| `v8_enable_pointer_compression` | `0` (off) |

Two consequences worth stating out loud:

- **GodotJS pins V8 15.7.112.12; Node 26 ships V8 14.6.** No published Node
  release carries a 15.x V8, so supporting Node means compiling the engine's V8
  layer against 14.6 headers. The measured differences are smaller than the
  version numbers suggest:

  | | V8 15.7 headers | V8 14.6, inside Node 26 |
  |---|---|---|
  | `Value::GetIsolate()`, `Context::GetIsolate()` | absent | absent too — no difference; GodotJS already switched to `Isolate::GetCurrent()` |
  | `Set`/`GetAlignedPointerInEmbedderData(..., EmbedderDataTypeTag)` | present | present, and 14.6 keeps the deprecated untagged overloads as well |
  | installed V8 headers | 64 `v8-*.h` | 51 — Node's installer skips the ones an addon does not need |
  | of the skipped ones, what GodotJS includes | — | `v8-inspector.h`, `v8-version-string.h`; `package_node.sh` copies both out of `deps/v8/include` |

  What does not work is mixing: an object file compiled against 15.7 cannot be
  linked against the 14.6 library, so one engine build uses one bundle.
- **Pointer compression is off in Node 26.** GodotJS's `v8_support` path that
  defines `V8_COMPRESS_POINTERS` does not apply to a Node bundle. `manifest.json`
  in each platform directory records `pointer_compression` so the engine build can
  check it instead of assuming.

Third parties publish ready-made Node libraries for Godot, and those are a
reference for what is possible - they are not something this repository can use,
because the distribution model is different. They ship a plugin with prebuilt
binaries the user drops into a project; here the engine binary itself links Node,
so the archives have to come out of the same toolchain and the same compile
choices as the engine build: RTTI on and `-rdynamic` off (section 3), C++20 with
exceptions off, and every release reproducible from the official source with the
configure arguments and checksums recorded in `manifest.json`. A downloaded archive
cannot answer "which flags built this", which is the first question when the engine
fails to link. The platform sets differ too: the web export runs in the browser's
engine and needs no Node bundle at all, and both mobile targets have to be
cross-compiled and checked here (section 6) rather than trusted from someone else's
build.

## 2. Files added here

| File | What it does |
|---|---|
| `node.<platform>_<arch>.configure.txt` | `./configure` arguments for one platform. One argument per line, `#` starts a comment |
| `node.extra_26.x.configure.txt` | arguments that only exist in Node 26.x, appended by the prepare script |
| `prepare_node_build.sh` | patches the Node source for embedding and appends the version-specific arguments to the args file you pass (pass a copy, not the tracked file) |
| `package_node.sh` | turns a finished build into the bundle: archives, headers, `link.txt`, `manifest.json` |
| `verify_node_bundle.sh` | compiles and runs `tools/node_link_probe.cc` against a bundle |
| `tools/node_link_probe.cc` | the program that proves a bundle is usable (see section 7) |
| `tools/node_v8_version.sh` | prints the V8 version a Node version embeds, so the standalone V8 bundle can be built at the same one |
| `tools/local_node_job_check.sh` | replays one desktop job of `build_node.yml` on your own machine (unpack, prepare, configure, ninja, package, verify), and first parse-checks every platform's `configure.txt` against `node`'s own `configure --help` |
| `tools/check_workflow_contexts.py` | checks `.github/workflows/` for things GitHub only reports while parsing the file: a `shell:` value that uses a context it does not allow, and steps whose script is not valid for the shell that runs them |
| `.github/workflows/build_node.yml` | one matrix job per platform/arch, called by `build_all.yml` |

Before changing any of these scripts, run the local replay instead of pushing and
waiting for CI:

```bash
bash tools/local_node_job_check.sh --tarball /path/to/node-v26.13.1.tar.xz
# ... --reuse-build re-packages an existing build in seconds
```

Measured here (16 cores, GCC 15.2): 4395 ninja targets in about 26 minutes, the
bundle is 287 MB with 36 archives (6 whole-archive, 30 plain) and 3 system
flags, and the probe ends in `node_link_probe: PASS`. The job pins gcc-13, so
this proves the scripts and the bundle, not the pinned compiler.

The naming (`linux.x86_64.release`, `windows_x86_64_release`) follows the V8
bundle: Godot's `methods.py` turns the directory name into a C++ identifier, so
Windows uses `_` where the other platforms use `.`.

## 3. Two changes Node's own build needs before it can be embedded

`prepare_node_build.sh <node_source_dir> <args_file> <version>` applies both, and
marks the file so running it twice does nothing. The version-specific arguments are
written into `<args_file>`, so pass a copy - the CI job does
`cp Scripts/$ARGS_FILE args.txt` first, and the script refuses a file still named
`node.*.configure.txt` rather than dirty a tracked file.

**RTTI.** `common.gypi` sets `-fno-rtti`. An embedder whose code derives from V8
or Node classes — Godot's array-buffer allocator, its platform delegate — needs
typeinfo, and the link fails with `undefined reference to typeinfo for
v8::ArrayBuffer::Allocator`. The script removes the flag and sets
`GCC_ENABLE_CPP_RTTI=YES`. Measured after the change: `nm` shows
`V typeinfo for v8::ArrayBuffer::Allocator` in `libv8_base_without_compiler.a`,
and the probe's `dynamic_cast` through that base works. The cost is Node's own
typeinfo tables in the archive (a few MB across 280 MB).

**`-rdynamic`.** Node adds it so that `.node` addons can resolve symbols in the
executable. An engine does not want to export its whole symbol table, so the flag
is removed from `common.gypi` and `tools/v8_gypfiles/toolchain.gypi`. The
remaining `ldflags!` entries in `common.gypi` are removals, not additions. After
the change the final link line contains no `-rdynamic` and no
`-Wl,--export-dynamic`.

This is a trade-off, not a free win: an engine built this way cannot dlopen a
`.node` addon that expects to resolve Node symbols from the host binary. Loading
addons through Node's own loader works, because it uses the archives' symbols.

## 4. Archives: there is no single library, and six need `--whole-archive`

`libnode.a` is not "the Node library" — it is one of 36 archives this build
produces, and it holds a single object file. Node's link command is what defines
the real shape, so `package_node.sh` reads it out of `out/Release/build.ninja`
(`ninja -t commands node`) instead of keeping a hard-coded list. From that list it
derives, in order:

- which archives Node wraps in `-Wl,--whole-archive` — `libnode_base.a`,
  `libv8_base_without_compiler.a`, `libzlib.a`, `libuv.a`, `libv8_snapshot.a`,
  `libopenssl.a`;
- the plain archives, in Node's own order;
- the system libraries (`-ldl -lm -pthread`).

The result is written as `link.txt` in the platform directory (`whole`, `plain`,
`system`, `define` lines). An engine build should read that file rather than
repeat the list, because the set and the grouping change between Node versions.
`verify_node_bundle.sh` builds its link line from `link.txt`, so the file is
checked, not just shipped.

**Why the grouping matters**: linking the same 36 archives without
`--whole-archive` does not produce a program that misbehaves at runtime — the
link fails, with undefined references such as `BrotliDecoderCreateInstance` and
`inflate_table`. The whole-archive group is what keeps Node's self-contained
dependency order intact.

**Thin archives.** On Linux, `ar` produces thin archives: the file only holds the
paths of the object files, so copying `libuv.a` to another machine makes it
useless. `package_node.sh` rewrites every thin archive as a normal one. Note that
GNU `ar` refuses to extract from a thin archive (`'x' cannot be used on thin
archives`); the member list `ar t` prints is a path relative to the build
directory, so the objects are re-archived straight from there. The script then
compares the member count before and after, because `ar` stores members by file
name and two objects with the same name in different directories would silently
collapse into one.

## 5. Headers: use Node's own installer

`package_node.sh` runs Node's `tools/install.py install --headers-only` — the
same code path that produces the official `node-vX-headers.tar.gz` — into
`include/node/`. That gives `node.h`, `node_api.h`, `node_buffer.h`,
`node_object_wrap.h`, `v8.h` and the rest of V8's public headers, `uv.h`, `cppgc/`,
`libplatform/`, and OpenSSL's headers. One `-I` is enough for an embedder.

Three things follow from that choice:

- The list is Node's, so it cannot drift from upstream. It is deliberately the
  public set: `env.h`, `env-inl.h`, `node_internals.h` and friends are not
  installed, and a binding layer that includes them has to copy `src/` itself and
  accept that they change without a deprecation cycle. The probe in this repo
  touches only the public set on purpose.
- Two headers GodotJS includes are not in Node's install list, so
  `package_node.sh` copies them from `deps/v8/include` after the installer runs:
  `v8-inspector.h` and `v8-version-string.h`. A missing file stops the packaging,
  because "the header is gone" is much cheaper to hear here than in an engine
  compile. Not copied, because nothing includes them today:
  `v8-fast-api-calls.h`, `v8-metrics.h`, `v8-util.h`, `v8-wasm-trap-handler-*.h`.
- `install.py` puts `config.gypi` and `common.gypi` next to the headers. Those two
  describe the defines and flags of **one** platform, and every platform job
  writes into the same staging tree before the zips are made, so `package_node.sh`
  moves them into the platform directory. Otherwise the bundle would ship whichever
  platform finished last.
- OpenSSL's `archs/` directory holds a copy per platform (20 of them, 66 MB).
  A per-platform bundle keeps only its own, which takes the header tree from
  67 MB to 6.6 MB.

`v8-version.h` is read back and compared against `manifest.json`, so a bundle can
never present 14.6 headers next to a different V8 library — that combination
links and then crashes.

## 6. configure arguments

Per platform, in `node.<platform>_<arch>.configure.txt`:

```
--ninja
--dest-os=<linux|macos|win>
--dest-cpu=<x64|arm64>
--with-intl=full-icu
--without-node-options
--without-npm
--disable-single-executable-application
```

`--with-intl=full-icu` is what makes `Intl.Collator`, `Intl.Segmenter` and
`\p{Script=Han}` regexes work; Node 26's default is already `full-icu`, and the
data is compiled in, so the bundle has no `icudtl.dat` and the engine does not
need `GODOTJS_ICU_DATA` for a Node build.

Version-specific options go in `node.extra_26.x.configure.txt`:

- `--without-lief` exists only in 26.x. Node's `configure` is a plain Python
  `argparse` script and fails immediately on an unknown option, which is why these
  cannot be merged into the per-platform files (the same reason V8 15's extra gn
  args live in their own file).

`--without-node-options` and `--disable-single-executable-application` exist from
22.23.x and 24.22.x on, so they are safe in the per-platform files.

Two switches are left at Node's default on purpose: `--without-amaro` (Node's
TypeScript stripper) and `--without-sqlite`. Neither changes what an embedder
links, and keeping Node's defaults means the archives behave like Node's own.
The build also needs no Rust toolchain, even though `BUILDING.md` mentions Rust:
that is for `Temporal`, and Node 26's V8 is configured with
`v8_enable_temporal_support = 0` by default (`config.gypi` shows
`cargo_rust_target = ''` after a successful configure).

Windows files add `--clang-cl`: since Node 24, the documented Windows toolchain is
clang-cl, which is an optional Visual Studio component (`VC.Llvm.Clang` plus
`VC.Llvm.ClangToolset`), and the CI job says so when the component is missing.
The option's value is the LLVM version, so it has to be written
`--clang-cl=19.1.5`; a bare `--clang-cl` stops configure with
`argument --clang-cl: expected one argument` before anything is built. The version
belongs to the machine, so it is not in the args file: the job reads
`clang-cl --version` and appends the flag, which is what Node's own `vcbuild.bat`
does. Building by hand on Windows means adding it yourself.
`--dest-os` is spelled Node's way: `linux`, `mac`, `win`.

### Mobile: Android and iOS, cross-compiled despite upstream's "not supported"

Upstream Node says Android is unsupported and does not cover iOS at all. That
describes upstream's CI, not what is possible: moluopro/libnode publishes
`android/arm64/libnode.a` and `ios/arm64/libnode.a`, and gode 2.4.8 ships both
inside its released plugin - its `.github/shell/prepare-libnode.sh` refuses a zip
that is missing either path. Their build scripts live in a private Node fork
(`moluopro/nodejs`, not public), so the arguments here come from reading Node's own
build machinery, not from copying theirs.

`node.android_arm64.configure.txt`, `node.android_arm32.configure.txt` and
`node.android_x86_64.configure.txt` add `--dest-os=android`. Two things are
different from a desktop build.

#### Android

**The compiler is not a configure argument.** `./configure` has no option for it;
gyp's ninja generator reads `CC_target`, `CXX_target`, `AR_target`, `NM_target`,
`READELF_target` from the environment (`GetEnvironFallback` in
`tools/gyp/pylib/gyp/generator/ninja.py`). The NDK is convenient here because its
wrapper compilers already have the target and API level in the file name:

```
$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/
  aarch64-linux-android28-clang      ->  CC_target
  aarch64-linux-android28-clang++    ->  CXX_target
  llvm-ar / llvm-nm / llvm-readelf   ->  AR_target / NM_target / READELF_target
```

`armv7a-linux-androideabi<api>-clang` and `x86_64-linux-android<api>-clang` are the
arm32 and x86_64 equivalents. The API level comes from `vars.NODE_ANDROID_API`
(default 28, the minimum the Godot Android export templates use). Host tools
(`mksnapshot`, the snapshot blob) are still built with the host compiler, which is
why these cross builds need no qemu.

If those variables are simply not set, nothing fails at configure time - the build
compiles host-architecture objects into an archive named `android.arm64.release`,
and the error shows up when the engine links it. `prepare_node_build.sh` therefore
checks that all five point at something runnable and stops with the NDK path
pattern in the message.

**Node's own Android helper is gone.** Node 26 no longer ships
`tools/android_configure.py`, so `./android-configure` is a stub that imports a
module that is not there. Setting the variables above and calling `./configure`
directly is the only way in. This is consistent with `BUILDING.md` ("Android is not
a supported platform"), and it means the target has no upstream CI behind it.

What is not known, because no Android build has been run yet:

- OpenSSL's pre-generated configurations under `deps/openssl/config/archs/` cover
  linux, macOS, Windows and friends but contain no `android-*` entry, so if the
  build stops inside `deps/openssl`, that is where to look. `prepare_node_build.sh`
  prints a warning about this when it sees an Android args file.
- `package_node.sh` cannot trim the OpenSSL header tree for Android for the same
  reason, so an Android bundle carries the whole pre-generated set.
- Whether the arm32 target still builds at all (32-bit Android is the least used
  entry and the first one to drop if it does not).

Verification for a cross target cannot run the probe - there is no device - so the
CI job sets `NODE_VERIFY_CXX` to the NDK compiler and `NODE_VERIFY_LINK_ONLY=1`,
which compiles and links `tools/node_link_probe.cc` against the archives and stops.
That still catches a missing archive, a wrong `--whole-archive` group, and an ABI
mismatch; it proves nothing about runtime behaviour, which needs a device
(`adb push` the probe built with `NODE_VERIFY_KEEP=1` for that).

Because both mobile targets are unproven in this repo, both jobs are **off by
default**: `build_all.yml` runs them only with the repository variables
`NODE_ANDROID=true` / `NODE_IOS=true`. To try one, run `build_node.yml` on its own
with `only=android` or `only=ios`. Until it is green, GodotJS keeps using the V8
bundle on mobile.

#### iOS: three obstacles, all found in the source

1. **gyp has no `ios` flavour.** Node passes `--dest-os` straight through as gyp's
   flavour (`configure.py`, near the end: `flavor_params['flavor'] = options.dest_os`),
   and the ninja generator only special-cases `win` and `mac`. So `--dest-os=ios`
   gets no xcode emulation: no `-isysroot`, no framework handling, no libtool
   wrapper. The toolchain has to be supplied whole, through `CC_target` and friends.
2. **Parts of the tree are ready.** `deps/cares/cares.gyp`, `deps/zlib/zlib.gyp` and
   `tools/v8_gypfiles/toolchain.gypi` contain `OS=="ios"` conditions, so the
   dependencies know about iOS even though Node's documentation does not.
3. **iOS forbids executable memory**, so V8 cannot JIT. The archives cannot record
   that; the embedder has to start Node with JIT disabled or the bundle is useless
   at runtime (a runtime failure, not a link failure).

The `ios` toolchain step in `build_node.yml` writes wrapper compilers into
`$RUNNER_TEMP/node-xc-bin` (`cc`, `cxx`, `ar`, `nm`) that bake in
`-target arm64-apple-ios<deployment>` and
`-isysroot "$(xcrun --sdk iphoneos --show-sdk-path)"`, then exports them as the
`*_target` variables. There is deliberately no `READELF_target`: the Xcode toolchain
has no readelf, and a static build never reaches the rules that would call it
(`prepare_node_build.sh` does not require it for iOS). The deployment target comes
from `vars.NODE_IOS_DEPLOYMENT`, default 16.0 - the value the third-party builds use.

#### What a consumer has to link besides libnode

Taken from gode's `CMakeLists.txt`, which links the same archives for six platforms:

| platform | libnode file | extra system libraries |
|---|---|---|
| windows | `libnode.lib` | `Dbghelp Psapi Winmm Ws2_32 Advapi32 Crypt32 Ole32 Iphlpapi Shell32 User32 Userenv Uuid`, plus `/WHOLEARCHIVE:` |
| linux | `libnode.a` | `dl pthread rt` |
| macos | `libnode.a` | `-framework CoreFoundation -framework Security` |
| android | `libnode.a` | `log dl` |
| ios | `libnode.a` | `-framework Foundation` |

That is also the answer to "what should `link.txt` end up containing on Android"
(`-llog` is not optional there - libuv needs it), and the iOS link-only check passes
`NODE_VERIFY_EXTRA_LINK=-framework Foundation` for the same reason.

gode collapses everything into one `libnode.a` per platform and whole-archives the
whole file. This repo keeps the 36 archives and records the order in `link.txt`, so
the engine can whole-archive the six that need it instead of guessing "all of them".

Build cost on this machine (16 cores, 61 GB RAM, GCC 15.2): `./configure` 2.5
minutes, `ninja -C out/Release node` 19.5 minutes, source plus build tree 1.7 GB.
Packaging is about 5 s and the verification about 4 s.

## 7. What an embedder has to do, and in which order

`tools/node_link_probe.cc` is a small program that does every step an engine
embedding Node has to do, checks the result, and fails the build if any step
misbehaves. Running it against the bundle is `bash verify_node_bundle.sh
<staging_dir>`. The order below is not stylistic: each of these was a real crash
or a real link error before it was written down.

Before any of that it checks the two things a bundle can get wrong without any of
the steps below noticing: the V8 header tree and the V8 library have to be from
the same build (`V8_VERSION_STRING` from the shipped headers is compared with
`v8::V8::GetVersion()` from the archives - a mismatch links and then behaves like
memory corruption), and the headers GodotJS includes but Node does not install,
`v8-inspector.h` above all, have to be present and still spell the names
`bridge/jsb_debugger.cpp` derives from.

1. Create the platform and hand it to V8:
   `node::MultiIsolatePlatform::Create(4)`, then `v8::V8::InitializePlatform(...)`.
2. `node::InitializeOncePerProcess(args,
   node::ProcessInitializationFlags::kLegacyInitializeNodeWithArgsBehavior)`.
   That flag bundle is Node's own "do not touch my host process" set: no stdio
   takeover, no signal handlers, no resource-limit changes, no `NODE_OPTIONS`, no
   OpenSSL config, and V8, the V8 platform and cppgc are left to the embedder.
   The probe then asserts that RLIMIT_NOFILE is untouched, that stdout/stderr are
   still the same files (compared by device and inode, because "is it seekable" is
   a useless answer when the output is redirected to a log), and that Node
   installed no signal handler.
3. `v8::V8::Initialize()` — **after** step 2. Node hands its option parsing
   results to V8 as flags, and V8 aborts with `Check failed: !IsFrozen()` if
   flags are set after it was initialized.
4. cppgc: `v8::V8::Initialize()` initialises it when the embedder initializes V8.
   Calling `cppgc::InitializeProcess()` afterwards aborts with
   `Check failed: !internal::g_page_allocator`. Guard with `cppgc::IsInitialized()`.
5. Create the environment: `node::CommonEnvironmentSetup::Create(platform, &errors,
   args, exec_args)`. It returns the isolate, the context, the environment and the
   event loop, all reachable from the public header.
6. `node::LoadEnvironment(env, "<main script>")`. Without it the isolate has no
   JavaScript side: `process.getBuiltinModule()`, `process.stdout` and the module
   loader do not exist yet.
7. Run code. Inside a script an embedder compiles itself, `require` is **not** a
   global — it belongs to the module loader — so built-ins come from
   `process.getBuiltinModule('node:fs')`. `setup->context()` hands out a handle,
   so it has to be called with a `v8::HandleScope` open, or V8 aborts with
   "Cannot create a handle without a HandleScope".
8. Extra script contexts: `node::NewContext(isolate)` for a Node-shaped one, or
   your own `v8::Context::New` followed by `node::InitializeContext(context)`.
   `node::RegisterContext` / `node::UnregisterContext` attach a context to the
   environment (inspector, promise hooks). Registering a context that never went
   through Node segfaults.
9. Teardown, in this order: leave the V8 scopes, `node::Stop(env)` (returns an
   `int` exit code in 26), pump the loop a few times, then destroy the setup.
   Destroying the environment while the thread still has the isolate entered
   aborts with `v8::Isolate::Deinitialize() Deinitializing the isolate that is
   entered by a thread`. For a bare isolate use `platform->DisposeIsolate(isolate)`
   rather than `isolate->Dispose()`. `MultiIsolatePlatform` has no `Shutdown()` in
   26 — destroying it joins its threads.

Two things the probe checks that are easy to get wrong outside Node's own loop:

- The host keeps the loop. `uv_run(loop, UV_RUN_NOWAIT)` plus
  `platform->DrainTasks(isolate)` once per frame is the Godot shape, and the probe
  drives a libuv timer exactly that way. Remember that `uv_timer_stop` does not
  close a handle: until `uv_close` has run its callback, `uv_loop_close` returns
  `UV_EBUSY`.
- **Node 26 has no `node::AsyncScope` and no `Environment::async_scope()`** (grep
  over `src/` finds neither). An embedding recipe ported from an older Node that
  used them needs rewriting: V8's own async-context tracking, or
  `env->push_async_context()` / `env->pop_async_context()`, which are what the
  current headers offer.

Compile flags: the probe is built with `gnu++20`, RTTI on, exceptions off, and no
`V8_*` macros at all. That is not laziness — Node's own sources are compiled the
same way, and the `config.gypi` defines an embedder does need
(`DISABLE_SINGLE_EXECUTABLE_APPLICATION`, `NODE_OPENSSL_CONF_NAME`,
`NODE_WITHOUT_NODE_OPTIONS`, `ICU_NO_USER_DATA_OVERRIDE`) are written into
`link.txt` as `define` lines.

Compile flags: the probe is built with `gnu++20`, RTTI on, exceptions off, and no
`V8_*` macros at all. That is not laziness — Node's own sources are compiled the
same way, and the `config.gypi` defines an embedder does need
(`DISABLE_SINGLE_EXECUTABLE_APPLICATION`, `NODE_OPENSSL_CONF_NAME`,
`NODE_WITHOUT_NODE_OPTIONS`, `ICU_NO_USER_DATA_OVERRIDE`) are written into
`link.txt` as `define` lines.

### Does GodotJS's own source compile against a Node bundle?

Yes, after two names. Measured rather than guessed: every bridge and module source
(27 files, `bridge/*.cpp` plus `jsb.cpp`) was syntax-checked (`g++ -fsyntax-only
-std=gnu++20 -fno-exceptions`) twice - once against the standalone V8 15.7 headers
the module vendors today, once against `include/node` from a Node 26 bundle. Two
differences existed, both the same thing:

| | V8 15.7 (standalone bundle) | V8 14.6 (what Node 26 ships) |
|---|---|---|
| prototype accessors | `Object::GetPrototype()` / `SetPrototype(ctx, proto)` | `GetPrototypeV2()` / `SetPrototypeV2(ctx, proto)` |

GodotJS had two call sites; they now go through `impl::Helper::GetPrototype` /
`SetPrototype` in `impl/v8/jsb_v8_helper.h`, which pick the spelling by
`V8_VERSION_NEWER_THAN(15, 0, 0)`. With that in place the two sweeps report
identical results: one file fails, `jsb_editor_utility_funcs.cpp`, and it fails for
the reason it states itself (`#error CAN NOT COMPILE WITHOUT TOOLS_ENABLED`) because
the sweep does not pass `-DTOOLS_ENABLED`. Nothing else differs - the 40 remaining
error messages are the same 40 on both header sets.

One trap the sweeps cannot catch, because it is not a compile error: GodotJS's
`SCsub` adds `V8_COMPRESS_POINTERS` for desktop platforms, and this Node build has
pointer compression **off** (`config.gypi`: `v8_enable_pointer_compression: 0`).
V8's public headers do not record the setting, so passing the wrong define compiles
and links and then corrupts the heap at runtime. `link.txt` now carries that as a
`feature` line:

```
feature v8_enable_pointer_compression=0
feature v8_enable_pointer_compression_shared_cage=0
```

`verify_node_bundle.sh` reads and prints it. What the engine has to do is read those
lines instead of hard-coding the macro - and the same goes for `V8_COMPRESS_POINTERS`
on Android and iOS, where `SCsub` currently skips it by platform rather than by
what the bundle says.

## 8. Not verified, and what is missing

- **The archives carry the build machine's C library floor.** A program linked
  against this bundle needs `GLIBC_2.43` and `GLIBCXX_3.4.32` here, which is simply
  this container's glibc 2.43 and GCC 15.2. Node's own downloadable binaries are
  built on an old enterprise Linux and run on glibc 2.17; a bundle built here will
  not do that, so an engine shipping it is tied to the runner's userland. To read
  the floor off a bundle, link anything against it (the probe, with
  `NODE_VERIFY_KEEP=1` so the binary is left behind) and run
  `objdump -T <program> | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1`. The CI
  runners are `ubuntu-24.04` (glibc 2.39), so their bundles should sit a little
  lower, but that number has not been measured, and neither has the macOS
  deployment target or the Windows CRT version.
- **Only Linux x86_64 was built and run end to end, and only on this machine.**
  `tools/local_node_job_check.sh` replays the whole job here and ends in
  `node_link_probe: PASS`. In CI (run 43679251682) both Linux entries compiled all
  4395 targets and then failed in the `Package` step, and that one is still
  unexplained - a full disk is the likely cause (the object files alone are several
  GB), so the job now deletes them before packaging and both steps print `df -h`.
  The macOS and Windows entries each died for their own reason, and all of those
  reasons are section 9 material: `--clang-cl` needs a value, the macOS runner's shell
  has no `mapfile`, gyp has to be told where Visual Studio is, and a missing nasm was
  quietly dropping OpenSSL's assembly. Neither path has reached `Package` on a runner
  yet, and Linux arm64 was not built locally either.
- **Mobile is coded, not compiled.** Android and iOS cross builds exist (section 6)
  and are gated behind `NODE_ANDROID` / `NODE_IOS` because neither has been run yet;
  today GodotJS still links the standalone V8 bundle on both. The V8 bundle therefore
  stays, and its version is derived from Node instead of chosen separately.
- **The web export needs neither bundle.** GodotJS compiles `impl/web` and runs
  inside the browser's own JavaScript engine, so `v8_*.zip` and `node_*.zip` are both
  irrelevant there.
- **Nothing in GodotJS consumes a Node bundle yet.** `SCsub` still expects one
  `v8_monolith` archive; reading `link.txt` and issuing the multiple
  `LIBPATH`/`LIBS`/`--whole-archive` directives is engine-side work that has not
  been started.
- **The engine's own behaviour with Node is untested**: script reload, worker
  threads, inspector, per-frame costs. The probe measures embedding and process
  hygiene, not gameplay-loop performance.
- **Node's embedding API is documented as breakable between majors.** The API used
  here (`InitializationResult`, `CommonEnvironmentSetup`) carries Node's own note
  that it can change without deprecation, so this whole file has to be re-checked
  on every Node major bump, not just patched.

## 9. Runner constraints the scripts have to respect

Two rules that come from the build machines rather than from Node. Both were found
by failing in CI.

### 9.1 macOS only guarantees bash 3.2

macOS ships `/bin/bash` 3.2 - the version number has not moved since Mac OS X 10.3
(the reported reason is bash 4 moving to GPLv3, which Apple does not ship; treat that
motivation as background, the version itself is the measurable fact). That 3.2 is what
a workflow step runs with, and the runner image does not install a newer one.
`mapfile`, `readarray`, nameref (`local -n`) and associative arrays are bash 4, so a
step that uses one dies at that line:

```text
prepare_node_build: done
/Users/runner/work/_temp/....sh: line 7: mapfile: command not found
##[error]Process completed with exit code 127.
```

Exit 127 together with "command not found" for something that is a shell builtin is
the signature of this mistake. Anything in this repository that a macOS runner
executes sticks to bash 3.2: an array is filled with
`while IFS= read -r line; do arr+=("$line"); done < <(...)`, which is how
`build_node.yml` reads a `configure.txt` and how `tools/local_node_job_check.sh`
reads one, so the same script also runs on a developer's Mac.

Nothing here has been deprecated away, which is worth stating because "2009" invites
the opposite assumption. Checked against first-hand sources on 2026-11-15:

- the image our job ran on (`macos-26-arm64`, image version 20261102.0473) lists
  `Bash 3.2.57(1)-release` as its only bash, in
  `images/macos/macos-26-arm64-Readme.md` of `actions/runner-images`; the same line
  appears in the macos-15 image, so it has not moved for years;
- the Actions runner runs a `shell: bash` step as
  `<bash found on PATH> --noprofile --norc -e -o pipefail {0}` - the argument list is
  in `_defaultArguments` of `ScriptHandlerHelpers.cs`, the lookup is
  `WhichUtil.Which("bash")` in `ScriptHandler.cs`, both in `actions/runner`; the docs
  say the same thing in prose: "if bash is not found in the path, this is treated as
  `sh`";
- Homebrew's bash is `5.3.20` and `keg_only: false`
  (`https://formulae.brew.sh/api/formula/bash.json`), so installing it does put a
  `bash` on the Homebrew bin path;
- Node's own CI (`.github/workflows/build-shared.yml` in nodejs/node) uses
  `shell: bash` and keeps the step to `python3 ./configure` plus `make`, with no bash 4
  constructs; Homebrew's own CI names its own flags instead
  (`shell: bash -xeuo pipefail {0}` on `macos-26`).

So the version really is 3.2, and it is not going away; the way to get a modern bash in
a workflow is to install one and let `PATH` find it:

```yaml
- name: Toolchain            # macOS case
  run: |
    brew install bash
    echo "$(brew --prefix bash)/bin" >> "$GITHUB_PATH"
```

`GITHUB_PATH` is prepended to `PATH` for the steps that follow, and since the runner
looks `bash` up on `PATH`, every later step - and every `bash Scripts/x.sh` call inside
one - runs the new one. `shell:` itself stays the plain literal `bash`, so nothing is
lost from the runner's default flags. `$(brew --prefix bash)/bin` is used rather than a
hardcoded `/opt/homebrew/...` because it is also correct on Intel images (`/usr/local`),
and it works whether or not the formula is linked.

If a step does name its own interpreter instead, two rules bite:

- GitHub's documented form is a template string `command [options] {0}`. A custom path
  gets no default arguments from the runner, so `--noprofile --norc -e -o pipefail {0}`
  has to be written out; leaving them off silently drops `set -e` and `pipefail`.
- An expression in `shell:` (in a step or in `defaults.run.shell`) may not use the
  `env` context: `${{ env.X }}` fails while GitHub parses the file
  ("Unrecognized named-value: 'env'") and, for a workflow reached through
  `workflow_call`, takes the caller down too. Only `github`, `needs`, `strategy`,
  `matrix`, `vars`, `secrets` and `inputs` are available there.
  `tools/check_workflow_contexts.py` enforces that rule across `.github/workflows/`,
  because the parser error otherwise only surfaces on GitHub.

The step that installs the newer bash still runs on 3.2, and every script here stays
3.2-safe regardless, so a developer on a Mac can run them without installing anything.
`gode`, the reference for the bundle layout, has no macOS job at all, and Godot's own
macOS CI takes a different route (`shell: sh` with the work in Python scripts under
`misc/scripts/`), so neither is a guide for this.

### 9.2 `--whole-archive` is GNU ld syntax only

GNU ld opens a group with `-Wl,--whole-archive` and closes it with
`-Wl,--no-whole-archive`. Apple's ld64 has no group and takes `-force_load` once per
archive; MSVC uses `/WHOLEARCHIVE:<lib>`. That matters in both directions:

- `package_node.sh` works out the force-load set from Node's own link command, so a
  macOS or Windows link line can arrive with no group marker at all. Instead of
  recording nothing, it then records the six archives Node always force-loads (the
  same six as section 4) and says so in the log, and it recognises
  `/WHOLEARCHIVE:<lib>` tokens too. Checked by deleting the two marker lines from
  this machine's link command and repacking: same result as the marked-up version
  (6 force-load, 30 plain) and the probe still reports `PASS`.
- `verify_node_bundle.sh` builds the link line according to `uname -s`:
  `-Wl,-force_load,<archive>` per archive on Darwin, the `--whole-archive` group
  everywhere else. The Linux path is unchanged.

An embedder reading `link.txt` has the same choice to make, and the bundle does not
say which linker family the consumer uses - see section 7.

### 9.3 Windows: gyp has to be told where Visual Studio is

```text
  File "...\tools\gyp\pylib\gyp\MSVSVersion.py", line 601, in SelectVisualStudioVersion
    raise ValueError("Could not locate Visual Studio installation.")
```

gyp's Windows generator finds the compiler by reading the registry
(`msvs_emulation.GetVSVersion` → `MSVSVersion.SelectVisualStudioVersion`), and when the
registry does not answer it gives up - on a machine that does have Visual Studio.
clang-cl does not avoid this: the headers, import libraries and Windows SDK still
come from Visual Studio, and gyp is what runs `vcvarsall.bat` for every compile rule.

Passing the path in is the established answer, not an invention here. V8's own build
sets `GYP_MSVS_OVERRIDE_PATH` itself (`build/vs_toolchain.py`, and
`build/toolchain/win/setup_toolchain.py` does the same), precisely because a VS 2017
or newer install location is meant to be found through COM rather than the registry -
that is why the V8 Windows jobs never meet this error. depot_tools reaches the same
conclusion with `vswhere -prerelease` in `win_toolchain/package_from_installed.py`.
So the Windows job asks `vswhere` - Microsoft's own locator, shipped with the Visual
Studio installer - and hands gyp
`GYP_MSVS_OVERRIDE_PATH=<installationPath>` plus `GYP_MSVS_VERSION=<name>`, where the
name has to match the major (15 → 2017, 16 → 2019, 17 → 2022, 18 → 2026). With the
override set, gyp skips the registry probe altogether.

If vswhere is missing or answers nothing, the job walks the same install directories
Chromium's `vs_toolchain.py` walks: a `vs<year>_install` environment hint, then one
directory per edition (`Enterprise`, `Professional`, `Community`, `Preview`,
`Insiders`, `BuildTools`) under the per-year install root, accepting a directory only
when `VC\Auxiliary\Build\vcvarsall.bat` is really there. Checked by pointing it at
fake trees: newest edition wins, an `vs2026_install` hint wins over everything, and
when nothing exists the search comes back empty and the step fails with vswhere's list
of installed products rather than falling through to configure.

### 9.4 A missing nasm changes the Windows bundle without saying so

```text
WARNING: No acceptable ASM compiler found!
```

That warning is not harmless. On x86 and x64 `configure.py` asks for `nasm`, and when
there is none it sets `openssl_no_asm=1`, so OpenSSL is compiled without its assembly -
the bundle is then slower at crypto than Node's own Windows build, and the log only
says "WARNING". The Windows job installs nasm and stops if it still cannot be run.
Writing `--openssl-no-asm` into the args file is the alternative when that install is
not wanted; what must not happen is the build choosing it because a tool was missing.

### 9.5 On Linux, Node's `.a` files are thin archives

GNU `ar` on Linux writes *thin* archives for Node: the `.a` file holds the paths of its
object files, not their contents. The object files are therefore part of the input to
packaging, and this is what the failure looks like when they are gone:

```text
package_node: 6 archive(s) whole-archive, 31 plain, 3 system flags
ar: .../node/out/Release/obj/libnode_base.a: No such file or directory
```

The message names the archive, which is misleading: the archive exists, its members do
not. Listing a thin archive means opening every object file it points at, so `ar t`
fails and reports the archive's own name. Reproduced locally (GNU binutils 2.46) with
any archive whose members were deleted.

Two consequences, both implemented:

- `package_node.sh` un-thins each archive by archiving the members itself, and says so
  plainly when the members are missing, instead of leaving ar's message on its own.
- The CI job must not delete `*.o` before Package. "Free the object files" is a step of
  its own, after the bundle has been verified; it exists to keep disk free for the
  artifact upload, and on a Linux build it is the last thing that may touch them.

macOS (Apple `libtool`) and Windows (`lib.exe`) produce ordinary archives, so this is a
Linux-only constraint. `head -c 8 <archive>` shows which kind you have: `!<arch>` is a
normal archive, `!<thin>` is a thin one.
