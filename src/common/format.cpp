#include "first_rpc/common/format.hpp"

#include <algorithm>
#include <sstream>
#include <vector>

namespace first_rpc {

std::string format_reply(const rpc::ActionReply& reply) {
    std::ostringstream oss;
    oss << "ok: " << (reply.ok() ? "true" : "false") << '\n';
    oss << "action: " << reply.action() << '\n';
    oss << "summary: " << reply.summary() << '\n';
    oss << "duration_ms: " << reply.duration_ms() << '\n';
    if (!reply.error().empty()) {
        oss << "error: " << reply.error() << '\n';
    }
    if (reply.data().empty()) {
        return oss.str();
    }

    oss << "data:\n";
    std::vector<std::string> keys;
    keys.reserve(reply.data().size());
    for (const auto& [key, _] : reply.data()) {
        keys.push_back(key);
    }
    std::sort(keys.begin(), keys.end());
    for (const auto& key : keys) {
        oss << "[" << key << "]\n" << reply.data().at(key) << '\n';
    }
    return oss.str();
}

}  // namespace first_rpc
