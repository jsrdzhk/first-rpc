#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

#include "first_rpc/client/request_args.hpp"
#include "first_rpc/client/rpc_client.hpp"
#include "first_rpc/common/format.hpp"

namespace {

std::string arg_value(int argc, char** argv, const std::string& name, const std::string& fallback) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::string(argv[i]) == name) {
            return argv[i + 1];
        }
    }
    return fallback;
}

bool has_arg(int argc, char** argv, const std::string& name) {
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == name) {
            return true;
        }
    }
    return false;
}

void print_usage() {
    std::cout
        << "Usage:\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token health_check\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token list_dir --path .\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token read_file --path app.log\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token tail_file --path app.log --lines 50\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token grep_file --path app.log --needle ERROR\n";
}

first_rpc::RequestArgs build_request(int argc, char** argv) {
    if (argc < 2) {
        throw std::runtime_error("Missing action");
    }

    first_rpc::RequestArgs request;
    request.token = arg_value(argc, argv, "--token", "");

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "health_check" || arg == "list_dir" || arg == "read_file" ||
            arg == "tail_file" || arg == "grep_file") {
            request.action = arg;
            break;
        }
    }

    if (request.action.empty()) {
        throw std::runtime_error("Missing action");
    }

    if (request.action == "health_check") {
        return request;
    }

    request.params["path"] = arg_value(argc, argv, "--path", "");

    if (request.action == "list_dir") {
        return request;
    }

    if (request.action == "read_file") {
        request.params["max_bytes"] = arg_value(argc, argv, "--max-bytes", "65536");
        return request;
    }

    if (request.action == "tail_file") {
        request.params["lines"] = arg_value(argc, argv, "--lines", "50");
        request.params["max_bytes"] = arg_value(argc, argv, "--max-bytes", "65536");
        return request;
    }

    if (request.action == "grep_file") {
        request.params["needle"] = arg_value(argc, argv, "--needle", "");
        request.params["max_matches"] = arg_value(argc, argv, "--max-matches", "100");
        request.params["max_line_length"] = arg_value(argc, argv, "--max-line-length", "4096");
        return request;
    }

    throw std::runtime_error("Unsupported action: " + request.action);
}

}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc == 1 || has_arg(argc, argv, "--help")) {
            print_usage();
            return 0;
        }

        const auto host = arg_value(argc, argv, "--host", "127.0.0.1");
        const auto port = static_cast<std::uint16_t>(std::stoi(arg_value(argc, argv, "--port", "18777")));
        const auto request = build_request(argc, argv);

        first_rpc::RpcClient client(host, port);
        first_rpc::rpc::ActionReply response;

        if (request.action == "health_check") {
            response = client.HealthCheck(request.token);
        } else if (request.action == "list_dir") {
            response = client.ListDir(request.token, request.params.at("path"));
        } else if (request.action == "read_file") {
            response = client.ReadFile(request.token, request.params.at("path"),
                                       static_cast<std::uint64_t>(std::stoull(request.params.at("max_bytes"))));
        } else if (request.action == "tail_file") {
            response = client.TailFile(request.token, request.params.at("path"),
                                       static_cast<std::uint64_t>(std::stoull(request.params.at("lines"))),
                                       static_cast<std::uint64_t>(std::stoull(request.params.at("max_bytes"))));
        } else if (request.action == "grep_file") {
            response = client.GrepFile(request.token, request.params.at("path"), request.params.at("needle"),
                                       static_cast<std::uint64_t>(std::stoull(request.params.at("max_matches"))),
                                       static_cast<std::uint64_t>(std::stoull(request.params.at("max_line_length"))));
        } else {
            throw std::runtime_error("Unsupported action: " + request.action);
        }

        std::cout << first_rpc::format_reply(response);
        return response.ok() ? 0 : 1;
    } catch (const std::exception& ex) {
        std::cerr << "client failed: " << ex.what() << '\n';
        return 1;
    }
}
