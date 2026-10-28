//! rclone remotes: list configured remotes and mount/unmount them via
//! `rclone mount` (FUSE). Mounted remotes show up in the sidebar.

use crate::util;
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;

#[derive(Clone, Debug, Serialize)]
pub struct RemoteState {
    pub name: String,
    pub mounted: bool,
    pub path: String,
}

pub fn is_available() -> bool {
    util::which("rclone").is_some()
}

fn rclone_bin() -> Option<PathBuf> {
    util::which("rclone")
}

/// Names of configured remotes (`rclone listremotes` prints `name:` lines).
pub fn list_remotes() -> Vec<String> {
    let Some(bin) = rclone_bin() else { return Vec::new() };
    let mut cmd = Command::new(bin);
    cmd.arg("listremotes");
    let (ok, out, _) = util::run_capture(cmd, None);
    if !ok {
        return Vec::new();
    }
    out.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(|l| l.trim_end_matches(':').to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

fn base_dir() -> PathBuf {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| util::home().join(".cache"));
    base.join("loaf").join("rclone")
}

pub fn mount_point(remote: &str) -> PathBuf {
    base_dir().join(sanitize(remote))
}

fn sanitize(name: &str) -> String {
    let clean: String = name
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' || c == '.' { c } else { '_' })
        .collect();
    let clean = clean.trim_matches('.').trim();
    if clean.is_empty() { "remote".to_string() } else { clean.to_string() }
}

/// remote -> mountpoint for currently FUSE-mounted rclone dirs we own.
pub fn mounted_map() -> HashMap<String, PathBuf> {
    let mut map = HashMap::new();
    let Ok(mounts) = std::fs::read_to_string("/proc/mounts") else { return map };
    let base = base_dir().to_string_lossy().to_string();
    for line in mounts.lines() {
        let mut parts = line.split_whitespace();
        let (Some(source), Some(target)) = (parts.next(), parts.next()) else { continue };
        if !target.starts_with(&base) {
            continue;
        }
        // rclone mount sources look like "remote:path".
        let remote = source.split_once(':').map(|(r, _)| r).unwrap_or(source);
        map.insert(remote.to_string(), PathBuf::from(target));
    }
    map
}

pub fn is_mounted(remote: &str) -> bool {
    mounted_map().contains_key(remote)
}

/// Mount a remote with `rclone mount --daemon`, waiting until the kernel
/// reports the FUSE mount. Blocks for up to ~15s.
pub fn mount(remote: &str) -> Result<String, String> {
    let Some(bin) = rclone_bin() else { return Err("rclone is not installed".into()) };
    if remote.trim().is_empty() {
        return Err("Unknown rclone remote".into());
    }
    if let Some(path) = mounted_map().get(remote) {
        return Ok(path.to_string_lossy().to_string());
    }
    let dir = mount_point(remote);
    std::fs::create_dir_all(&dir).map_err(|e| format!("Could not create {}: {}", dir.display(), e))?;
    let mut cmd = Command::new(bin);
    cmd.args(["mount", &format!("{}:", remote), &dir.to_string_lossy(), "--daemon"]);
    let (ok, _, err) = util::run_capture(cmd, None);
    if !ok && !err.trim().is_empty() {
        return Err(err.lines().next().unwrap_or("rclone mount failed").trim().to_string());
    }
    for _ in 0..150 {
        if let Some(path) = mounted_map().get(remote) {
            return Ok(path.to_string_lossy().to_string());
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    Err(format!("{} mounted, but its folder did not appear", remote))
}

fn fusermount_bin() -> Option<PathBuf> {
    util::which("fusermount3").or_else(|| util::which("fusermount"))
}

pub fn unmount(remote: &str) -> Result<(), String> {
    let Some(path) = mounted_map().get(remote).cloned() else { return Ok(()) };
    if let Some(bin) = fusermount_bin() {
        let mut cmd = Command::new(bin);
        cmd.args(["-u", &path.to_string_lossy()]);
        let (ok, _, err) = util::run_capture(cmd, None);
        if ok {
            return Ok(());
        }
        return Err(err.lines().next().unwrap_or("unmount failed").trim().to_string());
    }
    let mut cmd = Command::new("umount");
    cmd.arg(&path);
    let (ok, _, err) = util::run_capture(cmd, None);
    if ok {
        Ok(())
    } else {
        Err(err.lines().next().unwrap_or("unmount failed").trim().to_string())
    }
}

pub fn status_json() -> String {
    let mounted = mounted_map();
    let list: Vec<RemoteState> = list_remotes()
        .into_iter()
        .map(|name| {
            let path = mounted
                .get(&name)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default();
            RemoteState { mounted: !path.is_empty(), path, name }
        })
        .collect();
    serde_json::to_string(&list).unwrap_or_else(|_| "[]".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_remote_names() {
        assert_eq!(sanitize("my drive"), "my_drive");
        assert_eq!(sanitize("../../etc"), "etc");
        assert_eq!(sanitize(""), "remote");
        assert_eq!(sanitize("backup-2024.01"), "backup-2024.01");
    }

    #[test]
    fn mount_point_lives_under_cache() {
        let p = mount_point("gdrive");
        assert!(p.to_string_lossy().contains("loaf"));
        assert!(p.ends_with("gdrive"));
    }
}
