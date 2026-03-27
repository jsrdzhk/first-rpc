#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

#include <grpcpp/grpcpp.h>

#include "first_rpc/server/service_impl.hpp"

namespace {

std::string arg_value(int argc, char** argv, const std::string& name, const std::string& fallback) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::string(argv[i]) == name) {
            return argv[i + 1];
        }
    }
    return fallback;
}

void print_usage() {
    std::cout << "Usage: first_rpc_server [--host 127.0.0.1] [--port 18777] [--root .] [--token token]\n";
}

}  // namespace

int main(int argc, char** argv) {
    try {
        for (int i = 1; i < argc; ++i) {
            if (std::string(argv[i]) == "--help") {
                print_usage();
                return 0;
            }
        }

        const auto host = arg_value(argc, argv, "--host", "127.0.0.1");
        const auto port = arg_value(argc, argv, "--port", "18777");
        const auto root = std::filesystem::path(arg_value(argc, argv, "--root", "."));
        const auto token = arg_value(argc, argv, "--token", "");
        const std::string address = host + ":" + port;

        first_rpc::RemoteOpsServiceImpl service(root, token);

        grpc::ServerBuilder builder;
        builder.AddListeningPort(address, grpc::InsecureServerCredentials());
        builder.RegisterService(&service);

        std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
        if (!server) {
            throw std::runtime_error("Failed to start gRPC server");
        }

        std::cout << "first-rpc gRPC server listening on " << address
                  << " root=" << std::filesystem::weakly_canonical(root).generic_string()
                  << '\n';
        server->Wait();
        return 0;
    } catch (const std::exception& ex) {
        std::cerr << "server failed: " << ex.what() << '\n';
        return 1;
    }
}
