use std::env;
use std::fs::File;
use std::io::Read;

use anyhow::{anyhow, Result};
use first_rpc_rust::cli::{arg_value, format_reply, has_arg};
use first_rpc_rust::generated::rpc::remote_ops_client::RemoteOpsClient;
use first_rpc_rust::generated::rpc::ActionReply;
use first_rpc_rust::ops::{
    exec_client, grep_file_client, health_check_client, list_dir_client, read_file_client,
    tail_file_client, upload_abort_client, upload_chunk_client, upload_commit_client,
    upload_init_client,
};
use tonic::transport::Channel;

const DEFAULT_CHUNK_SIZE: usize = 1024 * 1024;

fn print_usage() {
    println!(
        "Usage:\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token health_check\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token list_dir --path .\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token read_file --path app.log\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token tail_file --path app.log --lines 50\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token grep_file --path app.log --needle ERROR\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token upload_file --local app.jar --path deploy/app.jar\n  first_rpc_client_rust --host 127.0.0.1 --port 18777 --token token exec --command \"pwd\" --working-dir ."
    );
}

fn action_from_args(args: &[String]) -> Result<String> {
    args.iter()
        .find(|arg| {
            matches!(
                arg.as_str(),
                "health_check"
                    | "list_dir"
                    | "read_file"
                    | "tail_file"
                    | "grep_file"
                    | "upload_file"
                    | "exec"
            )
        })
        .cloned()
        .ok_or_else(|| anyhow!("Missing action"))
}

fn bool_arg(args: &[String], name: &str, fallback: bool) -> bool {
    let value = arg_value(args, name, if fallback { "true" } else { "false" });
    !matches!(value.as_str(), "false" | "0" | "no")
}

async fn upload_file(
    client: &mut RemoteOpsClient<Channel>,
    token: String,
    local: String,
    remote: String,
    overwrite: bool,
    chunk_size: usize,
) -> Result<ActionReply> {
    if remote.is_empty() {
        return Err(anyhow!("Remote --path is required for upload_file"));
    }
    if local.is_empty() {
        return Err(anyhow!("Local --local path is required for upload_file"));
    }

    let metadata = std::fs::metadata(&local)?;
    if !metadata.is_file() {
        return Err(anyhow!("Local path is not a regular file"));
    }

    let init_reply =
        upload_init_client(client, token.clone(), remote, overwrite, metadata.len()).await?;
    if !init_reply.ok {
        return Ok(init_reply);
    }

    let upload_id = init_reply
        .data
        .get("upload_id")
        .cloned()
        .ok_or_else(|| anyhow!("Upload init reply did not contain upload_id"))?;

    let mut file = File::open(local)?;
    let mut buffer = vec![0_u8; chunk_size];
    let mut offset = 0_u64;

    loop {
        let read_count = file.read(&mut buffer)?;
        if read_count == 0 {
            break;
        }

        let chunk_reply = upload_chunk_client(
            client,
            token.clone(),
            upload_id.clone(),
            offset,
            buffer[..read_count].to_vec(),
        )
        .await?;
        if !chunk_reply.ok {
            let _ = upload_abort_client(client, token.clone(), upload_id.clone()).await;
            return Ok(chunk_reply);
        }
        offset += read_count as u64;
    }

    match upload_commit_client(client, token.clone(), upload_id.clone()).await {
        Ok(reply) => Ok(reply),
        Err(err) => {
            let _ = upload_abort_client(client, token, upload_id).await;
            Err(err)
        }
    }
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
            grep_file_client(
                &mut client,
                token,
                path,
                needle,
                max_matches,
                max_line_length,
            )
            .await?
        }
        "upload_file" => {
            let remote = arg_value(&args, "--path", "");
            let local = arg_value(&args, "--local", "");
            let overwrite = bool_arg(&args, "--overwrite", true);
            let chunk_size = arg_value(&args, "--chunk-size", &DEFAULT_CHUNK_SIZE.to_string())
                .parse::<usize>()?;
            upload_file(&mut client, token, local, remote, overwrite, chunk_size).await?
        }
        "exec" => {
            let command = arg_value(&args, "--command", "");
            let working_dir = arg_value(&args, "--working-dir", ".");
            let timeout_ms = arg_value(&args, "--timeout-ms", "30000").parse::<u64>()?;
            let max_output_bytes =
                arg_value(&args, "--max-output-bytes", "65536").parse::<u64>()?;
            exec_client(
                &mut client,
                token,
                command,
                working_dir,
                timeout_ms,
                max_output_bytes,
            )
            .await?
        }
        _ => return Err(anyhow!("Unsupported action: {}", action)),
    };

    print!("{}", format_reply(&reply));
    std::process::exit(if reply.ok { 0 } else { 1 });
}
