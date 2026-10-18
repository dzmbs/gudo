//! accepted Microsoft's licence in the app, else Gitpod's openvscode-server (MIT), downloaded
//! on demand into the state directory and SHA-256 pinned. Either is bound to `127.0.0.1` with
//! a random connection token, one server per workspace folder, and reached by the app through
//! a port forward. The server belongs to the daemon (not a pane) and stops with it.
//!
//! "Open file at line" first uses the editor's own CLI channel: the server's extension host
//! exports `VSCODE_IPC_HOOK_CLI`, and its bundled remote CLI (`bin/remote-cli/*`) with that
//! socket opens the file in the window already showing the folder. Without a window (or on a
//! failure) it falls back to a URL the app loads, whose `payload` (`openFile` +
//! `gotoLineMode`) makes the workbench open the file at the line.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use proto::{
    EditorAvailability, EditorChoice, EditorInstance, EditorKind, EditorLaunch, EditorList,
    EditorOpened, UnixMillis, WsError,
};
use tokio::process::{Child, Command};

use crate::config::Config;
use crate::fsutil;
use crate::procinfo;

/// The pinned openvscode-server release (Linux only: Gitpod publishes no macOS build).
pub(crate) const OPENVSCODE_VERSION: &str = "v1.109.5";
/// `(rust arch, release arch, SHA-256 of the tarball)`.
const OPENVSCODE_BUILDS: &[(&str, &str, &str)] = &[
    (
        "x86_64",
        "x64",
        "b433bf4f0227321a7014d8460d10a8f958adc0f45aa79bd889e84e65e8f88363",
    ),
    (
        "aarch64",
        "arm64",
        "36d9c14036489b63de84ebace837fcacf7e60e669a0dc715802c5443684ea4dc",
    ),
];
/// How long a server may take to accept connections (`code serve-web` downloads Microsoft's
/// server on its first run).
const START_TIMEOUT: Duration = Duration::from_secs(180);

struct Running {
    info: EditorInstance,
    child: Child,
}

impl Drop for Running {
    fn drop(&mut self) {
        // The server runs in its own process group; take its children (extension hosts,
        // the downloaded server under `code serve-web`) down with it.
        // SAFETY: plain syscall; the group id is the child's pid (process_group(0)).
        unsafe { libc::kill(-(self.info.pid as libc::pid_t), libc::SIGTERM) };
        let _ = self.child.start_kill();
    }
}

#[derive(Default)]
pub(crate) struct Editors {
    running: tokio::sync::Mutex<HashMap<String, Running>>,
    /// Serialises the openvscode download.
    install: tokio::sync::Mutex<()>,
}

/// The VS Code CLI: the user's own, else the one the daemon installed from Microsoft.
fn find_code(cfg: &Config) -> Option<PathBuf> {
    find_user_code(cfg).or_else(|| super::tunnel::managed_cli(cfg))
}

/// The user's own VS Code CLI (`editor.code`, `PATH`, the usual install locations).
pub(crate) fn find_user_code(cfg: &Config) -> Option<PathBuf> {
    if let Some(code) = &cfg.code_cli {
        return code.is_file().then(|| code.clone());
    }
    let path = cfg.pane_var("PATH").unwrap_or_default();
    let home = cfg.home();
    std::env::split_paths(&path)
        .map(|d| d.join("code"))
        .chain([
            PathBuf::from("/usr/local/bin/code"),
            PathBuf::from("/opt/homebrew/bin/code"),
            PathBuf::from("/usr/bin/code"),
            PathBuf::from("/snap/bin/code"),
            PathBuf::from("/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
            home.join("Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
        ])
        .find(|p| p.is_file())
}

fn openvscode_build() -> Option<(&'static str, &'static str)> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    OPENVSCODE_BUILDS
        .iter()
        .find(|(arch, _, _)| *arch == std::env::consts::ARCH)
        .map(|&(_, rel, sha)| (rel, sha))
}

fn openvscode_dir(cfg: &Config) -> Option<PathBuf> {
    if let Some(dir) = &cfg.openvscode_dir {
        return Some(dir.clone());
    }
    let (arch, _) = openvscode_build()?;
    Some(cfg.state_dir.join("editors").join(format!(
        "openvscode-server-{OPENVSCODE_VERSION}-linux-{arch}"
    )))
}

fn openvscode_bin(dir: &Path) -> PathBuf {
    dir.join("bin/openvscode-server")
}

fn token() -> String {
    fsutil::hex(&fsutil::random::<16>())
}

/// Percent-encodes a query value.
fn encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn url_path(token: &str, folder: &str) -> String {
    format!("/?tkn={token}&folder={}", encode(folder))
}

fn free_port() -> Result<u16, WsError> {
    std::net::TcpListener::bind(("127.0.0.1", 0))
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .map_err(|e| WsError::Failed(format!("no free port: {e}")))
}

impl Editors {
    pub async fn status(&self, cfg: &Config) -> EditorList {
        let code = find_code(cfg);
        let ovs = openvscode_dir(cfg);
        let ovs_installed = ovs.as_deref().is_some_and(|d| openvscode_bin(d).is_file());
        let available = vec![
            EditorAvailability {
                kind: EditorKind::VsCode,
                installed: code.is_some(),
                downloadable: false,
                path: code.map(|p| p.to_string_lossy().into_owned()),
                version: None,
                note: Some(
                    "Microsoft VS Code Server licence: single user, no hosting as a service; \
                     the user must accept it (accept_vscode_license)"
                        .into(),
                ),
            },
            EditorAvailability {
                kind: EditorKind::OpenVsCode,
                installed: ovs_installed,
                downloadable: openvscode_build().is_some() && cfg.openvscode_dir.is_none(),
                path: ovs
                    .filter(|_| ovs_installed)
                    .map(|d| openvscode_bin(&d).to_string_lossy().into_owned()),
                version: cfg
                    .openvscode_dir
                    .is_none()
                    .then(|| OPENVSCODE_VERSION.to_owned()),
                note: (openvscode_build().is_none() && cfg.openvscode_dir.is_none()).then(|| {
                    "openvscode-server publishes Linux builds only; install VS Code's `code` CLI"
                        .to_owned()
                }),
            },
        ];
        let mut running = self.running.lock().await;
        reap(&mut running);
        EditorList {
            available,
            running: running.values().map(|r| r.info.clone()).collect(),
        }
    }

    pub async fn launch(
        &self,
        cfg: &Config,
        req: &EditorLaunch,
        folder: &Path,
    ) -> Result<EditorInstance, WsError> {
        if !folder.is_dir() {
            return Err(WsError::NotFound(format!(
                "{} is not a directory",
                folder.display()
            )));
        }
        let folder_s = folder.to_string_lossy().into_owned();
        {
            let mut running = self.running.lock().await;
            reap(&mut running);
            if let Some(r) = running.get(&folder_s) {
                let wanted = match req.choice {
                    EditorChoice::Auto => None,
                    EditorChoice::Only(k) => Some(k),
                };
                if wanted.is_none_or(|k| k == r.info.kind) {
                    return Ok(r.info.clone());
                }
            }
        }
        let code = find_code(cfg);
        // openvscode-server is an explicit fallback only (12-vscode.md): Auto means Microsoft's
        // VS Code, and says what is missing instead of silently switching editors.
        let kind = match req.choice {
            EditorChoice::Only(k) => k,
            EditorChoice::Auto if code.is_none() => {
                return Err(WsError::Unavailable(
                    "the VS Code `code` CLI is not installed: install it (VsCodeCliInstall) \
                     and use the VS Code tunnel, or choose openvscode-server explicitly"
                        .into(),
                ));
            }
            EditorChoice::Auto => EditorKind::VsCode,
        };
        let port = free_port()?;
        let token = token();
        let mut cmd = match kind {
            EditorKind::VsCode => {
                let code = code.ok_or_else(|| {
                    WsError::Unavailable("the VS Code `code` CLI is not installed".into())
                })?;
                if !req.accept_vscode_license {
                    return Err(WsError::Denied(
                        "code serve-web needs the Microsoft VS Code Server licence accepted \
                         (https://aka.ms/vscode-server-license)"
                            .into(),
                    ));
                }
                let mut cmd = Command::new(code);
                cmd.args(["serve-web", "--host", "127.0.0.1", "--port"])
                    .arg(port.to_string())
                    .arg("--connection-token")
                    .arg(&token)
                    .arg("--accept-server-license-terms");
                cmd
            }
            EditorKind::OpenVsCode => {
                let dir = self.ensure_openvscode(cfg).await?;
                let mut cmd = Command::new(openvscode_bin(&dir));
                cmd.args(["--host", "127.0.0.1", "--port"])
                    .arg(port.to_string())
                    .arg("--connection-token")
                    .arg(&token)
                    .args(["--telemetry-level", "off"]);
                cmd
            }
        };
        let log_dir = cfg.state_dir.join("editors");
        std::fs::create_dir_all(&log_dir).map_err(|e| WsError::Failed(e.to_string()))?;
        let log_path = log_dir.join(format!("{kind:?}-{port}.log").to_lowercase());
        let log = std::fs::File::create(&log_path).map_err(|e| WsError::Failed(e.to_string()))?;
        let log_err = log
            .try_clone()
            .map_err(|e| WsError::Failed(e.to_string()))?;
        cmd.current_dir(folder)
            .stdin(Stdio::null())
            .stdout(log)
            .stderr(log_err)
            .process_group(0)
            .kill_on_drop(true);
        let child = cmd
            .spawn()
            .map_err(|e| WsError::Failed(format!("starting the editor: {e}")))?;
        let pid = child.id().unwrap_or_default();
        let mut run = Running {
            info: EditorInstance {
                kind,
                folder: folder_s.clone(),
                port,
                token: token.clone(),
                url_path: url_path(&token, &folder_s),
                pid,
                started_at: UnixMillis(crate::identity::now_millis()),
            },
            child,
        };
        wait_ready(&mut run, &log_path).await?;
        let info = run.info.clone();
        self.running.lock().await.insert(folder_s, run);
        tracing::info!(?kind, port, folder = %folder.display(), "editor started");
        Ok(info)
    }

    pub async fn stop(&self, folder: &str) -> Result<(), WsError> {
        self.running
            .lock()
            .await
            .remove(folder)
            .map(drop)
            .ok_or_else(|| WsError::NotFound(format!("no editor serving {folder}")))
    }

    pub async fn stop_all(&self) {
        self.running.lock().await.clear();
    }

    pub async fn open(
        &self,
        folder: Option<&str>,
        path: &Path,
        line: Option<u32>,
        column: Option<u32>,
    ) -> Result<EditorOpened, WsError> {
        let instance = {
            let mut running = self.running.lock().await;
            reap(&mut running);
            match folder {
                Some(f) => running.get(f).map(|r| r.info.clone()),
                None => running
                    .values()
                    .filter(|r| path.starts_with(&r.info.folder))
                    .max_by_key(|r| r.info.folder.len())
                    .map(|r| r.info.clone()),
            }
        }
        .ok_or_else(|| {
            WsError::NotFound(format!(
                "no running editor for {}; launch one first",
                path.display()
            ))
        })?;
        let goto = match (line, column) {
            (Some(l), Some(c)) => format!("{}:{l}:{c}", path.display()),
            (Some(l), None) => format!("{}:{l}", path.display()),
            _ => path.display().to_string(),
        };
        let in_window = open_via_cli(instance.pid, &goto).await;
        let payload = format!(
            "[[\"openFile\",\"vscode-remote://localhost:{}{}\"],[\"gotoLineMode\",\"true\"]]",
            instance.port,
            json_escape(&goto)
        );
        let url_path = format!("{}&payload={}", instance.url_path, encode(&payload));
        Ok(EditorOpened {
            instance,
            in_window,
            url_path,
        })
    }

    /// Downloads, verifies and unpacks the pinned openvscode-server once.
    async fn ensure_openvscode(&self, cfg: &Config) -> Result<PathBuf, WsError> {
        let dir = openvscode_dir(cfg).ok_or_else(|| {
            WsError::Unavailable(
                "openvscode-server publishes Linux builds only (x86_64, arm64); on macOS install \
                 VS Code's `code` CLI and use code serve-web"
                    .into(),
            )
        })?;
        if openvscode_bin(&dir).is_file() {
            return Ok(dir);
        }
        if cfg.openvscode_dir.is_some() {
            return Err(WsError::NotFound(format!(
                "{} not found",
                openvscode_bin(&dir).display()
            )));
        }
        let _guard = self.install.lock().await;
        if openvscode_bin(&dir).is_file() {
            return Ok(dir);
        }
        let (arch, sha) = openvscode_build().expect("dir implies a build");
        let name = format!("openvscode-server-{OPENVSCODE_VERSION}-linux-{arch}");
        let url = format!(
            "https://github.com/gitpod-io/openvscode-server/releases/download/\
             openvscode-server-{OPENVSCODE_VERSION}/{name}.tar.gz"
        );
        let dir2 = dir.clone();
        tokio::task::spawn_blocking(move || install(&url, sha, &name, &dir2))
            .await
            .map_err(|e| WsError::Failed(e.to_string()))??;
        Ok(dir)
    }
}

fn reap(running: &mut HashMap<String, Running>) {
    running.retain(|_, r| matches!(r.child.try_wait(), Ok(None)));
}

/// Waits until the server accepts connections, or fails with the end of its log.
async fn wait_ready(run: &mut Running, log: &Path) -> Result<(), WsError> {
    let start = Instant::now();
    loop {
        if let Ok(Some(status)) = run.child.try_wait() {
            return Err(WsError::Failed(format!(
                "the editor exited ({status}): {}",
                log_tail(log)
            )));
        }
        if tokio::net::TcpStream::connect(("127.0.0.1", run.info.port))
            .await
            .is_ok()
        {
            return Ok(());
        }
        if start.elapsed() > START_TIMEOUT {
            return Err(WsError::Failed(format!(
                "the editor did not start listening: {}",
                log_tail(log)
            )));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn log_tail(path: &Path) -> String {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let tail: Vec<&str> = text.lines().rev().take(5).collect();
    tail.into_iter().rev().collect::<Vec<_>>().join(" | ")
}

fn json_escape(s: &str) -> String {
    serde_json::to_string(s)
        .map(|q| q[1..q.len() - 1].to_owned())
        .unwrap_or_default()
}

/// Opens `goto` (`path[:line[:col]]`) in the server's open window through its remote CLI.
/// Returns whether that worked.
pub(crate) async fn open_via_cli(server_pid: u32, goto: &str) -> bool {
    let found = tokio::task::spawn_blocking(move || {
        procinfo::process_tree(server_pid)
            .into_iter()
            .find_map(|pid| {
                let hook = procinfo::process_env_var(pid, "VSCODE_IPC_HOOK_CLI")?;
                // The extension host runs the server's bundled node: `<server>/node`.
                let server = procinfo::exe_path(pid)?.parent()?.to_owned();
                let cli = std::fs::read_dir(server.join("bin/remote-cli"))
                    .ok()?
                    .filter_map(Result::ok)
                    .map(|e| e.path())
                    .find(|p| p.is_file())?;
                Some((hook, cli))
            })
    })
    .await
    .ok()
    .flatten();
    let Some((hook, cli)) = found else {
        return false;
    };
    let run = Command::new(&cli)
        .args(["--goto", goto])
        .env("VSCODE_IPC_HOOK_CLI", hook)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .status();
    matches!(
        tokio::time::timeout(Duration::from_secs(15), run).await,
        Ok(Ok(s)) if s.success()
    )
}

/// curl (or wget) → SHA-256 check → `tar -xzf` → atomic rename into `dir`.
fn install(url: &str, sha256: &str, name: &str, dir: &Path) -> Result<(), WsError> {
    let parent = dir.parent().expect("under the state dir");
    std::fs::create_dir_all(parent).map_err(|e| WsError::Failed(e.to_string()))?;
    let tag = fsutil::hex(&fsutil::random::<4>());
    let tarball = parent.join(format!(".{name}-{tag}.tar.gz"));
    let staging = parent.join(format!(".{name}-{tag}"));
    let cleanup = || {
        let _ = std::fs::remove_file(&tarball);
        let _ = std::fs::remove_dir_all(&staging);
    };
    tracing::info!(%url, "downloading openvscode-server");
    let fetched = std::process::Command::new("curl")
        .args(["-fsSL", "--retry", "3", "-o"])
        .arg(&tarball)
        .arg(url)
        .status()
        .or_else(|_| {
            std::process::Command::new("wget")
                .args(["-q", "-O"])
                .arg(&tarball)
                .arg(url)
                .status()
        });
    if !fetched.is_ok_and(|s| s.success()) {
        cleanup();
        return Err(WsError::Failed(format!(
            "downloading {url} failed (curl/wget)"
        )));
    }
    let got = sha256_file(&tarball).map_err(|e| WsError::Failed(e.to_string()))?;
    if got != sha256 {
        cleanup();
        return Err(WsError::Failed(format!(
            "openvscode-server checksum mismatch: got {got}, pinned {sha256}"
        )));
    }
    std::fs::create_dir_all(&staging).map_err(|e| WsError::Failed(e.to_string()))?;
    let unpacked = std::process::Command::new("tar")
        .arg("-xzf")
        .arg(&tarball)
        .arg("-C")
        .arg(&staging)
        .status();
    if !unpacked.is_ok_and(|s| s.success()) {
        cleanup();
        return Err(WsError::Failed("unpacking openvscode-server failed".into()));
    }
    let inner = staging.join(name);
    let result = std::fs::rename(&inner, dir).map_err(|e| WsError::Failed(e.to_string()));
    cleanup();
    result
}

pub(crate) fn sha256_file(path: &Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buf = vec![0; 1 << 16];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
    }
    Ok(fsutil::hex(ctx.finish().as_ref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_and_encodes() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("x");
        std::fs::write(&f, b"abc").unwrap();
        assert_eq!(
            sha256_file(&f).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(url_path("t", "/a b"), "/?tkn=t&folder=/a%20b");
    }
}
