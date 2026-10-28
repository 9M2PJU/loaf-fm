//! DLNA/UPnP media server powered by `rclone serve dlna`.
//! Serves a folder to TVs/consoles/players on the local network.

use crate::{rclone, util};
use serde::Serialize;
use std::net::{TcpListener, UdpSocket};
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Debug, Default, Serialize)]
pub struct DlnaStatus {
    pub running: bool,
    pub dir: String,
    pub url: String,
    pub port: u16,
}

struct ActiveServer {
    child: Child,
    dir: String,
    port: u16,
}

static ACTIVE: OnceLock<Mutex<Option<ActiveServer>>> = OnceLock::new();

fn active() -> &'static Mutex<Option<ActiveServer>> {
    ACTIVE.get_or_init(|| Mutex::new(None))
}

pub fn is_available() -> bool {
    rclone::is_available()
}

/// Best-effort LAN IPv4 address (no traffic is sent; connecting a UDP
/// socket only selects the local interface the route would use).
pub fn lan_ip() -> String {
    UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| {
            s.connect("1.1.1.1:80")?;
            s.local_addr()
        })
        .map(|a| a.ip().to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string())
}

fn free_port() -> Result<u16, String> {
    TcpListener::bind("0.0.0.0:0")
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .map_err(|e| format!("Could not find a free port: {}", e))
}

/// Serve `dir` via DLNA. Stops any previously running server first.
pub fn start(dir: &str) -> Result<DlnaStatus, String> {
    let path = PathBuf::from(dir);
    if !path.is_dir() {
        return Err("Choose a folder to serve".into());
    }
    let Some(bin) = util::which("rclone") else {
        return Err("rclone is not installed".into());
    };
    stop();
    let port = free_port()?;
    let mut cmd = Command::new(bin);
    cmd.args([
        "serve",
        "dlna",
        &path.to_string_lossy(),
        "--name",
        "Loaf",
        "--addr",
        &format!("0.0.0.0:{}", port),
    ]);
    cmd.stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let child = cmd.spawn().map_err(|e| format!("Could not start DLNA server: {}", e))?;
    {
        let mut guard = active().lock().unwrap();
        *guard = Some(ActiveServer { child, dir: path.to_string_lossy().to_string(), port });
    }
    // Wait until rclone accepts connections (or exits early on error).
    for _ in 0..100 {
        {
            let mut guard = active().lock().unwrap();
            if let Some(srv) = guard.as_mut() {
                match srv.child.try_wait() {
                    Ok(Some(_)) => {
                        *guard = None;
                        return Err("DLNA server exited immediately".into());
                    }
                    Ok(None) => {}
                    Err(e) => {
                        *guard = None;
                        return Err(format!("Could not start DLNA server: {}", e));
                    }
                }
            } else {
                return Err("DLNA server did not start".into());
            }
        }
        if std::net::TcpStream::connect(format!("127.0.0.1:{}", port)).is_ok() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    Ok(status())
}

pub fn stop() {
    let mut guard = active().lock().unwrap();
    if let Some(mut srv) = guard.take() {
        let _ = srv.child.kill();
        let _ = srv.child.wait();
    }
}

pub fn status() -> DlnaStatus {
    let mut guard = active().lock().unwrap();
    if let Some(srv) = guard.as_mut() {
        match srv.child.try_wait() {
            Ok(None) => {
                return DlnaStatus {
                    running: true,
                    dir: srv.dir.clone(),
                    url: format!("http://{}:{}", lan_ip(), srv.port),
                    port: srv.port,
                };
            }
            _ => {
                *guard = None;
            }
        }
    }
    DlnaStatus::default()
}

pub fn status_json() -> String {
    serde_json::to_string(&status()).unwrap_or_else(|_| "{\"running\":false}".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_defaults_to_stopped() {
        // Ensure a clean slate even if another test started a server.
        stop();
        let s = status();
        assert!(!s.running);
        assert_eq!(s.port, 0);
    }

    #[test]
    fn rejects_missing_dirs() {
        assert!(start("/definitely/not/a/loaf/dir").is_err());
    }
}
