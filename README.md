# first-rpc

`first-rpc` is a standalone C++ project for a cross-platform gRPC client/server used for remote operations and log troubleshooting.

## Goals

- Support Windows, Linux, and macOS for both client and server.
- Avoid direct dependence on unstable SSH for routine log investigation.
- Keep the first version small, auditable, and easy to deploy.
- Use C++23 with CMake 4.3.0.

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

## Build

This project uses Conan to manage dependencies.

### Windows

```powershell
.\build.ps1
```

如果需要显式指定构建类型：

```powershell
.\build.ps1 -BuildType Debug
```

如果只是依赖已经装好，想跳过 `conan install`：

```powershell
.\build.ps1 -SkipConanInstall
```

### Linux / macOS

```bash
export HTTP_PROXY=http://127.0.0.1:7897 HTTPS_PROXY=http://127.0.0.1:7897
conan profile detect --force
conan install . --output-folder=build --build=missing -s build_type=Release
cmake --preset conan-release
cmake --build --preset conan-release -j
```

## Run

Start a server:

```bash
first_rpc_server --host 127.0.0.1 --port 18777 --root /var/log --token demo-token
```

Health check:

```bash
first_rpc_client --host 127.0.0.1 --port 18777 --token demo-token health_check
```

Tail a file:

```bash
first_rpc_client --host 127.0.0.1 --port 18777 --token demo-token tail_file --path app.log --lines 50
```

## CentOS 7 + GCC 15 Notes

Your target combination is feasible with some caveats:

- CentOS 7 ships with glibc 2.17, which is old but still workable.
- If GCC 15 is installed locally on that CentOS 7 host, C++23 compilation is realistic for this project.
- You should make sure Conan uses that newer GCC 15 profile instead of the system `g++ 4.8.5`.
- The resulting binary will depend on that host's runtime combination, especially `libstdc++`.
- Running the binary on the same machine where it was built is the safest path.
- Reusing the binary across different Linux machines may require bundling or statically linking `libstdc++` if runtime compatibility becomes an issue.

Because your CentOS 7 environment already has Linuxbrew-managed gRPC available, using gRPC directly is a better long-term fit than maintaining a custom RPC protocol.

## Next Steps

- Add config file support for server allowlists
- Add structured module/log discovery
- Add stronger auth and audit logging
- Add service packaging for Linux
