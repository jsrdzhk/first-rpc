#include <chrono>
#include <filesystem>

#include <catch2/catch_test_macros.hpp>
#include <grpcpp/server_context.h>

#include "first_rpc/server/service_impl.hpp"

namespace fs = std::filesystem;

namespace {

struct TempDir {
    fs::path path;

    TempDir()
        : path(fs::temp_directory_path() / ("first-rpc-exec-" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()))) {
        fs::create_directories(path);
    }

    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

std::string success_command() {
#ifdef _WIN32
    return "echo exec smoke";
#else
    return "printf 'exec smoke\\n'";
#endif
}

std::string timeout_command() {
#ifdef _WIN32
    return "ping 127.0.0.1 -n 6 >nul";
#else
    return "sleep 5";
#endif
}

}  // namespace

TEST_CASE("exec RPC captures stdout and exit code", "[exec]") {
    TempDir temp_dir;
    first_rpc::RemoteOpsServiceImpl service(temp_dir.path, "");
    grpc::ServerContext context;

    first_rpc::rpc::ExecRequest request;
    request.set_command(success_command());
    request.set_working_dir(".");
    request.set_timeout_ms(2'000);
    request.set_max_output_bytes(4'096);

    first_rpc::rpc::ActionReply reply;
    REQUIRE(service.Exec(&context, &request, &reply).ok());
    REQUIRE(reply.ok());
    REQUIRE(reply.summary() == "command completed successfully");
    REQUIRE(reply.data().at("timed_out") == "false");
    REQUIRE(reply.data().at("exit_code") == "0");
    REQUIRE(reply.data().at("stdout").find("exec smoke") != std::string::npos);
}

TEST_CASE("exec RPC times out long-running commands", "[exec]") {
    TempDir temp_dir;
    first_rpc::RemoteOpsServiceImpl service(temp_dir.path, "");
    grpc::ServerContext context;

    first_rpc::rpc::ExecRequest request;
    request.set_command(timeout_command());
    request.set_working_dir(".");
    request.set_timeout_ms(100);
    request.set_max_output_bytes(4'096);

    first_rpc::rpc::ActionReply reply;
    REQUIRE(service.Exec(&context, &request, &reply).ok());
    REQUIRE(reply.ok());
    REQUIRE(reply.summary() == "command timed out");
    REQUIRE(reply.data().at("timed_out") == "true");
}
