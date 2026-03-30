#include <string>

#include <catch2/catch_test_macros.hpp>

#include "first_rpc/common/format.hpp"

TEST_CASE("format_reply sorts data keys and renders error lines", "[format]") {
    first_rpc::rpc::ActionReply reply;
    reply.set_ok(false);
    reply.set_action("grep_file");
    reply.set_summary("request failed");
    reply.set_error("boom");
    reply.set_duration_ms(42);
    (*reply.mutable_data())["zeta"] = "last";
    (*reply.mutable_data())["alpha"] = "first";

    const auto formatted = first_rpc::format_reply(reply);

    REQUIRE(formatted.find("ok: false\n") != std::string::npos);
    REQUIRE(formatted.find("action: grep_file\n") != std::string::npos);
    REQUIRE(formatted.find("summary: request failed\n") != std::string::npos);
    REQUIRE(formatted.find("error: boom\n") != std::string::npos);
    REQUIRE(formatted.find("[alpha]\nfirst\n[zeta]\nlast\n") != std::string::npos);
}
