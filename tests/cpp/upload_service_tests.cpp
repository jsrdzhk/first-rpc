#include <filesystem>
#include <fstream>
#include <string>
#include <chrono>

#include <catch2/catch_test_macros.hpp>
#include <grpcpp/server_context.h>

#include "first_rpc/server/service_impl.hpp"

namespace fs = std::filesystem;

namespace {

struct TempDir {
    fs::path path;

    TempDir()
        : path(fs::temp_directory_path() / ("first-rpc-upload-" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()))) {
        fs::create_directories(path);
    }

    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

std::string file_text(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
}

}  // namespace

TEST_CASE("upload RPCs store and overwrite files", "[upload]") {
    TempDir temp_dir;
    first_rpc::RemoteOpsServiceImpl service(temp_dir.path, "");
    grpc::ServerContext context;

    first_rpc::rpc::UploadInitRequest init_request;
    init_request.set_path("uploads/demo.txt");
    init_request.set_expected_size(5);
    init_request.set_overwrite(true);

    first_rpc::rpc::ActionReply init_reply;
    REQUIRE(service.UploadInit(&context, &init_request, &init_reply).ok());
    REQUIRE(init_reply.ok());

    const auto upload_id = init_reply.data().at("upload_id");

    first_rpc::rpc::UploadChunkRequest chunk_request;
    chunk_request.set_upload_id(upload_id);
    chunk_request.set_offset(0);
    chunk_request.set_content("hello");

    first_rpc::rpc::ActionReply chunk_reply;
    REQUIRE(service.UploadChunk(&context, &chunk_request, &chunk_reply).ok());
    REQUIRE(chunk_reply.ok());

    first_rpc::rpc::UploadControlRequest commit_request;
    commit_request.set_upload_id(upload_id);

    first_rpc::rpc::ActionReply commit_reply;
    REQUIRE(service.UploadCommit(&context, &commit_request, &commit_reply).ok());
    REQUIRE(commit_reply.ok());
    REQUIRE(file_text(temp_dir.path / "uploads" / "demo.txt") == "hello");

    first_rpc::rpc::UploadInitRequest overwrite_init;
    overwrite_init.set_path("uploads/demo.txt");
    overwrite_init.set_expected_size(5);
    overwrite_init.set_overwrite(true);

    first_rpc::rpc::ActionReply overwrite_init_reply;
    REQUIRE(service.UploadInit(&context, &overwrite_init, &overwrite_init_reply).ok());
    REQUIRE(overwrite_init_reply.ok());

    first_rpc::rpc::UploadChunkRequest overwrite_chunk;
    overwrite_chunk.set_upload_id(overwrite_init_reply.data().at("upload_id"));
    overwrite_chunk.set_offset(0);
    overwrite_chunk.set_content("world");

    first_rpc::rpc::ActionReply overwrite_chunk_reply;
    REQUIRE(service.UploadChunk(&context, &overwrite_chunk, &overwrite_chunk_reply).ok());
    REQUIRE(overwrite_chunk_reply.ok());

    first_rpc::rpc::UploadControlRequest overwrite_commit;
    overwrite_commit.set_upload_id(overwrite_init_reply.data().at("upload_id"));

    first_rpc::rpc::ActionReply overwrite_commit_reply;
    REQUIRE(service.UploadCommit(&context, &overwrite_commit, &overwrite_commit_reply).ok());
    REQUIRE(overwrite_commit_reply.ok());
    REQUIRE(file_text(temp_dir.path / "uploads" / "demo.txt") == "world");
}

TEST_CASE("upload RPC rejects unexpected offsets", "[upload]") {
    TempDir temp_dir;
    first_rpc::RemoteOpsServiceImpl service(temp_dir.path, "");
    grpc::ServerContext context;

    first_rpc::rpc::UploadInitRequest init_request;
    init_request.set_path("uploads/demo.txt");
    init_request.set_expected_size(5);
    init_request.set_overwrite(true);

    first_rpc::rpc::ActionReply init_reply;
    REQUIRE(service.UploadInit(&context, &init_request, &init_reply).ok());
    REQUIRE(init_reply.ok());

    first_rpc::rpc::UploadChunkRequest chunk_request;
    chunk_request.set_upload_id(init_reply.data().at("upload_id"));
    chunk_request.set_offset(2);
    chunk_request.set_content("hello");

    first_rpc::rpc::ActionReply chunk_reply;
    REQUIRE(service.UploadChunk(&context, &chunk_request, &chunk_reply).ok());
    REQUIRE_FALSE(chunk_reply.ok());
    REQUIRE(chunk_reply.error() == "Unexpected upload offset");
}
