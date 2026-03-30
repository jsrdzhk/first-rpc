use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use chrono::Utc;
use hostname::get;
use tonic::{Request, Response, Status};

use crate::generated::rpc::remote_ops_client::RemoteOpsClient;
use crate::generated::rpc::remote_ops_server::RemoteOps;
use crate::generated::rpc::{
    ActionReply, GrepFileRequest, HealthCheckRequest, PathRequest, ReadFileRequest,
    TailFileRequest, UploadChunkRequest, UploadControlRequest, UploadInitRequest,
};

const MAX_UPLOAD_FILE_SIZE: u64 = 1024 * 1024 * 1024;
const DEFAULT_CHUNK_SIZE: u64 = 1024 * 1024;

#[derive(Clone)]
struct UploadSession {
    target_path: PathBuf,
    temp_path: PathBuf,
    expected_size: u64,
    received_size: u64,
    overwrite: bool,
}

pub struct RemoteOpsState {
    root: PathBuf,
    token: String,
    uploads: Mutex<HashMap<String, UploadSession>>,
}

impl RemoteOpsState {
    pub fn new(root: PathBuf, token: String) -> Self {
        Self {
            root,
            token,
            uploads: Mutex::new(HashMap::new()),
        }
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

    fn allocate_temp_upload_path(&self, upload_id: &str) -> Result<PathBuf> {
        let temp_dir = self.canonical_root()?.join(".first-rpc-uploads");
        fs::create_dir_all(&temp_dir)?;
        Ok(temp_dir.join(format!("{upload_id}.part")))
    }

    fn replace_file(source: &Path, target: &Path, overwrite: bool) -> Result<()> {
        if !overwrite && target.exists() {
            return Err(anyhow!("Target file already exists"));
        }

        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }

        if overwrite && target.exists() {
            fs::remove_file(target)?;
        }

        fs::rename(source, target)?;
        Ok(())
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

    async fn list_dir(
        &self,
        request: Request<PathRequest>,
    ) -> Result<Response<ActionReply>, Status> {
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
                items.push_str(if metadata.is_dir() {
                    "[dir] "
                } else {
                    "[file] "
                });
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

    async fn upload_init(
        &self,
        request: Request<UploadInitRequest>,
    ) -> Result<Response<ActionReply>, Status> {
        let request = request.into_inner();
        let reply = self.handle("upload_init", &request.token, || {
            if request.path.is_empty() {
                return Err(anyhow!("Path must not be empty"));
            }
            if request.expected_size > MAX_UPLOAD_FILE_SIZE {
                return Err(anyhow!("File exceeds max upload size of 1GB"));
            }

            let target_path = self.resolve_path(&request.path)?;
            let upload_id = format!(
                "{:x}-{:x}",
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos(),
                Utc::now().timestamp_nanos_opt().unwrap_or_default()
            );
            let temp_path = self.allocate_temp_upload_path(&upload_id)?;
            if temp_path.exists() {
                fs::remove_file(&temp_path)?;
            }
            fs::File::create(&temp_path)?;

            let session = UploadSession {
                target_path: target_path.clone(),
                temp_path,
                expected_size: request.expected_size,
                received_size: 0,
                overwrite: request.overwrite,
            };
            self.uploads
                .lock()
                .expect("upload mutex poisoned")
                .insert(upload_id.clone(), session);

            let mut data = BTreeMap::new();
            data.insert("upload_id".to_string(), upload_id);
            data.insert(
                "path".to_string(),
                target_path.to_string_lossy().replace('\\', "/"),
            );
            data.insert("chunk_size".to_string(), DEFAULT_CHUNK_SIZE.to_string());
            data.insert(
                "max_upload_size".to_string(),
                MAX_UPLOAD_FILE_SIZE.to_string(),
            );
            Ok(("upload session initialized".to_string(), data))
        });
        Ok(Response::new(reply))
    }

    async fn upload_chunk(
        &self,
        request: Request<UploadChunkRequest>,
    ) -> Result<Response<ActionReply>, Status> {
        let request = request.into_inner();
        let reply = self.handle("upload_chunk", &request.token, || {
            let session = {
                let uploads = self.uploads.lock().expect("upload mutex poisoned");
                let session = uploads
                    .get(&request.upload_id)
                    .ok_or_else(|| anyhow!("Upload session not found"))?;
                if request.offset != session.received_size {
                    return Err(anyhow!("Unexpected upload offset"));
                }
                if session.received_size + request.content.len() as u64 > session.expected_size {
                    return Err(anyhow!("Upload content exceeds expected file size"));
                }
                session.clone()
            };

            let mut output = fs::OpenOptions::new()
                .append(true)
                .open(&session.temp_path)?;
            output.write_all(&request.content)?;
            output.flush()?;

            let mut uploads = self.uploads.lock().expect("upload mutex poisoned");
            let stored = uploads
                .get_mut(&request.upload_id)
                .ok_or_else(|| anyhow!("Upload session not found"))?;
            stored.received_size += request.content.len() as u64;

            let mut data = BTreeMap::new();
            data.insert(
                "received_size".to_string(),
                stored.received_size.to_string(),
            );
            data.insert(
                "expected_size".to_string(),
                stored.expected_size.to_string(),
            );
            Ok(("upload chunk stored".to_string(), data))
        });
        Ok(Response::new(reply))
    }

    async fn upload_commit(
        &self,
        request: Request<UploadControlRequest>,
    ) -> Result<Response<ActionReply>, Status> {
        let request = request.into_inner();
        let reply = self.handle("upload_commit", &request.token, || {
            let session = {
                let uploads = self.uploads.lock().expect("upload mutex poisoned");
                uploads
                    .get(&request.upload_id)
                    .cloned()
                    .ok_or_else(|| anyhow!("Upload session not found"))?
            };

            if session.received_size != session.expected_size {
                return Err(anyhow!("Uploaded size does not match expected size"));
            }
            if !session.temp_path.exists() {
                return Err(anyhow!("Temp upload file does not exist"));
            }

            Self::replace_file(&session.temp_path, &session.target_path, session.overwrite)?;
            self.uploads
                .lock()
                .expect("upload mutex poisoned")
                .remove(&request.upload_id);

            let mut data = BTreeMap::new();
            data.insert(
                "path".to_string(),
                session.target_path.to_string_lossy().replace('\\', "/"),
            );
            data.insert("size".to_string(), session.expected_size.to_string());
            Ok(("upload committed".to_string(), data))
        });
        Ok(Response::new(reply))
    }

    async fn upload_abort(
        &self,
        request: Request<UploadControlRequest>,
    ) -> Result<Response<ActionReply>, Status> {
        let request = request.into_inner();
        let reply = self.handle("upload_abort", &request.token, || {
            let session = self
                .uploads
                .lock()
                .expect("upload mutex poisoned")
                .remove(&request.upload_id)
                .ok_or_else(|| anyhow!("Upload session not found"))?;
            if session.temp_path.exists() {
                fs::remove_file(session.temp_path)?;
            }
            Ok(("upload aborted".to_string(), BTreeMap::new()))
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
    Ok(client
        .list_dir(PathRequest { token, path })
        .await?
        .into_inner())
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

pub async fn upload_init_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
    path: String,
    overwrite: bool,
    expected_size: u64,
) -> Result<ActionReply> {
    Ok(client
        .upload_init(UploadInitRequest {
            token,
            path,
            overwrite,
            expected_size,
        })
        .await?
        .into_inner())
}

pub async fn upload_chunk_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
    upload_id: String,
    offset: u64,
    content: Vec<u8>,
) -> Result<ActionReply> {
    Ok(client
        .upload_chunk(UploadChunkRequest {
            token,
            upload_id,
            offset,
            content,
        })
        .await?
        .into_inner())
}

pub async fn upload_commit_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
    upload_id: String,
) -> Result<ActionReply> {
    Ok(client
        .upload_commit(UploadControlRequest { token, upload_id })
        .await?
        .into_inner())
}

pub async fn upload_abort_client(
    client: &mut RemoteOpsClient<tonic::transport::Channel>,
    token: String,
    upload_id: String,
) -> Result<ActionReply> {
    Ok(client
        .upload_abort(UploadControlRequest { token, upload_id })
        .await?
        .into_inner())
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;
    use tonic::Request;

    use crate::generated::rpc::{
        GrepFileRequest, PathRequest, ReadFileRequest, UploadChunkRequest, UploadControlRequest,
        UploadInitRequest,
    };

    use super::RemoteOps;
    use super::RemoteOpsState;

    #[test]
    fn resolve_path_rejects_parent_escape() {
        let dir = tempdir().expect("tempdir");
        let state = RemoteOpsState::new(dir.path().to_path_buf(), String::new());

        let err = state
            .resolve_path("../escape.txt")
            .expect_err("expected escape failure");
        assert!(err
            .to_string()
            .contains("Requested path escapes configured root"));
    }

    #[tokio::test]
    async fn upload_roundtrip_overwrites_by_default() {
        let dir = tempdir().expect("tempdir");
        let state = RemoteOpsState::new(dir.path().to_path_buf(), String::new());

        let init_reply = state
            .upload_init(Request::new(UploadInitRequest {
                token: String::new(),
                path: "uploads/demo.txt".to_string(),
                overwrite: true,
                expected_size: 5,
            }))
            .await
            .expect("upload init")
            .into_inner();
        assert!(init_reply.ok);

        let upload_id = init_reply
            .data
            .get("upload_id")
            .cloned()
            .expect("upload id");

        let chunk_reply = state
            .upload_chunk(Request::new(UploadChunkRequest {
                token: String::new(),
                upload_id: upload_id.clone(),
                offset: 0,
                content: b"hello".to_vec(),
            }))
            .await
            .expect("upload chunk")
            .into_inner();
        assert!(chunk_reply.ok);

        let commit_reply = state
            .upload_commit(Request::new(UploadControlRequest {
                token: String::new(),
                upload_id: upload_id.clone(),
            }))
            .await
            .expect("upload commit")
            .into_inner();
        assert!(commit_reply.ok);
        assert_eq!(
            std::fs::read_to_string(dir.path().join("uploads/demo.txt"))
                .expect("read first upload"),
            "hello"
        );

        let overwrite_init_reply = state
            .upload_init(Request::new(UploadInitRequest {
                token: String::new(),
                path: "uploads/demo.txt".to_string(),
                overwrite: true,
                expected_size: 5,
            }))
            .await
            .expect("overwrite init")
            .into_inner();
        assert!(overwrite_init_reply.ok);

        let overwrite_upload_id = overwrite_init_reply
            .data
            .get("upload_id")
            .cloned()
            .expect("overwrite upload id");

        let overwrite_chunk_reply = state
            .upload_chunk(Request::new(UploadChunkRequest {
                token: String::new(),
                upload_id: overwrite_upload_id.clone(),
                offset: 0,
                content: b"world".to_vec(),
            }))
            .await
            .expect("overwrite chunk")
            .into_inner();
        assert!(overwrite_chunk_reply.ok);

        let overwrite_commit_reply = state
            .upload_commit(Request::new(UploadControlRequest {
                token: String::new(),
                upload_id: overwrite_upload_id,
            }))
            .await
            .expect("overwrite commit")
            .into_inner();
        assert!(overwrite_commit_reply.ok);
        assert_eq!(
            std::fs::read_to_string(dir.path().join("uploads/demo.txt"))
                .expect("read overwritten upload"),
            "world"
        );
    }

    #[tokio::test]
    async fn upload_rejects_bad_offset() {
        let dir = tempdir().expect("tempdir");
        let state = RemoteOpsState::new(dir.path().to_path_buf(), String::new());

        let init_reply = state
            .upload_init(Request::new(UploadInitRequest {
                token: String::new(),
                path: "uploads/demo.txt".to_string(),
                overwrite: true,
                expected_size: 5,
            }))
            .await
            .expect("upload init")
            .into_inner();
        let upload_id = init_reply
            .data
            .get("upload_id")
            .cloned()
            .expect("upload id");

        let chunk_reply = state
            .upload_chunk(Request::new(UploadChunkRequest {
                token: String::new(),
                upload_id,
                offset: 2,
                content: b"hello".to_vec(),
            }))
            .await
            .expect("upload chunk")
            .into_inner();

        assert!(!chunk_reply.ok);
        assert!(chunk_reply.error.contains("Unexpected upload offset"));
    }

    #[tokio::test]
    async fn file_rpc_reads_expected_content() {
        let dir = tempdir().expect("tempdir");
        std::fs::write(dir.path().join("sample.log"), "alpha\nbeta\nERROR line\n")
            .expect("write sample");
        let state = RemoteOpsState::new(dir.path().to_path_buf(), String::new());

        let read_reply = state
            .read_file(Request::new(ReadFileRequest {
                token: String::new(),
                path: "sample.log".to_string(),
                max_bytes: 1024,
            }))
            .await
            .expect("read file")
            .into_inner();
        assert!(read_reply.ok);
        assert!(read_reply.data["content"].contains("ERROR line"));

        let grep_reply = state
            .grep_file(Request::new(GrepFileRequest {
                token: String::new(),
                path: "sample.log".to_string(),
                needle: "ERROR".to_string(),
                max_matches: 10,
                max_line_length: 1024,
            }))
            .await
            .expect("grep file")
            .into_inner();
        assert!(grep_reply.ok);
        assert_eq!(grep_reply.data["matches"], "3:ERROR line\n");

        let list_reply = state
            .list_dir(Request::new(PathRequest {
                token: String::new(),
                path: ".".to_string(),
            }))
            .await
            .expect("list dir")
            .into_inner();
        assert!(list_reply.ok);
        assert!(list_reply.data["items"].contains("sample.log"));
    }
}
