#pragma once

#include <string>
#include <unordered_map>

namespace first_rpc {

struct RequestArgs {
    std::string token;
    std::string action;
    std::unordered_map<std::string, std::string> params;
};

}  // namespace first_rpc
