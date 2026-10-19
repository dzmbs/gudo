//! Daemon configuration and default locations.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

/// Which relays the daemon's iroh endpoint uses. Pairing tickets carry the choice, so paired
/// devices dial the same way (`proto::TicketRelays`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum RelayMode {
    /// n0's public relays and address lookup (`presets::N0`): works across NATs with no open
    /// inbound ports.
    #[default]
    Default,
    /// No relays and no address lookup: direct addresses only ("local only": LAN, Tailscale,
    /// a VPN, tests).
    Disabled,
    /// Self-hosted `iroh-relay` servers only, no third-party address lookup (docs/RELAYS.md).
    Custom(CustomRelays),
}

/// Self-hosted relays (`[relay]` in `config.toml`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CustomRelays {
    /// Relay URLs, `https://relay.example.com`.
    pub urls: Vec<String>,
    /// A shared access token the relays require (`iroh-relay`'s token access mode).
    pub auth_token: Option<String>,
    /// PEM files with extra CA certificates to trust for the relays' TLS (a private CA). The
    /// usual web roots stay trusted.
    pub ca_files: Vec<PathBuf>,
}

impl RelayMode {
    /// What a pairing ticket says about these relays.
    pub fn ticket_relays(&self) -> proto::TicketRelays {
        match self {
            Self::Default => proto::TicketRelays::Default,
            Self::Disabled => proto::TicketRelays::Disabled,
            Self::Custom(c) => proto::TicketRelays::Custom {
                urls: c.urls.clone(),
                auth_token: c.auth_token.clone(),
            },
        }
    }
}

/// Push notifications through the push relay (`[push]` in `config.toml`, docs/PUSH.md).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushConfig {
    /// Send pushes at all (`push.enabled`, default on). Off, registrations are kept but
    /// nothing leaves the host.
    pub enabled: bool,
    /// The relay to POST to when a device's registration names none (`push.relay`).
    pub relay_url: String,
    /// How long an attention item must stay unseen before it is pushed (`push.delay_ms`). A
    /// client focusing the pane in that window, or a newer item for the same pane, cancels it.
    pub delay: Duration,
    /// Lifetime of the Approve / Deny token in an approval notification.
    pub action_ttl: Duration,
    /// Delivery attempts per push (transient failures only).
    pub attempts: u32,
    /// First retry delay; doubled each attempt.
    pub backoff: Duration,
}

impl Default for PushConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            relay_url: brand::PUSH_RELAY_URL.to_owned(),
            delay: Duration::from_secs(3),
            action_ttl: Duration::from_secs(60 * 60),
            attempts: 5,
            backoff: Duration::from_secs(1),
        }
    }
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
    /// A VSCodium Web Host (REH web) to use instead of the pinned download: a directory
    /// containing `bin/codium-server` (`editor.vscodium` in `config.toml`).
    pub vscodium_dir: Option<PathBuf>,
    /// The editor `EditorChoice::Auto` launches (`editor.default` in `config.toml`:
    /// `"vscode"`, the default, or `"vscodium"`).
    pub editor_default: proto::EditorKind,
    /// Microsoft's update service, where the `code` CLI is downloaded from on the user's
    /// request (tests point it at a local `file://` tree).
    pub vscode_update_url: String,
    /// Push notifications.
    pub push: PushConfig,
    /// A pane's control lease moves to someone who asked for it once the holder has not typed
    pub lease_idle: Duration,
    /// Command history for completion and the line editor (`[history]` in `config.toml`).
    pub history: crate::assist::HistoryConfig,
    pub artifacts: ArtifactLimits,
    /// The executable this daemon runs from, when its owner may replace it over the
    /// connection (`proto::info`): the new build is written next to it and renamed over it.
    /// `None` (the default; library users and tests opt in) refuses upgrades.
    pub self_exe: Option<PathBuf>,
    /// Tests only: announce this snapshot format instead of libghostty-vt's, to exercise a
    /// client that cannot decode it.
    #[doc(hidden)]
    pub test_snapshot_format: Option<u32>,
    /// The git-native workspace: repository watching, `gh`, worktree housekeeping.
    pub repos: RepoConfig,
}

/// Timings and tools of the git-native workspace (`ws::repo`).
#[derive(Debug, Clone)]
pub struct RepoConfig {
    /// The GitHub CLI; found on `PATH` and the usual install locations when `None`
    /// (`worktrees.gh` in `config.toml`).
    pub gh: Option<PathBuf>,
    /// Quiet period after a file change before a worktree is re-read.
    pub debounce: Duration,
    /// How often worktrees with panes are re-read without a file event (a safety net).
    pub poll: Duration,
    /// How often worktrees without panes are re-read.
    pub idle_poll: Duration,
    /// Pull requests with running checks are asked about this often; others less often.
    pub pr_poll: Duration,
    /// How often merged worktrees are swept for auto-delete.
    pub sweep: Duration,
    /// Length of the "day" in the auto-delete setting (tests shorten it).
    pub day: Duration,
}

impl Default for RepoConfig {
    fn default() -> Self {
        Self {
            gh: None,
            debounce: Duration::from_millis(300),
            poll: Duration::from_secs(10),
            idle_poll: Duration::from_secs(60),
            pr_poll: Duration::from_secs(30),
            sweep: Duration::from_secs(3600),
            day: Duration::from_secs(86_400),
        }
    }
}

/// Size caps for the artifact store (drawings, images, op logs).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArtifactLimits {
    /// Largest blob (image, PNG) in bytes. Claude Code refuses sources over 128 MB and
    /// downscales anything over 2000 px, so 32 MiB is plenty.
    pub blob_max: u64,
    /// Everything stored (blobs and op logs) per daemon, in bytes.
    pub total_max: u64,
    /// One drawing's op log, in bytes (postcard).
    pub log_max: u64,
    /// One committed batch, in bytes.
    pub batch_max: u64,
    /// Artifacts per session.
    pub per_session: usize,
}

impl Default for ArtifactLimits {
    fn default() -> Self {
        Self {
            blob_max: 32 << 20,
            total_max: 1 << 30,
            log_max: 8 << 20,
            batch_max: 1 << 20,
            per_session: 1000,
        }
    }
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
            vscodium_dir: None,
            editor_default: proto::EditorKind::VsCode,
            vscode_update_url: crate::ws::VSCODE_UPDATE_URL.to_owned(),
            push: PushConfig::default(),
            lease_idle: Duration::from_secs(5),
            artifacts: ArtifactLimits::default(),
            history: crate::assist::HistoryConfig::default(),
            self_exe: None,
            test_snapshot_format: None,
            repos: RepoConfig::default(),
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
    /// vscodium = "/opt/vscodium-reh-web"   # instead of the pinned download
    /// default = "vscode"           # "vscode" | "vscodium": what `Auto` launches
    ///
    /// [relay]                     # docs/RELAYS.md
    /// mode = "custom"              # "default" | "custom" | "local-only"
    /// urls = ["https://relay.example.com"]
    /// auth_token = "…"             # if the relays require one
    /// ca_file = "/etc/ssl/my-ca.pem"   # a private CA, besides the web roots
    ///
    /// [push]                       # docs/PUSH.md
    /// enabled = true
    /// relay = "https://push.example.com"
    /// delay_ms = 3000
    ///
    /// [multiplayer]
    /// lease_idle_secs = 5
    ///
    /// [history]                    # docs/DAEMON.md §7
    /// enabled = true
    /// ignore_space = true          # commands typed with a leading space are not kept
    /// max_entries = 50000
    /// import = true                # import zsh/bash/fish history once
    /// ```
    ///
    /// A relay mode set before this runs (`hostd run --no-relay`) wins over the file's.
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
        if let Some(gh) = file.worktrees.gh {
            self.repos.gh = Some(gh);
        }
        if let Some(code) = file.editor.code {
            self.code_cli = Some(code);
        }
        if let Some(dir) = file.editor.openvscode {
            self.openvscode_dir = Some(dir);
        }
        if let Some(dir) = file.editor.vscodium {
            self.vscodium_dir = Some(dir);
        }
        if let Some(default) = file.editor.default {
            self.editor_default = match default {
                DefaultEditor::Vscode => proto::EditorKind::VsCode,
                DefaultEditor::Vscodium => proto::EditorKind::Vscodium,
            };
        }
        if self.relay == RelayMode::Default {
            self.relay = file
                .relay
                .mode()
                .map_err(|e| std::io::Error::other(format!("{}: {e}", path.display())))?;
        }
        if let Some(enabled) = file.push.enabled {
            self.push.enabled = enabled;
        }
        if let Some(relay) = file.push.relay {
            self.push.relay_url = relay;
        }
        if let Some(ms) = file.push.delay_ms {
            self.push.delay = Duration::from_millis(ms);
        }
        if let Some(secs) = file.multiplayer.lease_idle_secs {
            self.lease_idle = Duration::from_secs(secs);
        }
        let history = file.history;
        if let Some(on) = history.enabled {
            self.history.enabled = on;
        }
        if let Some(on) = history.ignore_space {
            self.history.ignore_space = on;
        }
        if let Some(max) = history.max_entries {
            self.history.max_entries = max.max(1);
        }
        if let Some(on) = history.import {
            self.history.import = on;
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

    /// The Ghostty snapshot format this daemon encodes (and announces).
    pub(crate) fn snapshot_format(&self) -> u32 {
        self.test_snapshot_format
            .unwrap_or_else(|| u32::from(ghostty_vt::snapshot_format()))
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
    relay: RelaySection,
    push: PushSection,
    multiplayer: MultiplayerSection,
    history: HistorySection,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct HistorySection {
    enabled: Option<bool>,
    ignore_space: Option<bool>,
    max_entries: Option<usize>,
    import: Option<bool>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct RelaySection {
    mode: Option<String>,
    urls: Vec<String>,
    auth_token: Option<String>,
    ca_file: Option<PathBuf>,
}

impl RelaySection {
    fn mode(self) -> Result<RelayMode, String> {
        let mode = self.mode.as_deref().unwrap_or(if self.urls.is_empty() {
            "default"
        } else {
            "custom"
        });
        match mode {
            "default" => Ok(RelayMode::Default),
            "local-only" | "disabled" | "none" => Ok(RelayMode::Disabled),
            "custom" if self.urls.is_empty() => {
                Err("relay.mode = \"custom\" needs relay.urls".into())
            }
            "custom" => {
                for url in &self.urls {
                    if !(url.starts_with("https://") || url.starts_with("http://")) {
                        return Err(format!("relay url {url:?} is not an http(s) URL"));
                    }
                }
                Ok(RelayMode::Custom(CustomRelays {
                    urls: self.urls,
                    auth_token: self.auth_token,
                    ca_files: self.ca_file.into_iter().collect(),
                }))
            }
            other => Err(format!(
                "relay.mode {other:?}: expected \"default\", \"custom\" or \"local-only\""
            )),
        }
    }
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct PushSection {
    enabled: Option<bool>,
    relay: Option<String>,
    delay_ms: Option<u64>,
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
    gh: Option<PathBuf>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct EditorSection {
    code: Option<PathBuf>,
    openvscode: Option<PathBuf>,
    vscodium: Option<PathBuf>,
    default: Option<DefaultEditor>,
}

/// `editor.default`.
#[derive(Debug, Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
enum DefaultEditor {
    Vscode,
    Vscodium,
}
