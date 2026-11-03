//! Real Microsoft VS Code through a Remote Tunnel.
//!
//! The host runs Microsoft's own `code tunnel`, signed in with the user's own GitHub or
//! Microsoft account (device code), and the app opens `https://vscode.dev/tunnel/<name>/<path>`
//! (or desktop VS Code through `vscode://vscode-remote/tunnel+<name>/<path>`). That is the
//! Microsoft-hosted, Microsoft-licensed path: Marketplace extensions, Copilot, Settings Sync.
//!
//! - **CLI**: the user's own `code` (config, `PATH`, the app bundle) or, only when the user
//!   asks and accepted the VS Code licence in the app, the CLI downloaded from Microsoft's
//!   update service (`update.code.visualstudio.com`), checked against the SHA-256 that service
//!   publishes, version and hash recorded in `<state>/vscode/cli/install.json`.
//! - **Tunnel**: one per host, a long-lived child in its own process group, started only with
//!   the server licence accepted in the app (`--accept-server-license-terms` is passed on the
//!   user's behalf after that). The device-code prompt and the vscode.dev link are parsed from
//!   its output and pushed to every client. It restarts with back-off when it exits, and again
//!   at daemon start once it was enabled (without starting a new sign-in then). A tunnel the
//!   user runs themselves (`code tunnel`, its service) is adopted, not duplicated.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use proto::{
    DeviceLogin, TunnelProvider, TunnelState, UnixMillis, VsCodeCli, VsCodeTunnelOpened,
    VsCodeTunnelStart, VsCodeTunnelStatus, WsError,
};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{broadcast, mpsc};
use tokio::task::AbortHandle;

use crate::config::Config;
use crate::core::{Event, lock};
use crate::fsutil;

/// Microsoft's update service (the CLI's own self-update source).
pub const DEFAULT_UPDATE_URL: &str = "https://update.code.visualstudio.com";
/// Longest tunnel machine name the service accepts.
const MAX_NAME_LEN: usize = 20;
/// Lines of tunnel output kept for failure messages.
const TAIL_LINES: usize = 8;
/// A run this long resets the restart back-off.
const HEALTHY_RUN: Duration = Duration::from_secs(60);
const MAX_BACKOFF: Duration = Duration::from_secs(60);
const ADOPTED_POLL: Duration = Duration::from_secs(30);

/// What survives a daemon restart (`<state>/vscode/tunnel.json`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Record {
    enabled: bool,
    name: Option<String>,
    provider: Option<TunnelProvider>,
    /// When the user accepted the server licence in the app.
    license_accepted_at: Option<u64>,
}

/// A CLI the daemon installed (`<state>/vscode/cli/install.json`).
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Installed {
    path: PathBuf,
    version: String,
    commit: String,
    sha256: String,
    url: String,
    platform: String,
    installed_at: u64,
}

/// The update service's answer (`/api/update/<platform>/stable/latest`).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Release {
    pub url: String,
    /// The commit.
    pub version: String,
    pub product_version: Option<String>,
    pub name: Option<String>,
    pub sha256hash: String,
}

struct Inner {
    state: TunnelState,
    provider: Option<TunnelProvider>,
    /// Bumped whenever the supervisor is replaced: updates from an older one are dropped.
    generation: u64,
    task: Option<AbortHandle>,
    /// Our `code tunnel` process (its process group).
    pid: Option<u32>,
    /// `(path, version, commit)` of the last CLI asked for its version.
    version_cache: Option<(PathBuf, Option<String>, Option<String>)>,
}

/// The host's VS Code tunnel.
pub(crate) struct Tunnel {
    inner: Arc<Mutex<Inner>>,
    events: broadcast::Sender<Event>,
    install: tokio::sync::Mutex<()>,
}

impl Tunnel {
    pub fn new(events: broadcast::Sender<Event>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                state: TunnelState::Stopped,
                provider: None,
                generation: 0,
                task: None,
                pid: None,
                version_cache: None,
            })),
            events,
            install: tokio::sync::Mutex::new(()),
        }
    }

    pub async fn status(&self, config: &Config) -> VsCodeTunnelStatus {
        let cli = self.cli_info(config).await;
        let inner = lock(&self.inner);
        VsCodeTunnelStatus {
            cli,
            cli_downloadable: cli_platform().is_some(),
            state: inner.state.clone(),
            provider: inner.provider.or_else(|| load_record(config).provider),
        }
    }

    /// Downloads the CLI from Microsoft (the caller checked the licence was accepted).
    pub async fn install_cli(&self, config: &Config) -> Result<VsCodeTunnelStatus, WsError> {
        let _guard = self.install.lock().await;
        let platform = cli_platform().ok_or_else(|| {
            WsError::Unavailable(format!(
                "Microsoft publishes no VS Code CLI for {} {}",
                std::env::consts::OS,
                std::env::consts::ARCH
            ))
        })?;
        let base_url = config.vscode_update_url.clone();
        let root = cli_root(config);
        tokio::task::spawn_blocking(move || install_cli(&base_url, platform, &root))
            .await
            .map_err(|error| WsError::Failed(error.to_string()))??;
        lock(&self.inner).version_cache = None;
        let status = self.status(config).await;
        let _ = self.events.send(Event::VsCodeTunnel(status.clone()));
        Ok(status)
    }

    /// Starts the tunnel, or returns the running one (the caller checked the licence).
    pub async fn start(
        &self,
        config: &Config,
        request: &VsCodeTunnelStart,
    ) -> Result<VsCodeTunnelStatus, WsError> {
        let code = find_cli(config).ok_or_else(|| {
            WsError::Unavailable(
                "the VS Code `code` CLI is not installed (install it first: VsCodeCliInstall)"
                    .into(),
            )
        })?;
        let mut record = load_record(config);
        let name = match &request.name {
            Some(name) => valid_name(name)?,
            None => record
                .name
                .clone()
                .unwrap_or_else(|| default_name(&hostname())),
        };
        let restart = {
            let inner = lock(&self.inner);
            let alive = inner.task.as_ref().is_some_and(|task| !task.is_finished());
            let same = record.name.as_deref() == Some(name.as_str())
                && record.provider == Some(request.provider);
            // A failed tunnel that gave up, or a new name or account, starts over.
            !alive
                || !same
                || matches!(
                    inner.state,
                    TunnelState::Failed {
                        retrying: false,
                        ..
                    }
                )
        };
        record.enabled = true;
        record.name = Some(name.clone());
        record.provider = Some(request.provider);
        record.license_accepted_at = Some(crate::identity::now_millis());
        save_record(config, &record)?;
        if restart {
            self.spawn(config, code, name, request.provider, true);
        }
        Ok(self.status(config).await)
    }

    /// Restarts the tunnel at daemon start if the user had it running.
    pub fn autostart(&self, config: &Config) {
        let record = load_record(config);
        if !record.enabled || record.license_accepted_at.is_none() {
            return;
        }
        let (Some(name), Some(provider)) = (record.name, record.provider) else {
            return;
        };
        match find_cli(config) {
            Some(code) => self.spawn(config, code, name, provider, false),
            None => tracing::warn!("VS Code tunnel enabled but no `code` CLI found"),
        }
    }

    pub async fn stop(&self, config: &Config) -> Result<VsCodeTunnelStatus, WsError> {
        let mut record = load_record(config);
        record.enabled = false;
        save_record(config, &record)?;
        self.halt(TunnelState::Stopped);
        let status = self.status(config).await;
        let _ = self.events.send(Event::VsCodeTunnel(status.clone()));
        Ok(status)
    }

    /// Daemon shutdown: stop the process but keep it enabled for the next start.
    pub fn shutdown(&self) {
        self.halt(TunnelState::Stopped);
    }

    fn halt(&self, state: TunnelState) {
        let mut inner = lock(&self.inner);
        inner.generation += 1;
        if let Some(task) = inner.task.take() {
            task.abort();
        }
        if let Some(pid) = inner.pid.take() {
            kill_group(pid);
        }
        inner.state = state;
    }

    fn spawn(
        &self,
        config: &Config,
        code: PathBuf,
        name: String,
        provider: TunnelProvider,
        interactive: bool,
    ) {
        self.halt(TunnelState::Starting);
        let generation = {
            let mut inner = lock(&self.inner);
            inner.provider = Some(provider);
            inner.generation
        };
        let supervisor = Supervisor {
            inner: Arc::clone(&self.inner),
            events: self.events.clone(),
            generation,
            name,
            provider,
            log_dir: config.state_dir.join("editors"),
            cli: Some(managed_info(config, &code)),
            code,
        };
        let task = tokio::spawn(supervisor.run(interactive));
        lock(&self.inner).task = Some(task.abort_handle());
    }

    /// Where `path` opens through the running tunnel. `folder` is the workspace folder.
    pub async fn open(
        &self,
        folder: &Path,
        home: &Path,
        path: &Path,
        line: Option<u32>,
        column: Option<u32>,
    ) -> Result<VsCodeTunnelOpened, WsError> {
        let (name, web_url, pid) = {
            let inner = lock(&self.inner);
            match &inner.state {
                TunnelState::Running { name, web_url, .. } => {
                    (name.clone(), web_url.clone(), inner.pid)
                }
                _ => {
                    return Err(WsError::Unavailable(
                        "the VS Code tunnel is not running".into(),
                    ));
                }
            }
        };
        let base_url = web_url
            .find("/tunnel/")
            .map_or("https://vscode.dev", |index| &web_url[..index]);
        let suffix = match (line, column) {
            (Some(line), Some(column)) => format!(":{line}:{column}"),
            (Some(line), None) => format!(":{line}"),
            _ => String::new(),
        };
        let folder_text = folder.to_string_lossy().into_owned();
        let path_text = path.to_string_lossy().into_owned();
        let in_window = match pid {
            Some(pid) if path.is_file() => {
                super::editor::open_via_cli(pid, &format!("{path_text}{suffix}")).await
            }
            _ => false,
        };
        Ok(VsCodeTunnelOpened {
            web_url: workbench_url(base_url, &name, folder, home),
            desktop_uri: format!(
                "vscode://vscode-remote/tunnel+{name}{}{suffix}",
                url_path(&path_text)
            ),
            name,
            folder: folder_text,
            in_window,
        })
    }

    async fn cli_info(&self, config: &Config) -> Option<VsCodeCli> {
        let path = find_cli(config)?;
        let info = managed_info(config, &path);
        if info.managed {
            return Some(info);
        }
        let cached = lock(&self.inner)
            .version_cache
            .clone()
            .filter(|(cached_path, _, _)| *cached_path == path);
        let (version, commit) = match cached {
            Some((_, version, commit)) => (version, commit),
            None => {
                let (version, commit) = cli_version(&path).await;
                lock(&self.inner).version_cache =
                    Some((path.clone(), version.clone(), commit.clone()));
                (version, commit)
            }
        };
        Some(VsCodeCli {
            path: path.to_string_lossy().into_owned(),
            version,
            commit,
            sha256: None,
            managed: false,
        })
    }
}

impl Drop for Tunnel {
    fn drop(&mut self) {
        self.halt(TunnelState::Stopped);
    }
}

struct Supervisor {
    inner: Arc<Mutex<Inner>>,
    events: broadcast::Sender<Event>,
    generation: u64,
    code: PathBuf,
    name: String,
    provider: TunnelProvider,
    log_dir: PathBuf,
    cli: Option<VsCodeCli>,
}

/// Kills a child's process group when dropped (the tunnel's servers run under it).
struct ProcessGroup(Child);

impl Drop for ProcessGroup {
    fn drop(&mut self) {
        if let Some(pid) = self.0.id() {
            kill_group(pid);
        }
        let _ = self.0.start_kill();
    }
}

fn kill_group(pid: u32) {
    // SAFETY: plain syscall; the group id is the child's pid (process_group(0)).
    unsafe { libc::kill(-(pid as libc::pid_t), libc::SIGTERM) };
}

/// What a line of CLI output says.
#[derive(Debug, PartialEq, Eq)]
enum CliLine {
    DeviceCode { url: String, code: String },
    Link { name: String, url: String },
}

impl Supervisor {
    /// Publishes a state unless a newer supervisor replaced this one.
    fn set(&self, state: TunnelState) {
        let status = {
            let mut inner = lock(&self.inner);
            if inner.generation != self.generation {
                return;
            }
            inner.state = state.clone();
            VsCodeTunnelStatus {
                cli: self.cli.clone(),
                cli_downloadable: cli_platform().is_some(),
                state,
                provider: Some(self.provider),
            }
        };
        let _ = self.events.send(Event::VsCodeTunnel(status));
    }

    fn set_pid(&self, pid: Option<u32>) {
        let mut inner = lock(&self.inner);
        if inner.generation == self.generation {
            inner.pid = pid;
        }
    }

    async fn run(mut self, interactive: bool) {
        if let Some(cli) = self.cli.as_mut().filter(|cli| cli.version.is_none()) {
            (cli.version, cli.commit) = cli_version(&self.code).await;
        }
        let mut interactive = interactive;
        let mut backoff = Duration::from_secs(1);
        loop {
            // The user's own tunnel (or its service) already serves this machine.
            if let Some(name) = running_tunnel(&self.code).await {
                self.set(TunnelState::Running {
                    web_url: format!("https://vscode.dev/tunnel/{name}"),
                    name,
                    adopted: true,
                });
                while running_tunnel(&self.code).await.is_some() {
                    tokio::time::sleep(ADOPTED_POLL).await;
                }
                continue;
            }
            if !self.logged_in().await {
                if !interactive {
                    self.set(TunnelState::Failed {
                        message: "signed out of the tunnel service; start it from the app to \
                                  sign in again"
                            .into(),
                        retrying: false,
                    });
                    return;
                }
                self.set(TunnelState::Starting);
                if let Err(message) = self.login().await {
                    self.set(TunnelState::Failed {
                        message,
                        retrying: false,
                    });
                    return;
                }
            }
            self.set(TunnelState::Starting);
            let started = Instant::now();
            let message = self.tunnel().await;
            self.set_pid(None);
            if started.elapsed() >= HEALTHY_RUN {
                backoff = Duration::from_secs(1);
            }
            tracing::warn!(%message, ?backoff, "VS Code tunnel exited; restarting");
            self.set(TunnelState::Failed {
                message,
                retrying: true,
            });
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(MAX_BACKOFF);
            // A sign-in the user started from the app may be repeated on restarts.
            interactive = true;
        }
    }

    async fn logged_in(&self) -> bool {
        let status = Command::new(&self.code)
            .args(["tunnel", "user", "show"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .status();
        matches!(
            tokio::time::timeout(Duration::from_secs(30), status).await,
            Ok(Ok(status)) if status.success()
        )
    }

    /// `code tunnel user login --provider …`: publishes the device code, waits for the user.
    async fn login(&self) -> Result<(), String> {
        let provider = match self.provider {
            TunnelProvider::GitHub => "github",
            TunnelProvider::Microsoft => "microsoft",
        };
        let mut command = Command::new(&self.code);
        command.args(["tunnel", "user", "login", "--provider", provider]);
        let (mut child, mut lines) = spawn_lines(command, &self.log_dir.join("vscode-login.log"))?;
        let mut tail = Vec::new();
        while let Some(line) = lines.recv().await {
            if let Some(CliLine::DeviceCode { url, code }) = parse_line(&line) {
                self.set(TunnelState::NeedsLogin(DeviceLogin {
                    provider: self.provider,
                    verification_url: url,
                    user_code: code,
                    at: UnixMillis(crate::identity::now_millis()),
                }));
            }
            push_tail(&mut tail, line);
        }
        match child.0.wait().await {
            Ok(status) if status.success() => Ok(()),
            Ok(status) => Err(format!("sign-in failed ({status}): {}", tail.join(" | "))),
            Err(error) => Err(format!("sign-in failed: {error}")),
        }
    }

    /// Runs `code tunnel` until it exits; returns why it stopped.
    async fn tunnel(&self) -> String {
        let mut command = Command::new(&self.code);
        command
            .args(["tunnel", "--accept-server-license-terms", "--name"])
            .arg(&self.name);
        let (mut child, mut lines) =
            match spawn_lines(command, &self.log_dir.join("vscode-tunnel.log")) {
                Ok(spawned) => spawned,
                Err(error) => return error,
            };
        self.set_pid(child.0.id());
        let mut tail = Vec::new();
        while let Some(line) = lines.recv().await {
            match parse_line(&line) {
                Some(CliLine::DeviceCode { url, code }) => {
                    self.set(TunnelState::NeedsLogin(DeviceLogin {
                        provider: self.provider,
                        verification_url: url,
                        user_code: code,
                        at: UnixMillis(crate::identity::now_millis()),
                    }));
                }
                Some(CliLine::Link { name, url }) => {
                    tracing::info!(%name, %url, "VS Code tunnel connected");
                    self.set(TunnelState::Running {
                        name,
                        web_url: url,
                        adopted: false,
                    });
                }
                None => {}
            }
            push_tail(&mut tail, line);
        }
        let status = child.0.wait().await;
        format!(
            "code tunnel exited ({}): {}",
            status.map_or_else(|error| error.to_string(), |status| status.to_string()),
            tail.join(" | ")
        )
    }
}

fn push_tail(tail: &mut Vec<String>, line: String) {
    if !line.trim().is_empty() && !line.starts_with('*') {
        tail.push(line);
        if tail.len() > TAIL_LINES {
            tail.remove(0);
        }
    }
}

/// Spawns `command` in its own process group and streams its stdout and stderr lines (also
/// appended to `log`).
fn spawn_lines(
    mut command: Command,
    log: &Path,
) -> Result<(ProcessGroup, mpsc::UnboundedReceiver<String>), String> {
    if let Some(dir) = log.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .ok()
        .map(|file| Arc::new(Mutex::new(file)));
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|error| format!("starting the VS Code CLI: {error}"))?;
    let (tx, rx) = mpsc::unbounded_channel();
    let stdout = child
        .stdout
        .take()
        .map(|stream| Box::new(stream) as Box<dyn Reader>);
    let stderr = child
        .stderr
        .take()
        .map(|stream| Box::new(stream) as Box<dyn Reader>);
    for stream in [stdout, stderr].into_iter().flatten() {
        let tx = tx.clone();
        let log_file = log_file.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stream).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let line = strip_ansi(&line);
                if let Some(file) = &log_file {
                    use std::io::Write;
                    let _ = writeln!(lock(file), "{line}");
                }
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
    }
    Ok((ProcessGroup(child), rx))
}

trait Reader: tokio::io::AsyncRead + Unpin + Send {}
impl<T: tokio::io::AsyncRead + Unpin + Send> Reader for T {}

fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for ch in chars.by_ref() {
                    if ch.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
        } else if ch != '\r' {
            out.push(ch);
        }
    }
    out
}

/// Recognises the CLI's device-code prompt and its vscode.dev link:
///
/// - `To grant access to the server, please log into https://github.com/login/device and use
///   code 4766-3D57`
/// - `To sign in, use a web browser to open the page https://login.microsoft.com/device and
///   enter the code LW94CRGJT to authenticate.`
/// - `Open this link in your browser https://vscode.dev/tunnel/<name>/<folder>`
fn parse_line(line: &str) -> Option<CliLine> {
    let urls: Vec<&str> = line
        .split_whitespace()
        .filter(|word| word.starts_with("https://"))
        .map(|word| word.trim_end_matches(['.', ',', ')']))
        .collect();
    if let Some(url) = urls.iter().find(|url| url.contains("vscode.dev/tunnel/")) {
        let rest = &url[url.find("/tunnel/")? + "/tunnel/".len()..];
        let name = rest.split('/').next().filter(|name| !name.is_empty())?;
        return Some(CliLine::Link {
            name: name.to_owned(),
            url: (*url).to_owned(),
        });
    }
    let url = urls.first()?;
    let words: Vec<&str> = line.split_whitespace().collect();
    let code = words
        .windows(2)
        .find(|pair| pair[0].eq_ignore_ascii_case("code"))
        .map(|pair| pair[1].trim_end_matches(['.', ',']))
        .filter(|code| {
            code.len() >= 4
                && code
                    .chars()
                    .all(|ch| ch.is_ascii_alphanumeric() || ch == '-')
        })?;
    Some(CliLine::DeviceCode {
        url: (*url).to_owned(),
        code: code.to_owned(),
    })
}

/// The name of a tunnel already running on this machine (`code tunnel status`).
async fn running_tunnel(code: &Path) -> Option<String> {
    let output = Command::new(code)
        .args(["tunnel", "status"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(Duration::from_secs(30), output)
        .await
        .ok()?
        .ok()?;
    parse_status(&String::from_utf8_lossy(&output.stdout))
}

/// `{"tunnel":null,"service_installed":false}` or `{"tunnel":{"name":"box",…},…}`.
fn parse_status(text: &str) -> Option<String> {
    let json: serde_json::Value = serde_json::from_str(text.trim()).ok()?;
    let tunnel = json.get("tunnel")?;
    if tunnel.is_null() {
        return None;
    }
    tunnel
        .get("name")
        .and_then(|name| name.as_str())
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
}

async fn cli_version(code: &Path) -> (Option<String>, Option<String>) {
    let output = Command::new(code)
        .arg("--version")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(Duration::from_secs(15), output).await {
        Ok(Ok(output)) => parse_version(&String::from_utf8_lossy(&output.stdout)),
        _ => (None, None),
    }
}

/// `code 1.142.0 (commit 6d62…)` (the standalone CLI) or `1.105.1\n7d84…\narm64` (the
/// desktop launcher).
fn parse_version(text: &str) -> (Option<String>, Option<String>) {
    let text = text.trim();
    if let Some(rest) = text.strip_prefix("code ") {
        let version = rest.split_whitespace().next().map(str::to_owned);
        let commit = rest
            .split("commit ")
            .nth(1)
            .map(|commit| commit.trim_end_matches(')').trim().to_owned());
        return (version, commit);
    }
    let mut lines = text.lines();
    let version = lines
        .next()
        .filter(|line| line.chars().next().is_some_and(|ch| ch.is_ascii_digit()))
        .map(str::to_owned);
    let commit = lines
        .next()
        .map(|line| line.trim().to_owned())
        .filter(|_| version.is_some());
    (version, commit)
}

pub(crate) fn hostname() -> String {
    let mut name = [0u8; 256];
    // SAFETY: the buffer is valid for its length; gethostname NUL-terminates on success.
    let ok = unsafe { libc::gethostname(name.as_mut_ptr().cast(), name.len()) } == 0;
    if !ok {
        return String::new();
    }
    let end = name
        .iter()
        .position(|&byte| byte == 0)
        .unwrap_or(name.len());
    String::from_utf8_lossy(&name[..end]).into_owned()
}

/// A tunnel name from a host name: lowercase letters, digits and `-`, at most 20.
fn default_name(host: &str) -> String {
    let host = host.split('.').next().unwrap_or_default();
    let mut name: String = host
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    name.truncate(MAX_NAME_LEN);
    let name = name.trim_matches('-').to_owned();
    if name.is_empty() {
        format!("host-{}", fsutil::hex(&fsutil::random::<3>()))
    } else {
        name
    }
}

fn valid_name(name: &str) -> Result<String, WsError> {
    let ok = !name.is_empty()
        && name.len() <= MAX_NAME_LEN
        && name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-');
    if ok {
        Ok(name.to_owned())
    } else {
        Err(WsError::Invalid(format!(
            "tunnel name {name:?}: use at most {MAX_NAME_LEN} letters, digits and '-'"
        )))
    }
}

/// Percent-encodes a path for a URL, keeping `/`.
/// The tunnel's workbench on `folder`, or an empty one when `folder` holds the home directory
/// (the editor would search and index everything under home).
fn workbench_url(base_url: &str, name: &str, folder: &Path, home: &Path) -> String {
    if super::paths::holds_home(folder, home) {
        format!("{base_url}/tunnel/{name}")
    } else {
        format!(
            "{base_url}/tunnel/{name}{}",
            url_path(&folder.to_string_lossy())
        )
    }
}

fn url_path(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    if !path.starts_with('/') {
        out.push('/');
    }
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"-_.~/".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn record_path(config: &Config) -> PathBuf {
    config.state_dir.join("vscode").join("tunnel.json")
}

fn load_record(config: &Config) -> Record {
    fsutil::read_optional(&record_path(config))
        .ok()
        .flatten()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn save_record(config: &Config, record: &Record) -> Result<(), WsError> {
    let data =
        serde_json::to_vec_pretty(record).map_err(|error| WsError::Failed(error.to_string()))?;
    fsutil::write_atomic(&record_path(config), &data)
        .map_err(|error| WsError::Failed(error.to_string()))
}

fn cli_root(config: &Config) -> PathBuf {
    config.state_dir.join("vscode").join("cli")
}

fn load_installed(config: &Config) -> Option<Installed> {
    let data = fsutil::read_optional(&cli_root(config).join("install.json"))
        .ok()
        .flatten()?;
    serde_json::from_slice::<Installed>(&data)
        .ok()
        .filter(|installed| installed.path.is_file())
}

/// What is known about `path` without running it: everything for a daemon install, else
/// only the path.
fn managed_info(config: &Config, path: &Path) -> VsCodeCli {
    match load_installed(config).filter(|installed| installed.path == path) {
        Some(installed) => VsCodeCli {
            path: path.to_string_lossy().into_owned(),
            version: Some(installed.version),
            commit: Some(installed.commit),
            sha256: Some(installed.sha256),
            managed: true,
        },
        None => VsCodeCli {
            path: path.to_string_lossy().into_owned(),
            version: None,
            commit: None,
            sha256: None,
            managed: false,
        },
    }
}

/// The CLI the daemon installed, if any.
pub(crate) fn managed_cli(config: &Config) -> Option<PathBuf> {
    load_installed(config).map(|installed| installed.path)
}

/// The user's own `code` first, then the one the daemon installed.
fn find_cli(config: &Config) -> Option<PathBuf> {
    super::editor::find_user_code(config).or_else(|| managed_cli(config))
}

/// Whether this Linux host's libc is musl (Alpine and the like).
pub(crate) fn is_musl() -> bool {
    Path::new("/etc/alpine-release").exists()
        || (!Path::new("/lib64/ld-linux-x86-64.so.2").exists()
            && !Path::new("/lib/ld-linux-aarch64.so.1").exists()
            && ["/lib/ld-musl-x86_64.so.1", "/lib/ld-musl-aarch64.so.1"]
                .iter()
                .any(|loader| Path::new(loader).exists()))
}

/// Microsoft's name for this host's CLI build.
fn cli_platform() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") if is_musl() => Some("cli-alpine-x64"),
        ("linux", "x86_64") => Some("cli-linux-x64"),
        ("linux", "aarch64") if is_musl() => Some("cli-alpine-arm64"),
        ("linux", "aarch64") => Some("cli-linux-arm64"),
        ("linux", "arm") => Some("cli-linux-armhf"),
        ("macos", "aarch64") => Some("cli-darwin-arm64"),
        ("macos", "x86_64") => Some("cli-darwin-x64"),
        _ => None,
    }
}

pub(crate) fn fetch(url: &str, dest: &Path) -> Result<(), WsError> {
    let ok = std::process::Command::new("curl")
        .args(["-fsSL", "--retry", "3", "--max-time", "600", "-o"])
        .arg(dest)
        .arg(url)
        .status()
        .or_else(|_| {
            std::process::Command::new("wget")
                .args(["-q", "-O"])
                .arg(dest)
                .arg(url)
                .status()
        })
        .is_ok_and(|status| status.success());
    if ok {
        Ok(())
    } else {
        Err(WsError::Failed(format!(
            "downloading {url} failed (curl/wget)"
        )))
    }
}

/// Asks the update service for the latest stable CLI, downloads it, checks the published
/// SHA-256, unpacks it and records what was installed.
fn install_cli(base_url: &str, platform: &str, root: &Path) -> Result<Installed, WsError> {
    let failed = |error: std::io::Error| WsError::Failed(error.to_string());
    std::fs::create_dir_all(root).map_err(failed)?;
    let tag = fsutil::hex(&fsutil::random::<4>());
    let release_path = root.join(format!(".release-{tag}.json"));
    let api = format!("{base_url}/api/update/{platform}/stable/latest");
    tracing::info!(%api, "looking up the VS Code CLI");
    fetch(&api, &release_path)?;
    let release_json = std::fs::read(&release_path).map_err(failed);
    let _ = std::fs::remove_file(&release_path);
    let release: Release = serde_json::from_slice(&release_json?)
        .map_err(|error| WsError::Failed(format!("unexpected update service answer: {error}")))?;
    if base_url == DEFAULT_UPDATE_URL && !release.url.starts_with("https://") {
        return Err(WsError::Failed(format!(
            "refusing a non-HTTPS download: {}",
            release.url
        )));
    }
    let version = release
        .product_version
        .clone()
        .or(release.name.clone())
        .unwrap_or_else(|| "unknown".into());
    let short_commit: String = release.version.chars().take(10).collect();
    let dir = root.join(format!("{version}-{short_commit}"));
    let archive = root.join(format!(
        ".cli-{tag}{}",
        if release.url.ends_with(".zip") {
            ".zip"
        } else {
            ".tar.gz"
        }
    ));
    let staging = root.join(format!(".cli-{tag}"));
    let cleanup = || {
        let _ = std::fs::remove_file(&archive);
        let _ = std::fs::remove_dir_all(&staging);
    };
    tracing::info!(url = %release.url, "downloading the VS Code CLI");
    if let Err(error) = fetch(&release.url, &archive) {
        cleanup();
        return Err(error);
    }
    let sha256 = super::editor::sha256_file(&archive).map_err(failed)?;
    if !sha256.eq_ignore_ascii_case(&release.sha256hash) {
        cleanup();
        return Err(WsError::Failed(format!(
            "VS Code CLI checksum mismatch: got {sha256}, Microsoft published {}",
            release.sha256hash
        )));
    }
    std::fs::create_dir_all(&staging).map_err(failed)?;
    let unpacked = if release.url.ends_with(".zip") {
        std::process::Command::new("unzip")
            .args(["-q", "-o"])
            .arg(&archive)
            .arg("-d")
            .arg(&staging)
            .status()
    } else {
        std::process::Command::new("tar")
            .arg("-xzf")
            .arg(&archive)
            .arg("-C")
            .arg(&staging)
            .status()
    };
    if !unpacked.is_ok_and(|status| status.success()) || !staging.join("code").is_file() {
        cleanup();
        return Err(WsError::Failed(
            "unpacking the VS Code CLI failed (no `code` in the archive)".into(),
        ));
    }
    // It must run here (glibc vs musl, architecture).
    let runs = std::process::Command::new(staging.join("code"))
        .arg("--version")
        .stdin(Stdio::null())
        .output();
    if !runs.as_ref().is_ok_and(|output| output.status.success()) {
        cleanup();
        return Err(WsError::Failed(format!(
            "the downloaded VS Code CLI does not run on this host: {}",
            runs.map_or_else(
                |error| error.to_string(),
                |output| String::from_utf8_lossy(&output.stderr).into_owned()
            )
        )));
    }
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::rename(&staging, &dir).map_err(failed)?;
    cleanup();
    let installed = Installed {
        path: dir.join("code"),
        version,
        commit: release.version,
        sha256,
        url: release.url,
        platform: platform.to_owned(),
        installed_at: crate::identity::now_millis(),
    };
    let data = serde_json::to_vec_pretty(&installed)
        .map_err(|error| WsError::Failed(error.to_string()))?;
    fsutil::write_atomic(&root.join("install.json"), &data).map_err(failed)?;
    tracing::info!(version = %installed.version, sha256 = %installed.sha256, "VS Code CLI installed");
    Ok(installed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_device_codes_and_links() {
        assert_eq!(
            parse_line(
                "To grant access to the server, please log into https://github.com/login/device \
                 and use code 4766-3D57"
            ),
            Some(CliLine::DeviceCode {
                url: "https://github.com/login/device".into(),
                code: "4766-3D57".into()
            })
        );
        assert_eq!(
            parse_line(
                "To sign in, use a web browser to open the page https://login.microsoft.com/device \
                 and enter the code LW94CRGJT to authenticate."
            ),
            Some(CliLine::DeviceCode {
                url: "https://login.microsoft.com/device".into(),
                code: "LW94CRGJT".into()
            })
        );
        assert_eq!(
            parse_line("Open this link in your browser https://vscode.dev/tunnel/box/home/me"),
            Some(CliLine::Link {
                name: "box".into(),
                url: "https://vscode.dev/tunnel/box/home/me".into()
            })
        );
        assert_eq!(
            parse_line("* the Visual Studio Code Server License Terms (https://aka.ms/x) and"),
            None
        );
        assert_eq!(
            parse_line(
                "[2026-10-18 17:50:37] info Using GitHub for authentication, run `code tunnel \
                 user login --provider <provider>` option to change this."
            ),
            None
        );
    }

    #[test]
    fn parses_status_and_versions() {
        assert_eq!(
            parse_status("{\"tunnel\":null,\"service_installed\":false}"),
            None
        );
        assert_eq!(
            parse_status("{\"tunnel\":{\"name\":\"box\",\"tunnel\":\"Connected\"}}").as_deref(),
            Some("box")
        );
        assert_eq!(
            parse_version("code 1.142.0 (commit 6d62b1d5)\n"),
            (Some("1.142.0".into()), Some("6d62b1d5".into()))
        );
        assert_eq!(
            parse_version("1.105.1\n7d842fb\narm64\n"),
            (Some("1.105.1".into()), Some("7d842fb".into()))
        );
        assert_eq!(parse_version("garbage"), (None, None));
    }

    #[test]
    fn names_and_urls() {
        assert_eq!(
            default_name("Build-Box-32GB-2.example.com"),
            "build-box-32gb-2"
        );
        assert_eq!(
            default_name("a_very_long_host_name_indeed"),
            "a-very-long-host-nam"
        );
        assert!(default_name("...").starts_with("host-"));
        assert!(valid_name("box-1").is_ok());
        assert!(valid_name("bad name").is_err());
        assert!(valid_name("x".repeat(21).as_str()).is_err());
        assert_eq!(url_path("/a b/c#d"), "/a%20b/c%23d");
        assert_eq!(strip_ansi("\x1b[1mhi\x1b[0m\r"), "hi");
    }

    #[test]
    fn tunnel_workbench_skips_home_as_a_workspace() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("me");
        let project = home.join("app");
        std::fs::create_dir_all(&project).unwrap();
        let base = "https://vscode.dev";

        assert_eq!(
            workbench_url(base, "box", &home, &home),
            "https://vscode.dev/tunnel/box"
        );
        assert_eq!(
            workbench_url(base, "box", root.path(), &home),
            "https://vscode.dev/tunnel/box"
        );
        assert!(workbench_url(base, "box", &project, &home).ends_with("/me/app"));
    }
}
