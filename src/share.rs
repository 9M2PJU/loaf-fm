use crate::archive;
use crate::util;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct ShareItem {
    pub id: String,
    pub name: String,
    pub original_path: String,
    pub file_path: String,
    pub is_archive: bool,
    pub size_bytes: u64,
    pub created_at: u64,
    pub expires_at: u64, // 0 if no expiration
    pub port: u16,
    pub url: String,
    pub status: String, // "starting", "ready", "error", "expired"
    pub error_message: Option<String>,
    pub bytes_sent: u64,
    pub download_count: u32,
    #[serde(skip)]
    pub temp_file_to_delete: Option<PathBuf>,
}

pub struct ShareManager {
    shares: Mutex<HashMap<String, ShareItem>>,
    handles: Mutex<HashMap<String, ActiveShareHandle>>,
    cloudflared_installing: AtomicBool,
}

struct ActiveShareHandle {
    stop_flag: Arc<AtomicBool>,
    bytes_sent: Arc<AtomicU64>,
    child_process: Option<Child>,
    temp_file: Option<PathBuf>,
}

static MANAGER: OnceLock<ShareManager> = OnceLock::new();

pub fn get_manager() -> &'static ShareManager {
    MANAGER.get_or_init(|| ShareManager {
        shares: Mutex::new(HashMap::new()),
        handles: Mutex::new(HashMap::new()),
        cloudflared_installing: AtomicBool::new(false),
    })
}

/// Stop every active share. Called on application exit so background
/// HTTP listeners and tunnel processes don't outlive the UI.
pub fn shutdown_all() {
    let ids: Vec<String> = {
        let guard = get_manager().shares.lock().unwrap();
        guard.keys().cloned().collect()
    };
    for id in ids {
        get_manager().stop_share(&id);
    }
}

/// Find cloudflared binary, checking system PATH, then ~/.local/share/loaf/bin/cloudflared
pub fn find_cloudflared() -> Option<PathBuf> {
    if let Some(p) = util::which("cloudflared") {
        return Some(p);
    }
    let local = util::data_home().join("loaf/bin/cloudflared");
    if local.is_file() {
        return Some(local);
    }
    None
}

pub fn is_cloudflared_installed() -> bool {
    find_cloudflared().is_some()
}

/// Downloads and installs cloudflared asynchronously if not already installed.
pub fn ensure_cloudflared_installed(on_complete: Box<dyn FnOnce(bool, String) + Send + 'static>) {
    if is_cloudflared_installed() {
        on_complete(true, String::new());
        return;
    }

    let mgr = get_manager();
    if mgr.cloudflared_installing.swap(true, Ordering::SeqCst) {
        on_complete(false, "Installation already in progress".into());
        return;
    }

    thread::spawn(move || {
        let res = install_cloudflared_sync();
        get_manager().cloudflared_installing.store(false, Ordering::SeqCst);
        match res {
            Ok(path) => on_complete(true, path.to_string_lossy().to_string()),
            Err(e) => on_complete(false, e),
        }
    });
}

fn install_cloudflared_sync() -> Result<PathBuf, String> {
    let dest_dir = util::data_home().join("loaf/bin");
    std::fs::create_dir_all(&dest_dir).map_err(|e| format!("Failed to create bin dir: {}", e))?;
    let dest_bin = dest_dir.join("cloudflared");
    let tmp_bin = dest_dir.join("cloudflared.tmp");

    let arch = match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        "arm" => "arm",
        other => return Err(format!("Unsupported architecture: {}", other)),
    };

    let url = format!(
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-{}",
        arch
    );

    // Try using curl, python3, or wget
    let downloaded = if let Some(curl) = util::which("curl") {
        let status = Command::new(curl)
            .args(["-fsSL", "-o", tmp_bin.to_str().unwrap(), &url])
            .status();
        matches!(status, Ok(s) if s.success())
    } else if let Some(wget) = util::which("wget") {
        let status = Command::new(wget)
            .args(["-q", "-O", tmp_bin.to_str().unwrap(), &url])
            .status();
        matches!(status, Ok(s) if s.success())
    } else if let Some(py) = util::which("python3") {
        let py_script = format!(
            "import urllib.request\nreq = urllib.request.Request('{}', headers={{'User-Agent': 'loaf/0.2'}})\nwith urllib.request.urlopen(req) as r, open('{}', 'wb') as f:\n    f.write(r.read())",
            url, tmp_bin.to_str().unwrap()
        );
        let status = Command::new(py).args(["-c", &py_script]).status();
        matches!(status, Ok(s) if s.success())
    } else {
        return Err("Neither curl, wget, nor python3 was found to download cloudflared".into());
    };

    if !downloaded || !tmp_bin.exists() {
        let _ = std::fs::remove_file(&tmp_bin);
        return Err("Download failed".into());
    }

    // Set executable permission (0o755)
    if let Ok(meta) = std::fs::metadata(&tmp_bin) {
        let mut perms = meta.permissions();
        perms.set_mode(0o755);
        let _ = std::fs::set_permissions(&tmp_bin, perms);
    }

    std::fs::rename(&tmp_bin, &dest_bin).map_err(|e| format!("Failed to move binary: {}", e))?;
    Ok(dest_bin)
}

impl ShareManager {
    pub fn list_shares_json(&self) -> String {
        let mut shares: Vec<ShareItem> = {
            let guard = self.shares.lock().unwrap();
            guard.values().cloned().collect()
        };

        // Update real-time stats
        {
            let handles = self.handles.lock().unwrap();
            for s in &mut shares {
                if let Some(h) = handles.get(&s.id) {
                    s.bytes_sent = h.bytes_sent.load(Ordering::Relaxed);
                }
            }
        }

        // Sort newest first
        shares.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        serde_json::to_string(&shares).unwrap_or_else(|_| "[]".into())
    }

    pub fn stop_share(&self, share_id: &str) -> bool {
        let mut h_guard = self.handles.lock().unwrap();
        if let Some(mut handle) = h_guard.remove(share_id) {
            handle.stop_flag.store(true, Ordering::SeqCst);
            if let Some(mut child) = handle.child_process.take() {
                let _ = child.kill();
            }
            if let Some(tmp) = handle.temp_file.take() {
                let _ = std::fs::remove_file(tmp);
            }
        }

        let mut s_guard = self.shares.lock().unwrap();
        if let Some(s) = s_guard.get_mut(share_id) {
            s.status = "expired".into();
            return true;
        }
        false
    }

    pub fn remove_share(&self, share_id: &str) -> bool {
        self.stop_share(share_id);
        let mut s_guard = self.shares.lock().unwrap();
        s_guard.remove(share_id).is_some()
    }
}

pub struct CreateShareParams {
    pub paths: Vec<PathBuf>,
    pub compress_folders: bool,
    pub compress_files: bool,
    pub format: String,
    pub password: String,
    pub expiration_hours: u32, // 0 for none
    pub throttle_kbps: u32,    // 0 for unlimited
    pub lan_only: bool,         // serve on the local network, no Cloudflare Tunnel
}

/// Spawns the sharing pipeline in background thread.
/// Calls on_url(Result<(share_id, url), error>) when ready or on error.
pub fn start_share_pipeline<F>(params: CreateShareParams, on_url: F)
where
    F: FnOnce(Result<(String, String), String>) + Send + 'static,
{
    thread::spawn(move || {
        let res = run_share_pipeline(params);
        match res {
            Ok((id, url)) => on_url(Ok((id, url))),
            Err(e) => on_url(Err(e)),
        }
    });
}

fn run_share_pipeline(params: CreateShareParams) -> Result<(String, String), String> {
    if params.paths.is_empty() {
        return Err("No files selected".into());
    }

    // Internet shares need the tunnel daemon; LAN shares serve directly.
    let cloudflared_bin = if params.lan_only {
        None
    } else {
        Some(find_cloudflared().ok_or("cloudflared is not installed".to_string())?)
    };

    // Wi-Fi / LAN shares are browsable: never archive, always serve the
    // original files with a modern index page. Internet shares keep the
    // previous single-file/archive download behaviour.
    if params.lan_only {
        return run_wifi_pipeline(params);
    }

    // Determine target file to serve (internet shares only)
    let single = params.paths.len() == 1;
    let single_path = &params.paths[0];
    let is_dir = single_path.is_dir();

    let needs_archive = if !single {
        true
    } else if is_dir {
        params.compress_folders
    } else {
        params.compress_files
    };

    let (file_to_serve, serve_name, temp_file) = if needs_archive {
        let base = if single {
            if is_dir {
                single_path
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string()
            } else {
                single_path
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string()
            }
        } else {
            "Shared_Files".to_string()
        };

        let ext = match params.format.as_str() {
            "7z" => "7z",
            "tar.gz" => "tar.gz",
            _ => "zip",
        };

        let temp_dir = std::env::temp_dir().join(format!("loaf-share-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&temp_dir);
        let archive_target = temp_dir.join(format!("{}.{}", base, ext));

        // Create the archive
        archive::compress(
            &archive_target,
            &params.paths,
            &params.format,
            &params.password,
            &|| false,
        )
        .map_err(|e| format!("Compression failed: {}", e))?;

        let name = format!("{}.{}", base, ext);
        (archive_target.clone(), name, Some(archive_target))
    } else {
        let name = single_path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        (single_path.clone(), name, None)
    };

    let file_meta = std::fs::metadata(&file_to_serve).map_err(|e| e.to_string())?;
    let file_size = file_meta.len();

    // Internet shares stay on loopback behind the Cloudflare Tunnel.
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("Failed to bind local port: {}", e))?;
    let local_port = listener.local_addr().map_err(|e| e.to_string())?.port();

    let share_id = format!(
        "{:x}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );
    let token = format!("{:x}", rand_u64());

    let now_sec = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let expires_at = if params.expiration_hours > 0 {
        now_sec + (params.expiration_hours as u64) * 3600
    } else {
        0
    };

    let stop_flag = Arc::new(AtomicBool::new(false));
    let bytes_sent = Arc::new(AtomicU64::new(0));

    // Register initial share item in manager
    let item = ShareItem {
        id: share_id.clone(),
        name: serve_name.clone(),
        original_path: single_path.to_string_lossy().to_string(),
        file_path: file_to_serve.to_string_lossy().to_string(),
        is_archive: needs_archive,
        size_bytes: file_size,
        created_at: now_sec,
        expires_at,
        port: local_port,
        url: String::new(),
        status: "starting".into(),
        error_message: None,
        bytes_sent: 0,
        download_count: 0,
        temp_file_to_delete: temp_file.clone(),
    };

    {
        let mut guard = get_manager().shares.lock().unwrap();
        guard.insert(share_id.clone(), item);
    }

    // Spawn HTTP file server thread
    let srv_file = file_to_serve.clone();
    let srv_name = serve_name.clone();
    let srv_stop = stop_flag.clone();
    let srv_bytes = bytes_sent.clone();
    let srv_token = token.clone();
    let srv_throttle = params.throttle_kbps;
    let srv_share_id = share_id.clone();

    thread::spawn(move || {
        run_file_server(
            listener,
            srv_file,
            srv_name,
            srv_token,
            srv_throttle,
            srv_stop,
            srv_bytes,
            srv_share_id,
        );
    });

    // Spawn cloudflared tunnel (internet shares only).
    let mut cloudflared_cmd = Command::new(cloudflared_bin.unwrap());
    cloudflared_cmd
        .args([
            "tunnel",
            "--url",
            &format!("http://127.0.0.1:{}", local_port),
            "--no-autoupdate",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = cloudflared_cmd
        .spawn()
        .map_err(|e| format!("Failed to spawn cloudflared: {}", e))?;

    let stderr = child
        .stderr
        .take()
        .ok_or("Failed to capture cloudflared stderr")?;

    // Read stderr until we find https://*.trycloudflare.com
    let (url_tx, url_rx) = std::sync::mpsc::channel();
    let stop_for_reader = stop_flag.clone();

    thread::spawn(move || {
        let reader = BufReader::new(stderr);
        let mut found = false;
        for line in reader.lines().flatten() {
            if !found {
                for word in line.split_whitespace() {
                    if (word.starts_with("https://") && word.contains(".trycloudflare.com"))
                        || (word.starts_with("http://") && word.contains(".trycloudflare.com"))
                    {
                        let mut clean_url = word.trim().to_string();
                        if clean_url.ends_with('|') || clean_url.ends_with(']') {
                            clean_url.pop();
                        }
                        let _ = url_tx.send(Ok(clean_url));
                        found = true;
                        break;
                    }
                }
            }
            if stop_for_reader.load(Ordering::Relaxed) {
                break;
            }
        }
        if !found {
            let _ = url_tx.send(Err("Tunnel did not produce a public URL".into()));
        }
    });

    let tunnel_base_url = match url_rx.recv_timeout(Duration::from_secs(30)) {
        Ok(Ok(u)) => u,
        Ok(Err(e)) => {
            let _ = child.kill();
            get_manager().stop_share(&share_id);
            return Err(e);
        }
        Err(_) => {
            let _ = child.kill();
            get_manager().stop_share(&share_id);
            return Err("Timed out waiting for Cloudflare Tunnel to connect".into());
        }
    };

    let direct_url = format!("{}/download/{}", tunnel_base_url, token);

    // Save active handle
    {
        let mut h_guard = get_manager().handles.lock().unwrap();
        h_guard.insert(
            share_id.clone(),
            ActiveShareHandle {
                stop_flag: stop_flag.clone(),
                bytes_sent: bytes_sent.clone(),
                child_process: Some(child),
                temp_file,
            },
        );
    }

    // Update share record with final URL and ready status
    {
        let mut s_guard = get_manager().shares.lock().unwrap();
        if let Some(s) = s_guard.get_mut(&share_id) {
            s.url = direct_url.clone();
            s.status = "ready".into();
        }
    }

    // If expiration configured, spawn background timer to auto-close
    if params.expiration_hours > 0 {
        let exp_id = share_id.clone();
        let exp_hours = params.expiration_hours;
        thread::spawn(move || {
            thread::sleep(Duration::from_secs((exp_hours as u64) * 3600));
            get_manager().stop_share(&exp_id);
        });
    }

    Ok((share_id, direct_url))
}

/// Wi-Fi pipeline: serve the original files browsably on the LAN with a
/// modern index page. No archiving, no tunnel.
fn run_wifi_pipeline(params: CreateShareParams) -> Result<(String, String), String> {
    // Keep only paths that still exist; symlinks are followed by the server
    // but never allowed to escape their shared root.
    let mut roots: Vec<PathBuf> = params
        .paths
        .into_iter()
        .filter(|p| std::fs::symlink_metadata(p).is_ok())
        .collect();
    if roots.is_empty() {
        return Err("No files selected".into());
    }
    roots.sort();
    roots.dedup();

    let single = roots.len() == 1;
    let display_name = if single {
        roots[0]
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| roots[0].to_string_lossy().to_string())
    } else {
        format!("{} items", roots.len())
    };

    let size_bytes = if single && roots[0].is_file() {
        std::fs::metadata(&roots[0]).map(|m| m.len()).unwrap_or(0)
    } else {
        0
    };

    let listener = TcpListener::bind("0.0.0.0:0")
        .map_err(|e| format!("Failed to bind local port: {}", e))?;
    let local_port = listener.local_addr().map_err(|e| e.to_string())?.port();

    let share_id = format!(
        "{:x}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );
    // Short hex token: easy to type on a phone, still unguessable on LAN.
    let token = format!("{:012x}", rand_u64() & 0xffff_ffff_ffff);

    let now_sec = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let expires_at = if params.expiration_hours > 0 {
        now_sec + (params.expiration_hours as u64) * 3600
    } else {
        0
    };

    let stop_flag = Arc::new(AtomicBool::new(false));
    let bytes_sent = Arc::new(AtomicU64::new(0));

    let item = ShareItem {
        id: share_id.clone(),
        name: display_name.clone(),
        original_path: roots[0].to_string_lossy().to_string(),
        file_path: roots[0].to_string_lossy().to_string(),
        is_archive: false,
        size_bytes,
        created_at: now_sec,
        expires_at,
        port: local_port,
        url: String::new(),
        status: "starting".into(),
        error_message: None,
        bytes_sent: 0,
        download_count: 0,
        temp_file_to_delete: None,
    };
    {
        let mut guard = get_manager().shares.lock().unwrap();
        guard.insert(share_id.clone(), item);
    }

    let srv_roots = roots.clone();
    let srv_name = display_name.clone();
    thread::spawn({
        let srv_stop = stop_flag.clone();
        let srv_bytes = bytes_sent.clone();
        let srv_token = token.clone();
        let srv_share_id = share_id.clone();
        let srv_throttle = params.throttle_kbps;
        move || {
            run_wifi_server(
                listener,
                srv_roots,
                srv_name,
                srv_token,
                srv_throttle,
                srv_stop,
                srv_bytes,
                srv_share_id,
            );
        }
    });

    let url = format!(
        "http://{}:{}/s/{}/",
        crate::dlna::lan_ip(),
        local_port,
        token
    );

    {
        let mut h_guard = get_manager().handles.lock().unwrap();
        h_guard.insert(
            share_id.clone(),
            ActiveShareHandle {
                stop_flag: stop_flag.clone(),
                bytes_sent: bytes_sent.clone(),
                child_process: None,
                temp_file: None,
            },
        );
    }
    {
        let mut s_guard = get_manager().shares.lock().unwrap();
        if let Some(s) = s_guard.get_mut(&share_id) {
            s.url = url.clone();
            s.status = "ready".into();
        }
    }

    if params.expiration_hours > 0 {
        let exp_id = share_id.clone();
        let exp_hours = params.expiration_hours;
        thread::spawn(move || {
            thread::sleep(Duration::from_secs((exp_hours as u64) * 3600));
            get_manager().stop_share(&exp_id);
        });
    }

    Ok((share_id, url))
}

fn rand_u64() -> u64 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let pid = std::process::id() as u64;
    now.as_nanos() as u64 ^ (pid << 32) ^ (now.as_nanos() as u64 >> 17)
}

// ---------------------------------------------------------------------------
// Internet single-file server (unchanged behaviour)
// ---------------------------------------------------------------------------

fn run_file_server(
    listener: TcpListener,
    file_path: PathBuf,
    filename: String,
    token: String,
    throttle_kbps: u32,
    stop_flag: Arc<AtomicBool>,
    bytes_sent: Arc<AtomicU64>,
    share_id: String,
) {
    listener
        .set_nonblocking(true)
        .expect("Cannot set non-blocking");

    while !stop_flag.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                let file = file_path.clone();
                let fname = filename.clone();
                let tok = token.clone();
                let b_sent = bytes_sent.clone();
                let s_id = share_id.clone();

                thread::spawn(move || {
                    handle_http_client(stream, file, fname, tok, throttle_kbps, b_sent, s_id);
                });
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(_) => break,
        }
    }
}

fn handle_http_client(
    mut stream: TcpStream,
    file_path: PathBuf,
    filename: String,
    token: String,
    throttle_kbps: u32,
    bytes_sent: Arc<AtomicU64>,
    share_id: String,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let mut reader = BufReader::new(&stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() || request_line.is_empty() {
        return;
    }

    let parts: Vec<&str> = request_line.split_whitespace().collect();
    if parts.len() < 2 || parts[0] != "GET" && parts[0] != "HEAD" {
        let resp = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n";
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    let is_head = parts[0] == "HEAD";
    let path = parts[1];
    let expected_path = format!("/download/{}", token);

    if path != expected_path && path != format!("{}/", expected_path) {
        let resp = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nNot Found";
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    let Ok(mut file) = File::open(&file_path) else {
        let resp = "HTTP/1.1 500 Internal Error\r\nContent-Length: 0\r\n\r\n";
        let _ = stream.write_all(resp.as_bytes());
        return;
    };

    let total_size = file.metadata().map(|m| m.len()).unwrap_or(0);

    // Escape quotation marks in filename for Content-Disposition
    let safe_name = filename.replace('"', "\\\"");

    let headers = format!(
        "HTTP/1.1 200 OK\r\n\
        Content-Type: application/octet-stream\r\n\
        Content-Length: {}\r\n\
        Content-Disposition: attachment; filename=\"{}\"\r\n\
        Connection: close\r\n\r\n",
        total_size, safe_name
    );

    if stream.write_all(headers.as_bytes()).is_err() || is_head {
        return;
    }

    // Increment download count
    {
        let mut s_guard = get_manager().shares.lock().unwrap();
        if let Some(s) = s_guard.get_mut(&share_id) {
            s.download_count += 1;
        }
    }

    // Stream file data
    let chunk_size = 64 * 1024; // 64 KB
    let mut buf = vec![0u8; chunk_size];

    loop {
        let start = Instant::now();
        match file.read(&mut buf) {
            Ok(0) => break, // EOF
            Ok(n) => {
                if stream.write_all(&buf[..n]).is_err() {
                    break;
                }
                bytes_sent.fetch_add(n as u64, Ordering::Relaxed);

                // Throttling
                if throttle_kbps > 0 {
                    let target_duration = Duration::from_micros(
                        ((n as u64) * 8 * 1_000_000) / ((throttle_kbps as u64) * 1000 * 8),
                    );
                    let elapsed = start.elapsed();
                    if target_duration > elapsed {
                        thread::sleep(target_duration - elapsed);
                    }
                }
            }
            Err(_) => break,
        }
    }
}

// ---------------------------------------------------------------------------
// Wi-Fi browsing server with modern index UI
// ---------------------------------------------------------------------------

fn run_wifi_server(
    listener: TcpListener,
    roots: Vec<PathBuf>,
    display_name: String,
    token: String,
    throttle_kbps: u32,
    stop_flag: Arc<AtomicBool>,
    bytes_sent: Arc<AtomicU64>,
    share_id: String,
) {
    listener
        .set_nonblocking(true)
        .expect("Cannot set non-blocking");

    while !stop_flag.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                let r = roots.clone();
                let name = display_name.clone();
                let tok = token.clone();
                let b = bytes_sent.clone();
                let sid = share_id.clone();
                thread::spawn(move || {
                    handle_wifi_client(stream, r, name, tok, throttle_kbps, b, sid);
                });
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(_) => break,
        }
    }
}

fn handle_wifi_client(
    mut stream: TcpStream,
    roots: Vec<PathBuf>,
    display_name: String,
    token: String,
    throttle_kbps: u32,
    bytes_sent: Arc<AtomicU64>,
    share_id: String,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let Ok(reader_stream) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(reader_stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() || request_line.trim().is_empty() {
        return;
    }
    let mut headers: HashMap<String, String> = HashMap::new();
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
                let t = line.trim();
                if t.is_empty() {
                    break;
                }
                if let Some((k, v)) = t.split_once(':') {
                    headers.insert(k.trim().to_lowercase(), v.trim().to_string());
                }
            }
            Err(_) => break,
        }
    }
    drop(reader);

    let parts: Vec<&str> = request_line.split_whitespace().collect();
    if parts.len() < 2 {
        let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    let method = parts[0];
    if method != "GET" && method != "HEAD" {
        let _ = stream.write_all(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    let is_head = method == "HEAD";
    let raw_target = parts[1];
    let (raw_path, raw_query) = match raw_target.split_once('?') {
        Some((p, q)) => (p, q),
        None => (raw_target, ""),
    };
    let path = url_decode(raw_path);

    // / -> redirect to the share root so typing IP:port just works.
    if path == "/" {
        let loc = format!("/s/{}/", token);
        let resp = format!(
            "HTTP/1.1 302 Found\r\nLocation: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            loc
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }
    if path == "/favicon.ico" {
        let _ = stream.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }

    // Legacy single-file URL: /download/<token> -> redirect to the index.
    if path == format!("/download/{}", token) || path == format!("/download/{}/", token) {
        if roots.len() == 1 && roots[0].is_file() {
            let fname = file_name_of(&roots[0]);
            let loc = format!("/s/{}/{}", token, url_encode(&fname));
            let resp = format!(
                "HTTP/1.1 302 Found\r\nLocation: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                loc
            );
            let _ = stream.write_all(resp.as_bytes());
        } else {
            let loc = format!("/s/{}/", token);
            let resp = format!(
                "HTTP/1.1 302 Found\r\nLocation: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                loc
            );
            let _ = stream.write_all(resp.as_bytes());
        }
        return;
    }

    let prefix = format!("/s/{}", token);
    if path != prefix && path != format!("{}/", prefix) && !path.starts_with(&format!("{}/", prefix)) {
        write_404(&mut stream);
        return;
    }
    let mut rel = path[prefix.len()..].to_string();
    if rel.starts_with('/') {
        rel = rel[1..].to_string();
    }
    // Strip trailing slash for resolution (but remember it was a dir URL).
    let rel = rel.trim_end_matches('/').to_string();
    let rel_decoded = url_decode(&rel);
    let force_download = raw_query.contains("download");

    match resolve_wifi_path(&roots, &rel_decoded) {
        WifiResolved::IndexVirtual => {
            let html = render_virtual_root(&display_name, &token, &roots);
            write_html(&mut stream, &html, is_head);
        }
        WifiResolved::Dir { real, crumbs, entries } => {
            let base_href = if rel_decoded.is_empty() {
                format!("/s/{}/", token)
            } else {
                format!("/s/{}/{}/", token, url_encode_path(&rel_decoded))
            };
            let html = render_dir_page(&display_name, &token, &crumbs, &base_href, &entries, force_download);
            let _ = real; // kept for future dir-size totals
            write_html(&mut stream, &html, is_head);
        }
        WifiResolved::File { real } => {
            // If the client wants HTML (browser navigation) and this is a
            // single-file share root, show the index instead of the bytes.
            // Direct file links always carry ?download or come from the
            // file row, so this only affects typing the share URL.
            let wants_html = !force_download
                && rel_decoded.is_empty()
                && roots.len() == 1
                && header_accepts_html(headers.get("accept"));
            if wants_html {
                let entries = vec![dir_entry_of(&real)];
                let crumbs = vec![display_name.clone()];
                let base_href = format!("/s/{}/", token);
                let html = render_dir_page(&display_name, &token, &crumbs, &base_href, &entries, false);
                write_html(&mut stream, &html, is_head);
                return;
            }
            serve_wifi_file(&mut stream, &real, headers.get("range"), throttle_kbps, &bytes_sent, &share_id, is_head, force_download);
        }
        WifiResolved::NotFound => write_404(&mut stream),
        WifiResolved::Forbidden => write_403(&mut stream),
    }
}

enum WifiResolved {
    IndexVirtual,
    Dir { real: PathBuf, crumbs: Vec<String>, entries: Vec<DirEntry> },
    File { real: PathBuf },
    NotFound,
    Forbidden,
}

#[derive(Clone, Debug)]
struct DirEntry {
    name: String,
    href: String,
    is_dir: bool,
    size: u64,
    modified: String,
    modified_secs: u64,
}

fn resolve_wifi_path(roots: &[PathBuf], rel: &str) -> WifiResolved {
    // Reject absolute paths and parent escapes lexically first.
    if rel.starts_with('/') {
        return WifiResolved::Forbidden;
    }
    let mut parts: Vec<String> = Vec::new();
    for comp in Path::new(rel).components() {
        match comp {
            Component::Normal(s) => parts.push(s.to_string_lossy().to_string()),
            Component::CurDir => {}
            Component::ParentDir => return WifiResolved::Forbidden,
            Component::RootDir | Component::Prefix(_) => return WifiResolved::Forbidden,
        }
    }

    if roots.len() == 1 {
        let root = &roots[0];
        if root.is_file() {
            if parts.is_empty() {
                return WifiResolved::File { real: root.clone() };
            }
            // Allow /s/<token>/<filename> as a direct file link.
            if parts.len() == 1 && parts[0] == file_name_of(root) {
                return WifiResolved::File { real: root.clone() };
            }
            return WifiResolved::NotFound;
        }
        // Single dir: rel is relative inside it.
        let mut real = root.clone();
        for p in &parts {
            real.push(p);
        }
        // Lexical containment: canonicalize when possible.
        if let (Ok(c_root), Ok(c_real)) = (root.canonicalize(), real.canonicalize()) {
            if !c_real.starts_with(&c_root) {
                return WifiResolved::Forbidden;
            }
            if c_real.is_dir() {
                let entries = list_dir(&c_real, &prefix_for(&parts));
                let mut crumbs = vec![root_name(root)];
                crumbs.extend(parts.clone());
                return WifiResolved::Dir { real: c_real, crumbs, entries };
            }
            if c_real.is_file() {
                return WifiResolved::File { real: c_real };
            }
            return WifiResolved::NotFound;
        }
        // Uncanonicalizable (broken symlink etc.): only allow if it exists lexically under root.
        if real.is_dir() {
            let entries = list_dir(&real, &prefix_for(&parts));
            let mut crumbs = vec![root_name(root)];
            crumbs.extend(parts.clone());
            return WifiResolved::Dir { real, crumbs, entries };
        }
        if real.is_file() {
            return WifiResolved::File { real };
        }
        return WifiResolved::NotFound;
    }

    // Multi-root virtual tree: /s/<token>/ -> roots, /s/<token>/<idx>/... -> inside root idx.
    if parts.is_empty() {
        return WifiResolved::IndexVirtual;
    }
    let idx: usize = match parts[0].parse() {
        Ok(i) => i,
        Err(_) => return WifiResolved::NotFound,
    };
    if idx >= roots.len() {
        return WifiResolved::NotFound;
    }
    let root = &roots[idx];
    if root.is_file() {
        if parts.len() == 1 {
            return WifiResolved::File { real: root.clone() };
        }
        return WifiResolved::NotFound;
    }
    let mut real = root.clone();
    for p in &parts[1..] {
        real.push(p);
    }
    if let (Ok(c_root), Ok(c_real)) = (root.canonicalize(), real.canonicalize()) {
        if !c_real.starts_with(&c_root) {
            return WifiResolved::Forbidden;
        }
        if c_real.is_dir() {
            let entries = list_dir(&c_real, &prefix_for(&parts));
            let mut crumbs = vec!["Shared files".to_string(), root_name(root)];
            crumbs.extend(parts[1..].iter().cloned());
            return WifiResolved::Dir { real: c_real, crumbs, entries };
        }
        if c_real.is_file() {
            return WifiResolved::File { real: c_real };
        }
        return WifiResolved::NotFound;
    }
    if real.is_dir() {
        let entries = list_dir(&real, &prefix_for(&parts));
        let mut crumbs = vec!["Shared files".to_string(), root_name(root)];
        crumbs.extend(parts[1..].iter().cloned());
        return WifiResolved::Dir { real, crumbs, entries };
    }
    if real.is_file() {
        return WifiResolved::File { real };
    }
    WifiResolved::NotFound
}

fn prefix_for(parts: &[String]) -> String {
    parts.join("/")
}

fn root_name(root: &Path) -> String {
    root.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| root.to_string_lossy().to_string())
}

fn file_name_of(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "download".to_string())
}

fn dir_entry_of(p: &Path) -> DirEntry {
    let meta = std::fs::symlink_metadata(p);
    let (size, modified, modified_secs, is_dir) = match meta {
        Ok(m) => {
            let ft = m.file_type();
            let is_dir = ft.is_dir();
            let size = if is_dir { 0 } else { m.len() };
            let (txt, secs) = fmt_mtime(&m);
            (size, txt, secs, is_dir)
        }
        Err(_) => (0, String::from("—"), 0, false),
    };
    DirEntry {
        name: file_name_of(p),
        href: String::new(),
        is_dir,
        size,
        modified,
        modified_secs,
    }
}

fn list_dir(dir: &Path, rel_prefix: &str) -> Vec<DirEntry> {
    let mut out: Vec<DirEntry> = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else { return out };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if name.is_empty() {
            continue;
        }
        let ft = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
        let is_dir = ft || p.is_dir();
        let (size, modified, modified_secs) = match std::fs::symlink_metadata(&p) {
            Ok(m) => {
                let s = if is_dir { 0 } else { m.len() };
                let (txt, secs) = fmt_mtime(&m);
                (s, txt, secs)
            }
            Err(_) => (0, String::from("—"), 0),
        };
        let href_rel = if rel_prefix.is_empty() {
            name.clone()
        } else {
            format!("{}/{}", rel_prefix, name)
        };
        out.push(DirEntry {
            name,
            href: url_encode_path(&href_rel),
            is_dir,
            size,
            modified,
            modified_secs,
        });
    }
    out.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });
    out
}

fn fmt_mtime(m: &std::fs::Metadata) -> (String, u64) {
    let (txt, secs) = match m.modified() {
        Ok(t) => {
            let d = t.duration_since(UNIX_EPOCH).unwrap_or_default();
            let secs = d.as_secs();
            // Format as YYYY-MM-DD HH:MM in local time via /etc/localtime is
            // overkill here; show a short relative/absolute mix using libc
            // localtime through `date`-style manual formatting is avoided to
            // keep this dependency-free: use days + time from epoch UTC.
            // Human-readable enough for a LAN page; QML shows exact dates.
            let days = secs / 86400;
            let (y, mo, dday) = days_to_ymd(days);
            let hh = (secs % 86400) / 3600;
            let mm = (secs % 3600) / 60;
            (format!("{:04}-{:02}-{:02} {:02}:{:02}", y, mo, dday, hh, mm), secs)
        }
        Err(_) => (String::from("—"), 0),
    };
    (txt, secs)
}

// Days since 1970-01-01 -> (y,m,d). Howard Hinnant's civil_from_days.
fn days_to_ymd(z: u64) -> (i32, u32, u32) {
    let z = z as i64 + 719468;
    let era = if z >= 0 { z } else { z - 146096 };
    let doe = (era - era / 146097 * 146097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe as i64 + era / 146097 * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y } as i32, m, d)
}

fn header_accepts_html(accept: Option<&String>) -> bool {
    match accept {
        Some(a) => a.contains("text/html"),
        None => false,
    }
}

fn serve_wifi_file(
    stream: &mut TcpStream,
    real: &Path,
    range: Option<&String>,
    throttle_kbps: u32,
    bytes_sent: &Arc<AtomicU64>,
    share_id: &str,
    is_head: bool,
    force_download: bool,
) {
    let Ok(meta) = std::fs::metadata(real) else {
        let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    if !meta.is_file() {
        let _ = stream.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    let total = meta.len();
    let fname = file_name_of(real);
    let mime = guess_mime(&fname);
    let disp = if force_download || !is_viewable(&mime) {
        format!("attachment; filename=\"{}\"", fname.replace('"', "_"))
    } else {
        format!("inline; filename=\"{}\"", fname.replace('"', "_"))
    };

    // Range support for video/audio seeking on phones.
    let (start, end, partial) = parse_range(range, total);

    let Ok(mut file) = File::open(real) else {
        let _ = stream.write_all(b"HTTP/1.1 500 Internal Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    {
        use std::io::Seek;
        use std::io::SeekFrom;
        let _ = file.seek(SeekFrom::Start(start));
    }
    let len = end.saturating_sub(start) + if total > 0 { 1 } else { 0 };
    let len = if total == 0 { 0 } else { len.min(total - start) };

    let header = if partial {
        format!(
            "HTTP/1.1 206 Partial Content\r\nContent-Type: {}\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nContent-Disposition: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
            mime, len, start, start + len - 1, total, disp
        )
    } else {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nContent-Disposition: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
            mime, total, disp
        )
    };
    if stream.write_all(header.as_bytes()).is_err() || is_head {
        return;
    }

    {
        let mut s_guard = get_manager().shares.lock().unwrap();
        if let Some(s) = s_guard.get_mut(share_id) {
            s.download_count += 1;
        }
    }

    let mut remaining = if partial { len } else { total };
    let mut buf = vec![0u8; 64 * 1024];
    while remaining > 0 {
        let want = (buf.len() as u64).min(remaining) as usize;
        let start_t = Instant::now();
        match file.read(&mut buf[..want]) {
            Ok(0) => break,
            Ok(n) => {
                if stream.write_all(&buf[..n]).is_err() {
                    break;
                }
                bytes_sent.fetch_add(n as u64, Ordering::Relaxed);
                remaining -= n as u64;
                if throttle_kbps > 0 {
                    let target = Duration::from_micros(
                        ((n as u64) * 1_000_000) / ((throttle_kbps as u64) * 1024),
                    );
                    let elapsed = start_t.elapsed();
                    if target > elapsed {
                        thread::sleep(target - elapsed);
                    }
                }
            }
            Err(_) => break,
        }
    }
}

fn parse_range(header: Option<&String>, total: u64) -> (u64, u64, bool) {
    let Some(h) = header else { return (0, total.saturating_sub(1), false) };
    let h = h.trim();
    // bytes=START- , bytes=START-END, bytes=-SUFFIX
    let Some(spec) = h.strip_prefix("bytes=") else { return (0, total.saturating_sub(1), false) };
    let spec = spec.split(',').next().unwrap_or("").trim();
    if let Some((s, e)) = spec.split_once('-') {
        if s.is_empty() {
            // suffix: last N bytes
            if let Ok(n) = e.parse::<u64>() {
                if n == 0 || total == 0 {
                    return (0, total.saturating_sub(1), false);
                }
                let n = n.min(total);
                return (total - n, total - 1, true);
            }
        } else if let Ok(start) = s.parse::<u64>() {
            if start >= total {
                return (0, total.saturating_sub(1), false);
            }
            if e.is_empty() {
                return (start, total - 1, true);
            }
            if let Ok(end) = e.parse::<u64>() {
                let end = end.min(total - 1);
                if end >= start {
                    return (start, end, true);
                }
            }
        }
    }
    (0, total.saturating_sub(1), false)
}

fn guess_mime(name: &str) -> &'static str {
    let lower = name.to_lowercase();
    let ext = lower.rsplit('.').next().unwrap_or("");
    match ext {
        "html" | "htm" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" => "application/json",
        "txt" | "md" | "log" | "csv" | "srt" | "vtt" => "text/plain; charset=utf-8",
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "heic" => "image/heic",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "mp4" | "m4v" => "video/mp4",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        "mov" => "video/quicktime",
        "ogv" => "video/ogg",
        "mp3" => "audio/mpeg",
        "ogg" | "oga" => "audio/ogg",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        "m4a" => "audio/mp4",
        "opus" => "audio/opus",
        "zip" => "application/zip",
        "7z" => "application/x-7z-compressed",
        "tar" => "application/x-tar",
        "gz" | "tgz" => "application/gzip",
        "xz" => "application/x-xz",
        "zst" => "application/zstd",
        "rar" => "application/vnd.rar",
        "iso" => "application/x-iso9660-image",
        "epub" => "application/epub+zip",
        "apk" => "application/vnd.android.package-archive",
        _ => "application/octet-stream",
    }
}

fn is_viewable(mime: &str) -> bool {
    mime.starts_with("image/")
        || mime.starts_with("video/")
        || mime.starts_with("audio/")
        || mime.starts_with("text/")
        || mime == "application/pdf"
}

fn write_404(stream: &mut TcpStream) {
    let body = "Not found";
    let resp = format!(
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.write_all(resp.as_bytes());
}

fn write_403(stream: &mut TcpStream) {
    let body = "Forbidden";
    let resp = format!(
        "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.write_all(resp.as_bytes());
}

fn write_html(stream: &mut TcpStream, html: &str, is_head: bool) {
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        html.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    if !is_head {
        let _ = stream.write_all(html.as_bytes());
    }
}

fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

fn url_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.as_bytes().iter().peekable();
    while let Some(&b) = it.next() {
        if b == b'%' {
            let h1 = it.next().copied().unwrap_or(b'0');
            let h2 = it.next().copied().unwrap_or(b'0');
            let hex = |c: u8| match c {
                b'0'..=b'9' => (c - b'0') as u32,
                b'a'..=b'f' => (c - b'a' + 10) as u32,
                b'A'..=b'F' => (c - b'A' + 10) as u32,
                _ => 0,
            };
            let v = hex(h1) * 16 + hex(h2);
            if let Some(ch) = char::from_u32(v) {
                out.push(ch);
            }
        } else if b == b'+' {
            out.push(' ');
        } else {
            out.push(b as char);
        }
    }
    out
}

fn url_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

fn url_encode_path(p: &str) -> String {
    p.split('/')
        .map(|seg| url_encode(seg))
        .collect::<Vec<_>>()
        .join("/")
}

fn format_size(n: u64) -> String {
    const UNITS: &[&str] = &["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut u = 0;
    while v >= 1024.0 && u + 1 < UNITS.len() {
        v /= 1024.0;
        u += 1;
    }
    if u == 0 {
        format!("{} {}", n, UNITS[u])
    } else if v >= 100.0 {
        format!("{:.0} {}", v, UNITS[u])
    } else {
        format!("{:.1} {}", v, UNITS[u])
    }
}

fn file_emoji(name: &str, is_dir: bool) -> &'static str {
    if is_dir {
        return "📁";
    }
    let lower = name.to_lowercase();
    let ext = lower.rsplit('.').next().unwrap_or("");
    match ext {
        "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "ogv" => "🎬",
        "mp3" | "flac" | "wav" | "ogg" | "m4a" | "opus" => "🎵",
        "png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" | "avif" | "bmp" | "heic" => "🖼️",
        "pdf" => "📕",
        "zip" | "7z" | "tar" | "gz" | "xz" | "zst" | "rar" | "tgz" => "📦",
        "txt" | "md" | "log" | "csv" => "📄",
        "doc" | "docx" | "odt" => "📝",
        "xls" | "xlsx" | "ods" => "📊",
        "ppt" | "pptx" | "odp" => "📽️",
        "apk" => "🤖",
        "iso" => "💿",
        "epub" => "📚",
        _ => "📄",
    }
}

fn render_virtual_root(display_name: &str, token: &str, roots: &[PathBuf]) -> String {
    let mut rows = String::new();
    for (i, r) in roots.iter().enumerate() {
        let name = root_name(r);
        let is_dir = r.is_dir();
        let (size_txt, mod_txt) = match std::fs::symlink_metadata(r) {
            Ok(m) => {
                let s = if is_dir { String::from("—") } else { format_size(m.len()) };
                let (t, _) = fmt_mtime(&m);
                (s, t)
            }
            Err(_) => (String::from("—"), String::from("—")),
        };
        rows.push_str(&format!(
            "<tr data-name=\"{}\" data-size=\"{}\" data-time=\"{}\"><td class=\"icon\">{}</td><td class=\"name\"><a href=\"/s/{}/{}/\">{}</a></td><td class=\"size\">{}</td><td class=\"time\">{}</td><td class=\"dl\">{}</td></tr>\n",
            html_escape(&name.to_lowercase()),
            if is_dir { 0 } else { std::fs::metadata(r).map(|m| m.len()).unwrap_or(0) },
            0,
            file_emoji(&name, is_dir),
            token,
            i,
            html_escape(&name),
            size_txt,
            mod_txt,
            if is_dir { String::new() } else { format!("<a class=\"btn\" href=\"/s/{}/{}/{}?download=1\">⬇</a>", token, i, url_encode(&name)) },
        ));
    }
    render_shell(display_name, token, &["Shared files".to_string()], &rows, roots.len(), "")
}

fn render_dir_page(
    display_name: &str,
    token: &str,
    crumbs: &[String],
    base_href: &str,
    entries: &[DirEntry],
    _force_download: bool,
) -> String {
    let mut rows = String::new();
    for e in entries {
        // e.href is share-root-relative (e.g. "0/photos/a.jpg" or "photos/a.jpg").
        let abs = if e.href.is_empty() {
            base_href.to_string()
        } else {
            format!("/s/{}/{}", token, e.href)
        };
        let dl_link = if e.is_dir {
            String::new()
        } else {
            format!("<a class=\"btn\" href=\"{}?download=1\" download>⬇</a>", abs)
        };
        rows.push_str(&format!(
            "<tr data-name=\"{}\" data-size=\"{}\" data-time=\"{}\"><td class=\"icon\">{}</td><td class=\"name\"><a href=\"{}\">{}</a></td><td class=\"size\">{}</td><td class=\"time\">{}</td><td class=\"dl\">{}</td></tr>\n",
            html_escape(&e.name.to_lowercase()),
            e.size,
            e.modified_secs,
            file_emoji(&e.name, e.is_dir),
            abs,
            html_escape(&e.name),
            if e.is_dir { String::from("—") } else { format_size(e.size) },
            e.modified,
            dl_link,
        ));
    }
    // For single-file shares the crumb is just the file name; show parent label.
    let crumb_list: Vec<String> = if crumbs.is_empty() {
        vec![display_name.to_string()]
    } else {
        crumbs.to_vec()
    };
    render_shell(display_name, token, &crumb_list, &rows, entries.len(), base_href)
}

fn render_shell(
    display_name: &str,
    token: &str,
    crumbs: &[String],
    rows: &str,
    count: usize,
    base_href: &str,
) -> String {
    let crumb_html = crumbs
        .iter()
        .enumerate()
        .map(|(i, c)| {
            if i == 0 {
                format!("<a href=\"/s/{}/\">{}</a>", token, html_escape(c))
            } else {
                format!("<span class=\"sep\">/</span><span>{}</span>", html_escape(c))
            }
        })
        .collect::<Vec<_>>()
        .join("");
    let empty = if count == 0 {
        "<div class=\"empty\">This folder is empty.</div>"
    } else {
        ""
    };
    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · Loaf Share</title>
<style>
:root{{color-scheme:light dark;--bg:#fafafa;--card:#fff;--ink:#1a1a1a;--muted:#666;--line:#e5e5e5;--acc:#0b57d0;--acc-ink:#fff;--chip:#e8f0fe}}
@media(prefers-color-scheme:dark){{:root{{--bg:#101114;--card:#1a1c20;--ink:#e8eaed;--muted:#9aa0a6;--line:#2a2d33;--acc:#7cacf8;--acc-ink:#062e6f;--chip:#2a3441}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}}
.wrap{{max-width:880px;margin:0 auto;padding:20px 16px 48px}}
header.card{{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px}}
h1{{margin:0 0 4px;font-size:22px}}h1 .loaf{{margin-right:8px}}
.sub{{color:var(--muted);font-size:13px;margin:0 0 12px}}
.crumbs{{display:flex;flex-wrap:wrap;gap:6px;align-items:center;background:var(--chip);border-radius:10px;padding:8px 12px;margin:12px 0;font-size:14px;overflow-wrap:anywhere}}
.crumbs a{{color:var(--acc);text-decoration:none;font-weight:600}}.sep{{opacity:.5}}
.toolbar{{display:flex;gap:10px;margin:12px 0;flex-wrap:wrap}}
.search{{flex:1;min-width:180px;display:flex;align-items:center;gap:8px;background:var(--card);border:1px solid var(--line);border-radius:999px;padding:8px 14px}}
.search input{{flex:1;border:0;background:transparent;color:var(--ink);font-size:14px;outline:none}}
table{{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:16px;overflow:hidden}}
th,td{{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);font-size:14px}}
th{{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.06em;cursor:pointer;user-select:none;white-space:nowrap}}
tr:last-child td{{border-bottom:0}}tr:hover td{{background:rgba(127,127,127,.08)}}
td.icon{{width:36px;font-size:20px}}td.size,td.time{{white-space:nowrap;color:var(--muted)}}td.dl{{width:56px;text-align:right}}
a{{color:var(--acc)}}.btn{{display:inline-block;min-width:36px;text-align:center;background:var(--acc);color:var(--acc-ink);border-radius:999px;padding:4px 10px;text-decoration:none;font-weight:700}}
.count{{color:var(--muted);font-size:13px;margin:10px 2px}}.empty{{padding:24px;text-align:center;color:var(--muted)}}
footer{{margin-top:16px;color:var(--muted);font-size:12px;text-align:center}}
.hint{{background:var(--card);border:1px dashed var(--line);border-radius:12px;padding:10px 14px;font-size:13px;color:var(--muted);margin-top:12px}}
@media(max-width:640px){{td.time, th.col-time{{display:none}}h1{{font-size:19px}}}}
</style>
</head>
<body>
<div class="wrap">
<header class="card">
<h1><span class="loaf">🍞</span>{title_esc}</h1>
<p class="sub">Shared from Loaf over Wi-Fi · open this page on any phone, tablet or computer on the same network.</p>
<nav class="crumbs">{crumbs}</nav>
<div class="toolbar">
<label class="search">🔍 <input id="q" type="search" placeholder="Filter files…" autocomplete="off"></label>
</div>
</header>
<p class="count" id="count">{count} items</p>
<table>
<thead><tr><th></th><th data-sort="name">Name ▲</th><th data-sort="size" class="col-size">Size</th><th data-sort="time" class="col-time">Modified</th><th></th></tr></thead>
<tbody id="rows">
{rows}
</tbody>
</table>
{empty}
<div class="hint">Tip: tap a file to preview it in the browser, or use ⬇ to download. Videos and music support seeking. Keep Loaf open while sharing.</div>
<footer>Served by Loaf · <a href="{base}">share root</a> · lightweight, no cloud</footer>
</div>
<script>
const q=document.getElementById('q'),rows=[...document.querySelectorAll('#rows tr')],count=document.getElementById('count');
q.addEventListener('input',()=>{{const s=q.value.toLowerCase();let n=0;for(const r of rows){{const ok=r.dataset.name.includes(s);r.style.display=ok?'':'none';if(ok)n++;}}count.textContent=n+' items';}});
let key='name',dir=1;
document.querySelectorAll('th[data-sort]').forEach(th=>th.addEventListener('click',()=>{{
const k=th.dataset.sort;dir=(key===k)?-dir:1;key=k;
rows.sort((a,b)=>{{
let x=a.dataset[k]||'',y=b.dataset[k]||'';
if(k!=='name'){{x=+x;y=+y;return (x-y)*dir;}}
return x.localeCompare(y)*dir;
}});
const tb=document.getElementById('rows');rows.forEach(r=>tb.appendChild(r));
document.querySelectorAll('th[data-sort]').forEach(h=>h.textContent=h.textContent.replace(/ [▲▼]/,''));
th.textContent+=' '+(dir===1?'▲':'▼');
}}));
</script>
</body>
</html>"#,
        title = html_escape(display_name),
        title_esc = html_escape(display_name),
        crumbs = crumb_html,
        count = count,
        rows = rows,
        empty = empty,
        base = if base_href.is_empty() {
            format!("/s/{}/", token)
        } else {
            html_escape(base_href)
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_parent_escapes() {
        let roots = vec![PathBuf::from("/tmp")];
        assert!(matches!(
            resolve_wifi_path(&roots, "../etc"),
            WifiResolved::Forbidden
        ));
        assert!(matches!(
            resolve_wifi_path(&roots, "a/../../b"),
            WifiResolved::Forbidden
        ));
    }

    #[test]
    fn parses_ranges() {
        assert_eq!(parse_range(Some(&"bytes=0-99".to_string()), 1000), (0, 99, true));
        assert_eq!(parse_range(Some(&"bytes=500-".to_string()), 1000), (500, 999, true));
        assert_eq!(parse_range(Some(&"bytes=-100".to_string()), 1000), (900, 999, true));
        assert_eq!(parse_range(None, 1000), (0, 999, false));
    }

    #[test]
    fn guesses_mime() {
        assert!(guess_mime("a.mp4").starts_with("video/"));
        assert!(guess_mime("a.pdf").contains("pdf"));
        assert_eq!(guess_mime("a.unknown123"), "application/octet-stream");
    }

    fn http_get(port: u16, target: &str) -> String {
        use std::io::{Read, Write};
        let mut s = std::net::TcpStream::connect(format!("127.0.0.1:{}", port)).expect("connect");
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let req = format!("GET {} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", target);
        s.write_all(req.as_bytes()).unwrap();
        let mut out = Vec::new();
        s.read_to_end(&mut out).unwrap();
        String::from_utf8_lossy(&out).into_owned()
    }

    #[test]
    fn wifi_serves_index_and_files() {
        let base = std::env::temp_dir().join(format!("loaf-wifi-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(base.join("sub"));
        std::fs::write(base.join("hello.txt"), b"hello wifi").unwrap();
        std::fs::write(base.join("sub").join("a.mp4"), b"fake").unwrap();

        let params = CreateShareParams {
            paths: vec![base.clone()],
            compress_folders: false,
            compress_files: false,
            format: "zip".into(),
            password: String::new(),
            expiration_hours: 0,
            throttle_kbps: 0,
            lan_only: true,
        };
        let (id, url) = run_wifi_pipeline(params).expect("pipeline");
        // url is http://lan-ip:port/s/<token>/
        let port: u16 = url.split(':').last().unwrap().split('/').next().unwrap().parse().unwrap();
        let token = url.trim_end_matches('/').rsplit('/').next().unwrap().to_string();
        // Wait for server thread.
        for _ in 0..50 {
            let r = http_get(port, &format!("/s/{}/", token));
            if r.contains("200 OK") {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let index = http_get(port, &format!("/s/{}/", token));
        assert!(index.contains("200 OK"), "index status: {}", &index[..index.len().min(200)]);
        assert!(index.contains("hello.txt"), "index lists file");
        assert!(index.contains("sub"), "index lists subdir");
        assert!(index.contains("Filter files"), "modern search UI present");

        let sub = http_get(port, &format!("/s/{}/sub/", token));
        assert!(sub.contains("200 OK"));
        assert!(sub.contains("a.mp4"));

        let file = http_get(port, &format!("/s/{}/hello.txt", token));
        assert!(file.contains("200 OK"));
        assert!(file.contains("hello wifi"));

        // Range request for media seeking.
        {
            use std::io::{Read, Write};
            let mut s = std::net::TcpStream::connect(format!("127.0.0.1:{}", port)).unwrap();
            s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let req = format!(
                "GET /s/{}/hello.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-4\r\nConnection: close\r\n\r\n",
                token
            );
            s.write_all(req.as_bytes()).unwrap();
            let mut out = Vec::new();
            s.read_to_end(&mut out).unwrap();
            let txt = String::from_utf8_lossy(&out);
            assert!(txt.contains("206 Partial Content"), "range: {}", &txt[..txt.len().min(300)]);
            assert!(txt.contains("Content-Range:"));
        }

        // Token auth: wrong token -> 404.
        let bad = http_get(port, "/s/wrongtoken123/");
        assert!(bad.contains("404"));

        get_manager().stop_share(&id);
        get_manager().remove_share(&id);
        let _ = std::fs::remove_dir_all(&base);
    }
}
