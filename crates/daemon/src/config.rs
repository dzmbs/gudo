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
        }
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
