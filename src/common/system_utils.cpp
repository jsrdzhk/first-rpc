#include "first_rpc/common/system_utils.hpp"

#include <chrono>
#include <cstdlib>
#include <ctime>
#include <iomanip>
#include <sstream>
#include <string>

#if defined(_WIN32)
#include <Windows.h>
#else
#include <unistd.h>
#endif

namespace first_rpc {

std::string hostname() {
#if defined(_WIN32)
    char buffer[MAX_COMPUTERNAME_LENGTH + 1] = {};
    DWORD size = static_cast<DWORD>(sizeof(buffer));
    if (GetComputerNameA(buffer, &size)) {
        return std::string(buffer, size);
    }
    const char* env = std::getenv("COMPUTERNAME");
    return env ? std::string(env) : "unknown-host";
#else
    char buffer[256] = {};
    if (gethostname(buffer, sizeof(buffer)) == 0) {
        return std::string(buffer);
    }
    const char* env = std::getenv("HOSTNAME");
    return env ? std::string(env) : "unknown-host";
#endif
}

std::string platform_name() {
#if defined(_WIN32)
    return "windows";
#elif defined(__APPLE__)
    return "macos";
#elif defined(__linux__)
    return "linux";
#else
    return "unknown";
#endif
}

std::string now_iso8601_utc() {
    using clock = std::chrono::system_clock;
    const auto now = clock::now();
    const std::time_t tt = clock::to_time_t(now);
    std::tm tm = {};
#if defined(_WIN32)
    gmtime_s(&tm, &tt);
#else
    gmtime_r(&tt, &tm);
#endif
    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%dT%H:%M:%SZ");
    return oss.str();
}

}  // namespace first_rpc
