use std::env;

use anyhow::{anyhow, Context, Result};
use first_rpc_rust::cli::has_arg;
use first_rpc_rust::generated::rpc::remote_ops_client::RemoteOpsClient;
use first_rpc_rust::generated::rpc::ActionReply;
use first_rpc_rust::ops::{
    exec_client, grep_file_client, health_check_client, list_dir_client, read_file_client,
    tail_file_client,
};
use serde_json::{json, Map, Value};
use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use tonic::transport::{Channel, Endpoint};

const DEFAULT_HOST: &str = "127.0.0.1";
const DEFAULT_PORT: &str = "18777";
const DEFAULT_MAX_BYTES: u64 = 65_536;
const DEFAULT_LINES: u64 = 50;
const DEFAULT_MAX_MATCHES: u64 = 100;
const DEFAULT_MAX_LINE_LENGTH: u64 = 4096;
const DEFAULT_TIMEOUT_MS: u64 = 30_000;
const MCP_PROTOCOL_VERSION: &str = "2024-11-05";

fn print_usage() {
    eprintln!(
        "Usage: first_rpc_mcp [--rpc-host HOST] [--rpc-port PORT] [--rpc-token TOKEN]\n\
         Environment: FIRST_RPC_HOST, FIRST_RPC_PORT, FIRST_RPC_TOKEN"
    );
}

fn config_value(args: &[String], flag: &str, env_name: &str, fallback: &str) -> String {
    first_rpc_rust::cli::arg_value(
        args,
        flag,
        &env::var(env_name).unwrap_or_else(|_| fallback.to_string()),
    )
}

fn endpoint(host: &str, port: &str) -> Result<Endpoint> {
    let authority = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    Ok(Endpoint::from_shared(format!("http://{authority}:{port}"))?)
}

fn object_args(args: Option<&Value>) -> Result<Map<String, Value>> {
    match args {
        Some(value) => value
            .as_object()
            .cloned()
            .ok_or_else(|| anyhow!("arguments must be an object")),
        None => Ok(Map::new()),
    }
}

fn required_string(args: &Map<String, Value>, name: &str) -> Result<String> {
    let value = args
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("{name} must be a non-empty string"))?;
    Ok(value.to_string())
}

fn optional_string(args: &Map<String, Value>, name: &str, fallback: &str) -> Result<String> {
    match args.get(name) {
        None => Ok(fallback.to_string()),
        Some(value) => value
            .as_str()
            .map(ToString::to_string)
            .ok_or_else(|| anyhow!("{name} must be a string")),
    }
}

fn optional_u64(args: &Map<String, Value>, name: &str, fallback: u64) -> Result<u64> {
    match args.get(name) {
        None => Ok(fallback),
        Some(value) => value
            .as_u64()
            .ok_or_else(|| anyhow!("{name} must be a non-negative integer")),
    }
}

fn output_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "ok": {"type": "boolean"},
            "action": {"type": "string"},
            "summary": {"type": "string"},
            "data": {"type": "object", "additionalProperties": {"type": "string"}},
            "error": {"type": "string"},
            "duration_ms": {"type": "integer", "minimum": 0}
        },
        "required": ["ok", "action", "summary", "data", "error", "duration_ms"],
        "additionalProperties": false
    })
}

fn tool(
    name: &str,
    title: &str,
    description: &str,
    input_schema: Value,
    read_only: bool,
    destructive: bool,
) -> Value {
    json!({
        "name": name,
        "title": title,
        "description": description,
        "inputSchema": input_schema,
        "outputSchema": output_schema(),
        "annotations": {
            "readOnlyHint": read_only,
            "destructiveHint": destructive,
            "openWorldHint": false
        }
    })
}

fn tools() -> Value {
    let empty = json!({
        "type": "object",
        "properties": {},
        "additionalProperties": false
    });
    let path = json!({
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
        "additionalProperties": false
    });
    let read_file = json!({
        "type": "object",
        "properties": {
            "path": {"type": "string"},
            "max_bytes": {"type": "integer", "minimum": 1, "default": DEFAULT_MAX_BYTES}
        },
        "required": ["path"],
        "additionalProperties": false
    });
    let tail_file = json!({
        "type": "object",
        "properties": {
            "path": {"type": "string"},
            "lines": {"type": "integer", "minimum": 1, "default": DEFAULT_LINES},
            "max_bytes": {"type": "integer", "minimum": 1, "default": DEFAULT_MAX_BYTES}
        },
        "required": ["path"],
        "additionalProperties": false
    });
    let grep_file = json!({
        "type": "object",
        "properties": {
            "path": {"type": "string"},
            "needle": {"type": "string"},
            "max_matches": {"type": "integer", "minimum": 1, "default": DEFAULT_MAX_MATCHES},
            "max_line_length": {"type": "integer", "minimum": 1, "default": DEFAULT_MAX_LINE_LENGTH}
        },
        "required": ["path", "needle"],
        "additionalProperties": false
    });
    let exec = json!({
        "type": "object",
        "properties": {
            "command": {"type": "string"},
            "working_dir": {"type": "string", "default": "."},
            "timeout_ms": {"type": "integer", "minimum": 1, "default": DEFAULT_TIMEOUT_MS},
            "max_output_bytes": {"type": "integer", "minimum": 1, "default": DEFAULT_MAX_BYTES}
        },
        "required": ["command"],
        "additionalProperties": false
    });

    json!({
        "tools": [
            tool("health_check", "Check first-rpc health", "Check connectivity and the configured remote root.", empty, true, false),
            tool("list_dir", "List a remote directory", "List entries under a path relative to the remote root.", path, true, false),
            tool("read_file", "Read a remote file", "Read a bounded amount of text from a remote file.", read_file, true, false),
            tool("tail_file", "Tail a remote file", "Read the last lines of a remote file.", tail_file, true, false),
            tool("grep_file", "Search a remote file", "Search a known remote file for a literal string.", grep_file, true, false),
            tool("exec", "Run a trusted remote command", "Run a trusted command under the remote server account. The working directory remains relative to the remote root, but this is not a sandbox.", exec, false, true)
        ]
    })
}

fn reply_value(reply: &ActionReply) -> Value {
    let data = reply
        .data
        .iter()
        .map(|(key, value)| (key.clone(), Value::String(value.clone())))
        .collect::<Map<_, _>>();
    json!({
        "ok": reply.ok,
        "action": reply.action,
        "summary": reply.summary,
        "data": data,
        "error": reply.error,
        "duration_ms": reply.duration_ms
    })
}

fn tool_result(value: Value, is_error: bool) -> Value {
    let text = serde_json::to_string_pretty(&value).unwrap_or_else(|_| value.to_string());
    json!({
        "content": [{"type": "text", "text": text}],
        "structuredContent": value,
        "isError": is_error
    })
}

async fn call_tool(
    name: &str,
    args: Option<&Value>,
    client: &mut RemoteOpsClient<Channel>,
    token: &str,
) -> Result<Value> {
    let args = object_args(args)?;
    let reply = match name {
        "health_check" => health_check_client(client, token.to_string()).await?,
        "list_dir" => {
            list_dir_client(client, token.to_string(), required_string(&args, "path")?).await?
        }
        "read_file" => {
            read_file_client(
                client,
                token.to_string(),
                required_string(&args, "path")?,
                optional_u64(&args, "max_bytes", DEFAULT_MAX_BYTES)?,
            )
            .await?
        }
        "tail_file" => {
            tail_file_client(
                client,
                token.to_string(),
                required_string(&args, "path")?,
                optional_u64(&args, "lines", DEFAULT_LINES)?,
                optional_u64(&args, "max_bytes", DEFAULT_MAX_BYTES)?,
            )
            .await?
        }
        "grep_file" => {
            grep_file_client(
                client,
                token.to_string(),
                required_string(&args, "path")?,
                required_string(&args, "needle")?,
                optional_u64(&args, "max_matches", DEFAULT_MAX_MATCHES)?,
                optional_u64(&args, "max_line_length", DEFAULT_MAX_LINE_LENGTH)?,
            )
            .await?
        }
        "exec" => {
            exec_client(
                client,
                token.to_string(),
                required_string(&args, "command")?,
                optional_string(&args, "working_dir", ".")?,
                optional_u64(&args, "timeout_ms", DEFAULT_TIMEOUT_MS)?,
                optional_u64(&args, "max_output_bytes", DEFAULT_MAX_BYTES)?,
            )
            .await?
        }
        _ => return Err(anyhow!("Unknown tool: {name}")),
    };

    let is_error = !reply.ok;
    Ok(tool_result(reply_value(&reply), is_error))
}

fn result_response(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn error_response(id: Value, code: i64, message: impl Into<String>) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {"code": code, "message": message.into()}
    })
}

fn initialize_result(message: &Value) -> Value {
    let protocol_version = message
        .get("params")
        .and_then(|params| params.get("protocolVersion"))
        .and_then(Value::as_str)
        .unwrap_or(MCP_PROTOCOL_VERSION);
    json!({
        "protocolVersion": protocol_version,
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {"name": "first-rpc", "version": env!("CARGO_PKG_VERSION")},
        "instructions": "Remote paths are relative to the first-rpc server root. Use read-only tools for inspection. The exec tool runs under the remote server account and is not a sandbox; use it only for trusted commands."
    })
}

async fn handle_line(
    line: &str,
    client: &mut RemoteOpsClient<Channel>,
    token: &str,
) -> Option<Value> {
    let message: Value = match serde_json::from_str(line) {
        Ok(message) => message,
        Err(error) => {
            return Some(error_response(
                Value::Null,
                -32700,
                format!("Parse error: {error}"),
            ))
        }
    };

    let id = message.get("id").cloned();
    let method = match message.get("method").and_then(Value::as_str) {
        Some(method) => method,
        None => return id.map(|id| error_response(id, -32600, "Invalid request")),
    };

    if id.is_none() {
        return None;
    }

    let id = id.expect("checked above");
    match method {
        "initialize" => Some(result_response(id, initialize_result(&message))),
        "ping" => Some(result_response(id, json!({}))),
        "tools/list" => Some(result_response(id, tools())),
        "tools/call" => {
            let params = message.get("params");
            let name = params
                .and_then(|params| params.get("name"))
                .and_then(Value::as_str);
            let Some(name) = name else {
                return Some(error_response(
                    id,
                    -32602,
                    "tools/call requires a tool name",
                ));
            };
            match call_tool(
                name,
                params.and_then(|params| params.get("arguments")),
                client,
                token,
            )
            .await
            {
                Ok(result) => Some(result_response(id, result)),
                Err(error) if error.to_string().starts_with("Unknown tool:") => {
                    Some(error_response(id, -32602, error.to_string()))
                }
                Err(error) => Some(result_response(
                    id,
                    tool_result(json!({"error": error.to_string()}), true),
                )),
            }
        }
        _ => Some(error_response(
            id,
            -32601,
            format!("Method not found: {method}"),
        )),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if has_arg(&args, "--help") {
        print_usage();
        return Ok(());
    }

    let host = config_value(&args, "--rpc-host", "FIRST_RPC_HOST", DEFAULT_HOST);
    let port = config_value(&args, "--rpc-port", "FIRST_RPC_PORT", DEFAULT_PORT);
    let token = config_value(&args, "--rpc-token", "FIRST_RPC_TOKEN", "");
    let channel = endpoint(&host, &port)
        .with_context(|| format!("invalid first-rpc endpoint {host}:{port}"))?
        .connect_lazy();
    let mut client = RemoteOpsClient::new(channel);

    let stdin = BufReader::new(io::stdin());
    let mut lines = stdin.lines();
    let mut stdout = BufWriter::new(io::stdout());

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        if let Some(response) = handle_line(&line, &mut client, &token).await {
            let encoded = serde_json::to_string(&response)?;
            stdout.write_all(encoded.as_bytes()).await?;
            stdout.write_all(b"\n").await?;
            stdout.flush().await?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{handle_line, tools};
    use first_rpc_rust::generated::rpc::remote_ops_client::RemoteOpsClient;
    use serde_json::Value;
    use tonic::transport::Endpoint;

    #[tokio::test]
    async fn lists_tools_without_connecting_to_remote_server() {
        let channel = Endpoint::from_static("http://127.0.0.1:1").connect_lazy();
        let mut client = RemoteOpsClient::new(channel);
        let response = handle_line(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#,
            &mut client,
            "",
        )
        .await
        .expect("tools/list response");

        let tools = response["result"]["tools"].as_array().expect("tool list");
        assert!(tools.iter().any(|tool| tool["name"] == "grep_file"));
        assert!(tools.iter().any(|tool| tool["name"] == "exec"));
    }

    #[test]
    fn action_output_schema_is_structured() {
        let tool = &tools()["tools"][0];
        assert_eq!(
            tool["outputSchema"]["type"],
            Value::String("object".to_string())
        );
        assert_eq!(tool["annotations"]["readOnlyHint"], Value::Bool(true));
    }
}
