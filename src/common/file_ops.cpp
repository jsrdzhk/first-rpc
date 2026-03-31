#include "first_rpc/common/file_ops.hpp"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "first_rpc/common/exec_utils.hpp"

namespace first_rpc {

namespace {

std::string truncate_text(std::string text, std::size_t max_bytes) {
    if (text.size() <= max_bytes) {
        return text;
    }
    return text.substr(0, max_bytes);
}

std::string shell_quote(const std::string& text) {
#ifdef _WIN32
    std::string quoted = "\"";
    for (const char ch : text) {
        if (ch == '"') {
            quoted += "\"\"";
        } else {
            quoted += ch;
        }
    }
    quoted += '"';
    return quoted;
#else
    std::string quoted = "'";
    for (const char ch : text) {
        if (ch == '\'') {
            quoted += "'\\''";
        } else {
            quoted += ch;
        }
    }
    quoted += '\'';
    return quoted;
#endif
}

bool rg_missing(const ExecResult& result) {
#ifdef _WIN32
    return result.exit_code == 9009 ||
           result.stderr_text.find("not recognized") != std::string::npos;
#else
    return result.exit_code == 127 ||
           result.stderr_text.find("not found") != std::string::npos;
#endif
}

std::size_t grep_output_limit(std::size_t max_matches, std::size_t max_line_length) {
    const auto safe_matches = std::max<std::size_t>(max_matches, 1);
    const auto safe_line_length = std::max<std::size_t>(max_line_length, 1);
    return std::max<std::size_t>(1024, safe_matches * (safe_line_length + 32));
}

std::string grep_file_text_builtin(const fs::path& path, const std::string& needle,
                                   std::size_t max_matches, std::size_t max_line_length) {
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("Failed to open file");
    }

    std::ostringstream oss;
    std::string line;
    std::size_t line_number = 0;
    std::size_t match_count = 0;
    while (std::getline(input, line)) {
        ++line_number;
        if (line.find(needle) == std::string::npos) {
            continue;
        }

        if (line.size() > max_line_length) {
            line = line.substr(0, max_line_length);
        }

        oss << line_number << ':' << line << '\n';
        ++match_count;

        if (match_count >= max_matches) {
            break;
        }
    }

    return oss.str();
}

std::string grep_file_text_with_rg(const fs::path& root, const fs::path& path,
                                   const std::string& needle, std::size_t max_matches,
                                   std::size_t max_line_length) {
    const std::string command =
        "rg -n -F -m " + std::to_string(max_matches) +
        " --color never --no-heading -- " +
        shell_quote(needle) + " " + shell_quote(path.string());

    const auto result = execute_command(root, ".", command, 30'000,
                                        grep_output_limit(max_matches, max_line_length));

    if (result.timed_out) {
        throw std::runtime_error("rg search timed out");
    }
    if (result.exit_code != 0 && result.exit_code != 1) {
        if (rg_missing(result)) {
            return grep_file_text_builtin(path, needle, max_matches, max_line_length);
        }
        throw std::runtime_error(
            "rg search failed: " +
            (result.stderr_text.empty() ? result.stdout_text : result.stderr_text));
    }

    std::ostringstream normalized;
    std::istringstream input(result.stdout_text);
    std::string line;
    std::size_t match_count = 0;
    while (std::getline(input, line)) {
        if (line.empty()) {
            continue;
        }

        const auto separator = line.find(':');
        if (separator == std::string::npos) {
            continue;
        }

        auto content = line.substr(separator + 1);
        if (content.size() > max_line_length) {
            content = content.substr(0, max_line_length);
        }

        normalized << line.substr(0, separator) << ':' << content << '\n';
        ++match_count;
        if (match_count >= max_matches) {
            break;
        }
    }

    return normalized.str();
}

}  // namespace

fs::path normalize_under_root(const fs::path& root, const fs::path& requested) {
    const fs::path base = fs::weakly_canonical(root);
    const fs::path candidate = fs::weakly_canonical(base / requested);

    const auto base_string = base.generic_string();
    const auto candidate_string = candidate.generic_string();
    if (candidate_string != base_string &&
        !candidate_string.starts_with(base_string + "/")) {
        throw std::runtime_error("Requested path escapes configured root");
    }

    return candidate;
}

std::string list_directory(const fs::path& root, const fs::path& requested) {
    const auto path = normalize_under_root(root, requested);
    if (!fs::exists(path)) {
        throw std::runtime_error("Directory does not exist");
    }
    if (!fs::is_directory(path)) {
        throw std::runtime_error("Requested path is not a directory");
    }

    std::ostringstream oss;
    for (const auto& entry : fs::directory_iterator(path)) {
        oss << (entry.is_directory() ? "[dir] " : "[file] ")
            << fs::relative(entry.path(), path).generic_string()
            << '\n';
    }
    return oss.str();
}

std::string read_file_text(const fs::path& root, const fs::path& requested, std::size_t max_bytes) {
    const auto path = normalize_under_root(root, requested);
    if (!fs::exists(path)) {
        throw std::runtime_error("File does not exist");
    }
    if (!fs::is_regular_file(path)) {
        throw std::runtime_error("Requested path is not a regular file");
    }

    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("Failed to open file");
    }

    std::ostringstream oss;
    oss << input.rdbuf();
    return truncate_text(oss.str(), max_bytes);
}

std::string tail_file_text(const fs::path& root, const fs::path& requested, std::size_t lines, std::size_t max_bytes) {
    const auto path = normalize_under_root(root, requested);
    if (!fs::exists(path)) {
        throw std::runtime_error("File does not exist");
    }

    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("Failed to open file");
    }

    std::vector<std::string> ring;
    ring.reserve(lines);
    std::string line;
    while (std::getline(input, line)) {
        if (ring.size() == lines) {
            ring.erase(ring.begin());
        }
        ring.push_back(line);
    }

    std::ostringstream oss;
    for (const auto& item : ring) {
        oss << item << '\n';
    }
    return truncate_text(oss.str(), max_bytes);
}

std::string grep_file_text(const fs::path& root, const fs::path& requested, const std::string& needle, std::size_t max_matches, std::size_t max_line_length) {
    const auto path = normalize_under_root(root, requested);
    if (!fs::exists(path)) {
        throw std::runtime_error("File does not exist");
    }
    if (needle.empty()) {
        throw std::runtime_error("Needle must not be empty");
    }

    return grep_file_text_with_rg(root, path, needle, max_matches, max_line_length);
}

}  // namespace first_rpc
