# GodotJS-Dependencies
Workflows to build all dependencies of GodotJS (v8 and libwebsockets).


- https://github.com/actions/runner-images
- https://github.com/actions/checkout
- https://github.com/actions/create-release


## V8 versions

The default is **12.6.228.49**: the last V8 release an embedder can still compile
against as C++17. `12.7.224.1` added `#error "C++20 or later required."` to
`include/v8config.h`, and Godot compiles its modules with `-std=gnu++17`, so
anything from 12.7 up forces the module onto C++20.

| V8 | Minimum C++ standard for the embedder |
|---|---|
| up to `12.6.228.49` | C++17 |
| from `12.7.224.1` | C++20 |


## Bundle contents

`v8_<version>.zip` contains `v8/include/` plus one `v8/<platform>.<arch>.release/`
directory per platform. The headers are copied by the Linux x86_64 job: they are
identical for every platform, and that is the one job `publish` can never skip
(`vars.SKIP_WINDOWS` and `vars.SKIP_APPLE` can skip the others).


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
