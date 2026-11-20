# GodotJS-Dependencies
Workflows to build all dependencies of GodotJS (v8, node and libwebsockets).


- https://github.com/actions/runner-images
- https://github.com/actions/checkout
- https://github.com/actions/create-release


## One version input: `node_version`

`build_all.yml` asks for a Node version and nothing else. V8 is not asked for,
because V8 follows Node: the standalone `v8_<ver>.zip` is built at whichever V8 the
chosen Node embeds, read out of Node's own tag by `tools/node_v8_version.sh`
(Node 26.13.1 -> V8 14.6.202.34, and that number does exist as a tag in the V8
repository). Shipping a release whose Node bundle carries one V8 and whose
standalone bundle carries another would mean two engines to test for no benefit.

| | `v8_<ver>.zip`, one monolith per platform | `node_<ver>_<platform>.<arch>.zip`, 36 archives + headers |
|---|---|---|
| Android | today's default: GodotJS links `libv8_monolith.a` | arm64 and x86_64, cross-built with NDK r29 (`SKIP_ANDROID=true` turns them off); arm32 needs a 32-bit ARM build machine (V8 refuses that cross build), see `node.android_arm32.configure.txt` |
| iOS | today's default: same | `arm64` against the iPhoneOS SDK, plus `x86_64` for the iPhone simulator: Godot builds the simulator as `arch=x86_64 simulator=yes`, so the bundle carries that name even though no iOS device has an x86 CPU (`SKIP_IOS=true` turns both off). The simulator bundle has no Temporal API: Rust publishes no standard library for `x86_64-apple-ios-sim`, so there is no compiler for it. The wrapper compilers come from `tools/apple_toolchain.sh`, and `tools/test_apple_toolchain.sh` checks them on any machine against a stand-in SDK. iOS forbids executable memory, so an embedder must start Node with JIT disabled |
| Linux, macOS, Windows | still usable, and what the engine links today | Linux x86_64 and arm64, macOS arm64 plus x86_64 (cross-built on the arm64 runner), Windows x86_64 and arm64 (GitHub's arm64 Windows runner); `SKIP_WINDOWS=true` / `SKIP_APPLE=true` turn them off |
| Web export | not needed | not needed: GodotJS's web bridge (`impl/web`) runs inside the browser's own JavaScript engine |

Two consequences of V8 following Node, both deliberate:

- **No standalone Windows bundle while Node's V8 is below 15.7.112.1.** MSVC cannot
  build V8 below that version (see "Windows needs V8 15.7.112.1 or newer" below), so
  the two `v8_windows_*` jobs skip themselves and Windows desktop takes its runtime
  from the Node bundle. The `derive_v8` job prints the reason into the log.
- Older V8 versions are not lost. Each `build_v8_*.yml` workflow still takes a
  `v8_version` input of its own, which is how 13.5.119 or the last C++17-compatible
  one (12.6.228.49) are still built on request.

`runtime` (**default `node`**) picks one runtime when the other is not wanted. The
V8 bundle already exists from earlier releases, so a normal release builds the Node
bundle; `both` additionally rebuilds V8, and `derive_v8` then decides whether a
standalone bundle is buildable at the derived version at all (these scripts build
the 15.x packages, so a Node version embedding V8 14.x leaves those eight jobs
skipped with the reason in the log; `FORCE_V8_PRE_15=true` forces an attempt).
`vars.SKIP_WINDOWS` and
`vars.SKIP_APPLE` apply to both runtimes the same way.

The Node Linux jobs pin `CC=gcc-13` / `CXX=g++-13` and check the standard library
version before compiling. Node 26 needs GCC >= 13.2 *or* Clang >= 19.1, and its V8
uses C++20 library pieces that libstdc++ 12 carries only in incomplete form
(`std::atomic_ref` with class template argument deduction, which `cppgc` relies
on). A newer clang paired with libstdc++ 12 headers therefore fails deep inside
`src/heap/cppgc`, half an hour into the build - so the pair is fixed and asserted
instead of left to whatever the image happens to resolve.

The eleven `lws_*` jobs ignore `runtime` and always build. libwebsockets is not a JS
runtime: GodotJS uses it as the WebSocket transport for the debugger connection,
because Godot's own `modules/websocket` cannot finish the handshake with Chrome
DevTools (see the `JSB_WITH_LWS` note in GodotJS's `SCsub`). The engine turns that
define on only when it finds the library under `lws/<platform>_<arch>_release/`, and
the name it looks for is built out of its own platform and architecture, so a stage
directory named any other way leaves an engine build without the debugger transport
and does not fail it.


## V8 versions

`build_all.yml` no longer takes a V8 version at all: it builds the V8 that the
selected Node embeds (V8 14.6.202.34 for Node 26.13.1). When a V8 bundle is built
on its own through `build_v8_*.yml`, the version in use is **15.7.112.12**, which
is also what GodotJS's `SCsub` pins today. Windows cannot be built below
15.7.112.1, see "Windows needs V8 15.7.112.1 or newer" below.

What a build here costs the embedder depends on the V8 version:

| V8 | Minimum C++ standard for the embedder |
|---|---|
| up to `12.6.228.49` | C++17 |
| from `12.7.224.1` | C++20 |

`12.7.224.1` added `#error "C++20 or later required."` to
`include/v8config.h`, and Godot compiles its modules with `-std=gnu++17`, so
anything from 12.7 up forces the module onto C++20. `12.6.228.49` is kept in the
version list as the last C++17-compatible option.

See [docs/v8-15.md](docs/v8-15.md) for what changes when building 15.x: four
extra gn args, ELF CREL, a newer libstdc++ on Linux, and what has not been
verified yet.


## Node versions

The default is **26.13.1** (Active LTS). Node embeds V8 itself, so a Node bundle
is an alternative to the V8 bundle, not an addition to it: Node 26.13.1 ships
V8 14.6.202.34, and no published Node release carries a 15.x V8.

Unlike the V8 bundle, Node is desktop-first in upstream's eyes: `BUILDING.md` says
Android is unsupported and does not cover iOS. That is about upstream's CI - shipped
third-party plugins do run Node on both - so this repo cross-builds both mobile
targets too, with the toolchain handed over as wrapper compilers and a link-only
bundle check because there is no device to run on (`docs/node-26.md` section 6).
Neither has been compiled here yet, so both jobs stay off by default. One Node
release is also far bigger: about 67 MB compressed per platform, 36 archives instead
of one, six of which must be linked with `--whole-archive`. To keep the download
per engine build reasonable, Node is released as **one asset per platform**
(`node_<version>_<platform>.<arch>.zip`) instead of one bundle with every
platform inside.

See [docs/node-26.md](docs/node-26.md) for what has to be changed in Node's
source before building, what the bundle layout is, the order an embedder has to
initialise and shut down Node in, and what has not been verified.


## Bundle contents

`v8_<version>.zip` contains `v8/include/` plus one `v8/<platform>.<arch>.release/`
directory per platform. The headers are copied by the Linux x86_64 job: they are
identical for every platform, and that is the one job `publish` can never skip
(`vars.SKIP_WINDOWS` and `vars.SKIP_APPLE` can skip the others).

`node_<version>_<platform>.<arch>.zip` contains `node/include/` (Node's own header
install: `node.h`, `v8.h`, `uv.h`, `cppgc/`, `openssl/`) plus one
`node/<platform>.<arch>.release/` directory with the archives, `link.txt` (which
archives, in which order, which ones whole-archive) and `manifest.json`.

Each platform directory also carries `icudtl.dat`. ICU is built with
`icu_use_data_file = true`, so its language resources live in that file instead of
inside the monolith: without it `Intl.*` is broken and
`Date.prototype.toLocaleDateString` aborts the process. GodotJS loads the file at
startup from next to the executable, or from the path in `GODOTJS_ICU_DATA`. It is
taken from the V8 checkout: `third_party/icu/common/` on desktop, and
`third_party/icu/android/` / `third_party/icu/ios/` on mobile (about 10 / 9 / 6 MB).


## Windows Toolset

Different Visual C++ Compilers are involved in different prebuilt GodotJS dependency releases:

| Package | Workflow Runners | Libraries | Toolset | Platforms/Architectures |
|---|---|---|---|---|
|[v8_r7](https://github.com/ialex32x/GodotJS-Dependencies/releases/download/v8_r7/v8_r7.zip)| windows-latest(2022)<br/>ubuntu-latest(22.04) |v8(12.4.254.20)| MSVC v143(14.40.33807)| Windows(x86_64)<br/>Linux(x86_64)<br/>MacOS(ARM64) |
|[v8_r9](https://github.com/ialex32x/GodotJS-Dependencies/releases/download/v8_r9/v8_r9.zip)| windows-latest(2022)<br/>ubuntu-latest(22.04) |v8(12.4.254.20)| VS2022(17.11.3)<br/> MSVC v143(14.41.34120)| Windows(x86_64)<br/>Linux(x86_64)<br/>MacOS(ARM64)<br/>Android(ARM64-v8a)<br/>iOS(ARM64) |
|[v8_r10](https://github.com/ialex32x/GodotJS-Dependencies/releases/download/v8_r10/v8_r10.zip)| windows-2019<br/>ubuntu-22.04 |v8(12.4.254.21)| MSVC v142(14.29.30133) | Windows(x86_64)<br/>Linux(x86_64)<br/>MacOS(ARM64)<br/>Android(ARM64-v8a)<br/>iOS(ARM64) |

> [!NOTE]
> Install specific VS 2022 MSVC toolset for different pacakge you used to avoid linkage errors.

-----

Why **windows_x86_64_release** does not follow the same naming rules?
> godot 4.3.1 generates `ActiveProjectItemList_` variable name with the path name (see methods.py)
> it'll fail if the path contains '.' or any other characters invalid as variable name
> detect and rename them for better compatibility


# V8 15.x and newer

V8 15 needs a few extra build settings that the older versions we build do not
understand, so they live in `v8.extra_15.x.args.gn` instead of the per-platform
`v8.<platform>_<arch>.args.gn` files (gn rejects args a version does not
declare). `prepare_v8_build.sh` appends that file for you, and does one more
thing:

```sh
bash prepare_v8_build.sh <v8_source_dir> <args_gn_path> <v8_version>
```

It also turns ELF CREL relocations off in `//build/config/compiler/BUILD.gn`.
Since V8 15 the build asks the assembler for CREL whenever lld is used, but
only lld can read them back: a `libv8_monolith.a` built that way cannot be
linked with GNU binutils, and `g++` fails with
`error in libv8_monolith.a(...)(.eh_frame); no .eh_frame_hdr table will be
created`. Turning CREL off costs a little link time and keeps the library
usable with the toolchain everyone already has. If you want CREL back (smaller
archive, faster link) run the script with `V8_KEEP_CREL=1`, and then link the
result with `-fuse-ld=lld` — GNU `nm`, `objdump`, `ar` and `objcopy` cannot read
the archive either.

The Linux jobs install `g++-14` for V8 14 and newer. The source needs two things
libstdc++ only declares in a newer compiler:
`std::hardware_destructive_interference_size` (from GCC 12; a `static_assert` in
`src/heap/mutable-page.cc`) and `std::powl` (from GCC 14; called by
`src/objects/js-duration-format.cc`). Measured on that call: g++-12 and g++-13
fail with `no member named 'powl' in namespace 'std'`, g++-14 and g++-15 compile
it. `ubuntu-24.04` ships GCC 13, so `g++-14` goes in next to it, and clang
automatically uses the newest GCC installation it finds, so no `cc`/`cxx` args
are needed. What the newer image costs is the C library floor - `use_sysroot`
is off, so the archives inherit the runner's glibc (2.39 on 24.04).

Two things to know when embedding a 15.x build:

- Compile the embedder as **C++20** (`include/v8config.h` errors out otherwise).
- On Linux/Apple, link **`-latomic`**. V8 15 does 128-bit compare-exchanges on
  values that are only 8-byte aligned, so the compiler emits a call to
  `__atomic_compare_exchange` instead of a `cmpxchg16b` instruction, and that
  function lives in libatomic. A 12.x library has no such reference.

The Linux x86_64 build of 15.7.112.12 was verified locally with ICU on:
`libv8_monolith.a` links with plain `g++ -std=c++20 ... -lv8_monolith -latomic`, and
the resulting program runs JavaScript, `Intl.NumberFormat`, `toLocaleDateString`
and a `\p{Script=Han}` regex. See [docs/v8-15.md](docs/v8-15.md).

## Windows on ARM

Two things on the arm64 Windows runner behaved differently from every other platform,
and neither failed loudly:

- **The shell reports the wrong architecture.** `uname -m` on the Windows-on-ARM
  runner says `x86_64` while the machine is arm64, so a native build looks like a
  cross build. Two decisions depend on that: the workflow's choice of whether
  clang-cl may be handed over, and `prepare_node_build.sh`'s decision about Temporal,
  which is refused in a Windows cross build because `deps/crates/crates.gyp` names
  the Rust archive after the target architecture and a host build would collide with
  it. Both ask Visual Studio instead: `VSCMD_ARG_HOST_ARCH`, published by the Visual
  Studio step for the whole job, spells the answer `x64` or `arm64`. `uname -m` stays
  as a fallback and says out loud when it is used, and `NODE_HOST_CPU` overrides both.
- **libffi's assembly never reached a link.** Windows/arm64 assembles
  `src/aarch64/win64_armasm.S` into a standalone object and names it in the libffi
  target's own `libraries` - but libffi is a static library, so that link line is
  never used, and `node_mksnapshot.exe` stopped with three unresolved symbols
  (`ffi_call_SYSV` and the two closure entry points). Other platforms get those
  symbols inside the archive, because there `sysv.S` is one of libffi's sources.
  `patches/godotjs-node-libffi-win-arm64-link-obj.patch` repeats the entry under
  `link_settings`, the block gyp hands to the link of everything that depends on
  libffi.

## iOS: why the C++ standard has to come from the compiler wrapper

`--dest-os=ios` gives gyp the `ios` flavour, and gyp's ninja generator only turns
`xcode_settings` into compiler flags for the `mac` flavour
(`tools/gyp/pylib/gyp/generator/ninja.py`, the line `if self.flavor == "mac"`). Node
puts its C++ standard and its exception setting in exactly those settings
(`common.gypi`: `CLANG_CXX_LANGUAGE_STANDARD = gnu++20`,
`GCC_ENABLE_CPP_EXCEPTIONS = NO`), so an iOS build reaches the compiler with no `-std=`
at all and the first C++ file ends at `deps/v8/include/v8config.h`:
`"C++20 or later required."` - on the host toolset too, because those settings belong
to the target rather than to a toolset. `tools/apple_toolchain.sh` therefore bakes
`-std=gnu++20 -fno-exceptions` into the C++ wrappers it writes for iOS: one for the
target and a `host_cxx` for the build-time programs, which have to stay macOS binaries.
`tools/test_apple_toolchain.sh` checks all of it on any machine, without Xcode.

Links needed the same treatment. abseil calls CoreFoundation (`CFTimeZoneCopyDefault`
and friends from its time-zone lookup) and the `node_js2c` host tool needs
CoreFoundation and Security, and both were named only where gyp reads flags for a
mac-flavour build - so the first binary to link abseil, the host tool `torque`,
stopped with "Undefined symbols for architecture arm64". `patches/
godotjs-node-abseil-ios-corefoundation.patch` and
`patches/godotjs-node-js2c-ios-frameworks.patch` name those frameworks in a form every
flavour reads; a macOS build gains at most a repeated `-framework`, which the linker
folds into one.

Two smaller facts from the same run, so nobody rediscovers them: `rustup target add
x86_64-apple-ios-sim` must not be attempted at all, because stable Rust publishes no
standard library for that triple (neither the 1.99.1 nor the 1.100.0 manifest has
one; `aarch64-apple-ios-sim` does exist) - the job skips it and sets `NODE_TEMPORAL=off`
instead, and the device bundle keeps Temporal. And the build job checks this
repository out under `Scripts/`, so the wrapper script is `Scripts/tools/
apple_toolchain.sh` there; only the `pick` job uses the default path.

## Rust and Temporal: which version, and what it costs on Windows

Node 26 turned V8's Temporal support on, and that implementation is Rust
(`deps/crates`), so every platform now carries a `node_crates` static library
compiled by cargo and then handed to the platform linker like any other archive.

**Version.** Node only sets a floor: rustc and cargo >= 1.86, LLVM >= 19
(`BUILDING.md`, "Building Node.js with Temporal support"), and
`deps/crates/Cargo.toml` repeats it as `rust-version = "1.86"`. There is no
`rust-toolchain` file in Node, so nothing in the source asks for a particular
release. Node's own Windows workflow declares `RUSTC_VERSION: '1.88'`, but as the
author of nodejs/node#67589 notes that `rustup override set` has been failing
quietly for a long time, so upstream has really been building against whatever
stable the runner image carries. This repository does the same: the runner's Rust
is used, and the repository variable `NODE_RUST_TOOLCHAIN` can name a version (for
example `1.88`, to match what Node declares) if you ever need to reproduce a build.

**What a newer Rust costs on Windows.** Because the archive is linked by
`link.exe` and not by rustc, every symbol the Rust standard library references has
to be findable through an import library. `WaitOnAddress`, `WakeByAddressSingle`
and `WakeByAddressAll` - what std waits on an address with - live in
`Synchronization.lib` (MSDN: header `synchapi.h`, served by
`API-MS-Win-Core-Synch-l1-2-0.dll`), and Node never named it. Up to Rust 1.99 std
declared them through a raw-dylib link attribute, which needs no import library,
so nothing was missing; newer Rust declares them as ordinary imports, and every
link of `node_crates.lib` then fails - `mksnapshot.exe` is the first, and the
message is

```text
error LNK2019: unresolved external symbol __imp_WakeByAddressSingle
    referenced in file node_crates.lib(std-*.rcgu.o)
```

The fix is to name the library, not to hold the compiler back:
`patches/godotjs-node-crates-win-synchronization.patch` adds `-lsynchronization`
to the Windows `link_settings` of `deps/crates/crates.gyp`, which is also what
nodejs/node#67590 does for nodejs/node#67589. Delete the patch once that upstream
change is in a release.

**One platform without Temporal.** The iOS simulator builds with
`NODE_TEMPORAL=off`, because Rust publishes no standard library for
`x86_64-apple-ios-sim` - the 1.99.1 and 1.100.0 dist manifests list the arm64
simulator but not that triple - so there is no rustc that can compile Temporal for
it. The device bundle keeps Temporal; only the simulator bundle lacks that one JS
API.

## Windows needs V8 15.7.112.1 or newer, plus `v8_use_metagen = false`

The MSVC standard library implements `std::atomic<T>` with `alignas(sizeof(T))`,
and under the Microsoft C++ ABI a required alignment cannot be lowered again by
`#pragma pack`. V8's `Map` holds `std::atomic` bit fields, so the `pack(1)`
`ExtendedMap` — which deliberately leaves `kTaggedSize - 1` bytes of tail padding
for its subclasses — comes out 44 bytes wide while its fields stop at 41. Linux
and macOS are unaffected because their standard library's atomics carry no such
alignment requirement.

The same mismatch bites in two places, and one V8 version bump does not cover
both:

1. **Torque's generated layout assertions.** Building 15.6.75.19 for Windows fails
   with `static_assert(kFlagsOffset == offsetof(JSInterceptorMap, flags_))`
   evaluating to `44 == 41`. Upstream fixed this in `99ebeac9c548e36f9e18658097df0b6c42b1c71c`,
   "[torque] Fix C++ object layout assertions for MSVC STL" (bug 531344950, also
   nodejs/node#65161); the first release branch carrying it is 15.7.112, which is
   why the default `v8_version` is `15.7.112.12` rather than `15.6.75.19`.
2. **Metagen's layout extraction.** From 15.7 metagen reads the object layout out
   of the C++ headers with libclang, and it requires `sizeof(class)` to equal the
   end of the class's fields, so it aborts on the same class:
   `[metagen] layout extraction failed: v8::internal::ExtendedMap: fields end at
   41, class size is 44`. That check is still strict on current upstream, and
   `ExtendedMap` is unchanged through 15.9, so **no newer version fixes this**.
   The Windows jobs therefore pass `v8_use_metagen = false`, which takes the old
   Torque path — the one upstream's fix covers. This is a supported configuration,
   not a workaround of our own: upstream keeps two bots on it
   (`debug_x64_no_metagen` and `torque_compare` in `infra/mb/mb_config.pyl`), and
   `BUILD.gn` asserts that `v8_verify_torque_generation_invariance` requires it.

Both Windows jobs gate the flag on the version, because `v8_use_metagen` does not
exist before 15.7 and gn rejects an assignment to an unknown argument.

The flag is transitional and upstream intends to retire Torque's layout path
eventually (`tools/metagen/metagen.py` carries a TODO to that effect). Remove the
`v8_use_metagen = false` lines from both Windows jobs once metagen can represent
the tail gap — either an annotation for fixed tail padding appears, or
`ExtendedMap` stops leaving the 3 bytes. Until then, expect to re-check this on
every V8 version bump.

Going from 15.6 to 15.7 moves 8 files in `include/` (67 added, 22 removed lines),
all of it additive — a new `DynamicScriptCompiledFromEmbedderCallback`, LA57
external-pointer constants, and debug-protocol fields — so the embedder side
should not need changes.

`docs/v8-15.md` has the full write-up: why each extra arg is needed, how to turn
CREL back on (it takes a change in both repositories), the local build recipe,
and what has not been verified yet.

-----

# Local Builds (with act)

This repository supports running our GitHub Actions locally with [act](https://github.com/nektos/act).

Important:
- Always pass: `--var HOST_MACOS=true` when running with act. It is required for macOS/iOS jobs and harmless for others.
- On Apple Silicon, add `--container-architecture linux/amd64` for Linux/Android jobs.
- Map macOS runners to your host: `-P macos-latest=-self-hosted`.
- Use `workflow_dispatch` on each workflow file directly (do not use build_all.yml for local runs).

Common arguments you can reuse:
- Docker images for Ubuntu:
  `-P ubuntu-latest=catthehacker/ubuntu:act-22.04 -P ubuntu-22.04=catthehacker/ubuntu:act-22.04`
- Artifact server path (optional): `--artifact-server-path ./artifacts`

Examples below use `--var HOST_MACOS=true` in all commands (safe across platforms).

## macOS Host (run on your Mac)

- LWS macOS x86_64
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_macos_x86_64.yml \
  -P macos-latest=-self-hosted \
  --var HOST_MACOS=true \
  -j build
```

- LWS macOS arm64
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_macos_arm64.yml \
  -P macos-latest=-self-hosted \
  --var HOST_MACOS=true \
  -j build
```

- LWS iOS device (arm64)
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_ios_arm64.yml \
  -P macos-latest=-self-hosted \
  --var HOST_MACOS=true \
  -j build
```

- LWS iOS simulator (x86_64)
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_ios_x86_64.yml \
  -P macos-latest=-self-hosted \
  --var HOST_MACOS=true \
  -j build
```

- V8 macOS x86_64
```sh
act workflow_dispatch \
  -W .github/workflows/build_v8_macos_x86_64.yml \
  -P macos-latest=-self-hosted \
  --var HOST_MACOS=true \
  --input v8_version=13.5.119 \
  -j build
```

- V8 macOS arm64
```sh
act workflow_dispatch \
  -W .github/workflows/build_v8_macos_arm64.yml \
  -P macos-latest=-self-hosted \
  --var HOST_MACOS=true \
  --input v8_version=13.5.119 \
  -j build
```

- V8 iOS device (arm64)
```sh
act workflow_dispatch \
  -W .github/workflows/build_v8_ios_arm64.yml \
  -P macos-latest=-self-hosted \
  --var HOST_MACOS=true \
  --input v8_version=13.5.119 \
  -j build
```

## Linux/Android (run in Docker)

Add these flags on Apple Silicon: `--container-architecture linux/amd64`.

- LWS Linux x86_64
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_linux_x86_64.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  -j build
```

- LWS Linux arm64 (cross)
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_linux_arm64.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  -j build
```

- LWS Linux arm32 (cross)
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_linux_arm32.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  -j build
```

- LWS Android arm64
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_android_arm64.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  -j build
```

- LWS Android arm32
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_android_arm32.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  -j build
```

- LWS Android x86_64
```sh
act workflow_dispatch \
  -W .github/workflows/build_lws_android_x86_64.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  -j build
```

- V8 Linux x86_64
```sh
act workflow_dispatch \
  -W .github/workflows/build_v8_linux_x86_64.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  --input v8_version=13.5.119 \
  -j build
```

- V8 Linux arm64
```sh
act workflow_dispatch \
  -W .github/workflows/build_v8_linux_arm64.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  --input v8_version=13.5.119 \
  -j build
```

- V8 Android arm64
```sh
act workflow_dispatch \
  -W .github/workflows/build_v8_android_arm64.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  --input v8_version=13.5.119 \
  -j build
```

- V8 Android arm32
```sh
act workflow_dispatch \
  -W .github/workflows/build_v8_android_arm32.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  --input v8_version=13.5.119 \
  -j build
```

- V8 Android x86_64
```sh
act workflow_dispatch \
  -W .github/workflows/build_v8_android_x86_64.yml \
  --artifact-server-path ./artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-22.04 \
  -P ubuntu-22.04=catthehacker/ubuntu:act-22.04 \
  --var HOST_MACOS=true \
  --input v8_version=13.5.119 \
  -j build
```
