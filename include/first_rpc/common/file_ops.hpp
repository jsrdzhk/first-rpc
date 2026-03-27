#pragma once

#include <filesystem>
#include <string>

namespace first_rpc {

namespace fs = std::filesystem;

fs::path normalize_under_root(const fs::path& root, const fs::path& requested);
std::string list_directory(const fs::path& root, const fs::path& requested);
std::string read_file_text(const fs::path& root, const fs::path& requested, std::size_t max_bytes);
std::string tail_file_text(const fs::path& root, const fs::path& requested, std::size_t lines, std::size_t max_bytes);
std::string grep_file_text(const fs::path& root, const fs::path& requested, const std::string& needle, std::size_t max_matches, std::size_t max_line_length);

}  // namespace first_rpc
