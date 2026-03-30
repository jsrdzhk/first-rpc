use std::env;
use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};
use first_rpc_rust::generated::rpc::remote_ops_server::RemoteOpsServer;
use first_rpc_rust::ops::RemoteOpsState;
use tonic::transport::Server;

fn arg_value(args: &[String], name: &str, fallback: &str) -> String {
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

fn print_usage() {
    println!("Usage: first_rpc_server_rust [--host 127.0.0.1] [--port 18777] [--root .] [--token token]");
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.iter().any(|arg| arg == "--help") {
        print_usage();
        return Ok(());
    }

    let host = arg_value(&args, "--host", "127.0.0.1");
    let port = arg_value(&args, "--port", "18777");
    let root = PathBuf::from(arg_value(&args, "--root", "."));
    let token = arg_value(&args, "--token", "");
    let address: SocketAddr = format!("{}:{}", host, port)
        .parse()
        .context("invalid listen address")?;

    let canonical_root = root.canonicalize().unwrap_or(root.clone());
    println!(
        "first-rpc Rust gRPC server listening on {} root={}",
        address,
        canonical_root.to_string_lossy().replace('\\', "/")
    );

    let service = RemoteOpsState::new(root, token);
    Server::builder()
        .add_service(RemoteOpsServer::new(service))
        .serve(address)
        .await
        .context("failed to start gRPC server")?;

    Ok(())
}
