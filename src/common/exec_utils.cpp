#include "first_rpc/common/exec_utils.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <stdexcept>
#include <string>

#include "first_rpc/common/file_ops.hpp"

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace first_rpc {

namespace {

constexpr std::uint64_t kDefaultExecTimeoutMs = 30'000;
constexpr std::size_t kDefaultExecOutputBytes = 65'536;

std::string truncate_output(const std::string& text, std::size_t max_output_bytes) {
    if (text.size() <= max_output_bytes) {
        return text;
    }
    return text.substr(0, max_output_bytes);
}

#ifndef _WIN32
void set_non_blocking(int fd) {
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        throw std::runtime_error("Failed to inspect pipe flags");
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        throw std::runtime_error("Failed to set pipe non-blocking");
    }
}

void append_from_fd(int fd, std::string& output) {
    std::array<char, 4096> buffer{};
    while (true) {
        const auto read_count = read(fd, buffer.data(), buffer.size());
        if (read_count > 0) {
            output.append(buffer.data(), static_cast<std::size_t>(read_count));
            continue;
        }
        if (read_count == 0) {
            break;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            break;
        }
        throw std::runtime_error("Failed to read command output");
    }
}
#else
void append_from_pipe(HANDLE pipe, std::string& output) {
    std::array<char, 4096> buffer{};
    while (true) {
        DWORD available = 0;
        if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) {
            const auto error = GetLastError();
            if (error == ERROR_BROKEN_PIPE) {
                break;
            }
            throw std::runtime_error("Failed to inspect command output pipe");
        }
        if (available == 0) {
            break;
        }

        DWORD bytes_read = 0;
        if (!ReadFile(pipe, buffer.data(), static_cast<DWORD>(std::min<std::size_t>(buffer.size(), available)),
                      &bytes_read, nullptr)) {
            const auto error = GetLastError();
            if (error == ERROR_BROKEN_PIPE) {
                break;
            }
            throw std::runtime_error("Failed to read command output");
        }
        if (bytes_read == 0) {
            break;
        }
        output.append(buffer.data(), bytes_read);
    }
}

std::wstring to_wide(const std::string& text) {
    if (text.empty()) {
        return {};
    }

    const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
    if (size <= 0) {
        throw std::runtime_error("Failed to convert string to wide char");
    }

    std::wstring converted(static_cast<std::size_t>(size), L'\0');
    if (MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, converted.data(), size) <= 0) {
        throw std::runtime_error("Failed to convert string to wide char");
    }
    converted.resize(static_cast<std::size_t>(size - 1));
    return converted;
}
#endif

}  // namespace

ExecResult execute_command(const std::filesystem::path& root, const std::string& working_dir,
                           const std::string& command, std::uint64_t timeout_ms,
                           std::size_t max_output_bytes) {
    if (command.empty()) {
        throw std::runtime_error("Command must not be empty");
    }

    const auto resolved_working_dir = normalize_under_root(root, working_dir.empty() ? "." : working_dir);
    const auto effective_timeout_ms = timeout_ms == 0 ? kDefaultExecTimeoutMs : timeout_ms;
    const auto effective_max_output = max_output_bytes == 0 ? kDefaultExecOutputBytes : max_output_bytes;

    ExecResult result;
    result.working_dir = resolved_working_dir;

#ifdef _WIN32
    SECURITY_ATTRIBUTES security_attributes{};
    security_attributes.nLength = sizeof(security_attributes);
    security_attributes.bInheritHandle = TRUE;

    HANDLE stdout_read = nullptr;
    HANDLE stdout_write = nullptr;
    HANDLE stderr_read = nullptr;
    HANDLE stderr_write = nullptr;

    if (!CreatePipe(&stdout_read, &stdout_write, &security_attributes, 0) ||
        !CreatePipe(&stderr_read, &stderr_write, &security_attributes, 0)) {
        throw std::runtime_error("Failed to create command output pipes");
    }

    auto close_handle = [](HANDLE handle) {
        if (handle != nullptr) {
            CloseHandle(handle);
        }
    };

    try {
        SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0);

        STARTUPINFOW startup_info{};
        startup_info.cb = sizeof(startup_info);
        startup_info.dwFlags = STARTF_USESTDHANDLES;
        startup_info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        startup_info.hStdOutput = stdout_write;
        startup_info.hStdError = stderr_write;

        PROCESS_INFORMATION process_info{};
        auto command_line = to_wide("cmd.exe /d /s /c \"" + command + "\"");
        auto working_dir_w = resolved_working_dir.wstring();

        if (!CreateProcessW(nullptr, command_line.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                            nullptr, working_dir_w.c_str(), &startup_info, &process_info)) {
            throw std::runtime_error("Failed to start command process");
        }

        close_handle(stdout_write);
        close_handle(stderr_write);
        stdout_write = nullptr;
        stderr_write = nullptr;

        const auto started = std::chrono::steady_clock::now();
        while (true) {
            append_from_pipe(stdout_read, result.stdout_text);
            append_from_pipe(stderr_read, result.stderr_text);

            const DWORD wait_result = WaitForSingleObject(process_info.hProcess, 50);
            if (wait_result == WAIT_OBJECT_0) {
                break;
            }
            if (wait_result != WAIT_TIMEOUT) {
                TerminateProcess(process_info.hProcess, 1);
                throw std::runtime_error("Failed while waiting for command process");
            }

            const auto elapsed_ms = static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - started
                ).count()
            );
            if (elapsed_ms >= effective_timeout_ms) {
                result.timed_out = true;
                TerminateProcess(process_info.hProcess, 124);
                WaitForSingleObject(process_info.hProcess, INFINITE);
                break;
            }
        }

        append_from_pipe(stdout_read, result.stdout_text);
        append_from_pipe(stderr_read, result.stderr_text);

        DWORD exit_code = 1;
        if (!GetExitCodeProcess(process_info.hProcess, &exit_code)) {
            exit_code = 1;
        }
        result.exit_code = static_cast<int>(exit_code);

        CloseHandle(process_info.hThread);
        CloseHandle(process_info.hProcess);
    } catch (...) {
        close_handle(stdout_read);
        close_handle(stdout_write);
        close_handle(stderr_read);
        close_handle(stderr_write);
        throw;
    }

    close_handle(stdout_read);
    close_handle(stdout_write);
    close_handle(stderr_read);
    close_handle(stderr_write);
#else
    int stdout_pipe[2]{-1, -1};
    int stderr_pipe[2]{-1, -1};
    if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
        throw std::runtime_error("Failed to create command output pipes");
    }

    auto close_fd = [](int& fd) {
        if (fd >= 0) {
            close(fd);
            fd = -1;
        }
    };

    pid_t child_pid = -1;
    try {
        set_non_blocking(stdout_pipe[0]);
        set_non_blocking(stderr_pipe[0]);

        child_pid = fork();
        if (child_pid < 0) {
            throw std::runtime_error("Failed to start command process");
        }

        if (child_pid == 0) {
            dup2(stdout_pipe[1], STDOUT_FILENO);
            dup2(stderr_pipe[1], STDERR_FILENO);
            close_fd(stdout_pipe[0]);
            close_fd(stdout_pipe[1]);
            close_fd(stderr_pipe[0]);
            close_fd(stderr_pipe[1]);

            if (chdir(resolved_working_dir.c_str()) != 0) {
                _exit(125);
            }

            execl("/bin/sh", "sh", "-lc", command.c_str(), static_cast<char*>(nullptr));
            _exit(127);
        }

        close_fd(stdout_pipe[1]);
        close_fd(stderr_pipe[1]);

        const auto started = std::chrono::steady_clock::now();
        bool child_finished = false;
        while (!child_finished) {
            pollfd fds[2] = {
                {stdout_pipe[0], POLLIN, 0},
                {stderr_pipe[0], POLLIN, 0}
            };
            poll(fds, 2, 50);
            append_from_fd(stdout_pipe[0], result.stdout_text);
            append_from_fd(stderr_pipe[0], result.stderr_text);

            int status = 0;
            const auto waited = waitpid(child_pid, &status, WNOHANG);
            if (waited == child_pid) {
                child_finished = true;
                if (WIFEXITED(status)) {
                    result.exit_code = WEXITSTATUS(status);
                } else if (WIFSIGNALED(status)) {
                    result.exit_code = 128 + WTERMSIG(status);
                } else {
                    result.exit_code = 1;
                }
                break;
            }

            const auto elapsed_ms = static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - started
                ).count()
            );
            if (elapsed_ms >= effective_timeout_ms) {
                result.timed_out = true;
                kill(child_pid, SIGKILL);
                waitpid(child_pid, nullptr, 0);
                result.exit_code = 124;
                child_finished = true;
            }
        }

        append_from_fd(stdout_pipe[0], result.stdout_text);
        append_from_fd(stderr_pipe[0], result.stderr_text);

        close_fd(stdout_pipe[0]);
        close_fd(stdout_pipe[1]);
        close_fd(stderr_pipe[0]);
        close_fd(stderr_pipe[1]);
    } catch (...) {
        if (child_pid > 0) {
            kill(child_pid, SIGKILL);
            waitpid(child_pid, nullptr, 0);
        }
        close_fd(stdout_pipe[0]);
        close_fd(stdout_pipe[1]);
        close_fd(stderr_pipe[0]);
        close_fd(stderr_pipe[1]);
        throw;
    }
#endif

    result.stdout_text = truncate_output(result.stdout_text, effective_max_output);
    result.stderr_text = truncate_output(result.stderr_text, effective_max_output);
    return result;
}

}  // namespace first_rpc
