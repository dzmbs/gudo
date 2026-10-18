//! Daemon configuration and default locations.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

/// Which relays the daemon's iroh endpoint uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RelayMode {
    /// n0's public relays and address lookup (`presets::N0`): works across NATs with no open
    /// inbound ports.
    #[default]
    Default,
    /// No relays and no address lookup: direct addresses only (LAN, Tailscale, tests).
    Disabled,
}

/// Daemon settings.
///
/// # Examples
///
/// ```
/// let config = daemon::Config::new("/tmp/un-state");
/// assert_eq!(config.relay, daemon::RelayMode::Default);
/// ```
#[derive(Debug, Clone)]
pub struct Config {
    /// Keys, paired devices, layout and the hook socket live here.
    pub state_dir: PathBuf,
    /// UDP address the iroh endpoint binds (port 0 picks one). `None` binds every interface,
    /// IPv4 and IPv6, on random ports.
    pub bind: Option<SocketAddr>,
    /// Relay usage.
    pub relay: RelayMode,
    /// Shell for new panes; `$SHELL`, then `/bin/sh`, when `None`.
    pub shell: Option<PathBuf>,
    /// Extra environment for every pane (tests set a predictable prompt with it).
    pub pane_env: Vec<(String, String)>,
    pub ring_capacity: usize,
    /// Scrollback the daemon's VT keeps per pane, in bytes.
    pub scrollback_bytes: usize,
    /// Size of a pane no client has sized yet: (cols, rows).
    pub default_size: (u16, u16),
    /// Quiet period before layout changes are written to disk.
    pub persist_debounce: Duration,
    /// The agent hook shim; next to the current executable when `None`.
    pub hook_bin: Option<PathBuf>,
    /// Inject Ghostty's shell integration into bash, zsh and fish panes (OSC 133 command
    /// marks, OSC 7 working directory). On by default.
    pub shell_integration: bool,
    /// A command running at least this long that finishes while no client shows its pane is
    /// announced with `CommandFinishedUnseen`.
    pub long_command: Duration,
    /// Directories file, git, worktree and editor requests may touch, besides `$HOME` (which
    /// is always allowed). `files.allow` in `<state_dir>/config.toml` adds to it.
    pub fs_allow: Vec<PathBuf>,
    /// Where new worktrees go: `<root>/<repo>/<branch slug>`. `~/.<product>/worktrees` when
    /// `None` (`worktrees.root` in `config.toml`).
    pub worktree_root: Option<PathBuf>,
    /// First `PORT` handed to a worktree; each worktree gets the next free one
    /// (`worktrees.port_base` in `config.toml`).
    pub worktree_port_base: u16,
    /// How often listening ports are rescanned while a client is connected.
    pub port_scan_interval: Duration,
    /// The VS Code CLI for `code serve-web`; found on `PATH` (and in the usual app bundle
    /// locations) when `None` (`editor.code` in `config.toml`).
    pub code_cli: Option<PathBuf>,
    /// An openvscode-server to use instead of the pinned download: a directory containing
    /// `bin/openvscode-server` (`editor.openvscode` in `config.toml`).
    pub openvscode_dir: Option<PathBuf>,
    /// Microsoft's update service, where the `code` CLI is downloaded from on the user's
    /// request (tests point it at a local `file://` tree).
    pub vscode_update_url: String,
    /// A pane's control lease moves to someone who asked for it once the holder has not typed
    pub lease_idle: Duration,
}

impl Config {
    /// Defaults for a daemon keeping its state in `state_dir`.
    pub fn new(state_dir: impl Into<PathBuf>) -> Self {
        Self {
            state_dir: state_dir.into(),
            bind: None,
            relay: RelayMode::Default,
            shell: None,
            pane_env: Vec::new(),
            ring_capacity: pty::DEFAULT_RING_CAPACITY,
            scrollback_bytes: 10 * 1024 * 1024,
            default_size: (80, 24),
            persist_debounce: Duration::from_millis(500),
            hook_bin: None,
            shell_integration: true,
            long_command: Duration::from_secs(10),
            fs_allow: Vec::new(),
            worktree_root: None,
            worktree_port_base: 4100,
            port_scan_interval: Duration::from_secs(2),
            code_cli: None,
            openvscode_dir: None,
            vscode_update_url: crate::ws::VSCODE_UPDATE_URL.to_owned(),
            lease_idle: Duration::from_secs(5),
        }
    }

    /// Applies `<state_dir>/config.toml`, if present:
    ///
    /// ```toml
    /// [files]
    /// allow = ["/srv/projects", "/tmp"]   # besides $HOME
    ///
    /// [worktrees]
    /// root = "/home/me/worktrees"
    /// port_base = 4100
    ///
    /// [editor]
    /// code = "/usr/local/bin/code"
    /// openvscode = "/opt/openvscode-server"
    ///
    /// [multiplayer]
    /// lease_idle_secs = 5
    /// ```
    ///
    /// # Errors
    ///
    /// Returns an error if the file exists but cannot be read or parsed.
    pub fn apply_user_file(&mut self) -> std::io::Result<()> {
        let path = self.state_dir.join("config.toml");
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(e),
        };
        let file: UserFile = toml::from_str(&text)
            .map_err(|e| std::io::Error::other(format!("{}: {e}", path.display())))?;
        self.fs_allow.extend(file.files.allow);
        if let Some(root) = file.worktrees.root {
            self.worktree_root = Some(root);
        }
        if let Some(base) = file.worktrees.port_base {
            self.worktree_port_base = base;
        }
        if let Some(code) = file.editor.code {
            self.code_cli = Some(code);
        }
        if let Some(dir) = file.editor.openvscode {
            self.openvscode_dir = Some(dir);
        }
        if let Some(secs) = file.multiplayer.lease_idle_secs {
            self.lease_idle = Duration::from_secs(secs);
        }
        Ok(())
    }

    /// `$HOME` of the daemon's user (pane environment first).
    pub(crate) fn home(&self) -> PathBuf {
        self.pane_var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/"))
    }

    /// The value of `name` in a pane's environment: the configured pane environment first,
    /// then the daemon's own.
    pub(crate) fn pane_var(&self, name: &str) -> Option<std::ffi::OsString> {
        self.pane_env
            .iter()
            .rev()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.into())
            .or_else(|| std::env::var_os(name))
    }

    pub(crate) fn shell(&self) -> PathBuf {
        self.shell
            .clone()
            .or_else(|| std::env::var_os("SHELL").map(PathBuf::from))
            .unwrap_or_else(|| PathBuf::from("/bin/sh"))
    }

    pub(crate) fn hook_bin(&self) -> PathBuf {
        self.hook_bin.clone().unwrap_or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|exe| exe.parent().map(|dir| dir.join(brand::HOOK_BIN)))
                .unwrap_or_else(|| PathBuf::from(brand::HOOK_BIN))
        })
    }
}

/// The default state directory.
///
/// - `$XDG_STATE_HOME/<name>` when set (any OS);
/// - Linux and other Unix: `~/.local/state/<name>` (XDG default);
/// - macOS: `~/Library/Application Support/<name>`.
pub fn default_state_dir() -> PathBuf {
    if let Some(xdg) = std::env::var_os("XDG_STATE_HOME").filter(|v| !v.is_empty()) {
        return PathBuf::from(xdg).join(brand::DIR_NAME);
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support")
            .join(brand::DIR_NAME)
    } else {
        home.join(".local/state").join(brand::DIR_NAME)
    }
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct UserFile {
    files: FilesSection,
    worktrees: WorktreesSection,
    editor: EditorSection,
    multiplayer: MultiplayerSection,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct MultiplayerSection {
    lease_idle_secs: Option<u64>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct FilesSection {
    allow: Vec<PathBuf>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct WorktreesSection {
    root: Option<PathBuf>,
    port_base: Option<u16>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct EditorSection {
    code: Option<PathBuf>,
    openvscode: Option<PathBuf>,
}
