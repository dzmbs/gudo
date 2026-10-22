//! Microsoft's VS Code server for the web, run directly: the server `code serve-web`
//! downloads and runs behind its own proxy.
//!
//! Run directly, the daemon decides how long it lives and how long a workbench may stay away
//! and still reconnect. serve-web stops its server an hour after the last connection closed,
//! sends new connections to a newer server as soon as Microsoft ships one, and keeps the
//! server's default reconnection grace (three hours, five minutes after another client came);
//! each of these ends every open workbench's session, which then has to be reloaded.
//!
//! The server comes from Microsoft's update service
//! (`/api/update/server-<platform>-web/stable/latest`), checked against the SHA-256 it
//! publishes, into `<state>/vscode/server/<commit>/`. It is downloaded and started only with
//! the VS Code Server licence accepted in the app, the acceptance serve-web needs too.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use proto::WsError;
use tokio::process::Command;

use super::tunnel::{self, Release};
use crate::config::Config;
use crate::fsutil;

/// How long a workbench that lost its connection (a sleeping device) can come back to its
/// session; an idle server is stopped after as long.
pub(crate) const RECONNECTION_GRACE: Duration = Duration::from_secs(48 * 3600);
/// How often the update service is asked for a newer server.
const CHECK_INTERVAL: Duration = Duration::from_secs(3600);
/// Names the commit of the newest server in the root.
const LATEST: &str = "latest";

/// Microsoft's name for this host's web server build.
fn platform() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") if tunnel::is_musl() => Some("server-linux-alpine-web"),
        ("linux", "x86_64") => Some("server-linux-x64-web"),
        ("linux", "aarch64") if tunnel::is_musl() => Some("server-alpine-arm64-web"),
        ("linux", "aarch64") => Some("server-linux-arm64-web"),
        ("linux", "arm") => Some("server-linux-armhf-web"),
        ("macos", "aarch64") => Some("server-darwin-arm64-web"),
        ("macos", "x86_64") => Some("server-darwin-web"),
        _ => None,
    }
}

fn root(cfg: &Config) -> PathBuf {
    cfg.state_dir.join("vscode").join("server")
}

fn entry(dir: &Path) -> PathBuf {
    dir.join("bin").join("code-server")
}

/// The newest server downloaded so far.
fn latest(root: &Path) -> Option<PathBuf> {
    let commit = std::fs::read_to_string(root.join(LATEST)).ok()?;
    let dir = root.join(commit.trim());
    entry(&dir).is_file().then_some(dir)
}

/// The command that serves on `127.0.0.1:port` with `token`, from the server in `dir`.
pub(crate) fn command(dir: &Path, port: u16, token: &str) -> Command {
    let mut cmd = Command::new(entry(dir));
    cmd.args(["--host", "127.0.0.1", "--port"])
        .arg(port.to_string())
        .arg("--connection-token")
        .arg(token)
        .arg("--accept-server-license-terms")
        .arg("--reconnection-grace-time")
        .arg(RECONNECTION_GRACE.as_secs().to_string());
    cmd
}

/// The host's VS Code servers.
#[derive(Default)]
pub(crate) struct Servers {
    /// When the update service last answered, and with which server.
    checked: tokio::sync::Mutex<Option<(Instant, PathBuf)>>,
}

impl Servers {
    /// The server to start: Microsoft's latest (downloaded first when it is new; the service
    /// is asked at most hourly), else the newest one here when the service cannot be reached.
    ///
    /// # Errors
    ///
    /// `Unavailable` when Microsoft publishes no server for this host; `Failed` when none is
    /// here and the download failed.
    pub(crate) async fn ensure(&self, cfg: &Config) -> Result<PathBuf, WsError> {
        let platform = platform().ok_or_else(|| {
            WsError::Unavailable("Microsoft publishes no VS Code server for this host".into())
        })?;
        // Held across the download: one download at a time.
        let mut checked = self.checked.lock().await;
        if let Some((at, dir)) = checked.as_ref()
            && at.elapsed() < CHECK_INTERVAL
            && entry(dir).is_file()
        {
            return Ok(dir.clone());
        }
        let root = root(cfg);
        let base = cfg.vscode_update_url.clone();
        let root2 = root.clone();
        let fetched = tokio::task::spawn_blocking(move || install(&base, platform, &root2))
            .await
            .map_err(|e| WsError::Failed(e.to_string()))
            .flatten();
        match fetched {
            Ok(dir) => {
                *checked = Some((Instant::now(), dir.clone()));
                Ok(dir)
            }
            Err(e) => latest(&root).ok_or(e).inspect(|dir| {
                tracing::warn!(dir = %dir.display(), "VS Code server update check failed; using the one here");
            }),
        }
    }
}

/// Asks the update service for the latest server and, when it is not here yet, downloads it,
/// checks the published SHA-256 and unpacks it; the one before stays (it may be running),
/// older ones go.
fn install(base: &str, platform: &str, root: &Path) -> Result<PathBuf, WsError> {
    let failed = |e: std::io::Error| WsError::Failed(e.to_string());
    std::fs::create_dir_all(root).map_err(failed)?;
    let tag = fsutil::hex(&fsutil::random::<4>());
    let meta_path = root.join(format!(".release-{tag}.json"));
    tunnel::fetch(
        &format!("{base}/api/update/{platform}/stable/latest"),
        &meta_path,
    )?;
    let meta = std::fs::read(&meta_path).map_err(failed);
    let _ = std::fs::remove_file(&meta_path);
    let release: Release = serde_json::from_slice(&meta?)
        .map_err(|e| WsError::Failed(format!("unexpected update service answer: {e}")))?;
    if base == tunnel::DEFAULT_UPDATE_URL && !release.url.starts_with("https://") {
        return Err(WsError::Failed(format!(
            "refusing a non-HTTPS download: {}",
            release.url
        )));
    }
    if release.version.is_empty() || !release.version.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(WsError::Failed(format!(
            "unexpected commit from the update service: {}",
            release.version
        )));
    }
    let dir = root.join(&release.version);
    let previous = latest(root);
    if previous.as_ref() == Some(&dir) {
        return Ok(dir);
    }
    if !entry(&dir).is_file() {
        unpack_release(&release, root, &tag, &dir)?;
    }
    fsutil::write_atomic(&root.join(LATEST), release.version.as_bytes()).map_err(failed)?;
    if let Ok(entries) = std::fs::read_dir(root) {
        for old in entries.filter_map(Result::ok).map(|e| e.path()) {
            if old.is_dir() && old != dir && Some(&old) != previous.as_ref() {
                let _ = std::fs::remove_dir_all(&old);
            }
        }
    }
    Ok(dir)
}

fn unpack_release(release: &Release, root: &Path, tag: &str, dir: &Path) -> Result<(), WsError> {
    let failed = |e: std::io::Error| WsError::Failed(e.to_string());
    let zip = release.url.ends_with(".zip");
    let archive = root.join(format!(
        ".server-{tag}{}",
        if zip { ".zip" } else { ".tar.gz" }
    ));
    let staging = root.join(format!(".server-{tag}"));
    let cleanup = || {
        let _ = std::fs::remove_file(&archive);
        let _ = std::fs::remove_dir_all(&staging);
    };
    tracing::info!(url = %release.url, "downloading the VS Code server");
    let result = (|| {
        tunnel::fetch(&release.url, &archive)?;
        let sha = super::editor::sha256_file(&archive).map_err(failed)?;
        if !sha.eq_ignore_ascii_case(&release.sha256hash) {
            return Err(WsError::Failed(format!(
                "VS Code server checksum mismatch: got {sha}, Microsoft published {}",
                release.sha256hash
            )));
        }
        std::fs::create_dir_all(&staging).map_err(failed)?;
        let mut unpack = if zip {
            let mut c = std::process::Command::new("unzip");
            c.args(["-q", "-o"]).arg(&archive).arg("-d").arg(&staging);
            c
        } else {
            let mut c = std::process::Command::new("tar");
            c.arg("-xzf").arg(&archive).arg("-C").arg(&staging);
            c
        };
        if !unpack.status().is_ok_and(|s| s.success()) {
            return Err(WsError::Failed(
                "unpacking the VS Code server failed".into(),
            ));
        }
        // One top-level directory (`vscode-server-<platform>-web`).
        let server = std::fs::read_dir(&staging)
            .map_err(failed)?
            .filter_map(Result::ok)
            .map(|e| e.path())
            .find(|p| entry(p).is_file())
            .ok_or_else(|| {
                WsError::Failed("the VS Code server archive has no bin/code-server".into())
            })?;
        let _ = std::fs::remove_dir_all(dir);
        std::fs::rename(&server, dir).map_err(failed)
    })();
    cleanup();
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `file://` update service serving a server archive for `platform`; its base URL.
    fn service(dir: &Path, platform: &str, commit: &str, body: &str) -> String {
        let src = dir.join("src").join(format!("vscode-server-{platform}"));
        std::fs::create_dir_all(src.join("bin")).unwrap();
        std::fs::write(src.join("bin/code-server"), body).unwrap();
        let archive = dir.join(format!("{commit}.tar.gz"));
        let ok = std::process::Command::new("tar")
            .arg("-czf")
            .arg(&archive)
            .arg("-C")
            .arg(dir.join("src"))
            .arg(format!("vscode-server-{platform}"))
            .status()
            .unwrap()
            .success();
        assert!(ok);
        std::fs::remove_dir_all(dir.join("src")).unwrap();
        let sha = super::super::editor::sha256_file(&archive).unwrap();
        let api = dir.join("api/update").join(platform).join("stable");
        std::fs::create_dir_all(&api).unwrap();
        std::fs::write(
            api.join("latest"),
            format!(
                r#"{{"url":"file://{}","version":"{commit}","name":"1.0.0","sha256hash":"{sha}"}}"#,
                archive.display()
            ),
        )
        .unwrap();
        format!("file://{}", dir.display())
    }

    #[test]
    fn installs_the_latest_keeps_the_one_before_and_drops_older() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("root");
        let p = "server-test-web";
        let mut installed = Vec::new();
        for (commit, body) in [("aa11", "one"), ("bb22", "two"), ("cc33", "three")] {
            let svc = tmp.path().join(commit);
            let base = service(&svc, p, commit, body);
            let dir = install(&base, p, &root).unwrap();
            assert_eq!(std::fs::read_to_string(entry(&dir)).unwrap(), body);
            assert_eq!(latest(&root).as_deref(), Some(dir.as_path()));
            installed.push(dir);
        }
        assert!(!installed[0].exists(), "older than the one before: removed");
        assert!(
            installed[1].exists(),
            "the one before stays (it may be running)"
        );
        // Asked again with nothing new: nothing is downloaded or removed.
        let svc = tmp.path().join("cc33");
        let again = install(&format!("file://{}", svc.display()), p, &root).unwrap();
        assert_eq!(again, installed[2]);
        assert!(installed[1].exists());
    }

    #[test]
    fn a_tampered_download_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let p = "server-test-web";
        let base = service(tmp.path(), p, "dd44", "x");
        std::fs::write(tmp.path().join("dd44.tar.gz"), b"not it").unwrap();
        let root = tmp.path().join("root");
        let err = install(&base, p, &root).unwrap_err();
        assert!(matches!(err, WsError::Failed(m) if m.contains("checksum")));
        assert!(latest(&root).is_none());
    }
}
