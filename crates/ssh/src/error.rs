//! The crate's error type.

use std::io;
use std::sync::Arc;

/// Errors from connecting, authenticating, running channels and bootstrapping.
///
/// [`SshError::is_fatal`] tells a reconnect loop which errors need the user (wrong
/// credentials, a changed host key) rather than another attempt.
#[derive(Debug, Clone, thiserror::Error)]
pub enum SshError {
    /// Socket-level failure (DNS, connect, read, write).
    #[error("{context}: {source}")]
    Io {
        /// What was being done.
        context: String,
        /// The underlying error.
        #[source]
        source: Arc<io::Error>,
    },
    /// The SSH protocol failed (kex, framing, channel open).
    #[error("ssh: {0}")]
    Protocol(String),
    /// A step did not finish in time.
    #[error("timed out {0}")]
    Timeout(&'static str),
    /// The connection is gone (closed, or declared dead by the keepalive monitor).
    #[error("connection closed: {0}")]
    Disconnected(String),
    /// Every authentication method was tried and refused.
    #[error("authentication failed for {user}@{host} (tried: {tried}; server allows: {allowed})")]
    AuthFailed {
        /// User name.
        user: String,
        /// Host.
        host: String,
        /// Methods tried, comma-separated.
        tried: String,
        /// Methods the server offered last, comma-separated.
        allowed: String,
    },
    /// The host presented a key different from the known or pinned one. Possibly an attack;
    /// never retried automatically.
    #[error(
        "HOST KEY MISMATCH for {host}: expected {}, got {actual}",
        expected.join(" or ")
    )]
    HostKeyMismatch {
        /// `host` or `[host]:port`.
        host: String,
        /// Fingerprints on record (`SHA256:…`).
        expected: Vec<String>,
        /// Fingerprint presented (`SHA256:…`).
        actual: String,
    },
    /// The host key is unknown and the policy or the user declined it.
    #[error("host key for {host} not trusted ({fingerprint})")]
    HostKeyRejected {
        /// `host` or `[host]:port`.
        host: String,
        /// Fingerprint presented (`SHA256:…`).
        fingerprint: String,
    },
    /// A private key could not be decoded.
    #[error("bad private key: {0}")]
    Key(String),
    /// The private key is encrypted and no passphrase was given.
    #[error("the private key is encrypted; a passphrase is needed")]
    KeyEncrypted,
    /// An external signer (Secure Enclave, agent) failed.
    #[error("signer: {0}")]
    Signer(String),
    /// `~/.ssh/config` or a host spec could not be parsed.
    #[error("config: {0}")]
    Config(String),
    /// A remote command failed.
    #[error("remote command failed ({status}): {stderr}")]
    Remote {
        /// Exit status, or a signal name.
        status: String,
        /// Its standard error, trimmed.
        stderr: String,
    },
    /// An upload arrived corrupted.
    #[error("upload checksum mismatch for {path}: sent {expected}, remote has {actual}")]
    ChecksumMismatch {
        /// Remote path.
        path: String,
        /// SHA-256 sent, hex.
        expected: String,
        /// SHA-256 on the remote, hex.
        actual: String,
    },
    /// Bootstrap could not proceed (unsupported platform, missing binary, bad output).
    #[error("bootstrap: {0}")]
    Bootstrap(String),
    /// The session was closed by the caller.
    #[error("the session is closed")]
    Closed,
}

impl SshError {
    /// Whether retrying cannot help without user action (credentials, host key, config).
    pub fn is_fatal(&self) -> bool {
        matches!(
            self,
            Self::AuthFailed { .. }
                | Self::HostKeyMismatch { .. }
                | Self::HostKeyRejected { .. }
                | Self::Key(_)
                | Self::KeyEncrypted
                | Self::Config(_)
                | Self::Closed
        )
    }

    pub(crate) fn io(context: impl Into<String>, source: io::Error) -> Self {
        Self::Io {
            context: context.into(),
            source: Arc::new(source),
        }
    }
}

impl From<russh::Error> for SshError {
    fn from(e: russh::Error) -> Self {
        match e {
            russh::Error::IO(source) => Self::io("ssh transport", source),
            russh::Error::KeepaliveTimeout => Self::Disconnected("keepalive timeout".into()),
            russh::Error::InactivityTimeout => Self::Disconnected("inactivity timeout".into()),
            russh::Error::Disconnect | russh::Error::HUP => {
                Self::Disconnected("the server closed the connection".into())
            }
            other => Self::Protocol(other.to_string()),
        }
    }
}

impl From<russh::keys::Error> for SshError {
    fn from(e: russh::keys::Error) -> Self {
        match e {
            russh::keys::Error::KeyIsEncrypted => Self::KeyEncrypted,
            other => Self::Key(other.to_string()),
        }
    }
}

impl From<russh::SendError> for SshError {
    fn from(_: russh::SendError) -> Self {
        Self::Disconnected("the session ended".into())
    }
}
