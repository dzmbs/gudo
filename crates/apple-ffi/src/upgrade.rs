//! The daemon's build and machine ([`DaemonInfo`]) and updating it over the connection
//! ([`DaemonClient::upgrade_daemon`]; `proto::info`).

use std::sync::Arc;

use client_core::proto;

use crate::client::DaemonClient;
use crate::on_runtime;
use crate::workspace::{TransferProgress, progress_adapter};

/// What a daemon said about itself (`ClientEvent::DaemonInfo`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DaemonInfo {
    /// Semantic version.
    pub version: String,
    /// Commit id (with `-dirty`), or `dev`.
    pub build: String,
    /// When the build's source was made, Unix seconds (0 for `dev`).
    pub built_unix: u64,
    /// Protocol level it speaks ([`protocol_level`] of its build).
    pub protocol: u32,
    /// The oldest client level it serves.
    pub min_client_protocol: u32,
    /// It accepts a new build of itself over the connection from its owner.
    pub self_upgrade: bool,
    /// The machine's host name (may include a domain); empty when refused.
    pub hostname: String,
    /// `linux`, `macos`.
    pub os: String,
    /// "Ubuntu 24.04.1 LTS", "macOS 26.1", or empty.
    pub os_name: String,
    /// `x86_64`, `aarch64`.
    pub arch: String,
    /// It answers `usage_watch` (agent plan usage).
    pub agent_usage: bool,
    #[uniffi(default = false)]
    pub multiplayer2: bool,
    /// It moves panes between tabs and merges tabs (`LayoutOp::BreakPane` …).
    #[uniffi(default = false)]
    pub pane_moves: bool,
    /// It names the commands that register its MCP server with the agents
    /// (`agent_mcp_commands`).
    #[uniffi(default = false)]
    pub agent_mcp: bool,
}

impl From<proto::DaemonInfo> for DaemonInfo {
    fn from(i: proto::DaemonInfo) -> Self {
        Self {
            version: i.version,
            build: i.build,
            built_unix: i.built_unix,
            protocol: i.protocol,
            min_client_protocol: i.min_client_protocol,
            self_upgrade: i.features.contains(proto::DaemonFeatures::SELF_UPGRADE),
            hostname: i.hostname,
            os: i.os,
            os_name: i.os_name,
            arch: i.arch,
            agent_usage: i.features.contains(proto::DaemonFeatures::AGENT_USAGE),
            multiplayer2: i.features.contains(proto::DaemonFeatures::MP2),
            pane_moves: i.features.contains(proto::DaemonFeatures::PANE_MOVES),
            agent_mcp: i.features.contains(proto::DaemonFeatures::AGENT_MCP),
        }
    }
}

/// The protocol level this core speaks (`proto::PROTOCOL_LEVEL`).
#[uniffi::export]
pub fn protocol_level() -> u32 {
    proto::PROTOCOL_LEVEL
}

/// The oldest daemon protocol level this core works with.
#[uniffi::export]
pub fn min_daemon_protocol() -> u32 {
    proto::MIN_DAEMON_PROTOCOL
}

/// Why the daemon refused or failed an upgrade.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UpgradeFailureCode {
    /// Only the owner may update the helper.
    Forbidden,
    /// The helper cannot replace itself (update it over SSH).
    Unsupported,
    /// Another update is running.
    Busy,
    /// The build arrived damaged.
    Corrupt,
    /// The build does not run on that host.
    Rejected,
    /// Writing or swapping the file failed.
    Io,
    /// The build is older than the helper's; the app never downgrades.
    Older,
}

impl From<proto::UpgradeFailure> for UpgradeFailureCode {
    fn from(f: proto::UpgradeFailure) -> Self {
        match f {
            proto::UpgradeFailure::Forbidden => Self::Forbidden,
            proto::UpgradeFailure::Unsupported => Self::Unsupported,
            proto::UpgradeFailure::Busy => Self::Busy,
            proto::UpgradeFailure::Corrupt => Self::Corrupt,
            proto::UpgradeFailure::Rejected => Self::Rejected,
            proto::UpgradeFailure::Io => Self::Io,
            proto::UpgradeFailure::Older => Self::Older,
        }
    }
}

/// Errors from [`DaemonClient::upgrade_daemon`].
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum UpgradeError {
    /// The daemon refused or failed; it keeps running its build.
    #[error("{message}")]
    Daemon {
        /// Why, as a code.
        code: UpgradeFailureCode,
        /// Why, in words.
        message: String,
    },
    /// The build could not be read or decoded on this device.
    #[error("{message}")]
    Local {
        /// Why.
        message: String,
    },
    /// The connection failed; the host may or may not have the new build.
    #[error("{message}")]
    Connection {
        /// Why.
        message: String,
    },
}

impl From<client_core::UpgradeError> for UpgradeError {
    fn from(e: client_core::UpgradeError) -> Self {
        match e {
            client_core::UpgradeError::Daemon { code, message } => Self::Daemon {
                code: code.into(),
                message,
            },
            client_core::UpgradeError::Local(message) => Self::Local { message },
            client_core::UpgradeError::Connection(message) => Self::Connection { message },
        }
    }
}

#[uniffi::export]
impl DaemonClient {
    /// What the daemon said about itself on the current (or last) connection; `nil` before
    /// the first connection and for daemons that predate it.
    pub fn daemon_info(&self) -> Option<DaemonInfo> {
        self.core().daemon_info().map(Into::into)
    }

    /// Whether the last connection was admitted only to update the daemon (it draws
    /// terminals in a format this core does not read).
    pub fn is_incompatible(&self) -> bool {
        self.core().is_incompatible()
    }

    /// Sends the daemon build at `path` (an executable or its gzip, as the app bundles them)
    /// to the daemon, which checks it, swaps it in and restarts into it. Owner devices only.
    /// Returns what the new build reported; the connection then drops and comes back by
    /// itself, panes restored from the daemon's layout (shells restart).
    ///
    /// # Errors
    ///
    /// [`UpgradeError`].
    pub async fn upgrade_daemon(
        &self,
        path: String,
        build: String,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<DaemonInfo, UpgradeError> {
        let client = self.core();
        let progress = progress_adapter(progress);
        on_runtime(async move {
            let build = tokio::task::spawn_blocking(move || {
                client_core::DaemonBuild::from_file(&path, build)
            })
            .await
            .map_err(|e| client_core::UpgradeError::Local(e.to_string()))??;
            client.upgrade_daemon(build, progress).await
        })
        .await
        .map(Into::into)
        .map_err(Into::into)
    }
}
