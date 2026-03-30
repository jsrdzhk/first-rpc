# first-rpc

`first-rpc` is a standalone C++ project for a cross-platform gRPC client/server used for remote operations and log troubleshooting.

## Goals

- Support Windows, Linux, and macOS for both client and server.
- Avoid direct dependence on unstable SSH for routine log investigation.
- Keep the first version small, auditable, and easy to deploy.
- Use C++20 with CMake 4.3.0.

## Current Scope

This initial implementation provides:

- A gRPC service definition under `proto/`
- A basic gRPC server with command whitelist style handlers
- A basic CLI client
- Initial handlers:
  - `health_check`
  - `list_dir`
  - `read_file`
- `tail_file`
- `grep_file`

Code structure guide for future onboarding:

- [doc/code-structure.md](doc/code-structure.md)

## Build

This project follows the official gRPC C++ source-build flow:

- clone `grpc/grpc` with submodules
- build it with CMake
- install it into a local prefix inside this repo
- point `first-rpc` at that prefix with `CMAKE_PREFIX_PATH`

Current pinned gRPC tag: `v1.80.0`

When `GrpcVersion` is not provided, the deps scripts now auto-select the latest stable gRPC tag that does not end with `-pre...`.

### Windows

```powershell
.\deps.ps1
.\build.ps1
```

Windows scripts default to `ProcessorCount` parallel jobs. You can override it with `-Parallel`, for example:

```powershell
.\deps.ps1 -Parallel 12
.\build.ps1 -Parallel 12
```

`deps.ps1` will:

- clone gRPC into `third_party/grpc-src`
- build it in `third_party/grpc-build/windows-<buildtype>`
- install it into `third_party/grpc-install/windows-<buildtype>`

如果需要显式指定构建类型：

```powershell
.\deps.ps1 -BuildType Debug
.\build.ps1 -BuildType Debug
```

目录约定：

- `Debug` 输出到 `cmake-build-debug`
- `Release` 输出到 `cmake-build-release`

如果依赖已经装好，日常改代码后通常只需要：

```powershell
.\build.ps1
```

如果只是想重新安装 gRPC：

```powershell
.\deps.ps1
```

如果只是想重新配置或重新编译：

```powershell
.\build.ps1 -SkipBuild
.\build.ps1 -SkipConfigure
```

### Rust

The repo also includes a Rust implementation under [rust/Cargo.toml](rust/Cargo.toml) that reuses the same protobuf contract and exposes matching executables with `_rust` suffixes:

- `first_rpc_server_rust`
- `first_rpc_client_rust`

Build it with Cargo:

```powershell
cargo build --release --manifest-path rust/Cargo.toml
```

or:

```bash
cargo build --release --manifest-path rust/Cargo.toml
```

Or use the helper scripts:

Windows:

```powershell
.\rust\rust_build.ps1 -BuildType Release
```

Linux / macOS:

```bash
./rust/rust_build.sh --build-type Release
```

### Linux / macOS

```bash
./deps.sh
./build.sh
```

在 CentOS 7 上如果你是通过 Software Collections 使用 GCC 11，先进入 devtoolset 环境再执行：

```bash
scl enable devtoolset-11 bash
./deps.sh
./build.sh
```

如果你要显式指定编译器，也可以这样跑：

```bash
./deps.sh --gcc gcc --gxx g++
./build.sh --gcc gcc --gxx g++
```

`deps.sh` 会同时做几件事：

- 导出 `CC` 和 `CXX`
- 克隆官方 `grpc/grpc` 源码和子模块
- 用本机工具链把 gRPC 安装到 `third_party/grpc-install/<platform-buildtype>`

这对 CentOS 7 很重要，因为即使系统默认还是 `g++ 4.8.5`，你只要先进入 `devtoolset-11`，脚本就会沿用那个 shell 里的 `gcc/g++` 去编译 gRPC 和 protobuf。

`deps.sh` now prints the detected `gcc/g++` versions and fails fast unless both compilers are present, share the same major version, and are at least GCC 11.

依赖装好之后，日常改代码通常只需要：

```bash
./build.sh
```

## Run

Start a server:

```bash
first_rpc_server --host 127.0.0.1 --port 18777 --root /var/log --token demo-token
```

On Linux servers, you can also use the helper script to manage a background process:

```bash
./run_server.sh start --host 0.0.0.0 --port 18777 --root /var/log --token demo-token
./run_server.sh status
./run_server.sh stop
```

The helper defaults to the C++ server. To launch the Rust server instead:

```bash
./run_server.sh start --impl rust --root /var/log --token demo-token
```

If the server binary is already in the current working directory or another custom location, you can point the helper at it directly:

```bash
./run_server.sh start --bin ./first_rpc_server --root /var/log --token demo-token
```

Health check:

```bash
first_rpc_client --host 127.0.0.1 --port 18777 --token demo-token health_check
```

Tail a file:

```bash
first_rpc_client --host 127.0.0.1 --port 18777 --token demo-token tail_file --path app.log --lines 50
```

## Smoke Test

After building, you can run a local end-to-end smoke test that starts the server on localhost, prepares a sample file, and verifies `health_check`, `list_dir`, `read_file`, `tail_file`, and `grep_file`.

Windows:

```powershell
.\smoke_test.ps1 -BuildType Release
```

Linux / macOS:

```bash
./smoke_test.sh --build-type Release
```

Rust smoke tests:

Windows:

```powershell
.\rust\smoke_test_rust.ps1 -BuildType Release
```

Linux / macOS:

```bash
./rust/smoke_test_rust.sh --build-type Release
```

## CentOS 7 + GCC 15 Notes

Your target combination is feasible with some caveats:

- CentOS 7 ships with glibc 2.17, which is old but still workable.
- If GCC 15 is installed locally on that CentOS 7 host, C++20 compilation is realistic for this project.
- You should make sure the source-build step uses your newer toolchain instead of the system `g++ 4.8.5`.
- The resulting binary will depend on that host's runtime combination, especially `libstdc++`.
- Running the binary on the same machine where it was built is the safest path.
- Reusing the binary across different Linux machines may require bundling or statically linking `libstdc++` if runtime compatibility becomes an issue.

This repo no longer depends on Conan. The entire dependency flow is local source build plus local install prefix, which is closer to the gRPC C++ quick start and easier to reason about when old platforms need special toolchains.

## Next Steps

- Add config file support for server allowlists
- Add structured module/log discovery
- Add stronger auth and audit logging
- Add service packaging for Linux
