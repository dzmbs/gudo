//! Product-name-bearing strings, defined once.
//!
//! Renaming the product means editing this file and `apple/Brand.xcconfig`. The names the
//! product had before live in [`legacy`], only to migrate installs made under them.

/// Human-readable product name.
pub const PRODUCT_NAME: &str = "Gudo";

/// QUIC ALPN identifier for the client <-> daemon protocol, version 1.
pub const ALPN: &[u8] = b"gudo/1";

/// Prefix for every environment variable we set in panes or read from the environment.
pub const ENV_PREFIX: &str = "GUDO_";

/// Name of the host daemon binary.
pub const DAEMON_BIN: &str = "gudo-hostd";

/// Name of the agent hook shim binary.
pub const HOOK_BIN: &str = "gudo-hook";

/// Directory name under the platform config/state roots (e.g. `~/.config/<this>`), and the
/// prefix of names the daemon gives things on the host (branches, refs, repo config files).
pub const DIR_NAME: &str = "gudo";

/// Directory name under macOS's `~/Library/Application Support` and `~/Library/Logs`.
pub const MAC_DIR_NAME: &str = "Gudo";

/// Builds a full environment variable name from a suffix.
///
/// # Examples
///
/// ```
/// assert_eq!(brand::env_var("PANE_ID"), "GUDO_PANE_ID");
/// ```
pub fn env_var(suffix: &str) -> String {
    format!("{ENV_PREFIX}{suffix}")
}

/// Reads the environment variable named by `suffix`, falling back to its [`legacy`] name
/// (set by a daemon or agent started before the rename).
pub fn var_os(suffix: &str) -> Option<std::ffi::OsString> {
    std::env::var_os(env_var(suffix)).or_else(|| std::env::var_os(legacy::env_var(suffix)))
}

/// [`var_os`] as UTF-8; `None` when unset or not Unicode.
pub fn var(suffix: &str) -> Option<String> {
    var_os(suffix).and_then(|value| value.into_string().ok())
}

/// URL scheme for links into the app, such as pairing tickets (`<scheme>://pair/…`).
pub const URL_SCHEME: &str = "gudo";

/// Web domain whose `https://<domain>/pair#…` and `/join#…` links open the app (universal
/// links) and whose site explains them to people without it.
pub const WEB_DOMAIN: &str = "gudo.dev";

/// The product's website.
pub const WEBSITE_URL: &str = "https://gudo.dev";

/// Name of the developer command-line client.
pub const CLI_BIN: &str = "gudo";

/// Reverse-DNS label for per-user services (the macOS LaunchAgent).
pub const SERVICE_LABEL: &str = "dev.gudo.hostd";

/// The iroh relay daemons and apps use by default, unless the daemon's `config.toml` or the
/// app's relay settings name others. See `docs/RELAYS.md`.
pub const RELAY_URL: &str = "https://relay.gudo.dev";

/// The push relay (a Cloudflare Worker) daemons send sealed notifications to, unless
/// `push.relay` in the daemon's `config.toml` names another. See `docs/PUSH.md`.
pub const PUSH_RELAY_URL: &str = "https://push.gudo.dev";

/// Names the product had before, for migrating what was installed under them.
pub mod legacy {
    /// ALPN older daemons accept and older apps dial.
    pub const ALPN: &[u8] = b"unnamed/1";

    /// Environment variable prefix older daemons set in panes.
    pub const ENV_PREFIX: &str = "UN_";

    /// [`super::env_var`] under the earlier prefix.
    pub fn env_var(suffix: &str) -> String {
        format!("{ENV_PREFIX}{suffix}")
    }

    /// Older daemon binary.
    pub const DAEMON_BIN: &str = "unnamed-hostd";

    /// Older hook shim binary.
    pub const HOOK_BIN: &str = "un-hook";

    /// Older developer command-line client.
    pub const CLI_BIN: &str = "un";

    /// Older state and config directory name (macOS and XDG alike).
    pub const DIR_NAME: &str = "unnamed";

    /// Older LaunchAgent label (`service install`).
    pub const SERVICE_LABEL: &str = "dev.unnamed.hostd";

    /// Older URL scheme, still read in pairing tickets and invites.
    pub const URL_SCHEME: &str = "unnamed";

    /// MCP server names older daemons registered with agents.
    pub const MCP_SERVER_NAMES: [&str; 2] = ["unnamed", "unnamed_drawings"];
}
