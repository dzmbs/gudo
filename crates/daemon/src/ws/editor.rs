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
use serde::{Deserialize, Serialize};
use tokio::process::{Child, Command};

use super::editor_ports::EditorPorts;
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
/// Only a folder opened this recently is prewarmed.
const PREWARM_RECENCY: Duration = Duration::from_secs(7 * 24 * 3600);
/// A prewarmed server no client used stops after this long.
const PREWARM_UNUSED: Duration = Duration::from_secs(15 * 60);
/// How long a stopping server gets to end before it is killed.
const STOP_GRACE: Duration = Duration::from_secs(2);

struct Running {
    /// `info.port` is the proxy's port when there is one, else the server's.
    info: EditorInstance,
    upstream_port: u16,
    child: Child,
    proxy: Option<EditorProxy>,
    server_dir: Option<PathBuf>,
    origin: LaunchOrigin,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LaunchOrigin {
    Client,
    /// Started ahead of a client for the folder opened last.
    Prewarm,
}

/// The editor a client launched last, prewarmed when an owner connects.
#[derive(Debug, Serialize, Deserialize)]
struct LastLaunch {
    folder: PathBuf,
    kind: EditorKind,
    accept_vscode_license: bool,
    at: UnixMillis,
}

impl Running {
    /// Stops the server and waits a moment for it to end, so a server started next for the
    /// folder gets its port.
    async fn stop(mut self) {
        if let Some(proxy) = self.proxy.take() {
            proxy.close().await;
        }
        self.signal_group(libc::SIGTERM);
        if tokio::time::timeout(STOP_GRACE, self.child.wait())
            .await
            .is_err()
        {
            self.signal_group(libc::SIGKILL);
            let _ = tokio::time::timeout(STOP_GRACE, self.child.wait()).await;
        }
    }

    /// Signals the server's process group (extension hosts, the downloaded server under
    /// `code serve-web`), only while the server is unreaped: after that its pid may be reused.
    fn signal_group(&self, signal: libc::c_int) {
        let Some(pid) = self.child.id().filter(|&pid| pid != 0) else {
            return;
        };
        // SAFETY: plain syscall; the group id is the child's pid (process_group(0)).
        unsafe { libc::kill(-(pid as libc::pid_t), signal) };
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        self.signal_group(libc::SIGTERM);
        let _ = self.child.start_kill();
    }
}

pub(crate) struct Editors {
    running: tokio::sync::Mutex<HashMap<String, Running>>,
    /// Serialises the openvscode and VSCodium downloads.
    install: tokio::sync::Mutex<()>,
    /// Compressed static assets, shared by every editor's proxy.
    asset_cache: std::sync::OnceLock<std::sync::Arc<AssetCache>>,
    /// Microsoft's server, run directly.
    servers: Servers,
    update_wanted: tokio::sync::Notify,
    prewarm_wanted: tokio::sync::Notify,
    ports: EditorPorts,
    last_launch_path: PathBuf,
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
    pub(crate) fn new(config: &Config) -> Self {
        Self {
            running: tokio::sync::Mutex::default(),
            install: tokio::sync::Mutex::default(),
            asset_cache: std::sync::OnceLock::new(),
            servers: Servers::default(),
            update_wanted: tokio::sync::Notify::new(),
            prewarm_wanted: tokio::sync::Notify::new(),
            ports: EditorPorts::load(config.state_dir.join("editors").join("ports.json")),
            last_launch_path: config.state_dir.join("editors").join("last-launch.json"),
        }
    }

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
        let instance = self
            .start(config, request, folder, LaunchOrigin::Client)
            .await?;
        let last = LastLaunch {
            folder: folder.to_owned(),
            kind: instance.kind,
            accept_vscode_license: request.accept_vscode_license,
            at: UnixMillis(crate::identity::now_millis()),
        };
        let path = self.last_launch_path.clone();
        let saved = tokio::task::spawn_blocking(move || {
            serde_json::to_vec(&last)
                .map_err(std::io::Error::other)
                .and_then(|bytes| fsutil::write_atomic(&path, &bytes))
        })
        .await
        .map_err(std::io::Error::other)
        .flatten();
        if let Err(error) = saved {
            tracing::warn!("recording the last editor launch: {error}");
        }
        Ok(instance)
    }

    /// Asks [`prewarm_on_connect`] to start the last launched editor ahead of the client.
    pub(crate) fn want_prewarm(&self) {
        self.prewarm_wanted.notify_one();
    }

    async fn prewarm(&self, config: &Config, policy: &super::Policy) {
        let Some(last) = std::fs::read(&self.last_launch_path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<LastLaunch>(&bytes).ok())
        else {
            return;
        };
        let age = Duration::from_millis(crate::identity::now_millis().saturating_sub(last.at.0));
        if age > PREWARM_RECENCY || !config.editor_compress || !self.is_installed(config, last.kind)
        {
            return;
        }
        let folder_key = last.folder.to_string_lossy().into_owned();
        if policy.resolve(&folder_key).is_err() {
            return;
        }
        {
            let mut running = self.running.lock().await;
            reap(&mut running);
            if running.contains_key(&folder_key)
                || running
                    .values()
                    .any(|editor| editor.origin == LaunchOrigin::Prewarm)
            {
                return;
            }
        }
        let request = EditorLaunch {
            folder: folder_key,
            choice: EditorChoice::Only(last.kind),
            accept_vscode_license: last.accept_vscode_license,
        };
        if let Err(error) = self
            .start(config, &request, &last.folder, LaunchOrigin::Prewarm)
            .await
        {
            tracing::info!(folder = %last.folder.display(), "no editor prewarmed: {error}");
        }
    }

    /// Whether `kind` starts without downloading anything first.
    fn is_installed(&self, config: &Config, kind: EditorKind) -> bool {
        match kind {
            EditorKind::VsCode => {
                !config.vscode_serve_web
                    && find_code(config).is_some()
                    && self.servers.installed(config).is_some()
            }
            EditorKind::OpenVsCode => {
                openvscode_dir(config).is_some_and(|dir| openvscode_bin(&dir).is_file())
            }
            EditorKind::Vscodium => {
                vscodium_dir(config).is_some_and(|dir| vscodium_bin(&dir).is_file())
            }
        }
    }

    async fn start(
        &self,
        config: &Config,
        request: &EditorLaunch,
        folder: &Path,
        origin: LaunchOrigin,
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
            let refusing = {
                let mut running = self.running.lock().await;
                running
                    .get(&folder_key)
                    .is_some_and(|editor| editor.info.pid == info.pid)
                    .then(|| running.remove(&folder_key))
                    .flatten()
            };
            if let Some(editor) = refusing {
                editor.stop().await;
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
        let code = match (kind, code) {
            (EditorKind::VsCode, None) => {
                return Err(WsError::Unavailable(
                    "the VS Code `code` CLI is not installed".into(),
                ));
            }
            (EditorKind::VsCode, Some(_)) if !request.accept_vscode_license => {
                return Err(WsError::Denied(
                    "code serve-web needs the Microsoft VS Code Server licence accepted \
                     (https://aka.ms/vscode-server-license)"
                        .into(),
                ));
            }
            (_, code) => code,
        };
        let replaced = self.running.lock().await.remove(&folder_key);
        if let Some(editor) = replaced {
            editor.stop().await;
        }
        let stable = self
            .ports
            .bind(&folder_key)
            .await
            .map_err(|error| WsError::Failed(format!("no free port: {error}")))?;
        let (port, proxy_listener) = if config.editor_compress {
            (free_port()?, Some(stable))
        } else {
            let port = stable
                .local_addr()
                .map_err(|error| WsError::Failed(error.to_string()))?
                .port();
            drop(stable);
            (port, None)
        };
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
            origin,
        };
        wait_ready(&mut editor, &log_path).await?;
        if let Some(listener) = proxy_listener {
            let cache = self
                .asset_cache
                .get_or_init(|| AssetCache::new(config.state_dir.join("editors").join("cache")));
            let proxy = EditorProxy::start(listener, port, Some(std::sync::Arc::clone(cache)))
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
        tracing::info!(?kind, ?origin, port, proxy = info.port, folder = %folder.display(), elapsed_ms = started.elapsed().as_millis(), "editor started");
        Ok(info)
    }

    /// Reaps idle servers and fetches a newer VS Code server when a check is due.
    pub(crate) async fn keep_current(&self, config: &Config) {
        let in_use = self.servers_in_use().await;
        if config.vscode_serve_web {
            return;
        }
        if let Err(error) = self.servers.update_if_due(config, in_use).await {
            tracing::debug!("VS Code server update: {error}");
        }
    }

    /// The VS Code server directories editors run from.
    async fn servers_in_use(&self) -> Vec<PathBuf> {
        let in_use: Vec<PathBuf> = {
            let mut running = self.running.lock().await;
            reap(&mut running);
            running
                .values()
                .filter_map(|editor| editor.server_dir.clone())
                .collect()
        };
        in_use
    }

    pub async fn stop(&self, folder: &str) -> Result<(), WsError> {
        let editor = self
            .running
            .lock()
            .await
            .remove(folder)
            .ok_or_else(|| WsError::NotFound(format!("no editor serving {folder}")))?;
        editor.stop().await;
        Ok(())
    }

    pub async fn stop_all(&self) {
        if let Some(cache) = self.asset_cache.get() {
            cache.close();
        }
        let editors: Vec<Running> = self
            .running
            .lock()
            .await
            .drain()
            .map(|(_, editor)| editor)
            .collect();
        futures_util::future::join_all(editors.into_iter().map(Running::stop)).await;
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

/// Prewarms the last launched editor each time [`Editors::want_prewarm`] is called, one at a time.
pub(crate) async fn prewarm_on_connect(core: std::sync::Arc<crate::core::Core>) {
    let editors = &core.ws.editors;
    loop {
        editors.prewarm_wanted.notified().await;
        editors.prewarm(&core.cfg, &core.ws.policy).await;
    }
}

/// Whether the server on `port` still accepts its own token. A slow answer counts as yes, so a
/// busy server is never restarted.
async fn accepts_token(port: u16, token: &str) -> bool {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    const PROBE_TIMEOUT: Duration = Duration::from_millis(300);
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
        let has_served = editor.proxy.as_ref().is_some_and(EditorProxy::has_served);
        let grace = idle_limit(editor.origin, has_served);
        matches!(editor.child.try_wait(), Ok(None))
            && editor
                .proxy
                .as_ref()
                .and_then(EditorProxy::idle_for)
                .is_none_or(|idle| idle < grace)
    });
}

fn idle_limit(origin: LaunchOrigin, has_served: bool) -> Duration {
    match origin {
        LaunchOrigin::Prewarm if !has_served => PREWARM_UNUSED,
        _ => vscode_server::RECONNECTION_GRACE,
    }
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

    #[test]
    fn an_unused_prewarm_stops_long_before_a_used_server() {
        assert_eq!(idle_limit(LaunchOrigin::Prewarm, false), PREWARM_UNUSED);
        assert_eq!(
            idle_limit(LaunchOrigin::Prewarm, true),
            vscode_server::RECONNECTION_GRACE
        );
        assert_eq!(
            idle_limit(LaunchOrigin::Client, false),
            vscode_server::RECONNECTION_GRACE
        );
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
        let silent = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let started = Instant::now();
        assert!(accepts_token(silent.local_addr().unwrap().port(), "t").await);
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "a busy server never holds up its reuse"
        );
        let gone = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = gone.local_addr().unwrap().port();
        drop(gone);
        assert!(!accepts_token(port, "t").await, "nothing listening");
    }

    #[tokio::test]
    async fn stopping_a_server_waits_until_it_and_its_group_are_gone() {
        let state = tempfile::tempdir().unwrap();
        let child = Command::new("/bin/sh")
            .args(["-c", "trap '' TERM; /bin/sleep 60 & echo $! > helper; wait"])
            .current_dir(state.path())
            .process_group(0)
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let pid = child.id().unwrap();
        let helper_file = state.path().join("helper");
        let deadline = Instant::now() + Duration::from_secs(10);
        let helper: libc::pid_t = loop {
            if let Some(pid) = std::fs::read_to_string(&helper_file)
                .ok()
                .and_then(|text| text.trim().parse().ok())
            {
                break pid;
            }
            assert!(Instant::now() < deadline, "the helper never started");
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        let editor = Running {
            info: EditorInstance {
                kind: EditorKind::OpenVsCode,
                folder: "/src/app".into(),
                port: 1,
                token: "t".into(),
                url_path: "/".into(),
                pid,
                started_at: UnixMillis(0),
            },
            upstream_port: 1,
            child,
            proxy: None,
            server_dir: None,
            origin: LaunchOrigin::Client,
        };
        editor.stop().await;
        // SAFETY: signal 0 only asks whether the process exists.
        assert_ne!(unsafe { libc::kill(pid as libc::pid_t, 0) }, 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        // SAFETY: as above.
        while unsafe { libc::kill(helper, 0) } == 0 {
            assert!(Instant::now() < deadline, "the server's helper outlived it");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}
