#include "first_rpc/client/rpc_client.hpp"

#include <utility>

#include <grpcpp/client_context.h>
#include <grpcpp/create_channel.h>
#include <grpcpp/security/credentials.h>

namespace first_rpc {

RpcClient::RpcClient(std::string host, std::uint16_t port)
    : channel_(grpc::CreateChannel(host + ":" + std::to_string(port), grpc::InsecureChannelCredentials())),
      stub_(rpc::RemoteOps::NewStub(channel_)) {}

template <typename Request, typename Method>
rpc::ActionReply RpcClient::Invoke(const Request& request, Method method) const {
    grpc::ClientContext context;
    rpc::ActionReply reply;
    const grpc::Status status = (stub_.get()->*method)(&context, request, &reply);
    if (!status.ok()) {
        reply.set_ok(false);
        reply.set_summary("rpc call failed");
        reply.set_error(status.error_message());
    }
    return reply;
}

rpc::ActionReply RpcClient::HealthCheck(const std::string& token) const {
    rpc::HealthCheckRequest request;
    request.set_token(token);
    return Invoke(request, &rpc::RemoteOps::Stub::HealthCheck);
}

rpc::ActionReply RpcClient::ListDir(const std::string& token, const std::string& path) const {
    rpc::PathRequest request;
    request.set_token(token);
    request.set_path(path);
    return Invoke(request, &rpc::RemoteOps::Stub::ListDir);
}

rpc::ActionReply RpcClient::ReadFile(const std::string& token, const std::string& path, std::uint64_t max_bytes) const {
    rpc::ReadFileRequest request;
    request.set_token(token);
    request.set_path(path);
    request.set_max_bytes(max_bytes);
    return Invoke(request, &rpc::RemoteOps::Stub::ReadFile);
}

rpc::ActionReply RpcClient::TailFile(const std::string& token, const std::string& path,
                                     std::uint64_t lines, std::uint64_t max_bytes) const {
    rpc::TailFileRequest request;
    request.set_token(token);
    request.set_path(path);
    request.set_lines(lines);
    request.set_max_bytes(max_bytes);
    return Invoke(request, &rpc::RemoteOps::Stub::TailFile);
}

rpc::ActionReply RpcClient::GrepFile(const std::string& token, const std::string& path, const std::string& needle,
                                     std::uint64_t max_matches, std::uint64_t max_line_length) const {
    rpc::GrepFileRequest request;
    request.set_token(token);
    request.set_path(path);
    request.set_needle(needle);
    request.set_max_matches(max_matches);
    request.set_max_line_length(max_line_length);
    return Invoke(request, &rpc::RemoteOps::Stub::GrepFile);
}

rpc::ActionReply RpcClient::UploadInit(const std::string& token, const std::string& path, bool overwrite,
                                       std::uint64_t expected_size) const {
    rpc::UploadInitRequest request;
    request.set_token(token);
    request.set_path(path);
    request.set_overwrite(overwrite);
    request.set_expected_size(expected_size);
    return Invoke(request, &rpc::RemoteOps::Stub::UploadInit);
}

rpc::ActionReply RpcClient::UploadChunk(const std::string& token, const std::string& upload_id, std::uint64_t offset,
                                        const std::string& content) const {
    rpc::UploadChunkRequest request;
    request.set_token(token);
    request.set_upload_id(upload_id);
    request.set_offset(offset);
    request.set_content(content);
    return Invoke(request, &rpc::RemoteOps::Stub::UploadChunk);
}

rpc::ActionReply RpcClient::UploadCommit(const std::string& token, const std::string& upload_id) const {
    rpc::UploadControlRequest request;
    request.set_token(token);
    request.set_upload_id(upload_id);
    return Invoke(request, &rpc::RemoteOps::Stub::UploadCommit);
}

rpc::ActionReply RpcClient::UploadAbort(const std::string& token, const std::string& upload_id) const {
    rpc::UploadControlRequest request;
    request.set_token(token);
    request.set_upload_id(upload_id);
    return Invoke(request, &rpc::RemoteOps::Stub::UploadAbort);
}

rpc::ActionReply RpcClient::Exec(const std::string& token, const std::string& command,
                                 const std::string& working_dir, std::uint64_t timeout_ms,
                                 std::uint64_t max_output_bytes) const {
    rpc::ExecRequest request;
    request.set_token(token);
    request.set_command(command);
    request.set_working_dir(working_dir);
    request.set_timeout_ms(timeout_ms);
    request.set_max_output_bytes(max_output_bytes);
    return Invoke(request, &rpc::RemoteOps::Stub::Exec);
}

}  // namespace first_rpc
