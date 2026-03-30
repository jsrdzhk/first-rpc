use std::collections::BTreeMap;

use crate::generated::rpc::ActionReply;

pub fn arg_value(args: &[String], name: &str, fallback: &str) -> String {
    args.windows(2)
        .find_map(|pair| {
            if pair[0] == name {
                Some(pair[1].clone())
            } else {
                None
            }
        })
        .unwrap_or_else(|| fallback.to_string())
}

pub fn has_arg(args: &[String], name: &str) -> bool {
    args.iter().any(|arg| arg == name)
}

pub fn format_reply(reply: &ActionReply) -> String {
    let mut output = String::new();
    output.push_str(&format!("ok: {}\n", if reply.ok { "true" } else { "false" }));
    output.push_str(&format!("action: {}\n", reply.action));
    output.push_str(&format!("summary: {}\n", reply.summary));
    output.push_str(&format!("duration_ms: {}\n", reply.duration_ms));
    if !reply.error.is_empty() {
        output.push_str(&format!("error: {}\n", reply.error));
    }

    if reply.data.is_empty() {
        return output;
    }

    output.push_str("data:\n");
    let ordered: BTreeMap<_, _> = reply
        .data
        .iter()
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    for (key, value) in ordered {
        output.push_str(&format!("[{}]\n{}\n", key, value));
    }
    output
}
