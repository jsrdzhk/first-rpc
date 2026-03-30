use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Component, Path, PathBuf};
use std::time::Instant;

use anyhow::{anyhow, Result};
use chrono::Utc;
use hostname::get;
use tonic::{Request, Response, Status};

use crate::generated::rpc::remote_ops_client::RemoteOpsClient;
use crate::generated::rpc::remote_ops_server::RemoteOps;
use crate::generated::rpc::{
    ActionReply, GrepFileRequest, HealthCheckRequest, PathRequest, ReadFileRequest, TailFileRequest,
};

pub struct RemoteOpsState {
    root: PathBuf,
    token: String,
}

impl RemoteOpsState {
    pub fn new(root: PathBuf, token: String) -> Self {
        Self { root, token }
    }

    fn handle<F>(&self, action: &str, token: &str, func: F) -> ActionReply
    where
        F: FnOnce() -> Result<(String, BTreeMap<String, String>)>,
    {
        let started = Instant::now();
        let mut reply = ActionReply {
            ok: false,
            action: action.to_string(),
            summary: String::new(),
            data: Default::default(),
            error: String::new(),
            duration_ms: 0,
        };

        let outcome = if !self.token.is_empty() && token != self.token {
            Err(anyhow!("Unauthorized"))
        } else {
            func()
        };

        match outcome {
            Ok((summary, data)) => {
                reply.ok = true;
                reply.summary = summary;
                reply.data = data.into_iter().collect();
            }
            Err(err) => {
                reply.ok = false;
                reply.summary = "request failed".to_string();
                reply.error = err.to_string();
            }
        }

        if reply.summary.is_empty() && reply.ok {
            reply.summary = "request succeeded".to_string();
        }
        reply.duration_ms = started.elapsed().as_millis() as u64;
        reply
    }

    fn canonical_root(&self) -> Result<PathBuf> {
        Ok(self.root.canonicalize()?)
    }

    fn resolve_path(&self, requested: &str) -> Result<PathBuf> {
        let root = self.canonical_root()?;
        let requested_path = Path::new(requested);
        if requested_path.is_absolute() {
            return Err(anyhow!("Requested path escapes configured root"));
        }

        let mut relative = PathBuf::new();
        for component in requested_path.components() {
            match component {
                Component::CurDir => {}
                Component::Normal(part) => relative.push(part),
                Component::ParentDir => {
                    if !relative.pop() {
                        return Err(anyhow!("Requested path escapes configured root"));
                    }
                }
                Component::Prefix(_) | Component::RootDir => {
                    return Err(anyhow!("Requested path escapes configured root"));
                }
            }
        }

        Ok(root.join(relative))
    }
}

#[tonic::async_trait]
impl RemoteOps for RemoteOpsState {
    async fn health_check(
        &self,
        request: Request<HealthCheckRequest>,
    ) -> Result<Response<ActionReply>, Status> {
        let token = request.into_inner().token;
        let reply = self.handle("health_check", &token, || {
            let mut data = BTreeMap::new();
            data.insert("host".to_string(), hostname());
            data.insert("platform".to_string(), platform_name());
            data.insert("time_utc".to_string(), now_iso8601_utc());
            data.insert(
                "root".to_string(),
                self.canonical_root()?.to_string_lossy().replace('\\', "/"),
            );
            Ok(("server is healthy".to_string(), data))
        });
        Ok(Response::new(reply))
    }

    async fn list_dir(&self, request: Request<PathRequest>) -> Result<Response<ActionReply>, Status> {
        let request = request.into_inner();
        let reply = self.handle("list_dir", &request.token, || {
            let path = self.resolve_path(&request.path)?;
            if !path.exists() {
                return Err(anyhow!("Directory does not exist"));
            }
            if !path.is_dir() {
                return Err(anyhow!("Requested path is not a directory"));
            }

            let mut items = String::new();
            for entry in fs::read_dir(&path)? {
                let entry = entry?;
                let metadata = entry.metadata()?;
                let name = entry.file_name().to_string_lossy().to_string();
                items.push_str(if metadata.is_dir() { "[dir] " } else { "[file] " });
                items.push_str(&name);
                items.push('\n');
            }

            let mut data = BTreeMap::new();
            data.insert("items".to_string(), items);
            Ok(("directory listed".to_string(), data))
        });
        Ok(Response::new(reply))
    }

    async fn read_file(
        &self,
        request: Request<ReadFileRequest>,
    ) -> Result<Response<ActionReply>, Status> {
        let request = request.into_inner();
        let reply = self.handle("read_file", &request.token, || {
            let path = self.resolve_path(&request.path)?;
            if !path.exists() {
                return Err(anyhow!("File does not exist"));
            }
            if !path.is_file() {
                return Err(anyhow!("Requested path is not a regular file"));
            }

            let mut file = fs::File::open(path)?;
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes)?;
            let text = String::from_utf8_lossy(&bytes);
            let content: String = text.chars().take(request.max_bytes as usize).collect();

            let mut data = BTreeMap::new();
            data.insert("content".to_string(), content);
            Ok(("file read".to_string(), data))
        });
        Ok(Response::new(reply))
    }

    async fn tail_file(
        &self,
        request: Request<TailFileRequest>,
    ) -> Result<Response<ActionReply>, Status> {
        let request = request.into_inner();
        let reply = self.handle("tail_file", &request.token, || {
            let path = self.resolve_path(&request.path)?;
            if !path.exists() {
                return Err(anyhow!("File does not exist"));
            }

            let file = fs::File::open(path)?;
            let reader = BufReader::new(file);
            let mut ring = VecDeque::with_capacity(request.lines as usize);
            for line in reader.lines() {
                let line = line?;
                if ring.len() == request.lines as usize {
                    ring.pop_front();
                }
                ring.push_back(line);
            }

            let mut content = ring.into_iter().collect::<Vec<_>>().join("\n");
            if !content.is_empty() {
                content.push('\n');
            }
            let content: String = content.chars().take(request.max_bytes as usize).collect();

            let mut data = BTreeMap::new();
            data.insert("content".to_string(), content);
            Ok(("file tailed".to_string(), data))
        });
        Ok(Response::new(reply))
    }

    async fn grep_file(
        &self,
        request: Request<GrepFileRequest>,
    ) -> Result<Response<ActionReply>, Status> {
        let request = request.into_inner();
        let reply = self.handle("grep_file", &request.token, || {
            let path = self.resolve_path(&request.path)?;
            if !path.exists() {
                return Err(anyhow!("File does not exist"));
            }
            if request.needle.is_empty() {
                return Err(anyhow!("Needle must not be empty"));
            }

            let file = fs::File::open(path)?;
            let reader = BufReader::new(file);
            let mut matches = String::new();
            let mut count = 0_u64;
            for (index, line) in reader.lines().enumerate() {
                let mut line = line?;
                if !line.contains(&request.needle) {
                    continue;
                }
                if line.len() > request.max_line_length as usize {
                    line.truncate(request.max_line_length as usize);
                }
                matches.push_str(&format!("{}:{}\n", index + 1, line));
                count += 1;
                if count >= request.max_matches {
                    break;
                }
            }

            let mut data = BTreeMap::new();
            data.insert("matches".to_string(), matches);
            Ok(("file searched".to_string(), data))
        });
        Ok(Response::new(reply))
    }
}

pub fn hostname() -> String {
    get()
        .ok()
        .and_then(|value| value.into_string().ok())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown-host".to_string())
}

pub fn platform_name() -> String {
    if cfg!(target_os = "windows") {
        "windows".to_string()
    } else if cfg!(target_os = "macos") {
        "macos".to_string()
    } else if cfg!(target_os = "linux") {
        "linux".to_string()
    } else {
        "unknown".to_string()
    }
}

pub fn now_iso8601_utc() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

pub async fn health_check_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
) -> Result<ActionReply> {
    Ok(client
        .health_check(HealthCheckRequest { token })
        .await?
        .into_inner())
}

pub async fn list_dir_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
    path: String,
) -> Result<ActionReply> {
    Ok(client.list_dir(PathRequest { token, path }).await?.into_inner())
}

pub async fn read_file_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
    path: String,
    max_bytes: u64,
) -> Result<ActionReply> {
    Ok(client
        .read_file(ReadFileRequest {
            token,
            path,
            max_bytes,
        })
        .await?
        .into_inner())
}

pub async fn tail_file_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
    path: String,
    lines: u64,
    max_bytes: u64,
) -> Result<ActionReply> {
    Ok(client
        .tail_file(TailFileRequest {
            token,
            path,
            lines,
            max_bytes,
        })
        .await?
        .into_inner())
}

pub async fn grep_file_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
    path: String,
    needle: String,
    max_matches: u64,
    max_line_length: u64,
) -> Result<ActionReply> {
    Ok(client
        .grep_file(GrepFileRequest {
            token,
            path,
            needle,
            max_matches,
            max_line_length,
        })
        .await?
        .into_inner())
}
