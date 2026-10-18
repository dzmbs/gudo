//! Product-name-bearing strings, defined once.
//!
//! The product is unnamed for now. Renaming it means editing this file and
//! `apple/Brand.xcconfig`; CI rejects the placeholder anywhere else.

/// Human-readable product name.
pub const PRODUCT_NAME: &str = "unnamed";

/// QUIC ALPN identifier for the client <-> daemon protocol, version 1.
pub const ALPN: &[u8] = b"unnamed/1";

/// Prefix for every environment variable we set in panes or read from the environment.
pub const ENV_PREFIX: &str = "UN_";

/// Name of the host daemon binary.
pub const DAEMON_BIN: &str = "unnamed-hostd";

/// Name of the agent hook shim binary.
pub const HOOK_BIN: &str = "un-hook";

/// Directory name under the platform config/state roots (e.g. `~/.config/<this>`).
pub const DIR_NAME: &str = "unnamed";

/// Builds a full environment variable name from a suffix.
///
/// # Examples
///
/// ```
/// assert_eq!(brand::env_var("PANE_ID"), "UN_PANE_ID");
/// ```
pub fn env_var(suffix: &str) -> String {
    format!("{ENV_PREFIX}{suffix}")
}
