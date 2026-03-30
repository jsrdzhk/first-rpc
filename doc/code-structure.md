# first-rpc Code Structure

This document is the main onboarding guide for future Codex sessions and developers working on `first-rpc`. Its purpose is to answer three questions quickly:

- where the protocol lives
- where the runtime entry points live
- where the shared logic and likely extension points live

## 1. Project Shape

`first-rpc` currently maintains two implementations of the same remote-ops contract:

- C++20 + source-built gRPC C++
- Rust + `tonic/prost`

Both implementations reuse the same protobuf contract and expose aligned client/server capabilities for remote inspection, controlled file upload, and bounded command execution.

Current user-facing actions:

- `health_check`
- `list_dir`
- `read_file`
- `tail_file`
- `grep_file`
- `upload_file`
- `exec`

## 2. Repository Layout

Important top-level directories:

- `proto/`
  - protobuf and RPC contract definitions
- `include/first_rpc/`
  - C++ public headers, split by `client/common/server`
- `src/`
  - C++ implementation
- `rust/`
  - Rust implementation
- `doc/`
  - project documentation and onboarding notes
- `third_party/`
  - local gRPC source, build directories, and install prefixes
- `cmake-build-*`
  - C++ build outputs
- `build/`
  - runtime test artifacts and local scratch files

In normal feature work, you usually do not need to inspect `third_party/grpc-src` unless the task is specifically about the gRPC build itself.

## 3. Protocol Layer

The protocol definition lives in [first_rpc.proto](../proto/first_rpc.proto).

This is the most stable center of the project and should usually be the first file you read. It defines:

- request messages
  - `HealthCheckRequest`
  - `PathRequest`
  - `ReadFileRequest`
  - `TailFileRequest`
  - `GrepFileRequest`
  - upload-related request messages
  - `ExecRequest`
- common reply model
  - `ActionReply`
- service interface
  - `RemoteOps`

`ActionReply` is the shared result model used by both implementations. Its core fields are:

- `ok`
- `action`
- `summary`
- `data`
- `error`
- `duration_ms`

When adding or changing RPC capabilities, the first step is almost always to update this file.

## 4. C++ Structure

### 4.1 Build Entry

The C++ build entry is [CMakeLists.txt](../CMakeLists.txt).

Its main responsibilities are:

- require a locally installed gRPC prefix through `FIRST_RPC_GRPC_ROOT`
- generate protobuf and gRPC C++ bindings with `protoc` and `grpc_cpp_plugin`
- build the shared library `first_rpc_common`
- build the executables
  - `first_rpc_server`
  - `first_rpc_client`

### 4.2 Header Layout

Headers are split under `include/first_rpc/`:

- `include/first_rpc/common/`
  - shared file operations, formatting, system helpers
- `include/first_rpc/server/`
  - server-side gRPC implementation declarations
- `include/first_rpc/client/`
  - client-side RPC wrapper declarations

Key headers:

- [service_impl.hpp](../include/first_rpc/server/service_impl.hpp)
  - C++ `RemoteOps` service declaration
- [rpc_client.hpp](../include/first_rpc/client/rpc_client.hpp)
  - C++ RPC client wrapper
- [file_ops.hpp](../include/first_rpc/common/file_ops.hpp)
  - shared file-operation declarations
- [format.hpp](../include/first_rpc/common/format.hpp)
  - `ActionReply` text formatting

### 4.3 Server Flow

Server entry point:

- [src/server/main.cpp](../src/server/main.cpp)

This file handles:

- parsing `--host --port --root --token`
- creating `RemoteOpsServiceImpl`
- starting the gRPC server

Main RPC handling logic:

- [src/server/service_impl.cpp](../src/server/service_impl.cpp)

When reading that file, focus on:

- the common `Handle(...)` wrapper
  - token validation
  - timing
  - `ActionReply` population
- how each RPC delegates to shared file helpers, upload-session state, or process-execution helpers

### 4.4 Shared C++ Logic

Shared file and system logic lives in:

- [src/common/file_ops.cpp](../src/common/file_ops.cpp)
- [src/common/exec_utils.cpp](../src/common/exec_utils.cpp)
- [src/common/format.cpp](../src/common/format.cpp)
- [src/common/system_utils.cpp](../src/common/system_utils.cpp)

[src/common/file_ops.cpp](../src/common/file_ops.cpp) is the most important shared file to inspect first because it defines the read-side safety boundary:

- `normalize_under_root`
  - constrains requested paths under the configured server root
- `list_directory`
- `read_file_text`
- `tail_file_text`
- `grep_file_text`

Upload session allocation, chunk writing, and commit/abort behavior currently live in the service implementation layer rather than `common/file_ops.cpp`.

[src/common/exec_utils.cpp](../src/common/exec_utils.cpp) is the shared process-execution boundary for the C++ implementation. Inspect it first when `exec` behaves differently on Windows versus Linux/macOS.
The current default timeout is 30 seconds, and timeout handling returns `timed_out=true` with exit code `124`.

### 4.5 C++ Client Flow

Client entry point:

- [src/client/main.cpp](../src/client/main.cpp)

This file handles:

- argument parsing
- request assembly
- dispatch by action
- client-side upload orchestration for `upload_file`
- final `ActionReply` formatting to stdout

RPC calls are wrapped in:

- [src/client/rpc_client.cpp](../src/client/rpc_client.cpp)

Formatted output is produced by:

- [src/common/format.cpp](../src/common/format.cpp)

If a user reports incorrect CLI behavior or missing argument support, start with the client entry and wrapper layers.

## 5. Rust Structure

The Rust implementation is a separate Cargo project rooted at [rust/Cargo.toml](../rust/Cargo.toml).

### 5.1 Generation and Module Entry

- [rust/build.rs](../rust/build.rs)
  - generates Rust protobuf/gRPC bindings from the shared proto
- [rust/src/lib.rs](../rust/src/lib.rs)
  - module aggregation entry

`lib.rs` currently exposes:

- `cli`
- `generated`
- `ops`

### 5.2 Rust Server and Client Entry Points

Rust server entry:

- [rust/src/bin/first_rpc_server_rust.rs](../rust/src/bin/first_rpc_server_rust.rs)

Rust client entry:

- [rust/src/bin/first_rpc_client_rust.rs](../rust/src/bin/first_rpc_client_rust.rs)

These files correspond to the C++ `main.cpp` files: they parse arguments and wire process entry points, but most business logic lives elsewhere.

### 5.3 Main Rust Logic

Most Rust-side logic is concentrated in:

- [rust/src/ops.rs](../rust/src/ops.rs)

This file currently holds:

- server state `RemoteOpsState`
- token validation and reply wrapping
- root-constrained path resolution
- file RPC implementations
- upload session management and upload RPC implementations
- command execution and timeout handling for `exec`
- Rust client helper functions for each RPC

If you want a quick understanding of the Rust implementation boundary, this is the single most useful file to read.

Supporting CLI logic lives in:

- [rust/src/cli.rs](../rust/src/cli.rs)

That file mainly handles:

- argument helper functions
- `ActionReply` text formatting

## 6. C++ / Rust Mapping

The two implementations line up roughly like this:

- protocol
  - both use [first_rpc.proto](../proto/first_rpc.proto)
- server entry
  - C++: [src/server/main.cpp](../src/server/main.cpp)
  - Rust: [rust/src/bin/first_rpc_server_rust.rs](../rust/src/bin/first_rpc_server_rust.rs)
- server core logic
  - C++: [src/server/service_impl.cpp](../src/server/service_impl.cpp)
  - Rust: [rust/src/ops.rs](../rust/src/ops.rs)
- shared file operations
  - C++: [src/common/file_ops.cpp](../src/common/file_ops.cpp)
  - Rust: [rust/src/ops.rs](../rust/src/ops.rs)
- client entry
  - C++: [src/client/main.cpp](../src/client/main.cpp)
  - Rust: [rust/src/bin/first_rpc_client_rust.rs](../rust/src/bin/first_rpc_client_rust.rs)
- reply formatting
  - C++: [src/common/format.cpp](../src/common/format.cpp)
  - Rust: [rust/src/cli.rs](../rust/src/cli.rs)

When extending the RPC surface, keep both implementations aligned unless there is a strong reason not to.

## 7. Script Layout

### 7.1 C++ Build Scripts

- [deps.ps1](../deps.ps1)
- [deps.sh](../deps.sh)
- [build.ps1](../build.ps1)
- [build.sh](../build.sh)

Responsibilities:

- `deps.*`
  - fetch and install gRPC into the local repository prefix
- `build.*`
  - configure and build the C++ project

### 7.2 Rust Build Scripts

- [rust/build.ps1](../rust/build.ps1)
- [rust/build.sh](../rust/build.sh)

Responsibilities:

- invoke `cargo build`

### 7.3 Local Validation Scripts

- C++
  - [smoke_test.ps1](../smoke_test.ps1)
  - [smoke_test.sh](../smoke_test.sh)
- Rust
- [rust/smoke_test.ps1](../rust/smoke_test.ps1)
- [rust/smoke_test.sh](../rust/smoke_test.sh)

These scripts:

- start a local server
- prepare sample files
- validate the supported RPC actions end to end

### 7.4 Linux Server Management Script

- [run_server.sh](../run_server.sh)

Responsibilities:

- start / stop / restart / inspect a background server process
- support both `cpp` and `rust` implementations
- manage pid files and stdout/stderr logs

If the server should run persistently on Linux, this is usually the first script to inspect.

### 7.5 Binary Installers

- [install.ps1](../install.ps1)
- [install.sh](../install.sh)

Responsibilities:

- copy built client/server executables into a user-facing install directory
- on Windows, install into `%LOCALAPPDATA%\first-rpc\bin` and update user PATH
- on Linux, install into `/usr/local/bin` by default

Use these scripts when the binaries already exist and you mainly want a convenient command-line entry point.

### 7.6 Linux systemd Packaging

- [install_systemd_service.sh](../install_systemd_service.sh)
- [uninstall_systemd_service.sh](../uninstall_systemd_service.sh)
- [systemd/first-rpc.service.template](../systemd/first-rpc.service.template)
- [systemd/first-rpc.env.example](../systemd/first-rpc.env.example)

Responsibilities:

- generate a concrete systemd unit bound to the current repository checkout
- generate an environment file for runtime settings such as `IMPLEMENTATION`, `PORT`, and `ROOT_DIR`
- require an explicit service `User/Group` during installation so the service does not accidentally run as `root`
- reload systemd and optionally enable/start the service
- stop/disable/remove the systemd service when uninstalling

If the task is about long-running Linux deployment rather than ad-hoc foreground execution, inspect these files right after `run_server.sh`.

## 8. Recommended Reading Order

### Scenario 1: Understand the whole project quickly

Recommended order:

1. [first_rpc.proto](../proto/first_rpc.proto)
2. [CMakeLists.txt](../CMakeLists.txt)
3. [src/server/service_impl.cpp](../src/server/service_impl.cpp)
4. [src/common/file_ops.cpp](../src/common/file_ops.cpp)
5. [rust/src/ops.rs](../rust/src/ops.rs)

### Scenario 2: Add a new RPC action

Recommended order:

1. update [first_rpc.proto](../proto/first_rpc.proto)
2. update C++ server and client dispatch
3. update Rust server and client dispatch
4. update smoke tests
5. update README and docs

### Scenario 3: Debug a failing remote action

Recommended order:

1. inspect client argument assembly
2. inspect token validation on the server
3. inspect root path confinement behavior
4. inspect file-operation or upload-session edge cases
5. reproduce with the smoke tests if possible

## 9. Important Context Facts

- This project started as a controlled remote inspection and file-transfer tool, and now also includes an explicit `exec` RPC for trusted environments.
- Path access is constrained by `--root`.
- `exec` can run shell commands. Its `working_dir` is constrained by `--root`, but the command itself is not sandboxed beyond the server process permissions.
- An empty token means no auth; production usage should normally provide a token.
- The C++ build depends on a locally installed gRPC prefix and does not use Conan.
- The Rust build uses Cargo-native dependencies but still shares the same protocol contract.
- For remote Linux investigation, prefer this RPC toolchain over unstable SSH whenever the task fits the current RPC surface.
