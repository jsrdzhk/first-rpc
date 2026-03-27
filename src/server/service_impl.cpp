#include "first_rpc/server/service_impl.hpp"

#include <chrono>
#include <cstdint>
#include <stdexcept>
#include <utility>

#include "first_rpc/common/file_ops.hpp"
#include "first_rpc/common/system_utils.hpp"

namespace first_rpc {

RemoteOpsServiceImpl::RemoteOpsServiceImpl(std::filesystem::path root, std::string token)
    : root_(std::move(root)), token_(std::move(token)) {}

template <typename Func>
grpc::Status RemoteOpsServiceImpl::Handle(const std::string& action, const std::string& token,
                                          rpc::ActionReply* reply, Func&& func) {
    const auto started = std::chrono::steady_clock::now();
    reply->set_action(action);

    try {
        if (!token_.empty() && token != token_) {
            throw std::runtime_error("Unauthorized");
        }
        func();
        reply->set_ok(true);
        if (reply->summary().empty()) {
            reply->set_summary("request succeeded");
        }
    } catch (const std::exception& ex) {
        reply->set_ok(false);
        reply->set_summary("request failed");
        reply->set_error(ex.what());
    }

    reply->set_duration_ms(static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started
        ).count()
    ));
    return grpc::Status::OK;
}

grpc::Status RemoteOpsServiceImpl::HealthCheck(grpc::ServerContext*, const rpc::HealthCheckRequest* request,
                                               rpc::ActionReply* reply) {
    return Handle("health_check", request->token(), reply, [&] {
        reply->set_summary("server is healthy");
        (*reply->mutable_data())["host"] = hostname();
        (*reply->mutable_data())["platform"] = platform_name();
        (*reply->mutable_data())["time_utc"] = now_iso8601_utc();
        (*reply->mutable_data())["root"] = std::filesystem::weakly_canonical(root_).generic_string();
    });
}

grpc::Status RemoteOpsServiceImpl::ListDir(grpc::ServerContext*, const rpc::PathRequest* request,
                                           rpc::ActionReply* reply) {
    return Handle("list_dir", request->token(), reply, [&] {
        reply->set_summary("directory listed");
        (*reply->mutable_data())["items"] = list_directory(root_, request->path());
    });
}

grpc::Status RemoteOpsServiceImpl::ReadFile(grpc::ServerContext*, const rpc::ReadFileRequest* request,
                                            rpc::ActionReply* reply) {
    return Handle("read_file", request->token(), reply, [&] {
        reply->set_summary("file read");
        (*reply->mutable_data())["content"] = read_file_text(root_, request->path(), static_cast<std::size_t>(request->max_bytes()));
    });
}

grpc::Status RemoteOpsServiceImpl::TailFile(grpc::ServerContext*, const rpc::TailFileRequest* request,
                                            rpc::ActionReply* reply) {
    return Handle("tail_file", request->token(), reply, [&] {
        reply->set_summary("file tailed");
        (*reply->mutable_data())["content"] = tail_file_text(
            root_,
            request->path(),
            static_cast<std::size_t>(request->lines()),
            static_cast<std::size_t>(request->max_bytes())
        );
    });
}

grpc::Status RemoteOpsServiceImpl::GrepFile(grpc::ServerContext*, const rpc::GrepFileRequest* request,
                                            rpc::ActionReply* reply) {
    return Handle("grep_file", request->token(), reply, [&] {
        reply->set_summary("file searched");
        (*reply->mutable_data())["matches"] = grep_file_text(
            root_,
            request->path(),
            request->needle(),
            static_cast<std::size_t>(request->max_matches()),
            static_cast<std::size_t>(request->max_line_length())
        );
    });
}

}  // namespace first_rpc
