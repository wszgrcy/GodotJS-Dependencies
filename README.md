# GodotJS-Dependencies
Workflows to build all dependencies of GodotJS (v8 and libwebsockets).


- https://github.com/actions/runner-images
- https://github.com/actions/checkout
- https://github.com/actions/create-release


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

The Linux jobs install `g++-13` for V8 15 and newer. V8 15 uses
`std::atomic_ref`, which needs libstdc++ from GCC 12 or newer, while
`ubuntu-22.04` ships GCC 11. clang automatically uses the newest GCC
installation it finds, so no `cc`/`cxx` args are needed.

Two things to know when embedding a 15.x build:

- Compile the embedder as **C++20** (`include/v8config.h` errors out otherwise).
- On Linux/Apple, link **`-latomic`**. V8 15 does 128-bit compare-exchanges on
  values that are only 8-byte aligned, so the compiler emits a call to
  `__atomic_compare_exchange` instead of a `cmpxchg16b` instruction, and that
  function lives in libatomic. A 12.x library has no such reference.

The Linux x86_64 build of 15.6.75.19 was verified locally: `libv8_monolith.a`
links with plain `g++ -std=c++20 ... -lv8_monolith -latomic` and the resulting
program runs JavaScript and reports `V8 version: 15.6.75.19`.

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
