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
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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
/// Unix milliseconds of the last update check.
const LAST_CHECK: &str = "last-check";

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

fn root(config: &Config) -> PathBuf {
    config.state_dir.join("vscode").join("server")
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

/// The command that serves on `127.0.0.1:port` with the token in `token_file`, from the
/// server in `dir`.
pub(crate) fn command(dir: &Path, port: u16, token_file: &Path) -> Command {
    let mut command = Command::new(entry(dir));
    command
        .args(["--host", "127.0.0.1", "--port"])
        .arg(port.to_string())
        .arg("--connection-token-file")
        .arg(token_file)
        .arg("--accept-server-license-terms")
        .arg("--reconnection-grace-time")
        .arg(RECONNECTION_GRACE.as_secs().to_string());
    command
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum UpdateCheck {
    NotDue,
    NothingInstalled,
    Checked(PathBuf),
}

#[derive(Default)]
pub(crate) struct Servers {
    updating: tokio::sync::Mutex<()>,
}

impl Servers {
    /// The newest server here, never asking the update service; downloads one only when none is here.
    pub(crate) async fn ensure(&self, config: &Config) -> Result<PathBuf, WsError> {
        let root = root(config);
        if let Some(dir) = latest(&root) {
            return Ok(dir);
        }
        let platform = server_platform()?;
        let _updating = self.updating.lock().await;
        if let Some(dir) = latest(&root) {
            return Ok(dir);
        }
        download_latest(config, platform, Vec::new()).await
    }

    /// Downloads a newer server for the next start when one is installed and the last check is stale.
    pub(crate) async fn update_if_due(
        &self,
        config: &Config,
        in_use: Vec<PathBuf>,
    ) -> Result<UpdateCheck, WsError> {
        let root = root(config);
        if latest(&root).is_none() {
            return Ok(UpdateCheck::NothingInstalled);
        }
        if checked_recently(&root, SystemTime::now()) {
            return Ok(UpdateCheck::NotDue);
        }
        let platform = server_platform()?;
        let _updating = self.updating.lock().await;
        if checked_recently(&root, SystemTime::now()) {
            return Ok(UpdateCheck::NotDue);
        }
        download_latest(config, platform, in_use)
            .await
            .map(UpdateCheck::Checked)
    }
}

fn server_platform() -> Result<&'static str, WsError> {
    platform().ok_or_else(|| {
        WsError::Unavailable("Microsoft publishes no VS Code server for this host".into())
    })
}

async fn download_latest(
    config: &Config,
    platform: &'static str,
    in_use: Vec<PathBuf>,
) -> Result<PathBuf, WsError> {
    let root = root(config);
    let base_url = config.vscode_update_url.clone();
    let started = Instant::now();
    let installed = tokio::task::spawn_blocking(move || {
        let installed = install(&base_url, platform, &root, &in_use);
        record_check(&root, SystemTime::now());
        installed
    })
    .await
    .map_err(|error| WsError::Failed(error.to_string()))
    .flatten();
    let elapsed_ms = started.elapsed().as_millis();
    match &installed {
        Ok(dir) => tracing::info!(dir = %dir.display(), elapsed_ms, "VS Code server is current"),
        Err(error) => tracing::warn!(elapsed_ms, "VS Code server update check failed: {error}"),
    }
    installed
}

fn checked_recently(root: &Path, now: SystemTime) -> bool {
    std::fs::read_to_string(root.join(LAST_CHECK))
        .ok()
        .and_then(|text| text.trim().parse::<u64>().ok())
        .map(|millis| UNIX_EPOCH + Duration::from_millis(millis))
        .and_then(|checked_at| now.duration_since(checked_at).ok())
        .is_some_and(|since| since < CHECK_INTERVAL)
}

fn record_check(root: &Path, now: SystemTime) {
    let millis = now
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    if let Err(error) = fsutil::write_atomic(&root.join(LAST_CHECK), millis.to_string().as_bytes())
    {
        tracing::warn!("recording the VS Code server update check: {error}");
    }
}

/// Installs the update service's latest server; keeps the previous one and those `in_use`.
fn install(
    base_url: &str,
    platform: &str,
    root: &Path,
    in_use: &[PathBuf],
) -> Result<PathBuf, WsError> {
    let failed = |error: std::io::Error| WsError::Failed(error.to_string());
    std::fs::create_dir_all(root).map_err(failed)?;
    let tag = fsutil::hex(&fsutil::random::<4>());
    let release_path = root.join(format!(".release-{tag}.json"));
    tunnel::fetch(
        &format!("{base_url}/api/update/{platform}/stable/latest"),
        &release_path,
    )?;
    let release_json = std::fs::read(&release_path).map_err(failed);
    let _ = std::fs::remove_file(&release_path);
    let release: Release = serde_json::from_slice(&release_json?)
        .map_err(|error| WsError::Failed(format!("unexpected update service answer: {error}")))?;
    if base_url == tunnel::DEFAULT_UPDATE_URL && !release.url.starts_with("https://") {
        return Err(WsError::Failed(format!(
            "refusing a non-HTTPS download: {}",
            release.url
        )));
    }
    if release.version.is_empty() || !release.version.bytes().all(|byte| byte.is_ascii_hexdigit()) {
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
        for old in entries.filter_map(Result::ok).map(|entry| entry.path()) {
            if old.is_dir()
                && old != dir
                && Some(&old) != previous.as_ref()
                && !in_use.contains(&old)
            {
                let _ = std::fs::remove_dir_all(&old);
            }
        }
    }
    Ok(dir)
}

fn unpack_release(release: &Release, root: &Path, tag: &str, dir: &Path) -> Result<(), WsError> {
    let failed = |error: std::io::Error| WsError::Failed(error.to_string());
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
        let actual = super::editor::sha256_file(&archive).map_err(failed)?;
        if !actual.eq_ignore_ascii_case(&release.sha256hash) {
            return Err(WsError::Failed(format!(
                "VS Code server checksum mismatch: got {actual}, Microsoft published {}",
                release.sha256hash
            )));
        }
        std::fs::create_dir_all(&staging).map_err(failed)?;
        let mut unpack = if zip {
            let mut command = std::process::Command::new("unzip");
            command
                .args(["-q", "-o"])
                .arg(&archive)
                .arg("-d")
                .arg(&staging);
            command
        } else {
            let mut command = std::process::Command::new("tar");
            command.arg("-xzf").arg(&archive).arg("-C").arg(&staging);
            command
        };
        if !unpack.status().is_ok_and(|status| status.success()) {
            return Err(WsError::Failed(
                "unpacking the VS Code server failed".into(),
            ));
        }
        // One top-level directory (`vscode-server-<platform>-web`).
        let server = std::fs::read_dir(&staging)
            .map_err(failed)?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| entry(path).is_file())
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
        let source = dir.join("src").join(format!("vscode-server-{platform}"));
        std::fs::create_dir_all(source.join("bin")).unwrap();
        std::fs::write(source.join("bin/code-server"), body).unwrap();
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
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("root");
        let platform = "server-test-web";
        let mut installed = Vec::new();
        for (commit, body) in [("aa11", "one"), ("bb22", "two"), ("cc33", "three")] {
            let service_dir = temp.path().join(commit);
            let base_url = service(&service_dir, platform, commit, body);
            let dir = install(&base_url, platform, &root, &[]).unwrap();
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
        let service_dir = temp.path().join("cc33");
        let again = install(
            &format!("file://{}", service_dir.display()),
            platform,
            &root,
            &[],
        )
        .unwrap();
        assert_eq!(again, installed[2]);
        assert!(installed[1].exists());
    }

    #[test]
    fn a_server_in_use_survives_two_updates() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("root");
        let platform = "server-test-web";
        let first_url = service(&temp.path().join("aa11"), platform, "aa11", "one");
        let running = install(&first_url, platform, &root, &[]).unwrap();
        for commit in ["bb22", "cc33"] {
            let base_url = service(&temp.path().join(commit), platform, commit, commit);
            install(&base_url, platform, &root, std::slice::from_ref(&running)).unwrap();
        }
        assert!(running.exists());
    }

    fn test_config(state_dir: &Path, update_url: String) -> Config {
        let mut config = Config::new(state_dir);
        config.vscode_update_url = update_url;
        config
    }

    #[tokio::test]
    async fn an_installed_server_starts_without_the_update_service() {
        let Some(platform) = platform() else { return };
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let old_url = service(&temp.path().join("aa11"), platform, "aa11", "old");
        let new_url = service(&temp.path().join("bb22"), platform, "bb22", "new");
        let servers = Servers::default();

        let unreachable = test_config(&state_dir, "file:///nonexistent".into());
        assert_eq!(
            servers
                .update_if_due(&unreachable, Vec::new())
                .await
                .unwrap(),
            UpdateCheck::NothingInstalled
        );
        let first = servers
            .ensure(&test_config(&state_dir, old_url))
            .await
            .unwrap();
        assert!(first.ends_with("aa11"));

        let started = Instant::now();
        assert_eq!(servers.ensure(&unreachable).await.unwrap(), first);
        assert!(started.elapsed() < Duration::from_millis(100));

        let newer = test_config(&state_dir, new_url);
        assert_eq!(servers.ensure(&newer).await.unwrap(), first);
        assert_eq!(
            servers.update_if_due(&newer, Vec::new()).await.unwrap(),
            UpdateCheck::NotDue,
            "the first download counts as a check"
        );
        let root = root(&newer);
        std::fs::remove_file(root.join(LAST_CHECK)).unwrap();
        let UpdateCheck::Checked(updated) =
            servers.update_if_due(&newer, Vec::new()).await.unwrap()
        else {
            panic!("a stale check asks the update service");
        };
        assert!(updated.ends_with("bb22"));
        assert_eq!(servers.ensure(&unreachable).await.unwrap(), updated);
    }

    #[test]
    fn a_check_is_due_an_hour_later_or_when_the_clock_went_back() {
        let temp = tempfile::tempdir().unwrap();
        let now = SystemTime::now();
        assert!(!checked_recently(temp.path(), now));
        record_check(temp.path(), now);
        assert!(checked_recently(temp.path(), now + Duration::from_secs(60)));
        assert!(!checked_recently(temp.path(), now + CHECK_INTERVAL));
        assert!(!checked_recently(
            temp.path(),
            now - Duration::from_secs(60)
        ));
    }

    #[test]
    fn a_tampered_download_is_refused() {
        let temp = tempfile::tempdir().unwrap();
        let platform = "server-test-web";
        let base_url = service(temp.path(), platform, "dd44", "x");
        std::fs::write(temp.path().join("dd44.tar.gz"), b"not it").unwrap();
        let root = temp.path().join("root");
        let error = install(&base_url, platform, &root, &[]).unwrap_err();
        assert!(matches!(error, WsError::Failed(message) if message.contains("checksum")));
        assert!(latest(&root).is_none());
    }
}
