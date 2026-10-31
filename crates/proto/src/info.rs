//! What a daemon is (version, build, protocol level, machine) and how its owner replaces it
//! with a newer build over the connection.
//!
//! # Versions
//!
//! [`PROTOCOL_LEVEL`] counts protocol features a client may rely on. It goes up whenever the
//! app starts needing something a daemon built before would not do; additions that old
//! peers simply ignore (a new [`Caps`](crate::Caps) bit, an appended variant nobody waits
//! for) do not need it. A daemon reports its level in [`DaemonInfo::protocol`] and the
//! oldest client level it still serves in [`DaemonInfo::min_client_protocol`]; a client
//! works with daemons at or above its own [`MIN_DAEMON_PROTOCOL`]. Daemons from before
//! [`DaemonInfo`] existed send none and count as level 0.
//!
//! Between two builds of the same level, [`DaemonInfo::built_unix`] orders them (the commit
//! time of a clean release build, the build time of a dirty one, 0 for a developer build).
//!
//! # Self upgrade
//!
//! On a [`StreamHeader::Upgrade`](crate::StreamHeader::Upgrade) stream (owner only): header
//! → [`UpgradeReply::Ready`] → the client sends exactly `size` bytes and finishes →
//! [`UpgradeReply::Installed`] once the daemon verified the build (SHA-256, then the binary
//! itself must run on this host and report its info, and must not be older than the running
//! build unless the owner sent it as a [`StreamHeader::Downgrade`](crate::StreamHeader::Downgrade))
//! and swapped it in atomically. The daemon
//! then saves its layout, stops its panes and executes the new build in its own process (same
//! PID, so systemd and launchd keep supervising it); the connection drops and the client
//! redials as after any restart. Panes come back from `layout.json` (shells restart in their
//! last directory, agents resume their sessions). [`UpgradeReply::Failed`] at any point leaves
//! the running daemon as it was.

use serde::{Deserialize, Serialize};

use crate::ids::DaemonFeatures;

/// The protocol level this build speaks (see the module docs).
pub const PROTOCOL_LEVEL: u32 = 1;

/// The oldest daemon level a client of this build works with.
pub const MIN_DAEMON_PROTOCOL: u32 = 0;

/// The oldest client level a daemon of this build serves.
pub const MIN_CLIENT_PROTOCOL: u32 = 0;

/// A daemon's build and machine, sent as [`ServerCtl::DaemonInfo`](crate::ServerCtl::DaemonInfo)
/// to clients announcing [`Caps::DAEMON_INFO`](crate::Caps::DAEMON_INFO).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonInfo {
    /// The daemon's semantic version (`CARGO_PKG_VERSION`).
    pub version: String,
    /// The build: a commit id (with `-dirty` for uncommitted changes), or `dev` for a build
    /// made without the release tooling.
    pub build: String,
    /// When the build's source was made, Unix seconds (0 for `dev` builds).
    pub built_unix: u64,
    /// The protocol level the daemon speaks ([`PROTOCOL_LEVEL`] of its build).
    pub protocol: u32,
    /// The oldest client level it serves.
    pub min_client_protocol: u32,
    /// Optional abilities.
    pub features: DaemonFeatures,
    /// The machine's host name as the system reports it (may include a domain). Empty when
    /// the connection was refused.
    pub hostname: String,
    /// `std::env::consts::OS` of the build: `linux`, `macos`.
    pub os: String,
    /// The operating system in words ("Ubuntu 24.04.1 LTS", "macOS 26.1"), or empty.
    pub os_name: String,
    /// `std::env::consts::ARCH` of the build: `x86_64`, `aarch64`.
    pub arch: String,
}

impl DaemonInfo {
    /// Whether this build is older than `other`: a lower protocol level, or the same level
    /// from an earlier source (see the module docs; `dev` builds are older than any release
    /// build). The same order as the app's `HelperVersion.isOlder`.
    ///
    /// # Examples
    ///
    /// ```
    /// # use proto::{DaemonFeatures, DaemonInfo};
    /// let build = |build: &str, built_unix, protocol| DaemonInfo {
    ///     version: "0.1.0".into(),
    ///     build: build.into(),
    ///     built_unix,
    ///     protocol,
    ///     min_client_protocol: 0,
    ///     features: DaemonFeatures::EMPTY,
    ///     hostname: String::new(),
    ///     os: "linux".into(),
    ///     os_name: String::new(),
    ///     arch: "x86_64".into(),
    /// };
    /// assert!(build("a", 100, 1).is_older_than(&build("b", 200, 1)));
    /// assert!(build("b", 200, 1).is_older_than(&build("a", 100, 2)));
    /// assert!(!build("a", 100, 1).is_older_than(&build("a", 100, 1)));
    /// assert!(build("dev", 0, 1).is_older_than(&build("a", 100, 1)));
    /// ```
    pub fn is_older_than(&self, other: &DaemonInfo) -> bool {
        if self.protocol != other.protocol {
            return self.protocol < other.protocol;
        }
        self.build != other.build && self.built_unix < other.built_unix
    }
}

/// How the bytes on an upgrade stream are encoded.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum UpgradeEncoding {
    /// The executable as is.
    Raw,
    /// gzip (one member), as the app bundles its daemons.
    Gzip,
}

/// First frame of a [`StreamHeader::Upgrade`](crate::StreamHeader::Upgrade) stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpgradeHeader {
    /// Bytes that follow on the stream (encoded).
    pub size: u64,
    /// Their encoding.
    pub encoding: UpgradeEncoding,
    /// SHA-256 of the executable after decoding.
    pub sha256: [u8; 32],
    /// The build the client believes it is sending, for the daemon's log and audit.
    pub build: String,
}

/// The daemon's frames on an upgrade stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum UpgradeReply {
    /// Send the bytes.
    Ready,
    /// The new build is in place and reported this about itself; the daemon restarts into
    /// it right after this frame.
    Installed(DaemonInfo),
    /// Nothing changed; the stream ends.
    Failed {
        /// Machine-readable reason.
        code: UpgradeFailure,
        /// Why, in words.
        message: String,
    },
}

/// Why an upgrade was refused or failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum UpgradeFailure {
    /// Only the daemon's owner (a paired device, not a guest) may replace it.
    Forbidden,
    /// This daemon cannot replace itself (not installed as a file it may write, or started in
    /// a way it cannot restart).
    Unsupported,
    /// Another upgrade is in progress.
    Busy,
    /// The bytes did not match the announced size or SHA-256, or did not decode.
    Corrupt,
    /// The new build did not run on this host (wrong platform, crashed) or reported nonsense.
    Rejected,
    /// Writing or swapping the file failed.
    Io,
    /// The new build is older than the running one; only an explicit
    /// [`StreamHeader::Downgrade`](crate::StreamHeader::Downgrade) installs it.
    Older,
}
