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
const MAX_NAME: usize = 20;
/// Lines of tunnel output kept for failure messages.
const TAIL: usize = 8;
/// A run this long resets the restart back-off.
const HEALTHY_RUN: Duration = Duration::from_secs(60);
const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// How often an adopted tunnel is checked.
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
struct Release {
    url: String,
    version: String,
    product_version: Option<String>,
    name: Option<String>,
    sha256hash: String,
}

struct St {
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
    st: Arc<Mutex<St>>,
    events: broadcast::Sender<Event>,
    install: tokio::sync::Mutex<()>,
}

impl Tunnel {
    pub fn new(events: broadcast::Sender<Event>) -> Self {
        Self {
            st: Arc::new(Mutex::new(St {
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

    pub async fn status(&self, cfg: &Config) -> VsCodeTunnelStatus {
        let cli = self.cli_info(cfg).await;
        let st = lock(&self.st);
        VsCodeTunnelStatus {
            cli,
            cli_downloadable: cli_platform().is_some(),
            state: st.state.clone(),
            provider: st.provider.or_else(|| load_record(cfg).provider),
        }
    }

    /// Downloads the CLI from Microsoft (the caller checked the licence was accepted).
    pub async fn install_cli(&self, cfg: &Config) -> Result<VsCodeTunnelStatus, WsError> {
        let _guard = self.install.lock().await;
        let platform = cli_platform().ok_or_else(|| {
            WsError::Unavailable(format!(
                "Microsoft publishes no VS Code CLI for {} {}",
                std::env::consts::OS,
                std::env::consts::ARCH
            ))
        })?;
        let base = cfg.vscode_update_url.clone();
        let root = cli_root(cfg);
        tokio::task::spawn_blocking(move || install_cli(&base, platform, &root))
            .await
            .map_err(|e| WsError::Failed(e.to_string()))??;
        lock(&self.st).version_cache = None;
        let status = self.status(cfg).await;
        let _ = self.events.send(Event::VsCodeTunnel(status.clone()));
        Ok(status)
    }

    /// Starts the tunnel, or returns the running one (the caller checked the licence).
    pub async fn start(
        &self,
        cfg: &Config,
        req: &VsCodeTunnelStart,
    ) -> Result<VsCodeTunnelStatus, WsError> {
        let code = find_cli(cfg).ok_or_else(|| {
            WsError::Unavailable(
                "the VS Code `code` CLI is not installed (install it first: VsCodeCliInstall)"
                    .into(),
            )
        })?;
        let mut record = load_record(cfg);
        let name = match &req.name {
            Some(n) => valid_name(n)?,
            None => record
                .name
                .clone()
                .unwrap_or_else(|| default_name(&hostname())),
        };
        let restart = {
            let st = lock(&self.st);
            let alive = st.task.as_ref().is_some_and(|t| !t.is_finished());
            let same = record.name.as_deref() == Some(name.as_str())
                && record.provider == Some(req.provider);
            // A failed tunnel that gave up, or a new name or account, starts over.
            !alive
                || !same
                || matches!(
                    st.state,
                    TunnelState::Failed {
                        retrying: false,
                        ..
                    }
                )
        };
        record.enabled = true;
        record.name = Some(name.clone());
        record.provider = Some(req.provider);
        record.license_accepted_at = Some(crate::identity::now_millis());
        save_record(cfg, &record)?;
        if restart {
            self.spawn(cfg, code, name, req.provider, true);
        }
        Ok(self.status(cfg).await)
    }

    /// Restarts the tunnel at daemon start if the user had it running.
    pub fn autostart(&self, cfg: &Config) {
        let record = load_record(cfg);
        if !record.enabled || record.license_accepted_at.is_none() {
            return;
        }
        let (Some(name), Some(provider)) = (record.name, record.provider) else {
            return;
        };
        match find_cli(cfg) {
            Some(code) => self.spawn(cfg, code, name, provider, false),
            None => tracing::warn!("VS Code tunnel enabled but no `code` CLI found"),
        }
    }

    pub async fn stop(&self, cfg: &Config) -> Result<VsCodeTunnelStatus, WsError> {
        let mut record = load_record(cfg);
        record.enabled = false;
        save_record(cfg, &record)?;
        self.halt(TunnelState::Stopped);
        let status = self.status(cfg).await;
        let _ = self.events.send(Event::VsCodeTunnel(status.clone()));
        Ok(status)
    }

    /// Daemon shutdown: stop the process but keep it enabled for the next start.
    pub fn shutdown(&self) {
        self.halt(TunnelState::Stopped);
    }

    fn halt(&self, state: TunnelState) {
        let mut st = lock(&self.st);
        st.generation += 1;
        if let Some(task) = st.task.take() {
            task.abort();
        }
        if let Some(pid) = st.pid.take() {
            kill_group(pid);
        }
        st.state = state;
    }

    fn spawn(
        &self,
        cfg: &Config,
        code: PathBuf,
        name: String,
        provider: TunnelProvider,
        interactive: bool,
    ) {
        self.halt(TunnelState::Starting);
        let generation = {
            let mut st = lock(&self.st);
            st.provider = Some(provider);
            st.generation
        };
        let sup = Supervisor {
            st: Arc::clone(&self.st),
            events: self.events.clone(),
            generation,
            name,
            provider,
            log_dir: cfg.state_dir.join("editors"),
            cli: Some(managed_info(cfg, &code)),
            code,
        };
        let task = tokio::spawn(sup.run(interactive));
        lock(&self.st).task = Some(task.abort_handle());
    }

    /// Where `path` opens through the running tunnel. `folder` is the workspace folder.
    pub async fn open(
        &self,
        folder: &Path,
        path: &Path,
        line: Option<u32>,
        column: Option<u32>,
    ) -> Result<VsCodeTunnelOpened, WsError> {
        let (name, web_url, pid) = {
            let st = lock(&self.st);
            match &st.state {
                TunnelState::Running { name, web_url, .. } => {
                    (name.clone(), web_url.clone(), st.pid)
                }
                _ => {
                    return Err(WsError::Unavailable(
                        "the VS Code tunnel is not running".into(),
                    ));
                }
            }
        };
        let base = web_url
            .find("/tunnel/")
            .map_or("https://vscode.dev", |i| &web_url[..i]);
        let suffix = match (line, column) {
            (Some(l), Some(c)) => format!(":{l}:{c}"),
            (Some(l), None) => format!(":{l}"),
            _ => String::new(),
        };
        let folder_s = folder.to_string_lossy().into_owned();
        let path_s = path.to_string_lossy().into_owned();
        let in_window = match pid {
            Some(pid) if path.is_file() => {
                super::editor::open_via_cli(pid, &format!("{path_s}{suffix}")).await
            }
            _ => false,
        };
        Ok(VsCodeTunnelOpened {
            web_url: format!("{base}/tunnel/{name}{}", url_path(&folder_s)),
            desktop_uri: format!(
                "vscode://vscode-remote/tunnel+{name}{}{suffix}",
                url_path(&path_s)
            ),
            name,
            folder: folder_s,
            in_window,
        })
    }

    async fn cli_info(&self, cfg: &Config) -> Option<VsCodeCli> {
        let path = find_cli(cfg)?;
        let info = managed_info(cfg, &path);
        if info.managed {
            return Some(info);
        }
        let cached = lock(&self.st)
            .version_cache
            .clone()
            .filter(|(p, _, _)| *p == path);
        let (version, commit) = match cached {
            Some((_, v, c)) => (v, c),
            None => {
                let (v, c) = cli_version(&path).await;
                lock(&self.st).version_cache = Some((path.clone(), v.clone(), c.clone()));
                (v, c)
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

// --- supervisor -------------------------------------------------------------------------------

struct Supervisor {
    st: Arc<Mutex<St>>,
    events: broadcast::Sender<Event>,
    generation: u64,
    code: PathBuf,
    name: String,
    provider: TunnelProvider,
    log_dir: PathBuf,
    cli: Option<VsCodeCli>,
}

/// Kills a child's process group when dropped (the tunnel's servers run under it).
struct Group(Child);

impl Drop for Group {
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
enum Said {
    DeviceCode { url: String, code: String },
    Link { name: String, url: String },
}

impl Supervisor {
    /// Publishes a state unless a newer supervisor replaced this one.
    fn set(&self, state: TunnelState) {
        let status = {
            let mut st = lock(&self.st);
            if st.generation != self.generation {
                return;
            }
            st.state = state.clone();
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
        let mut st = lock(&self.st);
        if st.generation == self.generation {
            st.pid = pid;
        }
    }

    async fn run(mut self, interactive: bool) {
        if let Some(cli) = self.cli.as_mut().filter(|c| c.version.is_none()) {
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
        let out = Command::new(&self.code)
            .args(["tunnel", "user", "show"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .status();
        matches!(
            tokio::time::timeout(Duration::from_secs(30), out).await,
            Ok(Ok(s)) if s.success()
        )
    }

    /// `code tunnel user login --provider …`: publishes the device code, waits for the user.
    async fn login(&self) -> Result<(), String> {
        let provider = match self.provider {
            TunnelProvider::GitHub => "github",
            TunnelProvider::Microsoft => "microsoft",
        };
        let mut cmd = Command::new(&self.code);
        cmd.args(["tunnel", "user", "login", "--provider", provider]);
        let (mut child, mut lines) = spawn_lines(cmd, &self.log_dir.join("vscode-login.log"))?;
        let mut tail = Vec::new();
        while let Some(line) = lines.recv().await {
            if let Some(Said::DeviceCode { url, code }) = parse_line(&line) {
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
            Ok(s) if s.success() => Ok(()),
            Ok(s) => Err(format!("sign-in failed ({s}): {}", tail.join(" | "))),
            Err(e) => Err(format!("sign-in failed: {e}")),
        }
    }

    /// Runs `code tunnel` until it exits; returns why it stopped.
    async fn tunnel(&self) -> String {
        let mut cmd = Command::new(&self.code);
        cmd.args(["tunnel", "--accept-server-license-terms", "--name"])
            .arg(&self.name);
        let (mut child, mut lines) = match spawn_lines(cmd, &self.log_dir.join("vscode-tunnel.log"))
        {
            Ok(c) => c,
            Err(e) => return e,
        };
        self.set_pid(child.0.id());
        let mut tail = Vec::new();
        while let Some(line) = lines.recv().await {
            match parse_line(&line) {
                Some(Said::DeviceCode { url, code }) => {
                    self.set(TunnelState::NeedsLogin(DeviceLogin {
                        provider: self.provider,
                        verification_url: url,
                        user_code: code,
                        at: UnixMillis(crate::identity::now_millis()),
                    }));
                }
                Some(Said::Link { name, url }) => {
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
            status.map_or_else(|e| e.to_string(), |s| s.to_string()),
            tail.join(" | ")
        )
    }
}

fn push_tail(tail: &mut Vec<String>, line: String) {
    if !line.trim().is_empty() && !line.starts_with('*') {
        tail.push(line);
        if tail.len() > TAIL {
            tail.remove(0);
        }
    }
}

/// Spawns `cmd` in its own process group and streams its stdout and stderr lines (also
/// appended to `log`).
fn spawn_lines(
    mut cmd: Command,
    log: &Path,
) -> Result<(Group, mpsc::UnboundedReceiver<String>), String> {
    if let Some(dir) = log.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .ok()
        .map(|f| Arc::new(Mutex::new(f)));
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("starting the VS Code CLI: {e}"))?;
    let (tx, rx) = mpsc::unbounded_channel();
    let stdout = child.stdout.take().map(|s| Box::new(s) as Box<dyn Reader>);
    let stderr = child.stderr.take().map(|s| Box::new(s) as Box<dyn Reader>);
    for out in [stdout, stderr].into_iter().flatten() {
        let tx = tx.clone();
        let log_file = log_file.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(out).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let line = strip_ansi(&line);
                if let Some(f) = &log_file {
                    use std::io::Write;
                    let _ = writeln!(lock(f), "{line}");
                }
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
    }
    Ok((Group(child), rx))
}

trait Reader: tokio::io::AsyncRead + Unpin + Send {}
impl<T: tokio::io::AsyncRead + Unpin + Send> Reader for T {}

fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
        } else if c != '\r' {
            out.push(c);
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
fn parse_line(line: &str) -> Option<Said> {
    let urls: Vec<&str> = line
        .split_whitespace()
        .filter(|w| w.starts_with("https://"))
        .map(|w| w.trim_end_matches(['.', ',', ')']))
        .collect();
    if let Some(url) = urls.iter().find(|u| u.contains("vscode.dev/tunnel/")) {
        let rest = &url[url.find("/tunnel/")? + "/tunnel/".len()..];
        let name = rest.split('/').next().filter(|n| !n.is_empty())?;
        return Some(Said::Link {
            name: name.to_owned(),
            url: (*url).to_owned(),
        });
    }
    let url = urls.first()?;
    let words: Vec<&str> = line.split_whitespace().collect();
    let code = words
        .windows(2)
        .find(|w| w[0].eq_ignore_ascii_case("code"))
        .map(|w| w[1].trim_end_matches(['.', ',']))
        .filter(|c| c.len() >= 4 && c.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))?;
    Some(Said::DeviceCode {
        url: (*url).to_owned(),
        code: code.to_owned(),
    })
}

/// The name of a tunnel already running on this machine (`code tunnel status`).
async fn running_tunnel(code: &Path) -> Option<String> {
    let out = Command::new(code)
        .args(["tunnel", "status"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(Duration::from_secs(30), out)
        .await
        .ok()?
        .ok()?;
    parse_status(&String::from_utf8_lossy(&out.stdout))
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
        .and_then(|n| n.as_str())
        .filter(|n| !n.is_empty())
        .map(str::to_owned)
}

async fn cli_version(code: &Path) -> (Option<String>, Option<String>) {
    let out = Command::new(code)
        .arg("--version")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(Duration::from_secs(15), out).await {
        Ok(Ok(o)) => parse_version(&String::from_utf8_lossy(&o.stdout)),
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
            .map(|c| c.trim_end_matches(')').trim().to_owned());
        return (version, commit);
    }
    let mut lines = text.lines();
    let version = lines
        .next()
        .filter(|v| v.chars().next().is_some_and(|c| c.is_ascii_digit()))
        .map(str::to_owned);
    let commit = lines
        .next()
        .map(|c| c.trim().to_owned())
        .filter(|_| version.is_some());
    (version, commit)
}

// --- names ------------------------------------------------------------------------------------

fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: the buffer is valid for its length; gethostname NUL-terminates on success.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    if !ok {
        return String::new();
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

/// A tunnel name from a host name: lowercase letters, digits and `-`, at most 20.
fn default_name(host: &str) -> String {
    let host = host.split('.').next().unwrap_or_default();
    let mut name: String = host
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    name.truncate(MAX_NAME);
    let name = name.trim_matches('-').to_owned();
    if name.is_empty() {
        format!("host-{}", fsutil::hex(&fsutil::random::<3>()))
    } else {
        name
    }
}

fn valid_name(name: &str) -> Result<String, WsError> {
    let ok = !name.is_empty()
        && name.len() <= MAX_NAME
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    if ok {
        Ok(name.to_owned())
    } else {
        Err(WsError::Invalid(format!(
            "tunnel name {name:?}: use at most {MAX_NAME} letters, digits and '-'"
        )))
    }
}

/// Percent-encodes a path for a URL, keeping `/`.
fn url_path(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    if !path.starts_with('/') {
        out.push('/');
    }
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

// --- records ----------------------------------------------------------------------------------

fn record_path(cfg: &Config) -> PathBuf {
    cfg.state_dir.join("vscode").join("tunnel.json")
}

fn load_record(cfg: &Config) -> Record {
    fsutil::read_optional(&record_path(cfg))
        .ok()
        .flatten()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn save_record(cfg: &Config, record: &Record) -> Result<(), WsError> {
    let data = serde_json::to_vec_pretty(record).map_err(|e| WsError::Failed(e.to_string()))?;
    fsutil::write_atomic(&record_path(cfg), &data).map_err(|e| WsError::Failed(e.to_string()))
}

fn cli_root(cfg: &Config) -> PathBuf {
    cfg.state_dir.join("vscode").join("cli")
}

fn load_installed(cfg: &Config) -> Option<Installed> {
    let data = fsutil::read_optional(&cli_root(cfg).join("install.json"))
        .ok()
        .flatten()?;
    serde_json::from_slice::<Installed>(&data)
        .ok()
        .filter(|i| i.path.is_file())
}

/// What is known about `path` without running it: everything for a daemon install, else
/// only the path.
fn managed_info(cfg: &Config, path: &Path) -> VsCodeCli {
    match load_installed(cfg).filter(|i| i.path == path) {
        Some(i) => VsCodeCli {
            path: path.to_string_lossy().into_owned(),
            version: Some(i.version),
            commit: Some(i.commit),
            sha256: Some(i.sha256),
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
pub(crate) fn managed_cli(cfg: &Config) -> Option<PathBuf> {
    load_installed(cfg).map(|i| i.path)
}

/// The user's own `code` first, then the one the daemon installed.
fn find_cli(cfg: &Config) -> Option<PathBuf> {
    super::editor::find_user_code(cfg).or_else(|| managed_cli(cfg))
}

// --- install ----------------------------------------------------------------------------------

/// Microsoft's name for this host's CLI build.
fn cli_platform() -> Option<&'static str> {
    let musl = || {
        Path::new("/etc/alpine-release").exists()
            || (!Path::new("/lib64/ld-linux-x86-64.so.2").exists()
                && !Path::new("/lib/ld-linux-aarch64.so.1").exists()
                && ["/lib/ld-musl-x86_64.so.1", "/lib/ld-musl-aarch64.so.1"]
                    .iter()
                    .any(|p| Path::new(p).exists()))
    };
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") if musl() => Some("cli-alpine-x64"),
        ("linux", "x86_64") => Some("cli-linux-x64"),
        ("linux", "aarch64") if musl() => Some("cli-alpine-arm64"),
        ("linux", "aarch64") => Some("cli-linux-arm64"),
        ("linux", "arm") => Some("cli-linux-armhf"),
        ("macos", "aarch64") => Some("cli-darwin-arm64"),
        ("macos", "x86_64") => Some("cli-darwin-x64"),
        _ => None,
    }
}

fn fetch(url: &str, dest: &Path) -> Result<(), WsError> {
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
        .is_ok_and(|s| s.success());
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
fn install_cli(base: &str, platform: &str, root: &Path) -> Result<Installed, WsError> {
    let failed = |e: std::io::Error| WsError::Failed(e.to_string());
    std::fs::create_dir_all(root).map_err(failed)?;
    let tag = fsutil::hex(&fsutil::random::<4>());
    let meta_path = root.join(format!(".release-{tag}.json"));
    let api = format!("{base}/api/update/{platform}/stable/latest");
    tracing::info!(%api, "looking up the VS Code CLI");
    fetch(&api, &meta_path)?;
    let meta = std::fs::read(&meta_path).map_err(failed);
    let _ = std::fs::remove_file(&meta_path);
    let release: Release = serde_json::from_slice(&meta?)
        .map_err(|e| WsError::Failed(format!("unexpected update service answer: {e}")))?;
    if base == DEFAULT_UPDATE_URL && !release.url.starts_with("https://") {
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
    let short: String = release.version.chars().take(10).collect();
    let dir = root.join(format!("{version}-{short}"));
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
    if let Err(e) = fetch(&release.url, &archive) {
        cleanup();
        return Err(e);
    }
    let sha = super::editor::sha256_file(&archive).map_err(failed)?;
    if !sha.eq_ignore_ascii_case(&release.sha256hash) {
        cleanup();
        return Err(WsError::Failed(format!(
            "VS Code CLI checksum mismatch: got {sha}, Microsoft published {}",
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
    if !unpacked.is_ok_and(|s| s.success()) || !staging.join("code").is_file() {
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
    if !runs.as_ref().is_ok_and(|o| o.status.success()) {
        cleanup();
        return Err(WsError::Failed(format!(
            "the downloaded VS Code CLI does not run on this host: {}",
            runs.map_or_else(
                |e| e.to_string(),
                |o| String::from_utf8_lossy(&o.stderr).into_owned()
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
        sha256: sha,
        url: release.url,
        platform: platform.to_owned(),
        installed_at: crate::identity::now_millis(),
    };
    let data = serde_json::to_vec_pretty(&installed).map_err(|e| WsError::Failed(e.to_string()))?;
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
            Some(Said::DeviceCode {
                url: "https://github.com/login/device".into(),
                code: "4766-3D57".into()
            })
        );
        assert_eq!(
            parse_line(
                "To sign in, use a web browser to open the page https://login.microsoft.com/device \
                 and enter the code LW94CRGJT to authenticate."
            ),
            Some(Said::DeviceCode {
                url: "https://login.microsoft.com/device".into(),
                code: "LW94CRGJT".into()
            })
        );
        assert_eq!(
            parse_line("Open this link in your browser https://vscode.dev/tunnel/box/home/me"),
            Some(Said::Link {
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
            default_name("Ubuntu-32GB-hel1-2.example.com"),
            "ubuntu-32gb-hel1-2"
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
}
