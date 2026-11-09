//! Daemon configuration and default locations.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

#[cfg(test)]
mod claude_tests;
#[cfg(test)]
mod codex_tests;

/// Which relays the daemon's iroh endpoint uses. Pairing tickets carry the choice, so paired
/// devices dial the same way (`proto::TicketRelays`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum RelayMode {
    /// The product's relay ([`brand::RELAY_URL`]) and n0's address lookup (`presets::N0`): works
    /// across NATs with no open inbound ports.
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
            Self::Custom(custom) => proto::TicketRelays::Custom {
                urls: custom.urls.clone(),
                auth_token: custom.auth_token.clone(),
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
    /// Lifetime of the Approve / Deny token in an approval notification: short, so a
    /// notification left on a lock screen cannot approve a request much later.
    pub action_ttl: Duration,
    /// Delivery attempts per push (transient failures only).
    pub attempts: u32,
    /// First retry delay; doubled each attempt.
    pub backoff: Duration,
    /// Send the agents Live Activity (start, update, end; `push.live_activity`, default on).
    pub live_activity: bool,
    /// How long agent states settle before the Live Activity is updated (a burst of changes
    /// becomes one push).
    pub activity_debounce: Duration,
    /// Least time between two routine Live Activity updates to a device
    /// (`push.activity_interval_ms`); an agent newly needing the user goes at once.
    pub activity_interval: Duration,
    /// How long every agent must stay idle before the Live Activity ends.
    pub activity_end_after: Duration,
    /// Least time between two "finished" pushes for one pane to a device: a pane that keeps
    /// finishing short turns sends the newest when the time is up, not one each.
    pub pane_interval: Duration,
}

impl Default for PushConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            relay_url: brand::PUSH_RELAY_URL.to_owned(),
            delay: Duration::from_secs(3),
            action_ttl: Duration::from_secs(15 * 60),
            attempts: 5,
            backoff: Duration::from_secs(1),
            live_activity: true,
            activity_debounce: Duration::from_secs(1),
            activity_interval: Duration::from_secs(15),
            activity_end_after: Duration::from_secs(120),
            pane_interval: Duration::from_secs(30),
        }
    }
}

/// Whether startup may change the user's shared agent configuration.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum AgentIntegration {
    #[default]
    Automatic,
    Install,
}

/// Daemon settings.
///
/// # Examples
///
/// ```
/// let config = daemon::Config::new("/tmp/gudo-state");
/// assert_eq!(config.relay, daemon::RelayMode::Default);
/// ```
#[derive(Debug, Clone)]
pub struct Config {
    /// Keys, paired devices, layout and the hook socket live here.
    pub state_dir: PathBuf,
    pub agent_integration: AgentIntegration,
    /// Pane-owned, version-gated Codex Chat for dedicated launches; not hot-handoff capable.
    pub codex_chat: bool,
    /// Version-gated display capture for dedicated Claude launches; not hot-handoff capable.
    pub claude_chat_streaming: bool,
    /// UDP address the iroh endpoint binds (port 0 picks one). `None` binds every interface,
    /// IPv4 and IPv6, on random ports.
    pub bind: Option<SocketAddr>,
    pub relay: RelayMode,
    /// Shell for new panes; `$SHELL`, then `/bin/sh`, when `None`.
    pub shell: Option<PathBuf>,
    /// Extra environment for every pane (tests set a predictable prompt with it).
    pub pane_env: Vec<(String, String)>,
    /// Bytes of raw output retained per pane for resuming clients.
    pub ring_capacity: usize,
    /// Scrollback the daemon's VT keeps per pane, in bytes.
    pub scrollback_bytes: usize,
    /// Kitty graphics image storage per pane and screen, in bytes; 0 turns the protocol off
    /// (`terminal.image_storage_mb` in `config.toml`). Sent to clients
    /// (`ServerCtl::TerminalLimits`), whose mirrors follow it up to their own cap.
    pub image_storage_bytes: u64,
    /// Size of a pane no client has sized yet: (cols, rows).
    pub default_size: (u16, u16),
    /// Quiet period before layout changes are written to disk.
    pub persist_debounce: Duration,
    /// How long after output a pane's screen is saved for after a restart (`screens`): at
    /// most once per this while it keeps changing.
    pub screen_save_delay: Duration,
    /// How long an agent's request to drive one of the user's panes waits for the owner.
    pub drive_ask_wait: Duration,
    /// The agent hook shim; next to the current executable when `None`.
    pub hook_bin: Option<PathBuf>,
    /// The shim itself once `hook_bin` points at the launcher in front of it.
    pub(crate) hook_shim: Option<PathBuf>,
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
    /// Put the compressing proxy (`ws/editor_proxy.rs`) in front of editor servers, so the
    /// app's forward carries brotli/gzip instead of ~24 MB of plain JavaScript on a cold load
    /// (`editor.compress` in `config.toml`; default on).
    pub editor_compress: bool,
    /// Run VS Code as `code serve-web` instead of Microsoft's server directly
    /// (`editor.serve_web` in `config.toml`; default off: `ws/vscode_server.rs` says why).
    pub vscode_serve_web: bool,
    /// Microsoft's update service, where the `code` CLI is downloaded from on the user's
    /// request (tests point it at a local `file://` tree).
    pub vscode_update_url: String,
    pub push: PushConfig,
    /// A pane's control lease moves to someone who asked for it once the holder has not typed
    /// for this long (`multiplayer.lease_idle_secs` in `config.toml`).
    pub lease_idle: Duration,
    /// How long a new connection has to complete the QUIC handshake and send its `Hello`.
    /// Anyone can connect with a fresh key, so a silent one must not hold a slot for long.
    pub hello_timeout: Duration,
    /// How many connections may be open before their `Hello`.
    pub pre_auth: crate::preauth::PreAuthLimits,
    /// When live presence calls someone typing, idle, away or gone.
    pub presence: PresenceTimes,
    /// Command history for completion and the line editor (`[history]` in `config.toml`).
    pub history: crate::assist::HistoryConfig,
    /// Size caps for drawings and images.
    pub artifacts: ArtifactLimits,
    /// Native password prompts (`[askpass]` in `config.toml`).
    pub askpass: AskpassConfig,
    /// The executable this daemon runs from, when its owner may replace it over the
    /// connection (`proto::info`): the new build is written next to it and renamed over it.
    /// `None` (the default; library users and tests opt in) refuses upgrades.
    pub self_exe: Option<PathBuf>,
    /// The executable this daemon runs from, wherever it is (an app bundle too): a local
    /// restart request (`gudo-hostd restart`, sent by the Mac app after it updated itself)
    /// restarts into the build installed there, handing over the running panes. `None` (the
    /// default) refuses such requests.
    pub exe: Option<PathBuf>,
    /// The program [`brand::CLI_BIN`] runs in panes (`gudo pair`, `gudo devices`): linked as
    /// `<state_dir>/bin/gudo`, a directory appended to every pane's `PATH`. `None` (the
    /// default) links nothing.
    pub cli_exe: Option<PathBuf>,
    /// Tests only: announce this snapshot format instead of libghostty-vt's, to exercise a
    /// client that cannot decode it.
    #[doc(hidden)]
    pub test_snapshot_format: Option<u32>,
    /// Agent plan usage: refresh intervals and endpoints.
    pub usage: crate::usage::UsageConfig,
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

/// Native password prompts: the askpass helper in every pane's environment, and how long a
/// prompt waits for an answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AskpassConfig {
    /// Set `SUDO_ASKPASS`, `SSH_ASKPASS` (+ `SSH_ASKPASS_REQUIRE=prefer`) and `GIT_ASKPASS`
    /// in panes, and push detected password prompts. On by default.
    pub enabled: bool,
    /// With shell integration, wrap `sudo` in interactive shells so it runs `sudo -A` while
    /// an app that can answer is attached to the pane. On by default.
    pub sudo: bool,
    /// How long a prompt waits for an answer before the program gets none.
    pub timeout: Duration,
    /// How long a prompt survives with no connection left that could answer it before the
    /// helper asks on the terminal instead (covers an app reconnecting).
    pub grace: Duration,
}

impl Default for AskpassConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            sudo: true,
            timeout: Duration::from_secs(300),
            grace: Duration::from_secs(10),
        }
    }
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
            agent_integration: AgentIntegration::default(),
            bind: None,
            relay: RelayMode::Default,
            shell: None,
            codex_chat: true,
            claude_chat_streaming: true,
            pane_env: Vec::new(),
            ring_capacity: pty::DEFAULT_RING_CAPACITY,
            scrollback_bytes: 10 * 1024 * 1024,
            image_storage_bytes: ghostty_vt::KITTY_IMAGE_STORAGE_LIMIT,
            default_size: (80, 24),
            persist_debounce: Duration::from_millis(500),
            screen_save_delay: Duration::from_secs(5),
            drive_ask_wait: Duration::from_secs(120),
            hook_bin: None,
            hook_shim: None,
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
            editor_compress: true,
            vscode_serve_web: false,
            vscode_update_url: crate::ws::VSCODE_UPDATE_URL.to_owned(),
            push: PushConfig::default(),
            lease_idle: Duration::from_secs(5),
            hello_timeout: Duration::from_secs(10),
            pre_auth: crate::preauth::PreAuthLimits::default(),
            presence: PresenceTimes::default(),
            artifacts: ArtifactLimits::default(),
            askpass: AskpassConfig::default(),
            history: crate::assist::HistoryConfig::default(),
            self_exe: None,
            exe: None,
            cli_exe: None,
            test_snapshot_format: None,
            usage: crate::usage::UsageConfig::default(),
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
    /// compress = true              # brotli/gzip proxy in front of the editor server
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
    /// live_activity = true          # the agents Live Activity
    /// activity_interval_ms = 15000  # least time between routine updates
    ///
    /// [multiplayer]
    /// lease_idle_secs = 5
    ///
    /// [history]
    /// enabled = true
    /// ignore_space = true          # commands typed with a leading space are not kept
    /// max_entries = 50000
    /// import = true                # import zsh/bash/fish history once
    ///
    /// [terminal]
    /// image_storage_mb = 64        # kitty graphics images per pane and screen; 0 = off
    ///
    /// [askpass]
    /// enabled = true               # askpass helper in panes, detected prompts
    /// sudo = true                  # interactive `sudo` runs `sudo -A` while the app can answer
    /// timeout_secs = 300
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
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        };
        let file: UserFile = toml::from_str(&text)
            .map_err(|error| std::io::Error::other(format!("{}: {error}", path.display())))?;
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
        if let Some(compress) = file.editor.compress {
            self.editor_compress = compress;
        }
        if let Some(serve_web) = file.editor.serve_web {
            self.vscode_serve_web = serve_web;
        }
        if self.relay == RelayMode::Default {
            self.relay = file
                .relay
                .mode()
                .map_err(|error| std::io::Error::other(format!("{}: {error}", path.display())))?;
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
        if let Some(enabled) = file.push.live_activity {
            self.push.live_activity = enabled;
        }
        if let Some(ms) = file.push.activity_interval_ms {
            self.push.activity_interval = Duration::from_millis(ms);
        }
        if let Some(secs) = file.multiplayer.lease_idle_secs {
            self.lease_idle = Duration::from_secs(secs);
        }
        let history = file.history;
        if let Some(enabled) = history.enabled {
            self.history.enabled = enabled;
        }
        if let Some(enabled) = history.ignore_space {
            self.history.ignore_space = enabled;
        }
        if let Some(max) = history.max_entries {
            self.history.max_entries = max.max(1);
        }
        if let Some(enabled) = history.import {
            self.history.import = enabled;
        }
        if let Some(mb) = file.terminal.image_storage_mb {
            self.image_storage_bytes = mb << 20;
        }
        if let Some(enabled) = file.askpass.enabled {
            self.askpass.enabled = enabled;
        }
        if let Some(enabled) = file.askpass.sudo {
            self.askpass.sudo = enabled;
        }
        if let Some(secs) = file.askpass.timeout_secs {
            self.askpass.timeout = Duration::from_secs(secs.max(1));
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
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.into())
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

    /// Whether the hook shim is there to run: native Chat launches go through it, and without
    /// it they would exit before the agent starts.
    pub(crate) fn hook_bin_runs(&self) -> bool {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(self.hook_shim.clone().unwrap_or_else(|| self.hook_bin()))
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    }
}

/// The default state directory.
///
/// - `$XDG_STATE_HOME/<name>` when set (any OS);
/// - Linux and other Unix: `~/.local/state/<name>` (XDG default);
/// - macOS: `~/Library/Application Support/<Name>`.
pub fn default_state_dir() -> PathBuf {
    state_dir_named(brand::MAC_DIR_NAME, brand::DIR_NAME)
}

/// [`default_state_dir`] under the product's earlier name.
pub fn legacy_state_dir() -> PathBuf {
    state_dir_named(brand::legacy::DIR_NAME, brand::legacy::DIR_NAME)
}

fn state_dir_named(mac: &str, xdg: &str) -> PathBuf {
    if let Some(root) = std::env::var_os("XDG_STATE_HOME").filter(|value| !value.is_empty()) {
        return PathBuf::from(root).join(xdg);
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support").join(mac)
    } else {
        home.join(".local/state").join(xdg)
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
    askpass: AskpassSection,
    terminal: TerminalSection,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct TerminalSection {
    image_storage_mb: Option<u64>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
struct AskpassSection {
    enabled: Option<bool>,
    sudo: Option<bool>,
    timeout_secs: Option<u64>,
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
    live_activity: Option<bool>,
    activity_interval_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy)]
pub struct PresenceTimes {
    /// "Typing" lasts this long after the last keystroke or draft change.
    pub typing: Duration,
    /// No input, focus or draft change for this long: idle.
    pub idle: Duration,
    /// A presence client silent this long (no heartbeat, no message): away.
    pub away: Duration,
    /// Silent this long: the connection is dropped, so no ghost lingers.
    pub gone: Duration,
}

impl Default for PresenceTimes {
    fn default() -> Self {
        Self {
            typing: Duration::from_secs(3),
            idle: Duration::from_secs(120),
            away: Duration::from_secs(25),
            gone: Duration::from_secs(60),
        }
    }
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
    compress: Option<bool>,
    serve_web: Option<bool>,
}

/// `editor.default`.
#[derive(Debug, Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
enum DefaultEditor {
    Vscode,
    Vscodium,
}
