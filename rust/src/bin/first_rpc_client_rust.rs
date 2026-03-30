use std::env;

use anyhow::{anyhow, Result};
use first_rpc_rust::cli::{arg_value, format_reply, has_arg};
use first_rpc_rust::generated::rpc::remote_ops_client::RemoteOpsClient;
use first_rpc_rust::generated::rpc::ActionReply;
use first_rpc_rust::ops::{
    grep_file_client, health_check_client, list_dir_client, read_file_client, tail_file_client,
};
use tonic::transport::Channel;

fn print_usage() {
    println!(
        "Usage:\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token health_check\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token list_dir --path .\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token read_file --path app.log\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token tail_file --path app.log --lines 50\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token grep_file --path app.log --needle ERROR"
    );
}

fn action_from_args(args: &[String]) -> Result<String> {
    args.iter()
        .find(|arg| matches!(arg.as_str(), "health_check" | "list_dir" | "read_file" | "tail_file" | "grep_file"))
        .cloned()
        .ok_or_else(|| anyhow!("Missing action"))
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() == 1 || has_arg(&args, "--help") {
        print_usage();
        return Ok(());
    }

    let host = arg_value(&args, "--host", "127.0.0.1");
    let port = arg_value(&args, "--port", "18777");
    let token = arg_value(&args, "--token", "");
    let action = action_from_args(&args)?;

    let endpoint = format!("http://{}:{}", host, port);
    let channel = Channel::from_shared(endpoint)?.connect().await?;
    let mut client = RemoteOpsClient::new(channel);

    let reply: ActionReply = match action.as_str() {
        "health_check" => health_check_client(&mut client, token).await?,
        "list_dir" => {
            let path = arg_value(&args, "--path", "");
            list_dir_client(&mut client, token, path).await?
        }
        "read_file" => {
            let path = arg_value(&args, "--path", "");
            let max_bytes = arg_value(&args, "--max-bytes", "65536").parse::<u64>()?;
            read_file_client(&mut client, token, path, max_bytes).await?
        }
        "tail_file" => {
            let path = arg_value(&args, "--path", "");
            let lines = arg_value(&args, "--lines", "50").parse::<u64>()?;
            let max_bytes = arg_value(&args, "--max-bytes", "65536").parse::<u64>()?;
            tail_file_client(&mut client, token, path, lines, max_bytes).await?
        }
        "grep_file" => {
            let path = arg_value(&args, "--path", "");
            let needle = arg_value(&args, "--needle", "");
            let max_matches = arg_value(&args, "--max-matches", "100").parse::<u64>()?;
            let max_line_length = arg_value(&args, "--max-line-length", "4096").parse::<u64>()?;
            grep_file_client(&mut client, token, path, needle, max_matches, max_line_length).await?
        }
        _ => return Err(anyhow!("Unsupported action: {}", action)),
    };

    print!("{}", format_reply(&reply));
    std::process::exit(if reply.ok { 0 } else { 1 });
}
