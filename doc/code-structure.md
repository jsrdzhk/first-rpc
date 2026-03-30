# first-rpc Code Structure

这份文档面向后续进入仓库排查或扩展 `first-rpc` 的 Codex / 开发者，目标是快速建立“协议在哪、入口在哪、公共逻辑在哪、先看什么”的代码上下文。

## 1. 项目目标

`first-rpc` 是一个跨平台远程排查工具仓库，目前同时维护两套实现：

- C++20 + 官方 gRPC C++ 源码构建版
- Rust + `tonic/prost` 版

两套实现复用同一份 protobuf 协议，暴露尽量一致的 server/client 能力，当前聚焦只读排查动作：

- `health_check`
- `list_dir`
- `read_file`
- `tail_file`
- `grep_file`

## 2. 目录总览

仓库的核心目录如下：

- `proto/`
  - RPC 协议定义，只维护一份源协议
- `include/first_rpc/`
  - C++ 头文件，按 `client/common/server` 分层
- `src/`
  - C++ 源码实现
- `rust/`
  - Rust 版完整工程
- `doc/`
  - 项目文档与代码结构说明
- `third_party/`
  - 本地安装的 gRPC 源码、构建目录、安装前缀
- `cmake-build-*`
  - C++ 主工程构建输出
- `build/`
  - 运行时测试产物、临时文件

理解代码时，通常不需要深入 `third_party/grpc-src`，除非是在排查 gRPC 本身的构建问题。

## 3. 协议层

协议定义在 [first_rpc.proto](../proto/first_rpc.proto)。

这是整个项目最稳定的中心点，建议优先阅读。它定义了：

- 请求消息
  - `HealthCheckRequest`
  - `PathRequest`
  - `ReadFileRequest`
  - `TailFileRequest`
  - `GrepFileRequest`
- 统一返回
  - `ActionReply`
- 服务接口
  - `RemoteOps`

`ActionReply` 是两套实现都围绕的统一结果模型，核心字段是：

- `ok`
- `action`
- `summary`
- `data`
- `error`
- `duration_ms`

后续如果扩展 RPC，通常第一步就是修改这份 proto。

## 4. C++ 代码结构

### 4.1 构建入口

C++ 主工程入口在 [CMakeLists.txt](../CMakeLists.txt)。

这里主要做几件事：

- 要求使用本地安装的 gRPC 前缀 `FIRST_RPC_GRPC_ROOT`
- 通过 `protoc + grpc_cpp_plugin` 生成 C++ 协议代码
- 构建共享库 `first_rpc_common`
- 构建可执行文件
  - `first_rpc_server`
  - `first_rpc_client`

### 4.2 头文件分层

头文件在 `include/first_rpc/` 下分三层：

- `include/first_rpc/common/`
  - 公共文件操作、格式化、系统信息
- `include/first_rpc/server/`
  - 服务端 gRPC 实现声明
- `include/first_rpc/client/`
  - 客户端封装声明

关键头文件：

- [service_impl.hpp](../include/first_rpc/server/service_impl.hpp)
  - C++ 服务端 `RemoteOps` 实现声明
- [rpc_client.hpp](../include/first_rpc/client/rpc_client.hpp)
  - C++ 客户端调用封装
- [file_ops.hpp](../include/first_rpc/common/file_ops.hpp)
  - 文件类操作函数声明
- [format.hpp](../include/first_rpc/common/format.hpp)
  - `ActionReply` 文本格式化

### 4.3 服务端链路

服务端入口：

- [main.cpp](../src/server/main.cpp)

这里负责：

- 解析命令行参数 `--host --port --root --token`
- 构造 `RemoteOpsServiceImpl`
- 启动 gRPC server

真正的 RPC 处理在：

- [service_impl.cpp](../src/server/service_impl.cpp)

阅读这个文件时重点看：

- 统一 `Handle(...)` 包装
  - token 校验
  - 执行耗时统计
  - `ActionReply` 填充
- 每个 RPC 如何把请求路由到公共文件操作函数

### 4.4 公共能力层

公共文件/系统逻辑主要在：

- [file_ops.cpp](../src/common/file_ops.cpp)
- [format.cpp](../src/common/format.cpp)
- [system_utils.cpp](../src/common/system_utils.cpp)

其中最值得先看的文件是 [file_ops.cpp](../src/common/file_ops.cpp)，因为它直接决定了远程排查能力边界：

- `normalize_under_root`
  - 负责把请求路径限制在配置根目录下
- `list_directory`
- `read_file_text`
- `tail_file_text`
- `grep_file_text`

如果后续要新增“按 traceId 搜索日志”“读取多个日志目录”“增加只读系统查询”之类能力，通常会从这里或其同层模块开始扩展。

### 4.5 客户端链路

客户端入口：

- [main.cpp](../src/client/main.cpp)

这里负责：

- 解析命令行参数
- 组装 `RequestArgs`
- 根据 action 分发到 `RpcClient`
- 把 `ActionReply` 格式化打印到 stdout

实际 RPC 调用封装在：

- [rpc_client.cpp](../src/client/rpc_client.cpp)

文本输出格式在：

- [format.cpp](../src/common/format.cpp)

所以如果用户反馈“CLI 打印格式不对”或“参数解析不支持某个动作”，先看客户端这两层。

## 5. Rust 代码结构

Rust 版是一个独立工程，根目录在 [Cargo.toml](../rust/Cargo.toml)。

### 5.1 生成与模块入口

- [build.rs](../rust/build.rs)
  - 根据同一份 proto 生成 Rust gRPC 代码
- [lib.rs](../rust/src/lib.rs)
  - 模块汇总入口

`lib.rs` 当前暴露：

- `cli`
- `generated`
- `ops`

### 5.2 服务端与客户端入口

Rust server 入口：

- [first_rpc_server_rust.rs](../rust/src/bin/first_rpc_server_rust.rs)

Rust client 入口：

- [first_rpc_client_rust.rs](../rust/src/bin/first_rpc_client_rust.rs)

这两个文件和 C++ 的 `main.cpp` 定位类似，负责参数解析与进程入口，不是业务逻辑主战场。

### 5.3 主要逻辑层

Rust 版核心逻辑集中在：

- [ops.rs](../rust/src/ops.rs)

这个文件同时承载：

- 服务端状态 `RemoteOpsState`
- token 校验和统一回复包装
- 文件路径解析与 root 越界保护
- 五个 RPC 的具体实现
- Rust client 侧的 RPC 调用辅助函数

如果只想快速理解 Rust 版能力边界，看这一份文件就够了。

辅助 CLI 逻辑在：

- [cli.rs](../rust/src/cli.rs)

这里主要负责：

- 参数取值工具
- `ActionReply` 文本格式化

## 6. C++ 与 Rust 的对应关系

两套实现大致可以这样对照：

- 协议
  - C++ / Rust 都来自 [first_rpc.proto](../proto/first_rpc.proto)
- 服务端入口
  - C++: [src/server/main.cpp](../src/server/main.cpp)
  - Rust: [rust/src/bin/first_rpc_server_rust.rs](../rust/src/bin/first_rpc_server_rust.rs)
- 服务端核心逻辑
  - C++: [src/server/service_impl.cpp](../src/server/service_impl.cpp)
  - Rust: [rust/src/ops.rs](../rust/src/ops.rs)
- 文件操作能力
  - C++: [src/common/file_ops.cpp](../src/common/file_ops.cpp)
  - Rust: [rust/src/ops.rs](../rust/src/ops.rs)
- 客户端入口
  - C++: [src/client/main.cpp](../src/client/main.cpp)
  - Rust: [rust/src/bin/first_rpc_client_rust.rs](../rust/src/bin/first_rpc_client_rust.rs)
- 回复格式化
  - C++: [src/common/format.cpp](../src/common/format.cpp)
  - Rust: [rust/src/cli.rs](../rust/src/cli.rs)

如果后续新增 RPC，最好两套实现一起保持字段和命令行行为一致。

## 7. 脚本结构

### 7.1 C++ 构建脚本

- [deps.ps1](../deps.ps1)
- [deps.sh](../deps.sh)
- [build.ps1](../build.ps1)
- [build.sh](../build.sh)

职责分工：

- `deps.*`
  - 获取并安装 gRPC 到仓库本地前缀
- `build.*`
  - 配置并构建主工程

### 7.2 Rust 构建脚本

- [rust_build.ps1](../rust/rust_build.ps1)
- [rust_build.sh](../rust/rust_build.sh)

职责：

- 直接调用 `cargo build`

### 7.3 本地验证脚本

- C++
  - [smoke_test.ps1](../smoke_test.ps1)
  - [smoke_test.sh](../smoke_test.sh)
- Rust
  - [smoke_test_rust.ps1](../rust/smoke_test_rust.ps1)
  - [smoke_test_rust.sh](../rust/smoke_test_rust.sh)

这些脚本都会：

- 启动本地 server
- 构造测试文件
- 调 client 验证五个基础 RPC

### 7.4 Linux 服务器运行脚本

- [run_server.sh](../run_server.sh)

职责：

- 后台启动 / 停止 / 重启 / 查询 RPC server
- 支持 `cpp` 和 `rust` 两套实现
- 管理 pid 文件和 stdout/stderr 日志

如果以后服务器上要常驻 first-rpc，通常优先从这份脚本切入。

## 8. 下次进入仓库时的推荐阅读顺序

### 场景 1：想快速理解整个项目

建议顺序：

1. [first_rpc.proto](../proto/first_rpc.proto)
2. [CMakeLists.txt](../CMakeLists.txt)
3. [src/server/service_impl.cpp](../src/server/service_impl.cpp)
4. [src/common/file_ops.cpp](../src/common/file_ops.cpp)
5. [rust/src/ops.rs](../rust/src/ops.rs)

### 场景 2：想扩一个新的 RPC 动作

建议顺序：

1. 修改 [first_rpc.proto](../proto/first_rpc.proto)
2. 修改 C++ server/client 分发
3. 修改 Rust server/client 分发
4. 更新 smoke test
5. 更新 README / 文档

### 场景 3：想排查为什么某个远程动作失败

建议顺序：

1. 看 client 入口是否正确组装参数
2. 看 server 是否通过 token 校验
3. 看 root 路径是否越界保护触发
4. 看具体文件操作函数是否命中边界条件
5. 看 smoke test 能否复现

## 9. 代码上下文里的几个关键事实

- 当前项目是“受控只读排查工具”，不是通用远程 shell。
- 路径访问默认受 `--root` 约束。
- token 为空时等价于不鉴权；生产环境建议总是设置 token。
- C++ 版依赖本地安装的 gRPC 前缀，不走 Conan。
- Rust 版依赖 Cargo 生态，构建链更轻，但协议仍与 C++ 共用。
- 后续如果排查 Linux 服务器问题，应优先通过这个仓库产出的 RPC 工具链完成，而不是回退到不稳定 SSH。
