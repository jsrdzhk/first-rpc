#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <mutex>
#include <string>
#include <unordered_map>

#include <grpcpp/grpcpp.h>

#include "first_rpc.grpc.pb.h"

namespace first_rpc {

class RemoteOpsServiceImpl final : public rpc::RemoteOps::Service {
public:
    RemoteOpsServiceImpl(std::filesystem::path root, std::string token);

    grpc::Status HealthCheck(grpc::ServerContext* context, const rpc::HealthCheckRequest* request,
                             rpc::ActionReply* reply) override;
    grpc::Status ListDir(grpc::ServerContext* context, const rpc::PathRequest* request,
                         rpc::ActionReply* reply) override;
    grpc::Status ReadFile(grpc::ServerContext* context, const rpc::ReadFileRequest* request,
                          rpc::ActionReply* reply) override;
    grpc::Status TailFile(grpc::ServerContext* context, const rpc::TailFileRequest* request,
                          rpc::ActionReply* reply) override;
    grpc::Status GrepFile(grpc::ServerContext* context, const rpc::GrepFileRequest* request,
                          rpc::ActionReply* reply) override;
    grpc::Status UploadInit(grpc::ServerContext* context, const rpc::UploadInitRequest* request,
                            rpc::ActionReply* reply) override;
    grpc::Status UploadChunk(grpc::ServerContext* context, const rpc::UploadChunkRequest* request,
                             rpc::ActionReply* reply) override;
    grpc::Status UploadCommit(grpc::ServerContext* context, const rpc::UploadControlRequest* request,
                              rpc::ActionReply* reply) override;
    grpc::Status UploadAbort(grpc::ServerContext* context, const rpc::UploadControlRequest* request,
                             rpc::ActionReply* reply) override;

private:
    struct UploadSession {
        std::filesystem::path target_path;
        std::filesystem::path temp_path;
        std::uint64_t expected_size = 0;
        std::uint64_t received_size = 0;
        bool overwrite = true;
    };

    template <typename Func>
    grpc::Status Handle(const std::string& action, const std::string& token, rpc::ActionReply* reply, Func&& func);
    std::filesystem::path canonical_root() const;
    std::filesystem::path allocate_temp_upload_path(const std::string& upload_id) const;
    static std::string generate_upload_id();
    static void replace_file(const std::filesystem::path& source, const std::filesystem::path& target, bool overwrite);

    std::filesystem::path root_;
    std::string token_;
    mutable std::mutex uploads_mutex_;
    std::unordered_map<std::string, UploadSession> uploads_;
};

}  // namespace first_rpc
