#include <algorithm>
#include <filesystem>
#include <fstream>
#include <string>
#include <chrono>

#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_string.hpp>

#include "first_rpc/common/file_ops.hpp"

namespace fs = std::filesystem;

namespace {

std::string normalize_newlines(std::string text) {
    text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
    return text;
}

struct TempDir {
    fs::path path;

    TempDir()
        : path(fs::temp_directory_path() / ("first-rpc-file-ops-" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()))) {
        fs::create_directories(path);
    }

    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

}  // namespace

TEST_CASE("normalize_under_root allows nested paths under root", "[file_ops]") {
    TempDir temp_dir;
    const auto resolved = first_rpc::normalize_under_root(temp_dir.path, "logs/app.log");

    REQUIRE(resolved == fs::weakly_canonical(temp_dir.path / "logs/app.log"));
}

TEST_CASE("normalize_under_root rejects parent traversal outside root", "[file_ops]") {
    TempDir temp_dir;

    REQUIRE_THROWS_WITH(
        first_rpc::normalize_under_root(temp_dir.path, "../escape.txt"),
        "Requested path escapes configured root"
    );
}

TEST_CASE("read tail and grep operate on constrained files", "[file_ops]") {
    TempDir temp_dir;
    const auto file_path = temp_dir.path / "sample.log";
    {
        std::ofstream output(file_path, std::ios::binary);
        output << "alpha\nbeta\nERROR target line\nomega\n";
    }

    SECTION("read_file_text returns content") {
        const auto content = normalize_newlines(first_rpc::read_file_text(temp_dir.path, "sample.log", 1024));
        REQUIRE(content == "alpha\nbeta\nERROR target line\nomega\n");
    }

    SECTION("tail_file_text returns last lines") {
        const auto content = normalize_newlines(first_rpc::tail_file_text(temp_dir.path, "sample.log", 2, 1024));
        REQUIRE(content == "ERROR target line\nomega\n");
    }

    SECTION("grep_file_text returns numbered matches") {
        const auto content = normalize_newlines(first_rpc::grep_file_text(temp_dir.path, "sample.log", "ERROR", 10, 1024));
        REQUIRE(content == "3:ERROR target line\n");
    }
}
