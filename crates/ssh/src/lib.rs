//! Client-side SSH for the app and the CLI: the zero-setup path and the fallback rung of
//! the transport ladder, on russh with ring crypto.
//!
//! - **Dial**: [`Connection::connect`] reaches a [`Target`] through any `ProxyJump` hops
//!   (`direct-tcpip` channels through each), verifies host keys against [`KnownHosts`]
//!   (TOFU via [`HostKeyPrompt`], pinning, mismatch errors with both fingerprints) and
//!   authenticates with the [`Credentials`] in order: agent, keys, [`ExternalSigner`]s
//!   (Secure Enclave), password, keyboard-interactive.
//! - **Stay up**: a [`Connection`] is alive only while keepalives are answered
//!   ([`Keepalive`]); a [`Session`] redials dead connections with backoff and never gives
//!   up in the foreground ([`ReconnectPolicy`]), reporting each [`ConnectionState`].
//! - **Use**: [`Connection::exec`], [`Connection::open_shell`] (PTY, resize, env),
//!   [`Connection::upload`] (exec `cat`/`gzip -dc` with a SHA-256 check, no SFTP).
//! - **Upgrade**: [`bootstrap`] installs `gudo-hostd` and returns a pairing ticket.
//! - **Configure**: [`SshConfig`] reads `~/.ssh/config` with OpenSSH semantics.
//!
//! The API takes and returns owned values and uses trait-object callbacks, so it maps onto
//! UniFFI (async methods, callback interfaces) without generics. See docs/SSH.md.
//!
//! # Examples
//!
//! ```no_run
//! use std::sync::Arc;
//! use ssh::{AuthMethod, Connection, ConnectOptions, Credentials, HostKeyPolicy, KnownHosts, SshConfig};
//!
//! # async fn demo() -> Result<(), ssh::SshError> {
//! let config = SshConfig::load_default()?;
//! let target = config.target("me@box", "me")?;
//! let credentials = Credentials::new().with(AuthMethod::Agent(None));
//! let known_hosts = Arc::new(KnownHosts::open(std::path::Path::new("/tmp/known_hosts"))?);
//! let options = ConnectOptions::new(credentials, known_hosts, HostKeyPolicy::AcceptNew);
//! let connection = Connection::connect(&target, &options).await?;
//! let output = connection.exec("uname -sm").await?.check()?;
//! println!("{}", output.stdout_text());
//! # Ok(())
//! # }
//! ```

mod auth;
mod bootstrap;
mod channel;
mod client;
mod config;
mod discovery;
mod error;
mod host_input;
mod keys;
mod known_hosts;
mod session;
mod target;
mod wildcard;

pub use auth::{AuthMethod, Credentials, InteractivePrompt, InteractiveResponder};
pub use bootstrap::{
    BinarySource, BootstrapListener, BootstrapOptions, BootstrapReport, BootstrapStep,
    HostPlatform, HostdBinaries, InstallAction, ServiceMode, bootstrap, detect_platform,
};
pub use channel::{
    ExecOutput, PtyRequest, Shell, ShellEvent, ShellOutput, UploadEncoding, UploadReport,
    sha256_hex, shell_quote,
};
pub use client::{ConnectOptions, Connection, Keepalive, Timeouts};
pub use config::{HostConfig, Route, SshConfig};
pub use discovery::{
    KnownHostName, LocalKey, PublicKeyInfo, agent_keys, known_host_names, local_keys,
};
pub use error::SshError;
pub use host_input::HostInput;
pub use keys::{
    EncryptedKey, ExternalSigner, GeneratedKey, KeyType, SecretKey, SecurityKeySignature,
    SignerError, authorize_key_command, generate_ed25519, generate_key,
};
pub use known_hosts::{
    HostKeyInfo, HostKeyPolicy, HostKeyPrompt, HostKeyStatus, KnownHosts, KnownHostsListener,
    fingerprint, host_name,
};
pub use session::{ConnectionState, ReconnectPolicy, Session, SessionListener};
pub use target::{DEFAULT_PORT, Destination, HostSpec, Target};

/// Re-exported for implementors of [`ExternalSigner`] and tests.
pub use russh::keys::PublicKey;
