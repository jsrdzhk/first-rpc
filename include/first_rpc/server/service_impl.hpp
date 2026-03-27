#pragma once

#include <chrono>
#include <filesystem>
#include <string>

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

private:
    template <typename Func>
    grpc::Status Handle(const std::string& action, const std::string& token, rpc::ActionReply* reply, Func&& func);

    std::filesystem::path root_;
    std::string token_;
};

}  // namespace first_rpc
