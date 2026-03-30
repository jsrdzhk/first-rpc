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
    output.push_str(&format!(
        "ok: {}\n",
        if reply.ok { "true" } else { "false" }
    ));
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

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use crate::generated::rpc::ActionReply;

    use super::format_reply;

    #[test]
    fn format_reply_orders_map_keys() {
        let reply = ActionReply {
            ok: true,
            action: "health_check".to_string(),
            summary: "server is healthy".to_string(),
            data: HashMap::from([
                ("zeta".to_string(), "last".to_string()),
                ("alpha".to_string(), "first".to_string()),
            ]),
            error: String::new(),
            duration_ms: 7,
        };

        let formatted = format_reply(&reply);

        assert!(formatted.contains("ok: true\n"));
        assert!(formatted.contains("[alpha]\nfirst\n[zeta]\nlast\n"));
    }
}
