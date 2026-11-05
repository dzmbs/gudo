//! Product-name-bearing strings, defined once.
//!
//! Renaming the product means editing this file and `apple/Brand.xcconfig`. The names the
//! product had before live in [`legacy`], only to migrate installs made under them.

/// Human-readable product name.
pub const IS_DEV: bool = cfg!(gudo_dev);
pub const PRODUCT_NAME: &str = if IS_DEV { "Gudo Dev" } else { "Gudo" };
pub const CARGO_DAEMON_BIN: &str = "gudo-hostd";
pub const BUILD_DIRECTORY: &str = if IS_DEV { "dev" } else { "" };

/// QUIC ALPN identifier for the client <-> daemon protocol, version 1.
pub const ALPN: &[u8] = b"gudo/1";

/// Prefix for every environment variable we set in panes or read from the environment.
pub const RELEASE_ENV_PREFIX: &str = "GUDO_";
pub const ENV_PREFIX: &str = if IS_DEV {
    "GUDO_DEV_"
} else {
    RELEASE_ENV_PREFIX
};

/// Name of the host daemon binary.
pub const DAEMON_BIN: &str = if IS_DEV {
    "gudo-dev-hostd"
} else {
    "gudo-hostd"
};

/// Name of the agent hook shim binary.
pub const HOOK_BIN: &str = if IS_DEV { "gudo-dev-hook" } else { "gudo-hook" };

/// Directory name under the platform config/state roots (e.g. `~/.config/<this>`), and the
/// prefix of names the daemon gives things on the host (branches, refs, repo config files).
pub const DIR_NAME: &str = if IS_DEV { "gudo-dev" } else { "gudo" };

/// How `devices` lists the app's own device on the computer it runs on.
pub const THIS_COMPUTER_APP: &str = if IS_DEV {
    "This Mac (Gudo Dev app)"
} else {
    "This Mac (Gudo app)"
};

/// Directory name under macOS's `~/Library/Application Support` and `~/Library/Logs`.
pub const MAC_DIR_NAME: &str = PRODUCT_NAME;

/// Builds a full environment variable name from a suffix.
///
/// # Examples
///
/// ```
/// assert_eq!(brand::env_var("PANE_ID"), format!("{}PANE_ID", brand::ENV_PREFIX));
/// ```
pub fn env_var(suffix: &str) -> String {
    format!("{ENV_PREFIX}{suffix}")
}

/// Reads the environment variable named by `suffix`, falling back to its [`legacy`] name
/// (set by a daemon or agent started before the rename).
pub fn var_os(suffix: &str) -> Option<std::ffi::OsString> {
    std::env::var_os(env_var(suffix)).or_else(|| {
        if IS_DEV {
            None
        } else {
            std::env::var_os(legacy::env_var(suffix))
        }
    })
}

/// [`var_os`] as UTF-8; `None` when unset or not Unicode.
pub fn var(suffix: &str) -> Option<String> {
    var_os(suffix).and_then(|value| value.into_string().ok())
}

/// URL scheme for links into the app, such as pairing tickets (`<scheme>://pair/…`).
pub const RELEASE_URL_SCHEME: &str = "gudo";
pub const DEV_URL_SCHEME: &str = "gudo-dev";
pub const URL_SCHEME: &str = if IS_DEV {
    DEV_URL_SCHEME
} else {
    RELEASE_URL_SCHEME
};

/// Web domain whose `https://<domain>/pair#…` and `/join#…` links open the app (universal
/// links) and whose site explains them to people without it.
pub const WEB_DOMAIN: &str = "gudo.dev";

/// The product's website.
pub const WEBSITE_URL: &str = "https://gudo.dev";

/// Name of the developer command-line client.
pub const CLI_BIN: &str = if IS_DEV { "gudo-dev" } else { "gudo" };

/// Reverse-DNS label for per-user services (the macOS LaunchAgent).
pub const SERVICE_LABEL: &str = if IS_DEV {
    "dev.gudo.dev.hostd"
} else {
    "dev.gudo.hostd"
};

/// The iroh relay daemons and apps use by default, unless the daemon's `config.toml` or the
/// app's relay settings name others. See `docs/RELAYS.md`.
pub const RELAY_URL: &str = "https://relay.gudo.dev";

/// Token the default relay asks for. Not a secret: it ships in every build and is public in this
/// repository. It only keeps unrelated iroh apps off our relay; traffic stays end-to-end
/// encrypted either way, and per-connection limits on the relay handle abuse. See
/// `docs/RELAYS.md`.
pub const RELAY_TOKEN: &str = "vpMx89kx8DZiOVUIP8aVBnCfbEUrMNzQfwVJKSBhRRI";

/// The push relay (a Cloudflare Worker) daemons send sealed notifications to, unless
/// `push.relay` in the daemon's `config.toml` names another. See `docs/PUSH.md`.
pub const PUSH_RELAY_URL: &str = "https://push.gudo.dev";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn development_and_release_names_are_disjoint() {
        let actual = [
            PRODUCT_NAME,
            DAEMON_BIN,
            HOOK_BIN,
            DIR_NAME,
            MAC_DIR_NAME,
            CLI_BIN,
            SERVICE_LABEL,
            URL_SCHEME,
            ENV_PREFIX,
        ];
        let release = [
            "Gudo",
            "gudo-hostd",
            "gudo-hook",
            "gudo",
            "Gudo",
            "gudo",
            "dev.gudo.hostd",
            "gudo",
            "GUDO_",
        ];
        let development = [
            "Gudo Dev",
            "gudo-dev-hostd",
            "gudo-dev-hook",
            "gudo-dev",
            "Gudo Dev",
            "gudo-dev",
            "dev.gudo.dev.hostd",
            "gudo-dev",
            "GUDO_DEV_",
        ];
        assert_eq!(actual, if IS_DEV { development } else { release });
        for (release, development) in release.iter().zip(development.iter()) {
            assert_ne!(release, development);
        }
    }
}

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
