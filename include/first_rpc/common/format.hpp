#pragma once

#include <string>

#include "first_rpc.grpc.pb.h"

namespace first_rpc {

std::string format_reply(const rpc::ActionReply& reply);

}  // namespace first_rpc
