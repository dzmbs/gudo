//! The editor server: VS Code's `code serve-web` when the user has the `code` CLI and accepted
//! Microsoft's licence in the app; VSCodium's Web Host (MIT, Open VSX) as the automatic fallback
//! when that CLI cannot be had (the client decides, DAEMON.md §5.3) or as the host's
//! `editor.default`; Gitpod's openvscode-server (MIT) only when asked for. The last two are
//! downloaded on demand into the state directory and SHA-256 pinned. Each is bound to
//! `127.0.0.1` with a random connection token, one server per workspace folder, and reached by
//! the app through a port forward. The server belongs to the daemon (not a pane) and stops with
//! it.
//!
//! "Open file at line" first uses the editor's own CLI channel: the server's extension host
//! exports `VSCODE_IPC_HOOK_CLI`, and its bundled remote CLI (`bin/remote-cli/*`) with that
//! socket opens the file in the window already showing the folder. Without a window (or on a
//! failure) it falls back to a URL the app loads, whose `payload` (`openFile` +
//! `gotoLineMode`) makes the workbench open the file at the line.
//!
//! The port handed to the app is not the server's own but that of a compressing proxy in
//! front of it ([`super::editor_proxy`]), unless `editor.compress = false`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use proto::{
    EditorAvailability, EditorChoice, EditorInstance, EditorKind, EditorLaunch, EditorList,
    EditorOpened, UnixMillis, WsError,
};
use tokio::process::{Child, Command};

use super::editor_proxy::{AssetCache, EditorProxy};
use super::vscode_server::{self, Servers};
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
/// The pinned VSCodium Web Host (`vscodium-reh-web`) release.
pub(crate) const VSCODIUM_VERSION: &str = "1.140.06880";
/// `(target os, rust arch, release platform, SHA-256 of the tarball)`, from the release's
/// published `.sha256` files and re-checked on download.
const VSCODIUM_BUILDS: &[(&str, &str, &str, &str)] = &[
    (
        "linux",
        "x86_64",
        "linux-x64",
        "f16388ea58170613c6d5e492aa10410a471e1d86d8cb343e3c8147493a7981a9",
    ),
    (
        "linux",
        "aarch64",
        "linux-arm64",
        "d21cccd1f21f0960b0b4ecb366149a6883bd1c5c5ecd0b32d44e65a618096a9f",
    ),
    (
        "macos",
        "aarch64",
        "darwin-arm64",
        "171645ce6b9909a3b7bed388cf16c2e53c36832c96d07e8212e6303606c96f60",
    ),
    (
        "macos",
        "x86_64",
        "darwin-x64",
        "76062c1a3546852b0ecf1e9cb842cff21faa768b3e3d9fffbe18d27ec4c94619",
    ),
];
/// Long because `code serve-web` downloads Microsoft's server on its first run.
const START_TIMEOUT: Duration = Duration::from_secs(180);
const HOUSEKEEPING_INTERVAL: Duration = Duration::from_secs(600);

struct Running {
    /// `info.port` is the proxy's port when there is one, else the server's.
    info: EditorInstance,
    upstream_port: u16,
    child: Child,
    proxy: Option<EditorProxy>,
    server_dir: Option<PathBuf>,
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
    /// Serialises the openvscode and VSCodium downloads.
    install: tokio::sync::Mutex<()>,
    /// Compressed static assets, shared by every editor's proxy.
    asset_cache: std::sync::OnceLock<std::sync::Arc<AssetCache>>,
    /// Microsoft's server, run directly.
    servers: Servers,
    update_wanted: tokio::sync::Notify,
}

/// The user's own VS Code CLI, else the one the daemon installed from Microsoft.
fn find_code(config: &Config) -> Option<PathBuf> {
    find_user_code(config).or_else(|| super::tunnel::managed_cli(config))
}

/// The user's own VS Code CLI (`editor.code`, `PATH`, the usual install locations).
pub(crate) fn find_user_code(config: &Config) -> Option<PathBuf> {
    if let Some(code) = &config.code_cli {
        return code.is_file().then(|| code.clone());
    }
    let path = config.pane_var("PATH").unwrap_or_default();
    let home = config.home();
    std::env::split_paths(&path)
        .map(|dir| dir.join("code"))
        .chain([
            PathBuf::from("/usr/local/bin/code"),
            PathBuf::from("/opt/homebrew/bin/code"),
            PathBuf::from("/usr/bin/code"),
            PathBuf::from("/snap/bin/code"),
            PathBuf::from("/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
            home.join("Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
        ])
        .find(|candidate| candidate.is_file())
}

/// `(release arch, SHA-256)` of the openvscode-server build for this host.
fn openvscode_build() -> Option<(&'static str, &'static str)> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    OPENVSCODE_BUILDS
        .iter()
        .find(|(arch, _, _)| *arch == std::env::consts::ARCH)
        .map(|&(_, release_arch, sha256)| (release_arch, sha256))
}

fn openvscode_dir(config: &Config) -> Option<PathBuf> {
    if let Some(dir) = &config.openvscode_dir {
        return Some(dir.clone());
    }
    let (arch, _) = openvscode_build()?;
    Some(config.state_dir.join("editors").join(format!(
        "openvscode-server-{OPENVSCODE_VERSION}-linux-{arch}"
    )))
}

fn openvscode_bin(dir: &Path) -> PathBuf {
    dir.join("bin/openvscode-server")
}

/// `(release platform, SHA-256)` of the VSCodium build for this host.
fn vscodium_build() -> Option<(&'static str, &'static str)> {
    VSCODIUM_BUILDS
        .iter()
        .find(|(os, arch, _, _)| *os == std::env::consts::OS && *arch == std::env::consts::ARCH)
        .map(|&(_, _, platform, sha256)| (platform, sha256))
}

fn vscodium_dir(config: &Config) -> Option<PathBuf> {
    if let Some(dir) = &config.vscodium_dir {
        return Some(dir.clone());
    }
    let (platform, _) = vscodium_build()?;
    Some(
        config
            .state_dir
            .join("editors")
            .join(format!("vscodium-reh-web-{platform}-{VSCODIUM_VERSION}")),
    )
}

fn vscodium_bin(dir: &Path) -> PathBuf {
    dir.join("bin/codium-server")
}

fn token() -> String {
    fsutil::hex(&fsutil::random::<16>())
}

/// Percent-encodes a query value.
fn encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-_.~/".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// The workbench for `folder`, or an empty one when `folder` holds the home directory: a
/// workspace there would have the editor search and index everything under home.
fn url_path(token: &str, folder: &Path, home: &Path) -> String {
    if super::paths::holds_home(folder, home) {
        format!("/?tkn={token}")
    } else {
        format!("/?tkn={token}&folder={}", encode(&folder.to_string_lossy()))
    }
}

fn free_port() -> Result<u16, WsError> {
    std::net::TcpListener::bind(("127.0.0.1", 0))
        .and_then(|listener| listener.local_addr())
        .map(|addr| addr.port())
        .map_err(|error| WsError::Failed(format!("no free port: {error}")))
}

impl Editors {
    pub async fn status(&self, config: &Config) -> EditorList {
        let code = find_code(config);
        let openvscode = openvscode_dir(config);
        let openvscode_installed = openvscode
            .as_deref()
            .is_some_and(|dir| openvscode_bin(dir).is_file());
        let available = vec![
            EditorAvailability {
                kind: EditorKind::VsCode,
                installed: code.is_some(),
                downloadable: false,
                path: code.map(|path| path.to_string_lossy().into_owned()),
                version: None,
                note: Some(
                    "Microsoft VS Code Server licence: single user, no hosting as a service; \
                     the user must accept it (accept_vscode_license)"
                        .into(),
                ),
            },
            EditorAvailability {
                kind: EditorKind::OpenVsCode,
                installed: openvscode_installed,
                downloadable: openvscode_build().is_some() && config.openvscode_dir.is_none(),
                path: openvscode
                    .filter(|_| openvscode_installed)
                    .map(|dir| openvscode_bin(&dir).to_string_lossy().into_owned()),
                version: config
                    .openvscode_dir
                    .is_none()
                    .then(|| OPENVSCODE_VERSION.to_owned()),
                note: (openvscode_build().is_none() && config.openvscode_dir.is_none()).then(|| {
                    "openvscode-server publishes Linux builds only; install VS Code's `code` CLI"
                        .to_owned()
                }),
            },
            {
                let dir = vscodium_dir(config);
                let installed = dir.as_deref().is_some_and(|dir| vscodium_bin(dir).is_file());
                EditorAvailability {
                    kind: EditorKind::Vscodium,
                    installed,
                    downloadable: vscodium_build().is_some() && config.vscodium_dir.is_none(),
                    path: dir
                        .filter(|_| installed)
                        .map(|dir| vscodium_bin(&dir).to_string_lossy().into_owned()),
                    version: config
                        .vscodium_dir
                        .is_none()
                        .then(|| VSCODIUM_VERSION.to_owned()),
                    note: Some(if vscodium_build().is_some() || config.vscodium_dir.is_some() {
                        "VSCodium (MIT): extensions from Open VSX; no licence prompt, no sign-in"
                            .to_owned()
                    } else {
                        "VSCodium publishes Web Host builds for Linux and macOS on x86_64 and \
                         arm64 only"
                            .to_owned()
                    }),
                }
            },
        ];
        let mut running = self.running.lock().await;
        reap(&mut running);
        EditorList {
            available,
            running: running.values().map(|editor| editor.info.clone()).collect(),
        }
    }

    pub async fn launch(
        &self,
        config: &Config,
        request: &EditorLaunch,
        folder: &Path,
    ) -> Result<EditorInstance, WsError> {
        if !folder.is_dir() {
            return Err(WsError::NotFound(format!(
                "{} is not a directory",
                folder.display()
            )));
        }
        let started = Instant::now();
        let folder_key = folder.to_string_lossy().into_owned();
        let reusable = {
            let mut running = self.running.lock().await;
            reap(&mut running);
            running.get(&folder_key).and_then(|editor| {
                let wanted = match request.choice {
                    EditorChoice::Auto => None,
                    EditorChoice::Only(kind) => Some(kind),
                };
                wanted
                    .is_none_or(|kind| kind == editor.info.kind)
                    .then(|| (editor.info.clone(), editor.upstream_port))
            })
        };
        if let Some((info, upstream_port)) = reusable {
            if accepts_token(upstream_port, &info.token).await {
                tracing::info!(elapsed_ms = started.elapsed().as_millis(), folder = %folder.display(), "editor reused");
                return Ok(info);
            }
            tracing::warn!(folder = %folder.display(), pid = info.pid, "editor refuses its token; restarting it");
            let mut running = self.running.lock().await;
            if running
                .get(&folder_key)
                .is_some_and(|editor| editor.info.pid == info.pid)
            {
                running.remove(&folder_key);
            }
        }
        let code = find_code(config);
        // Auto says what is missing instead of silently switching editors; openvscode-server
        // is an explicit choice only.
        let kind = match request.choice {
            EditorChoice::Only(kind) => kind,
            EditorChoice::Auto if config.editor_default != EditorKind::VsCode => {
                config.editor_default
            }
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
        let log_dir = config.state_dir.join("editors");
        // From a private file, never the command line: other users of the host can read the
        // process list and reach the server on the shared loopback.
        let token_file = log_dir.join(format!("{port}.token"));
        fsutil::write_atomic(&token_file, token.as_bytes())
            .map_err(|error| WsError::Failed(error.to_string()))?;
        let mut server_dir = None;
        let mut command = match kind {
            EditorKind::VsCode => {
                let code = code.ok_or_else(|| {
                    WsError::Unavailable("the VS Code `code` CLI is not installed".into())
                })?;
                if !request.accept_vscode_license {
                    return Err(WsError::Denied(
                        "code serve-web needs the Microsoft VS Code Server licence accepted \
                         (https://aka.ms/vscode-server-license)"
                            .into(),
                    ));
                }
                let direct = if config.vscode_serve_web {
                    None
                } else {
                    self.servers
                        .ensure(config)
                        .await
                        .inspect_err(|error| {
                            tracing::warn!(
                                "no VS Code server to run directly ({error}); using code serve-web"
                            )
                        })
                        .ok()
                };
                server_dir.clone_from(&direct);
                match direct {
                    Some(dir) => vscode_server::command(&dir, port, &token_file),
                    None => {
                        let mut command = Command::new(code);
                        command
                            .args(["serve-web", "--host", "127.0.0.1", "--port"])
                            .arg(port.to_string())
                            .arg("--connection-token-file")
                            .arg(&token_file)
                            .arg("--accept-server-license-terms");
                        command
                    }
                }
            }
            EditorKind::OpenVsCode => {
                let dir = self.ensure_openvscode(config).await?;
                let mut command = Command::new(openvscode_bin(&dir));
                command
                    .args(["--host", "127.0.0.1", "--port"])
                    .arg(port.to_string())
                    .arg("--connection-token-file")
                    .arg(&token_file)
                    .args(["--telemetry-level", "off"]);
                command
            }
            // MIT, no server licence (its product.json has an empty `serverLicense`), so no
            // acceptance flag and never a prompt or sign-in.
            EditorKind::Vscodium => {
                let dir = self.ensure_vscodium(config).await?;
                let mut command = Command::new(vscodium_bin(&dir));
                command
                    .args(["--host", "127.0.0.1", "--port"])
                    .arg(port.to_string())
                    .arg("--connection-token-file")
                    .arg(&token_file)
                    .args(["--telemetry-level", "off"]);
                command
            }
        };
        let log_path = log_dir.join(format!("{kind:?}-{port}.log").to_lowercase());
        let log =
            std::fs::File::create(&log_path).map_err(|error| WsError::Failed(error.to_string()))?;
        let log_stderr = log
            .try_clone()
            .map_err(|error| WsError::Failed(error.to_string()))?;
        command
            .current_dir(folder)
            .stdin(Stdio::null())
            .stdout(log)
            .stderr(log_stderr)
            .process_group(0)
            .kill_on_drop(true);
        let child = command
            .spawn()
            .map_err(|error| WsError::Failed(format!("starting the editor: {error}")))?;
        let pid = child.id().unwrap_or_default();
        let mut editor = Running {
            info: EditorInstance {
                kind,
                folder: folder_key.clone(),
                port,
                token: token.clone(),
                url_path: url_path(&token, folder, &config.home()),
                pid,
                started_at: UnixMillis(crate::identity::now_millis()),
            },
            upstream_port: port,
            child,
            proxy: None,
            server_dir,
        };
        wait_ready(&mut editor, &log_path).await?;
        if config.editor_compress {
            let cache = self
                .asset_cache
                .get_or_init(|| AssetCache::new(config.state_dir.join("editors").join("cache")));
            let proxy = EditorProxy::start(port, Some(std::sync::Arc::clone(cache)))
                .await
                .map_err(|error| WsError::Failed(format!("starting the editor proxy: {error}")))?;
            editor.info.port = proxy.port();
            editor.proxy = Some(proxy);
        }
        let info = editor.info.clone();
        let runs_microsoft_server = editor.server_dir.is_some();
        self.running.lock().await.insert(folder_key, editor);
        if runs_microsoft_server {
            self.update_wanted.notify_one();
        }
        tracing::info!(?kind, port, proxy = info.port, folder = %folder.display(), elapsed_ms = started.elapsed().as_millis(), "editor started");
        Ok(info)
    }

    /// Reaps idle servers and fetches a newer VS Code server when a check is due.
    pub(crate) async fn keep_current(&self, config: &Config) {
        let in_use = {
            let mut running = self.running.lock().await;
            reap(&mut running);
            running
                .values()
                .filter_map(|editor| editor.server_dir.clone())
                .collect()
        };
        if config.vscode_serve_web {
            return;
        }
        if let Err(error) = self.servers.update_if_due(config, in_use).await {
            tracing::debug!("VS Code server update: {error}");
        }
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
        if let Some(cache) = self.asset_cache.get() {
            cache.close();
        }
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
                Some(folder) => running.get(folder).map(|editor| editor.info.clone()),
                None => running
                    .values()
                    .filter(|editor| path.starts_with(&editor.info.folder))
                    .max_by_key(|editor| editor.info.folder.len())
                    .map(|editor| editor.info.clone()),
            }
        }
        .ok_or_else(|| {
            WsError::NotFound(format!(
                "no running editor for {}; launch one first",
                path.display()
            ))
        })?;
        let goto = match (line, column) {
            (Some(line), Some(column)) => format!("{}:{line}:{column}", path.display()),
            (Some(line), None) => format!("{}:{line}", path.display()),
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
    async fn ensure_openvscode(&self, config: &Config) -> Result<PathBuf, WsError> {
        let dir = openvscode_dir(config).ok_or_else(|| {
            WsError::Unavailable(
                "openvscode-server publishes Linux builds only (x86_64, arm64); on macOS install \
                 VS Code's `code` CLI and use code serve-web"
                    .into(),
            )
        })?;
        if openvscode_bin(&dir).is_file() {
            return Ok(dir);
        }
        if config.openvscode_dir.is_some() {
            return Err(WsError::NotFound(format!(
                "{} not found",
                openvscode_bin(&dir).display()
            )));
        }
        let _guard = self.install.lock().await;
        if openvscode_bin(&dir).is_file() {
            return Ok(dir);
        }
        let (arch, sha256) = openvscode_build().expect("dir implies a build");
        let name = format!("openvscode-server-{OPENVSCODE_VERSION}-linux-{arch}");
        let url = format!(
            "https://github.com/gitpod-io/openvscode-server/releases/download/\
             openvscode-server-{OPENVSCODE_VERSION}/{name}.tar.gz"
        );
        let install_dir = dir.clone();
        tokio::task::spawn_blocking(move || {
            install(&url, sha256, &name, Some(&name), &install_dir)
        })
        .await
        .map_err(|error| WsError::Failed(error.to_string()))??;
        Ok(dir)
    }

    /// Downloads, verifies and unpacks the pinned VSCodium Web Host once.
    async fn ensure_vscodium(&self, config: &Config) -> Result<PathBuf, WsError> {
        let dir = vscodium_dir(config).ok_or_else(|| {
            WsError::Unavailable(
                "VSCodium publishes Web Host builds for Linux and macOS (x86_64, arm64) only"
                    .into(),
            )
        })?;
        if vscodium_bin(&dir).is_file() {
            return Ok(dir);
        }
        if config.vscodium_dir.is_some() {
            return Err(WsError::NotFound(format!(
                "{} not found",
                vscodium_bin(&dir).display()
            )));
        }
        let _guard = self.install.lock().await;
        if vscodium_bin(&dir).is_file() {
            return Ok(dir);
        }
        let (platform, sha256) = vscodium_build().expect("dir implies a build");
        let name = format!("vscodium-reh-web-{platform}-{VSCODIUM_VERSION}");
        let url = format!(
            "https://github.com/VSCodium/vscodium/releases/download/{VSCODIUM_VERSION}/{name}.tar.gz"
        );
        let install_dir = dir.clone();
        // The tarball has no top-level directory: the staging directory is the server.
        tokio::task::spawn_blocking(move || install(&url, sha256, &name, None, &install_dir))
            .await
            .map_err(|error| WsError::Failed(error.to_string()))??;
        Ok(dir)
    }
}

/// [`Editors::keep_current`] at start, periodically and after each launch.
pub(crate) async fn run(core: std::sync::Arc<crate::core::Core>) {
    let editors = &core.ws.editors;
    loop {
        editors.keep_current(&core.cfg).await;
        tokio::select! {
            () = tokio::time::sleep(HOUSEKEEPING_INTERVAL) => {}
            () = editors.update_wanted.notified() => {}
        }
    }
}

/// Whether the server on `port` still accepts its own token. A slow answer counts as yes, so a
/// busy server is never restarted.
async fn accepts_token(port: u16, token: &str) -> bool {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    const PROBE_TIMEOUT: Duration = Duration::from_secs(5);
    let probe = async {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .ok()?;
        let request = format!(
            "GET /?tkn={token} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(request.as_bytes()).await.ok()?;
        let mut head = [0u8; 32];
        let len = stream.read(&mut head).await.ok()?;
        std::str::from_utf8(&head[..len])
            .ok()?
            .split_whitespace()
            .nth(1)?
            .parse::<u16>()
            .ok()
    };
    match tokio::time::timeout(PROBE_TIMEOUT, probe).await {
        Ok(Some(status)) => !matches!(status, 401 | 403),
        Ok(None) => false,
        Err(_) => true,
    }
}

/// Forgets servers that exited, and stops those no workbench has used for as long as one
/// may stay away and still come back.
fn reap(running: &mut HashMap<String, Running>) {
    running.retain(|_, editor| {
        matches!(editor.child.try_wait(), Ok(None))
            && editor
                .proxy
                .as_ref()
                .and_then(EditorProxy::idle_for)
                .is_none_or(|idle| idle < vscode_server::RECONNECTION_GRACE)
    });
}

/// Waits until the server accepts connections, or fails with the end of its log.
async fn wait_ready(editor: &mut Running, log: &Path) -> Result<(), WsError> {
    let start = Instant::now();
    loop {
        if let Ok(Some(status)) = editor.child.try_wait() {
            return Err(WsError::Failed(format!(
                "the editor exited ({status}): {}",
                log_tail(log)
            )));
        }
        if tokio::net::TcpStream::connect(("127.0.0.1", editor.upstream_port))
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

fn json_escape(text: &str) -> String {
    serde_json::to_string(text)
        .map(|quoted| quoted[1..quoted.len() - 1].to_owned())
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
                    .map(|entry| entry.path())
                    .find(|path| path.is_file())?;
                Some((hook, cli))
            })
    })
    .await
    .ok()
    .flatten();
    let Some((hook, cli)) = found else {
        return false;
    };
    let status = Command::new(&cli)
        .args(["--goto", goto])
        .env("VSCODE_IPC_HOOK_CLI", hook)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .status();
    matches!(
        tokio::time::timeout(Duration::from_secs(15), status).await,
        Ok(Ok(status)) if status.success()
    )
}

/// curl (or wget) → SHA-256 check → `tar -xzf` → atomic rename into `dir`. `inner` is the
/// tarball's top-level directory (`None`: the tarball is the directory's contents).
fn install(
    url: &str,
    sha256: &str,
    name: &str,
    inner: Option<&str>,
    dir: &Path,
) -> Result<(), WsError> {
    let parent = dir.parent().expect("under the state dir");
    std::fs::create_dir_all(parent).map_err(|error| WsError::Failed(error.to_string()))?;
    let tag = fsutil::hex(&fsutil::random::<4>());
    let tarball = parent.join(format!(".{name}-{tag}.tar.gz"));
    let staging = parent.join(format!(".{name}-{tag}"));
    let cleanup = || {
        let _ = std::fs::remove_file(&tarball);
        let _ = std::fs::remove_dir_all(&staging);
    };
    tracing::info!(%url, "downloading {name}");
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
    if !fetched.is_ok_and(|status| status.success()) {
        cleanup();
        return Err(WsError::Failed(format!(
            "downloading {url} failed (curl/wget)"
        )));
    }
    let actual = sha256_file(&tarball).map_err(|error| WsError::Failed(error.to_string()))?;
    if actual != sha256 {
        cleanup();
        return Err(WsError::Failed(format!(
            "{name} checksum mismatch: got {actual}, pinned {sha256}"
        )));
    }
    std::fs::create_dir_all(&staging).map_err(|error| WsError::Failed(error.to_string()))?;
    let unpacked = std::process::Command::new("tar")
        .arg("-xzf")
        .arg(&tarball)
        .arg("-C")
        .arg(&staging)
        .status();
    if !unpacked.is_ok_and(|status| status.success()) {
        cleanup();
        return Err(WsError::Failed(format!("unpacking {name} failed")));
    }
    let unpacked_dir = inner.map_or_else(|| staging.clone(), |inner| staging.join(inner));
    let result =
        std::fs::rename(&unpacked_dir, dir).map_err(|error| WsError::Failed(error.to_string()));
    cleanup();
    result
}

pub(crate) fn sha256_file(path: &Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    let mut chunk = vec![0; 1 << 16];
    loop {
        let len = file.read(&mut chunk)?;
        if len == 0 {
            break;
        }
        digest.update(&chunk[..len]);
    }
    Ok(fsutil::hex(digest.finish().as_ref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_and_encodes() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("x");
        std::fs::write(&file, b"abc").unwrap();
        assert_eq!(
            sha256_file(&file).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let home = dir.path().join("me");
        assert_eq!(
            url_path("t", Path::new("/a b"), &home),
            "/?tkn=t&folder=/a%20b"
        );
    }

    #[test]
    fn opens_no_workspace_on_home_or_above() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("me");
        let project = home.join("projects/app");
        std::fs::create_dir_all(&project).unwrap();

        assert_eq!(url_path("t", &home, &home), "/?tkn=t");
        assert_eq!(url_path("t", root.path(), &home), "/?tkn=t");
        assert_eq!(url_path("t", Path::new("/"), &home), "/?tkn=t");
        assert!(url_path("t", &project, &home).ends_with("/me/projects/app"));
    }

    /// A one-shot server answering with `status`; its port.
    async fn answering(status: &'static str) -> u16 {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 512];
            let _ = stream.read(&mut request).await;
            let reply = format!("HTTP/1.1 {status}\r\ncontent-length: 0\r\n\r\n");
            let _ = stream.write_all(reply.as_bytes()).await;
        });
        port
    }

    #[tokio::test]
    async fn a_server_refusing_its_token_is_not_reused() {
        assert!(accepts_token(answering("302 Found").await, "t").await);
        assert!(accepts_token(answering("200 OK").await, "t").await);
        assert!(!accepts_token(answering("403 Forbidden").await, "t").await);
        let gone = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = gone.local_addr().unwrap().port();
        drop(gone);
        assert!(!accepts_token(port, "t").await, "nothing listening");
    }
}
