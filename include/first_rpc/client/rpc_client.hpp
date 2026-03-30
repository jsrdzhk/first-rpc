#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include <grpcpp/channel.h>

#include "first_rpc.grpc.pb.h"

namespace first_rpc {

class RpcClient {
public:
    RpcClient(std::string host, std::uint16_t port);

    rpc::ActionReply HealthCheck(const std::string& token) const;
    rpc::ActionReply ListDir(const std::string& token, const std::string& path) const;
    rpc::ActionReply ReadFile(const std::string& token, const std::string& path, std::uint64_t max_bytes) const;
    rpc::ActionReply TailFile(const std::string& token, const std::string& path, std::uint64_t lines, std::uint64_t max_bytes) const;
    rpc::ActionReply GrepFile(const std::string& token, const std::string& path, const std::string& needle,
                              std::uint64_t max_matches, std::uint64_t max_line_length) const;
    rpc::ActionReply UploadInit(const std::string& token, const std::string& path, bool overwrite,
                                std::uint64_t expected_size) const;
    rpc::ActionReply UploadChunk(const std::string& token, const std::string& upload_id, std::uint64_t offset,
                                 const std::string& content) const;
    rpc::ActionReply UploadCommit(const std::string& token, const std::string& upload_id) const;
    rpc::ActionReply UploadAbort(const std::string& token, const std::string& upload_id) const;
    rpc::ActionReply Exec(const std::string& token, const std::string& command, const std::string& working_dir,
                          std::uint64_t timeout_ms, std::uint64_t max_output_bytes) const;

private:
    template <typename Request, typename Method>
    rpc::ActionReply Invoke(const Request& request, Method method) const;

    std::shared_ptr<grpc::Channel> channel_;
    std::unique_ptr<rpc::RemoteOps::Stub> stub_;
};

}  // namespace first_rpc
