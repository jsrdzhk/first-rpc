#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "first_rpc/client/request_args.hpp"
#include "first_rpc/client/rpc_client.hpp"
#include "first_rpc/common/format.hpp"

namespace {

constexpr std::uint64_t kDefaultChunkSize = 1024ULL * 1024ULL;

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

bool bool_arg(int argc, char** argv, const std::string& name, bool fallback) {
    const auto value = arg_value(argc, argv, name, fallback ? "true" : "false");
    return !(value == "false" || value == "0" || value == "no");
}

void print_usage() {
    std::cout
        << "Usage:\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token health_check\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token list_dir --path .\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token read_file --path app.log\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token tail_file --path app.log --lines 50\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token grep_file --path app.log --needle ERROR\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token upload_file --local app.jar --path deploy/app.jar\n"
        << "  first_rpc_client --host 127.0.0.1 --port 18777 --token token exec --command \"pwd\" --working-dir .\n";
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
            arg == "tail_file" || arg == "grep_file" || arg == "upload_file" || arg == "exec") {
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

    if (request.action == "upload_file") {
        request.params["local"] = arg_value(argc, argv, "--local", "");
        request.params["chunk_size"] = arg_value(argc, argv, "--chunk-size", std::to_string(kDefaultChunkSize));
        request.params["overwrite"] = bool_arg(argc, argv, "--overwrite", true) ? "true" : "false";
        return request;
    }

    if (request.action == "exec") {
        request.params["command"] = arg_value(argc, argv, "--command", "");
        request.params["working_dir"] = arg_value(argc, argv, "--working-dir", ".");
        request.params["timeout_ms"] = arg_value(argc, argv, "--timeout-ms", "30000");
        request.params["max_output_bytes"] = arg_value(argc, argv, "--max-output-bytes", "65536");
        return request;
    }

    throw std::runtime_error("Unsupported action: " + request.action);
}

first_rpc::rpc::ActionReply upload_file(const first_rpc::RpcClient& client, const first_rpc::RequestArgs& request) {
    const auto local_path = std::filesystem::path(request.params.at("local"));
    if (request.params.at("path").empty()) {
        throw std::runtime_error("Remote --path is required for upload_file");
    }
    if (request.params.at("local").empty()) {
        throw std::runtime_error("Local --local path is required for upload_file");
    }
    if (!std::filesystem::exists(local_path)) {
        throw std::runtime_error("Local file does not exist");
    }
    if (!std::filesystem::is_regular_file(local_path)) {
        throw std::runtime_error("Local path is not a regular file");
    }

    const auto expected_size = std::filesystem::file_size(local_path);
    const auto overwrite = request.params.at("overwrite") == "true";
    const auto chunk_size = static_cast<std::size_t>(std::stoull(request.params.at("chunk_size")));
    if (chunk_size == 0) {
        throw std::runtime_error("Chunk size must be greater than zero");
    }

    auto init_reply = client.UploadInit(request.token, request.params.at("path"), overwrite, expected_size);
    if (!init_reply.ok()) {
        return init_reply;
    }

    const auto upload_id_it = init_reply.data().find("upload_id");
    if (upload_id_it == init_reply.data().end() || upload_id_it->second.empty()) {
        throw std::runtime_error("Upload init reply did not contain upload_id");
    }
    const auto upload_id = upload_id_it->second;

    std::ifstream input(local_path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("Failed to open local file");
    }

    std::vector<char> buffer(chunk_size);
    std::uint64_t offset = 0;

    try {
        while (input) {
            input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
            const auto read_count = input.gcount();
            if (read_count <= 0) {
                break;
            }

            auto chunk_reply = client.UploadChunk(
                request.token,
                upload_id,
                offset,
                std::string(buffer.data(), static_cast<std::size_t>(read_count))
            );
            if (!chunk_reply.ok()) {
                client.UploadAbort(request.token, upload_id);
                return chunk_reply;
            }
            offset += static_cast<std::uint64_t>(read_count);
        }

        return client.UploadCommit(request.token, upload_id);
    } catch (...) {
        client.UploadAbort(request.token, upload_id);
        throw;
    }
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
        } else if (request.action == "upload_file") {
            response = upload_file(client, request);
        } else if (request.action == "exec") {
            response = client.Exec(request.token, request.params.at("command"), request.params.at("working_dir"),
                                   static_cast<std::uint64_t>(std::stoull(request.params.at("timeout_ms"))),
                                   static_cast<std::uint64_t>(std::stoull(request.params.at("max_output_bytes"))));
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
