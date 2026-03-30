#include "first_rpc/server/service_impl.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <optional>
#include <random>
#include <stdexcept>
#include <sstream>
#include <utility>

#include "first_rpc/common/file_ops.hpp"
#include "first_rpc/common/exec_utils.hpp"
#include "first_rpc/common/system_utils.hpp"

namespace first_rpc {

namespace {

constexpr std::uint64_t kMaxUploadFileSize = 1024ULL * 1024ULL * 1024ULL;
constexpr std::size_t kDefaultChunkSize = 1024ULL * 1024ULL;
constexpr std::uint64_t kDefaultExecTimeoutMs = 30'000ULL;
constexpr std::uint64_t kDefaultExecOutputBytes = 65'536ULL;

}  // namespace

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

std::filesystem::path RemoteOpsServiceImpl::canonical_root() const {
    return std::filesystem::weakly_canonical(root_);
}

std::filesystem::path RemoteOpsServiceImpl::allocate_temp_upload_path(const std::string& upload_id) const {
    const auto temp_dir = canonical_root() / ".first-rpc-uploads";
    std::filesystem::create_directories(temp_dir);
    return temp_dir / (upload_id + ".part");
}

std::string RemoteOpsServiceImpl::generate_upload_id() {
    static thread_local std::mt19937_64 rng(std::random_device{}());
    std::ostringstream oss;
    oss << std::hex << std::chrono::steady_clock::now().time_since_epoch().count() << '-' << rng();
    return oss.str();
}

void RemoteOpsServiceImpl::replace_file(const std::filesystem::path& source, const std::filesystem::path& target,
                                        bool overwrite) {
    std::optional<std::filesystem::perms> preserved_permissions;
    if (!overwrite && std::filesystem::exists(target)) {
        throw std::runtime_error("Target file already exists");
    }

    std::filesystem::create_directories(target.parent_path());
    if (overwrite && std::filesystem::exists(target)) {
        preserved_permissions = std::filesystem::status(target).permissions();
        std::filesystem::remove(target);
    }
    std::filesystem::rename(source, target);
    if (preserved_permissions.has_value()) {
        std::filesystem::permissions(target, *preserved_permissions, std::filesystem::perm_options::replace);
    }
}

grpc::Status RemoteOpsServiceImpl::HealthCheck(grpc::ServerContext*, const rpc::HealthCheckRequest* request,
                                               rpc::ActionReply* reply) {
    return Handle("health_check", request->token(), reply, [&] {
        reply->set_summary("server is healthy");
        (*reply->mutable_data())["host"] = hostname();
        (*reply->mutable_data())["platform"] = platform_name();
        (*reply->mutable_data())["time_utc"] = now_iso8601_utc();
        (*reply->mutable_data())["root"] = canonical_root().generic_string();
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

grpc::Status RemoteOpsServiceImpl::UploadInit(grpc::ServerContext*, const rpc::UploadInitRequest* request,
                                              rpc::ActionReply* reply) {
    return Handle("upload_init", request->token(), reply, [&] {
        if (request->path().empty()) {
            throw std::runtime_error("Path must not be empty");
        }
        if (request->expected_size() > kMaxUploadFileSize) {
            throw std::runtime_error("File exceeds max upload size of 1GB");
        }

        const auto target_path = normalize_under_root(root_, request->path());
        const auto upload_id = generate_upload_id();
        const auto temp_path = allocate_temp_upload_path(upload_id);

        if (std::filesystem::exists(temp_path)) {
            std::filesystem::remove(temp_path);
        }

        {
            std::ofstream output(temp_path, std::ios::binary | std::ios::trunc);
            if (!output) {
                throw std::runtime_error("Failed to create temp upload file");
            }
        }

        std::lock_guard<std::mutex> lock(uploads_mutex_);
        uploads_[upload_id] = UploadSession{
            target_path,
            temp_path,
            request->expected_size(),
            0,
            request->overwrite()
        };

        reply->set_summary("upload session initialized");
        (*reply->mutable_data())["upload_id"] = upload_id;
        (*reply->mutable_data())["path"] = target_path.generic_string();
        (*reply->mutable_data())["chunk_size"] = std::to_string(kDefaultChunkSize);
        (*reply->mutable_data())["max_upload_size"] = std::to_string(kMaxUploadFileSize);
    });
}

grpc::Status RemoteOpsServiceImpl::UploadChunk(grpc::ServerContext*, const rpc::UploadChunkRequest* request,
                                               rpc::ActionReply* reply) {
    return Handle("upload_chunk", request->token(), reply, [&] {
        UploadSession session;
        {
            std::lock_guard<std::mutex> lock(uploads_mutex_);
            const auto it = uploads_.find(request->upload_id());
            if (it == uploads_.end()) {
                throw std::runtime_error("Upload session not found");
            }
            if (request->offset() != it->second.received_size) {
                throw std::runtime_error("Unexpected upload offset");
            }
            if (it->second.received_size + request->content().size() > it->second.expected_size) {
                throw std::runtime_error("Upload content exceeds expected file size");
            }
            session = it->second;
        }

        std::ofstream output(session.temp_path, std::ios::binary | std::ios::app);
        if (!output) {
            throw std::runtime_error("Failed to open temp upload file");
        }
        output.write(request->content().data(), static_cast<std::streamsize>(request->content().size()));
        if (!output) {
            throw std::runtime_error("Failed to append upload chunk");
        }
        output.close();

        std::lock_guard<std::mutex> lock(uploads_mutex_);
        auto& stored = uploads_.at(request->upload_id());
        stored.received_size += request->content().size();
        reply->set_summary("upload chunk stored");
        (*reply->mutable_data())["received_size"] = std::to_string(stored.received_size);
        (*reply->mutable_data())["expected_size"] = std::to_string(stored.expected_size);
    });
}

grpc::Status RemoteOpsServiceImpl::UploadCommit(grpc::ServerContext*, const rpc::UploadControlRequest* request,
                                                rpc::ActionReply* reply) {
    return Handle("upload_commit", request->token(), reply, [&] {
        UploadSession session;
        {
            std::lock_guard<std::mutex> lock(uploads_mutex_);
            const auto it = uploads_.find(request->upload_id());
            if (it == uploads_.end()) {
                throw std::runtime_error("Upload session not found");
            }
            session = it->second;
        }

        if (session.received_size != session.expected_size) {
            throw std::runtime_error("Uploaded size does not match expected size");
        }
        if (!std::filesystem::exists(session.temp_path)) {
            throw std::runtime_error("Temp upload file does not exist");
        }

        replace_file(session.temp_path, session.target_path, session.overwrite);

        {
            std::lock_guard<std::mutex> lock(uploads_mutex_);
            uploads_.erase(request->upload_id());
        }

        reply->set_summary("upload committed");
        (*reply->mutable_data())["path"] = session.target_path.generic_string();
        (*reply->mutable_data())["size"] = std::to_string(session.expected_size);
    });
}

grpc::Status RemoteOpsServiceImpl::UploadAbort(grpc::ServerContext*, const rpc::UploadControlRequest* request,
                                               rpc::ActionReply* reply) {
    return Handle("upload_abort", request->token(), reply, [&] {
        std::filesystem::path temp_path;
        {
            std::lock_guard<std::mutex> lock(uploads_mutex_);
            const auto it = uploads_.find(request->upload_id());
            if (it == uploads_.end()) {
                throw std::runtime_error("Upload session not found");
            }
            temp_path = it->second.temp_path;
            uploads_.erase(it);
        }

        if (std::filesystem::exists(temp_path)) {
            std::filesystem::remove(temp_path);
        }

        reply->set_summary("upload aborted");
    });
}

grpc::Status RemoteOpsServiceImpl::Exec(grpc::ServerContext*, const rpc::ExecRequest* request,
                                        rpc::ActionReply* reply) {
    return Handle("exec", request->token(), reply, [&] {
        auto result = execute_command(
            root_,
            request->working_dir(),
            request->command(),
            request->timeout_ms() == 0 ? kDefaultExecTimeoutMs : request->timeout_ms(),
            static_cast<std::size_t>(request->max_output_bytes() == 0
                ? kDefaultExecOutputBytes
                : request->max_output_bytes())
        );

        if (result.timed_out) {
            reply->set_summary("command timed out");
        } else if (result.exit_code == 0) {
            reply->set_summary("command completed successfully");
        } else {
            reply->set_summary("command completed with non-zero exit code");
        }

        (*reply->mutable_data())["command"] = request->command();
        (*reply->mutable_data())["working_dir"] = result.working_dir.generic_string();
        (*reply->mutable_data())["exit_code"] = std::to_string(result.exit_code);
        (*reply->mutable_data())["timed_out"] = result.timed_out ? "true" : "false";
        (*reply->mutable_data())["stdout"] = std::move(result.stdout_text);
        (*reply->mutable_data())["stderr"] = std::move(result.stderr_text);
    });
}

}  // namespace first_rpc
