# first-rpc

`first-rpc` is a cross-platform gRPC client/server project for remote operations, log inspection, controlled file transfer, and trusted remote command execution.

## Goals

- Support Windows, Linux, and macOS for both client and server.
- Avoid direct dependence on unstable SSH for routine investigation tasks.
- Keep the first version small, auditable, and easy to deploy.
- Use C++20 with CMake 4.3.0 for the C++ implementation.

## Current Scope

This repository currently provides:

- A shared protobuf contract under `proto/`
- A C++ gRPC server and CLI client
- A Rust gRPC server and CLI client
- Supported actions:
  - `health_check`
  - `list_dir`
  - `read_file`
  - `tail_file`
  - `grep_file`
  - `upload_file`
  - `exec`

Code structure guide:

- [doc/code-structure.md](doc/code-structure.md)

## Build

This project follows the official gRPC C++ source-build flow:

- clone `grpc/grpc` with submodules
- build it with CMake
- install it into a local prefix inside this repository
- point `first-rpc` at that prefix with `CMAKE_PREFIX_PATH`

Current pinned gRPC tag: `v1.80.0`

When `GrpcVersion` is not provided, the dependency scripts auto-select the latest stable gRPC tag that does not end with `-pre...`.

### Windows

```powershell
.\deps.ps1
.\build.ps1
```

Windows scripts default to `ProcessorCount` parallel jobs. You can override that with `-Parallel`, for example:

```powershell
.\deps.ps1 -Parallel 12
.\build.ps1 -Parallel 12
```

`deps.ps1` will:

- clone gRPC into `third_party/grpc-src`
- build it in `third_party/grpc-build/windows-<buildtype>`
- install it into `third_party/grpc-install/windows-<buildtype>`

To build a specific configuration:

```powershell
.\deps.ps1 -BuildType Debug
.\build.ps1 -BuildType Debug
```

Build directory conventions:

- `Debug` uses `cmake-build-debug`
- `Release` uses `cmake-build-release`

For day-to-day C++ work after dependencies are already installed:

```powershell
.\build.ps1
```

To build and run C++ unit tests in one step:

```powershell
.\build.ps1 -RunTests
```

To reinstall gRPC only:

```powershell
.\deps.ps1
```

To reconfigure or rebuild only:

```powershell
.\build.ps1 -SkipBuild
.\build.ps1 -SkipConfigure
```

To install the built executables into a user-level PATH directory for direct PowerShell invocation:

```powershell
.\install.ps1
```

By default this installs binaries into `%LOCALAPPDATA%\first-rpc\bin` and adds that directory to the current user PATH.

On Linux, you can install the built executables into `/usr/local/bin`:

```bash
sudo ./install.sh
```

If the script is started without `root`, it now re-executes itself through `sudo`.

Examples:

```bash
sudo ./install.sh --impl cpp
sudo ./install.sh --impl rust --build-type Debug
```

### Rust

The repository also includes a Rust implementation under [rust/Cargo.toml](rust/Cargo.toml) that reuses the same protobuf contract and exposes matching executables with `_rust` suffixes:

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
.\rust\build.ps1 -BuildType Release
```

To build and run Rust unit tests in one step:

```powershell
.\rust\build.ps1 -RunTests
```

Linux / macOS:

```bash
./rust/build.sh --build-type Release
```

To build and run Rust unit tests in one step:

```bash
./rust/build.sh --run-tests
```

### Linux / macOS

```bash
./deps.sh
./build.sh
```

If your Linux environment requires a newer compiler toolchain, activate that toolchain before running the scripts. For example:

```bash
scl enable devtoolset-11 bash
./deps.sh
./build.sh
```

You can also specify the compiler explicitly:

```bash
./deps.sh --gcc gcc --gxx g++
./build.sh --gcc gcc --gxx g++
```

`deps.sh` will:

- export `CC` and `CXX`
- clone the official `grpc/grpc` source tree and submodules
- install gRPC into `third_party/grpc-install/<platform-buildtype>`

`deps.sh` prints the detected `gcc/g++` versions and fails fast unless both compilers are present, share the same major version, and are at least GCC 11.

For day-to-day C++ work after dependencies are already installed:

```bash
./build.sh
```

To build and run C++ unit tests in one step:

```bash
./build.sh --run-tests
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

By default, the helper writes runtime logs and pid files under `server-runtime/<impl>/` in the repository root.

### Linux systemd service

For a persistent Linux deployment, the repository now includes:

- [install_systemd_service.sh](install_systemd_service.sh)
- [systemd/first-rpc.service.template](systemd/first-rpc.service.template)
- [systemd/first-rpc.env.example](systemd/first-rpc.env.example)

The installer writes:

- a service unit, by default: `/etc/systemd/system/first-rpc.service`
- an environment file, by default: `/etc/first-rpc/first-rpc.env`

Typical install flow:

```bash
sudo ./install_systemd_service.sh --user dma --group dma --root /home/dma
sudo systemctl status first-rpc
sudo journalctl -u first-rpc -f
```

To install the Rust server instead:

```bash
sudo ./install_systemd_service.sh --impl rust --user dma --group dma --root /home/dma
```

Important notes:

- the installer auto-reexecs itself through `sudo` when it is not started as `root`
- the installer now requires explicit `--user` and `--group` so the service cannot silently run as `root`
- it reuses [run_server.sh](run_server.sh) in foreground mode for process startup
- the service reads runtime settings from the generated env file
- when `--bin` is omitted, the installer prefers an already installed server binary such as `/usr/local/bin/first_rpc_server`
- when `--log-dir` and `--pid-file` are omitted, they default under the service user's home, for example `/home/dma/first-rpc-runtime/cpp`
- use `--force` if you want to overwrite an existing unit or env file

To uninstall the systemd service:

```bash
sudo ./uninstall_systemd_service.sh
```

Health check:

```bash
first_rpc_client --host 127.0.0.1 --port 18777 --token demo-token health_check
```

Tail a file:

```bash
first_rpc_client --host 127.0.0.1 --port 18777 --token demo-token tail_file --path app.log --lines 50
```

Upload a file:

```bash
first_rpc_client --host 127.0.0.1 --port 18777 --token demo-token upload_file --local app.jar --path deploy/app.jar
```

Execute a command inside the configured root:

```bash
first_rpc_client --host 127.0.0.1 --port 18777 --token demo-token exec --command "pwd" --working-dir .
```

`exec` returns:

- `stdout`
- `stderr`
- `exit_code`
- `timed_out`
- the resolved `working_dir`

Default `exec` behavior:

- default timeout: `30000` ms
- default output cap: `65536` bytes for each of `stdout` and `stderr`
- when the timeout is hit, the server terminates the command, returns `timed_out=true`, and reports exit code `124`

`exec` only constrains the resolved working directory under `--root`. The executed command still runs with the server process account and can access anything that account can reach. Treat it as a controlled convenience for trusted environments, not a sandbox.

## Smoke Test

After building, you can run a local end-to-end smoke test that starts the server on localhost, prepares sample files, and verifies `health_check`, `list_dir`, `read_file`, `tail_file`, `grep_file`, `upload_file`, and `exec`.

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
.\rust\smoke_test.ps1 -BuildType Release
```

Linux / macOS:

```bash
./rust/smoke_test.sh --build-type Release
```

## Unit Tests

C++ unit tests use Catch2 and are registered through CTest.

After configuring and building the C++ project:

```bash
ctest --test-dir cmake-build-release --output-on-failure
```

Rust unit tests use the built-in Cargo test runner:

```bash
cargo test --manifest-path rust/Cargo.toml
```

## Next Steps

- Add config file support for server allowlists
- Add structured module and log discovery
- Add stronger auth and audit logging
- Add service packaging for Linux
