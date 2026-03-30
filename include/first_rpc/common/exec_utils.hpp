#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

namespace first_rpc {

struct ExecResult {
    int exit_code = -1;
    bool timed_out = false;
    std::string stdout_text;
    std::string stderr_text;
    std::filesystem::path working_dir;
};

ExecResult execute_command(const std::filesystem::path& root, const std::string& working_dir,
                           const std::string& command, std::uint64_t timeout_ms,
                           std::size_t max_output_bytes);

}  // namespace first_rpc
