//! SSH for the app: config parsing, keys, known_hosts, self-healing sessions, plain-SSH panes
//! and daemon bootstrap (docs/SSH.md), wrapping the `ssh` crate.

use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

use client_core::proto::PaneId;

use crate::bytes::Bytes;
use crate::client::{ClientEventListener, Forward};
use crate::on_runtime;
use crate::runtime;
use crate::types::PaneSize;

/// Errors from SSH operations. Mirrors the `ssh` crate's error.
#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum SshError {
    /// Socket-level failure (DNS, connect, read, write).
    #[error("{message}")]
    Io { message: String },
    #[error("ssh: {message}")]
    Protocol { message: String },
    /// A step did not finish in time.
    #[error("timed out {message}")]
    Timeout { message: String },
    /// The connection is gone.
    #[error("connection closed: {message}")]
    Disconnected { message: String },
    /// Every authentication method was refused.
    #[error("authentication failed for {user}@{host} (tried: {tried}; server allows: {allowed})")]
    AuthFailed {
        user: String,
        host: String,
        /// Methods tried, comma-separated.
        tried: String,
        /// Methods the server offered, comma-separated.
        allowed: String,
    },
    /// The host presented a key other than the one on record (and it was not accepted).
    #[error("HOST KEY MISMATCH for {host}: expected {}, got {actual}", expected.join(" or "))]
    HostKeyMismatch {
        /// `host` or `[host]:port`.
        host: String,
        /// Fingerprints on record.
        expected: Vec<String>,
        /// Fingerprint presented.
        actual: String,
    },
    /// An unknown host key was refused (policy or user).
    #[error("host key for {host} not trusted ({fingerprint})")]
    HostKeyRejected {
        /// `host` or `[host]:port`.
        host: String,
        /// Fingerprint presented.
        fingerprint: String,
    },
    /// A private key could not be decoded.
    #[error("bad private key: {message}")]
    Key { message: String },
    /// The private key is encrypted and no passphrase was given.
    #[error("the private key is encrypted; a passphrase is needed")]
    KeyEncrypted,
    #[error("signer: {message}")]
    Signer { message: String },
    /// ssh_config or a destination could not be parsed.
    #[error("config: {message}")]
    Config { message: String },
    #[error("remote command failed ({status}): {stderr}")]
    Remote {
        /// Exit status or signal.
        status: String,
        /// Its stderr, trimmed.
        stderr: String,
    },
    /// An upload arrived corrupted.
    #[error("upload checksum mismatch for {path}")]
    ChecksumMismatch {
        path: String,
        /// SHA-256 sent.
        expected: String,
        /// SHA-256 on the remote.
        actual: String,
    },
    /// Bootstrap could not proceed.
    #[error("bootstrap: {message}")]
    Bootstrap { message: String },
    /// The session was closed.
    #[error("the session is closed")]
    Closed,
}

impl SshError {
    fn io(message: impl Into<String>) -> Self {
        Self::Io {
            message: message.into(),
        }
    }
}

impl From<ssh::SshError> for SshError {
    fn from(ssh_error: ssh::SshError) -> Self {
        use ssh::SshError as E;
        match ssh_error {
            E::Io { .. } => Self::io(ssh_error.to_string()),
            E::Protocol(message) => Self::Protocol { message },
            E::Timeout(what) => Self::Timeout {
                message: what.to_owned(),
            },
            E::Disconnected(message) => Self::Disconnected { message },
            E::AuthFailed {
                user,
                host,
                tried,
                allowed,
            } => Self::AuthFailed {
                user,
                host,
                tried,
                allowed,
            },
            E::HostKeyMismatch {
                host,
                expected,
                actual,
            } => Self::HostKeyMismatch {
                host,
                expected,
                actual,
            },
            E::HostKeyRejected { host, fingerprint } => Self::HostKeyRejected { host, fingerprint },
            E::Key(message) => Self::Key { message },
            E::KeyEncrypted => Self::KeyEncrypted,
            E::Signer(message) => Self::Signer { message },
            E::Config(message) => Self::Config { message },
            E::Remote { status, stderr } => Self::Remote { status, stderr },
            E::ChecksumMismatch {
                path,
                expected,
                actual,
            } => Self::ChecksumMismatch {
                path,
                expected,
                actual,
            },
            E::Bootstrap(message) => Self::Bootstrap { message },
            E::Closed => Self::Closed,
        }
    }
}

/// One hop: where to connect and as whom.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshHostSpec {
    /// Host name or address.
    pub host: String,
    #[uniffi(default = 22)]
    pub port: u16,
    pub user: String,
    /// Name host keys are stored under instead of `host` (`HostKeyAlias`).
    #[uniffi(default = None)]
    pub host_key_alias: Option<String>,
}

impl From<ssh::HostSpec> for SshHostSpec {
    fn from(host_spec: ssh::HostSpec) -> Self {
        Self {
            host: host_spec.host,
            port: host_spec.port,
            user: host_spec.user,
            host_key_alias: host_spec.host_key_alias,
        }
    }
}

impl From<SshHostSpec> for ssh::HostSpec {
    fn from(ssh_host_spec: SshHostSpec) -> Self {
        Self {
            host: ssh_host_spec.host,
            port: ssh_host_spec.port,
            user: ssh_host_spec.user,
            host_key_alias: ssh_host_spec.host_key_alias,
        }
    }
}

/// A route: jump hosts (outermost first, `ProxyJump`) then the destination.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshTarget {
    /// Jump hosts, outermost first.
    #[uniffi(default = [])]
    pub jumps: Vec<SshHostSpec>,
    pub host: SshHostSpec,
}

impl From<ssh::Target> for SshTarget {
    fn from(target: ssh::Target) -> Self {
        Self {
            jumps: target.jumps.into_iter().map(Into::into).collect(),
            host: target.host.into(),
        }
    }
}

impl From<SshTarget> for ssh::Target {
    fn from(ssh_target: SshTarget) -> Self {
        Self {
            jumps: ssh_target.jumps.into_iter().map(Into::into).collect(),
            host: ssh_target.host.into(),
        }
    }
}

/// A parsed `[ssh://][user@]host[:port]`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshDestination {
    /// User, if given.
    pub user: Option<String>,
    /// Host, alias or address.
    pub host: String,
    /// Port, if given.
    pub port: Option<u16>,
}

/// Parses what the user typed in the "just ssh" field.
///
/// # Errors
///
/// [`SshError::Config`] if it is not a destination.
#[uniffi::export]
pub fn parse_ssh_destination(text: String) -> Result<SshDestination, SshError> {
    let destination: ssh::Destination = text.parse()?;
    Ok(SshDestination {
        user: destination.user,
        host: destination.host,
        port: destination.port,
    })
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EnvVar {
    pub name: String,
    pub value: String,
}

/// One host's settings after applying every matching ssh_config block.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshHostConfig {
    /// The name looked up.
    pub alias: String,
    /// `HostName` (or the alias).
    pub host_name: String,
    /// `User`.
    pub user: Option<String>,
    /// `Port`.
    pub port: u16,
    /// `IdentityFile`s, expanded (paths on the machine the config came from).
    pub identity_files: Vec<String>,
    /// `ProxyJump` hops as written (`user@host:port`).
    pub proxy_jump: Vec<String>,
    /// `ServerAliveInterval`.
    pub server_alive_interval: Option<Duration>,
    /// `ServerAliveCountMax`.
    pub server_alive_count_max: Option<u32>,
    /// `ConnectTimeout`.
    pub connect_timeout: Option<Duration>,
    /// `HostKeyAlias`.
    pub host_key_alias: Option<String>,
    /// `ForwardAgent` (not supported yet; shown for information).
    pub forward_agent: bool,
    /// `SetEnv`.
    pub set_env: Vec<EnvVar>,
    /// Keywords present but not supported.
    pub ignored: Vec<String>,
    /// `IdentitiesOnly yes`.
    pub identities_only: bool,
    /// `IdentityAgent` socket path, or `none`.
    pub identity_agent: Option<String>,
}

fn destination_text(destination: &ssh::Destination) -> String {
    let host = if destination.host.contains(':') {
        format!("[{}]", destination.host)
    } else {
        destination.host.clone()
    };
    let mut out = match &destination.user {
        Some(user) => format!("{user}@{host}"),
        None => host,
    };
    if let Some(port) = destination.port {
        out.push_str(&format!(":{port}"));
    }
    out
}

impl From<ssh::HostConfig> for SshHostConfig {
    fn from(host_config: ssh::HostConfig) -> Self {
        Self {
            proxy_jump: host_config
                .proxy_jump
                .iter()
                .map(destination_text)
                .collect(),
            alias: host_config.alias,
            host_name: host_config.host_name,
            user: host_config.user,
            port: host_config.port,
            identity_files: host_config.identity_files,
            server_alive_interval: host_config.server_alive_interval,
            server_alive_count_max: host_config.server_alive_count_max,
            connect_timeout: host_config.connect_timeout,
            host_key_alias: host_config.host_key_alias,
            forward_agent: host_config.forward_agent,
            set_env: host_config
                .set_env
                .into_iter()
                .map(|(name, value)| EnvVar { name, value })
                .collect(),
            ignored: host_config.ignored,
            identities_only: host_config.identities_only,
            identity_agent: host_config.identity_agent,
        }
    }
}

/// A parsed `~/.ssh/config` (text the app read or the user pasted; `Include`s are not
/// followed and show up in [`warnings`](Self::warnings)).
#[derive(uniffi::Object)]
pub struct SshConfigFile {
    inner: ssh::SshConfig,
}

#[uniffi::export]
impl SshConfigFile {
    /// Parses config text. `home` is what `~` and `%d` expand to, `local_user` what `%u`
    /// does.
    ///
    /// # Errors
    ///
    /// [`SshError::Config`] for a malformed line.
    #[uniffi::constructor(default(home = None, local_user = None))]
    pub fn parse(
        text: String,
        home: Option<String>,
        local_user: Option<String>,
    ) -> Result<Arc<Self>, SshError> {
        let mut inner = ssh::SshConfig::parse(&text)?;
        if let Some(home) = home {
            inner = inner.with_home(home);
        }
        if let Some(user) = local_user {
            inner = inner.with_local_user(user);
        }
        Ok(Arc::new(Self { inner }))
    }

    /// Concrete aliases on `Host` lines (no wildcards), in file order: hosts to import.
    pub fn host_aliases(&self) -> Vec<String> {
        self.inner.host_aliases()
    }

    /// The settings for `alias`.
    pub fn resolve(&self, alias: String) -> SshHostConfig {
        self.inner.resolve(&alias).into()
    }

    /// The route to `destination` (alias or `user@host:port`), `ProxyJump` chains
    /// expanded; `default_user` when neither the destination nor the config names one.
    ///
    /// # Errors
    ///
    /// [`SshError::Config`] for a bad destination or a `ProxyJump` loop.
    pub fn target(&self, destination: String, default_user: String) -> Result<SshTarget, SshError> {
        Ok(self.inner.target(&destination, &default_user)?.into())
    }

    /// The route to `destination` with `proxy_jump` (`-J` syntax, `none`, or `nil` for the
    /// config's own) and the `IdentityFile`s each jump host names.
    ///
    /// # Errors
    ///
    /// [`SshError::Config`] for a bad destination or hop, or a `ProxyJump` loop.
    #[uniffi::method(default(proxy_jump = None))]
    pub fn route(
        &self,
        destination: String,
        default_user: String,
        proxy_jump: Option<String>,
    ) -> Result<SshRoute, SshError> {
        let route = self
            .inner
            .route(&destination, proxy_jump.as_deref(), &default_user)?;
        Ok(SshRoute {
            target: route.target.into(),
            jump_identity_files: route.jump_identity_files,
        })
    }

    /// Problems found while parsing (unfollowed includes).
    pub fn warnings(&self) -> Vec<String> {
        self.inner.warnings().to_vec()
    }
}

#[uniffi::export]
impl SshConfigFile {
    /// Reads a config file from disk, following `Include`s relative to `home/.ssh`
    /// (macOS). A missing file is an empty config.
    ///
    /// # Errors
    ///
    /// [`SshError::Io`] if it exists but cannot be read, [`SshError::Config`] for a
    /// malformed line.
    #[uniffi::constructor(default(local_user = None))]
    pub fn load(
        path: String,
        home: String,
        local_user: Option<String>,
    ) -> Result<Arc<Self>, SshError> {
        let mut inner = if std::path::Path::new(&path).exists() {
            ssh::SshConfig::load(&path, Some(home.into()))?
        } else {
            ssh::SshConfig::default().with_home(home)
        };
        if let Some(user) = local_user {
            inner = inner.with_local_user(user);
        }
        Ok(Arc::new(Self { inner }))
    }
}

/// A route and what its jump hosts sign in with.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshRoute {
    pub target: SshTarget,
    /// `IdentityFile`s per jump host, in the order of `target.jumps`.
    pub jump_identity_files: Vec<Vec<String>>,
}

/// A host field's text: alias, `user@host:port`, `ssh://…` or a pasted `ssh …` command.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshHostInput {
    pub user: Option<String>,
    /// Host, address or ssh_config alias.
    pub host: String,
    pub port: Option<u16>,
    /// `-i`.
    pub identity_file: Option<String>,
    /// `-J`, as written.
    pub proxy_jump: Option<String>,
}

/// Parses a host field.
///
/// # Errors
///
/// [`SshError::Config`] if it names no host or a port is not a number.
#[uniffi::export]
pub fn parse_ssh_host_input(text: String) -> Result<SshHostInput, SshError> {
    let input = ssh::HostInput::parse(&text)?;
    Ok(SshHostInput {
        user: input.user,
        host: input.host,
        port: input.port,
        identity_file: input.identity_file,
        proxy_jump: input.proxy_jump,
    })
}

/// A public key as a key picker shows it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshPublicKeyInfo {
    /// OpenSSH line, comment included.
    pub public_key: String,
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `sk-ssh-ed25519@openssh.com`, …
    pub algorithm: String,
    pub comment: String,
    /// `SHA256:…`.
    pub fingerprint: String,
}

impl From<ssh::PublicKeyInfo> for SshPublicKeyInfo {
    fn from(info: ssh::PublicKeyInfo) -> Self {
        Self {
            public_key: info.public_key,
            algorithm: info.algorithm,
            comment: info.comment,
            fingerprint: info.fingerprint,
        }
    }
}

/// Reads an OpenSSH public key line.
///
/// # Errors
///
/// [`SshError::Key`] if it is not one.
#[uniffi::export]
pub fn parse_ssh_public_key(line: String) -> Result<SshPublicKeyInfo, SshError> {
    Ok(ssh::PublicKeyInfo::parse(&line)?.into())
}

/// A key pair on disk (`name` with `name.pub`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshLocalKey {
    /// The private key file.
    pub path: String,
    pub info: SshPublicKeyInfo,
    /// Needs a passphrase.
    pub encrypted: bool,
}

/// The key pairs in `directory` (`~/.ssh`), by file name. Private keys stay where they are.
#[uniffi::export]
pub fn list_local_ssh_keys(directory: String) -> Vec<SshLocalKey> {
    ssh::local_keys(std::path::Path::new(&directory))
        .into_iter()
        .map(|key| SshLocalKey {
            path: key.path.display().to_string(),
            info: key.info.into(),
            encrypted: key.encrypted,
        })
        .collect()
}

/// The identities an ssh-agent holds (`nil`: `$SSH_AUTH_SOCK`); empty without an agent.
///
/// # Errors
///
/// [`SshError::Signer`] if the agent's answer is unreadable.
#[uniffi::export(default(socket_path = None))]
pub async fn list_agent_ssh_keys(
    socket_path: Option<String>,
) -> Result<Vec<SshPublicKeyInfo>, SshError> {
    let keys = on_runtime(ssh::agent_keys(socket_path.map(Into::into))).await?;
    Ok(keys.into_iter().map(Into::into).collect())
}

/// A host named in plain text in known_hosts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshKnownHostName {
    pub host: String,
    pub port: u16,
}

/// The concrete hosts in known_hosts text (hashed entries and patterns skipped).
#[uniffi::export]
pub fn known_ssh_host_names(text: String) -> Vec<SshKnownHostName> {
    ssh::known_host_names(&text)
        .into_iter()
        .map(|name| SshKnownHostName {
            host: name.host,
            port: name.port,
        })
        .collect()
}

/// Key types generated in software.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SshKeyType {
    Ed25519,
    /// For servers that accept nothing newer; takes seconds.
    Rsa4096,
}

/// Generates a key pair, its private key encrypted with `passphrase` if one is given.
///
/// # Errors
///
/// [`SshError::Key`] if the random source or encoder fails.
#[uniffi::export(default(passphrase = None))]
pub fn generate_ssh_key(
    key_type: SshKeyType,
    comment: String,
    passphrase: Option<String>,
) -> Result<GeneratedSshKey, SshError> {
    let key_type = match key_type {
        SshKeyType::Ed25519 => ssh::KeyType::Ed25519,
        SshKeyType::Rsa4096 => ssh::KeyType::Rsa4096,
    };
    let key = ssh::generate_key(key_type, &comment, passphrase.as_deref())?;
    Ok(GeneratedSshKey {
        private_key: key.private_key.into_bytes().into(),
        public_key: key.public_key,
        fingerprint: key.fingerprint,
    })
}

/// The shell command that adds `public_key` to `~/.ssh/authorized_keys` once (run it
/// with [`SshSession::exec`]).
///
/// # Errors
///
/// [`SshError::Key`] if `public_key` is not one public key line.
#[uniffi::export]
pub fn ssh_authorize_key_command(public_key: String) -> Result<String, SshError> {
    Ok(ssh::authorize_key_command(&public_key)?)
}

/// A new key pair for the Keychain. `Debug` leaves the private key out.
#[derive(Clone, uniffi::Record)]
pub struct GeneratedSshKey {
    /// The unencrypted OpenSSH private key (PEM text as bytes); store it in the Keychain and
    /// pass it back as [`SshAuth::KeyData`].
    pub private_key: Bytes,
    /// `ssh-ed25519 AAAA… comment`, for `authorized_keys`.
    pub public_key: String,
    /// `SHA256:…`.
    pub fingerprint: String,
}

impl std::fmt::Debug for GeneratedSshKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GeneratedSshKey")
            .field("private_key", &"<redacted>")
            .field("public_key", &self.public_key)
            .field("fingerprint", &self.fingerprint)
            .finish()
    }
}

/// Generates an Ed25519 key pair.
///
/// # Errors
///
/// [`SshError::Key`] if the random source or encoder fails.
#[uniffi::export]
pub fn generate_ed25519_key(comment: String) -> Result<GeneratedSshKey, SshError> {
    let key = ssh::generate_ed25519(&comment)?;
    Ok(GeneratedSshKey {
        private_key: key.private_key.into_bytes().into(),
        public_key: key.public_key,
        fingerprint: key.fingerprint,
    })
}

/// What a private key is.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshKeyInfo {
    /// e.g. `ssh-ed25519`.
    pub algorithm: String,
    /// OpenSSH public key line.
    pub public_key: String,
    /// `SHA256:…`.
    pub fingerprint: String,
}

fn decode_key(pem: &[u8], passphrase: Option<&str>) -> Result<ssh::SecretKey, SshError> {
    let pem = std::str::from_utf8(pem).map_err(|_| SshError::Key {
        message: "not a PEM text key".into(),
    })?;
    Ok(ssh::SecretKey::decode(pem, passphrase)?)
}

/// Decodes a private key (OpenSSH, PKCS#8, PKCS#1, SEC1 PEM) to show or import it.
///
/// # Errors
///
/// [`SshError::KeyEncrypted`] if it needs a passphrase, [`SshError::Key`] if it cannot be
/// decoded or the passphrase is wrong.
#[uniffi::export(default(passphrase = None))]
pub fn inspect_private_key(pem: Bytes, passphrase: Option<String>) -> Result<SshKeyInfo, SshError> {
    let key = decode_key(&pem, passphrase.as_deref())?;
    Ok(SshKeyInfo {
        algorithm: key.algorithm(),
        public_key: key.public_key(),
        fingerprint: key.fingerprint(),
    })
}

/// Whether a private key PEM is passphrase-protected.
#[uniffi::export]
pub fn private_key_is_encrypted(pem: Bytes) -> bool {
    std::str::from_utf8(&pem).is_ok_and(ssh::SecretKey::is_encrypted)
}

/// Why a [`SshSigner`] could not sign.
#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum SignerError {
    /// The user cancelled (Face ID dismissed).
    #[error("cancelled")]
    Cancelled,
    /// Anything else (key missing, Secure Enclave error).
    #[error("{message}")]
    Failed { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for SignerError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed {
            message: error.reason,
        }
    }
}

/// A key whose private half the app holds (Secure Enclave P-256); implemented in Swift.
///
/// Called on a Rust blocking-pool thread during authentication, so `sign` may wait for
/// Face ID.
#[uniffi::export(foreign)]
pub trait SshSigner: Send + Sync {
    /// The public key, OpenSSH format (`ecdsa-sha2-nistp256 AAAA…`).
    fn public_key(&self) -> String;

    /// Signs `data`: for ECDSA P-256, `r ‖ s` (CryptoKit's `rawRepresentation`) or DER of
    /// a SHA-256 signature, as `P256.Signing.PrivateKey.signature(for:)` makes; for Ed25519
    /// the 64-byte signature.
    fn sign(&self, data: Bytes) -> Result<Bytes, SignerError>;

    /// For a FIDO2 security key (`sk-…` public key): a CTAP2 assertion with `rpId` = the
    /// key's application (`ssh:`) and `clientDataHash` = SHA-256 of `data`. Other signers
    /// throw.
    fn sign_security_key(&self, data: Bytes) -> Result<SecurityKeyAssertion, SignerError>;
}

/// A security key's answer to one assertion.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SecurityKeyAssertion {
    /// ECDSA `r ‖ s` or DER, or the 64-byte Ed25519 signature.
    pub signature: Bytes,
    /// Authenticator data flags (byte 32 of authenticatorData).
    pub flags: u8,
    /// Signature counter (bytes 33-36 of authenticatorData, big-endian).
    pub counter: u32,
}

struct SignerAdapter(Arc<dyn SshSigner>);

impl ssh::ExternalSigner for SignerAdapter {
    fn public_key(&self) -> String {
        self.0.public_key()
    }

    fn sign(&self, data: Vec<u8>) -> Result<Vec<u8>, ssh::SignerError> {
        self.0
            .sign(data.into())
            .map(Into::into)
            .map_err(|e| ssh::SignerError(e.to_string()))
    }

    fn sign_security_key(
        &self,
        data: Vec<u8>,
    ) -> Result<ssh::SecurityKeySignature, ssh::SignerError> {
        self.0
            .sign_security_key(data.into())
            .map(|assertion| ssh::SecurityKeySignature {
                signature: assertion.signature.into(),
                flags: assertion.flags,
                counter: assertion.counter,
            })
            .map_err(|e| ssh::SignerError(e.to_string()))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct InteractivePrompt {
    /// The prompt, e.g. `Verification code: `.
    pub prompt: String,
    /// Whether the answer may be shown while typing.
    pub echo: bool,
}

/// Answers keyboard-interactive challenges (2FA codes); implemented in Swift. Called on a
/// Rust blocking-pool thread, so it may wait for the user.
#[uniffi::export(foreign)]
pub trait SshInteractiveResponder: Send + Sync {
    /// One answer per prompt, or `nil` to give up on this method.
    fn respond(
        &self,
        name: String,
        instructions: String,
        prompts: Vec<InteractivePrompt>,
    ) -> Option<Vec<String>>;
}

struct ResponderAdapter(Arc<dyn SshInteractiveResponder>);

impl ssh::InteractiveResponder for ResponderAdapter {
    fn respond(
        &self,
        name: String,
        instructions: String,
        prompts: Vec<ssh::InteractivePrompt>,
    ) -> Option<Vec<String>> {
        let prompts = prompts
            .into_iter()
            .map(|prompt| InteractivePrompt {
                prompt: prompt.prompt,
                echo: prompt.echo,
            })
            .collect();
        self.0.respond(name, instructions, prompts)
    }
}

/// A way to authenticate, tried in the order given on every hop.
#[derive(Clone, uniffi::Enum)]
pub enum SshAuth {
    /// A password (then keyboard-interactive answering password prompts with it).
    Password { password: String },
    /// A private key file (desktop; on iOS keys live in the Keychain, use `KeyData`).
    KeyFile {
        path: String,
        /// Passphrase if encrypted.
        passphrase: Option<String>,
    },
    /// A private key PEM, e.g. from the Keychain.
    KeyData {
        /// PEM text bytes.
        pem: Bytes,
        /// Passphrase if encrypted.
        passphrase: Option<String>,
    },
    /// A key held by the app (Secure Enclave).
    Signer { signer: Arc<dyn SshSigner> },
    /// Every identity of an ssh-agent (`nil`: `$SSH_AUTH_SOCK`). macOS only.
    Agent { socket_path: Option<String> },
    /// One ssh-agent identity, by `SHA256:` fingerprint; the agent's other keys are not
    /// offered. macOS only.
    AgentKey {
        socket_path: Option<String>,
        fingerprint: String,
    },
    /// Keyboard-interactive with arbitrary prompts.
    Interactive {
        /// Answers the prompts.
        responder: Arc<dyn SshInteractiveResponder>,
    },
}

fn credentials(auth: Vec<SshAuth>) -> Result<ssh::Credentials, SshError> {
    let mut creds = ssh::Credentials::new();
    for method in auth {
        creds = creds.with(match method {
            SshAuth::Password { password } => ssh::AuthMethod::Password(password),
            SshAuth::KeyFile { path, passphrase } => {
                ssh::AuthMethod::Key(ssh::SecretKey::load(&path, passphrase.as_deref())?)
            }
            SshAuth::KeyData { pem, passphrase } => {
                ssh::AuthMethod::Key(decode_key(&pem, passphrase.as_deref())?)
            }
            SshAuth::Signer { signer } => {
                ssh::AuthMethod::External(Arc::new(SignerAdapter(signer)))
            }
            SshAuth::Agent { socket_path } => ssh::AuthMethod::Agent(socket_path.map(Into::into)),
            SshAuth::AgentKey {
                socket_path,
                fingerprint,
            } => ssh::AuthMethod::AgentKey {
                socket: socket_path.map(Into::into),
                fingerprint,
            },
            SshAuth::Interactive { responder } => {
                ssh::AuthMethod::Interactive(Arc::new(ResponderAdapter(responder)))
            }
        });
    }
    Ok(creds)
}

/// A host key as shown to the user.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostKeyInfo {
    /// The name it is stored under: `host`, or `[host]:port`.
    pub host: String,
    /// Key type, e.g. `ssh-ed25519`.
    pub algorithm: String,
    /// `SHA256:…`.
    pub fingerprint: String,
    /// OpenSSH public key, for pinning.
    pub public_key: String,
}

impl From<ssh::HostKeyInfo> for HostKeyInfo {
    fn from(host_key_info: ssh::HostKeyInfo) -> Self {
        Self {
            host: host_key_info.host,
            algorithm: host_key_info.algorithm,
            fingerprint: host_key_info.fingerprint,
            public_key: host_key_info.public_key,
        }
    }
}

/// Decides about host keys that are not on record; implemented in Swift.
///
/// Called on a Rust blocking-pool thread after the key exchange and before any credential
/// is sent, so it may wait for the user (an inline "Trust / Cancel" banner).
#[uniffi::export(foreign)]
pub trait HostKeyDelegate: Send + Sync {
    /// First connection to this host: `true` trusts and records the key.
    fn trust_new_host(&self, key: HostKeyInfo) -> bool;

    /// The host's key changed (`expected`: fingerprints on record). `true` replaces the
    /// recorded key; `false` fails with [`SshError::HostKeyMismatch`]. Never asked for
    /// pinned keys.
    fn trust_changed_host(&self, key: HostKeyInfo, expected: Vec<String>) -> bool;
}

struct PromptAdapter(Arc<dyn HostKeyDelegate>);

impl ssh::HostKeyPrompt for PromptAdapter {
    fn trust_new_host(&self, key: ssh::HostKeyInfo) -> bool {
        self.0.trust_new_host(key.into())
    }

    fn trust_changed_host(&self, key: ssh::HostKeyInfo, expected: Vec<String>) -> bool {
        self.0.trust_changed_host(key.into(), expected)
    }
}

/// What to do with a host whose key is not on record.
#[derive(Clone, uniffi::Enum)]
pub enum HostKeyPolicy {
    /// Refuse (`StrictHostKeyChecking yes`).
    Strict,
    /// Record and continue (`accept-new`).
    AcceptNew,
    /// Ask the delegate (new hosts and changed keys).
    Ask { delegate: Arc<dyn HostKeyDelegate> },
}

impl From<HostKeyPolicy> for ssh::HostKeyPolicy {
    fn from(host_key_policy: HostKeyPolicy) -> Self {
        match host_key_policy {
            HostKeyPolicy::Strict => Self::Strict,
            HostKeyPolicy::AcceptNew => Self::AcceptNew,
            HostKeyPolicy::Ask { delegate } => Self::Ask(Arc::new(PromptAdapter(delegate))),
        }
    }
}

/// Persists a [`KnownHostsStore`]; implemented in Swift (Keychain, file). Called on the
/// thread that changed the store (a Rust runtime thread during connects); return quickly.
#[uniffi::export(foreign)]
pub trait KnownHostsListener: Send + Sync {
    /// The store changed; `text` is its whole known_hosts text.
    fn changed(&self, text: String);
}

struct KnownHostsAdapter(Arc<dyn KnownHostsListener>);

impl ssh::KnownHostsListener for KnownHostsAdapter {
    fn changed(&self, text: String) {
        self.0.changed(text);
    }
}

/// The result of looking a key up.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum HostKeyStatus {
    /// On record.
    Trusted,
    /// Nothing on record for the host.
    Unknown,
    /// Other keys on record (their fingerprints).
    Mismatch {
        /// Fingerprints on record.
        expected: Vec<String>,
    },
    /// Marked `@revoked`.
    Revoked,
}

fn public_key(text: &str) -> Result<ssh::PublicKey, SshError> {
    ssh::PublicKey::from_openssh(text.trim()).map_err(|e| SshError::Key {
        message: e.to_string(),
    })
}

/// OpenSSH known_hosts kept in memory; the app owns persistence (load the text, save it
/// from the listener). Share one store across sessions.
#[derive(uniffi::Object)]
pub struct KnownHostsStore {
    inner: Arc<ssh::KnownHosts>,
}

#[uniffi::export]
impl KnownHostsStore {
    /// A store holding `text` (OpenSSH known_hosts lines; unparsable lines are skipped),
    /// reporting every change to `listener`.
    #[uniffi::constructor(default(text = "", listener = None))]
    pub fn new(text: String, listener: Option<Arc<dyn KnownHostsListener>>) -> Arc<Self> {
        let mut store = ssh::KnownHosts::from_text(&text);
        if let Some(listener) = listener {
            store = store.with_listener(Arc::new(KnownHostsAdapter(listener)));
        }
        Arc::new(Self {
            inner: Arc::new(store),
        })
    }

    /// The store as known_hosts text.
    pub fn to_text(&self) -> String {
        self.inner.to_text()
    }

    /// Looks `public_key` (OpenSSH format) up for `host:port`.
    ///
    /// # Errors
    ///
    /// [`SshError::Key`] for an unparsable key.
    pub fn check(
        &self,
        host: String,
        port: u16,
        public_key: String,
    ) -> Result<HostKeyStatus, SshError> {
        Ok(
            match self
                .inner
                .check(&host, port, &self::public_key(&public_key)?)
            {
                ssh::HostKeyStatus::Trusted => HostKeyStatus::Trusted,
                ssh::HostKeyStatus::Unknown => HostKeyStatus::Unknown,
                ssh::HostKeyStatus::Mismatch(expected) => HostKeyStatus::Mismatch { expected },
                ssh::HostKeyStatus::Revoked => HostKeyStatus::Revoked,
            },
        )
    }

    /// Records a key for `host:port`.
    ///
    /// # Errors
    ///
    /// [`SshError::Key`] for an unparsable key.
    pub fn add(&self, host: String, port: u16, public_key: String) -> Result<(), SshError> {
        Ok(self
            .inner
            .add(&host, port, &self::public_key(&public_key)?)?)
    }

    /// Pins a key for `host:port`: only pinned keys are accepted from then on, and a
    /// different key is refused without asking (e.g. a key the paired daemon attested).
    ///
    /// # Errors
    ///
    /// [`SshError::Key`] for an unparsable key.
    pub fn pin(&self, host: String, port: u16, public_key: String) -> Result<(), SshError> {
        Ok(self.inner.pin(&host, port, &public_key)?)
    }

    /// Forgets the keys recorded for exactly `host:port`; returns how many were removed.
    ///
    /// # Errors
    ///
    /// Never for an in-memory store.
    pub fn remove(&self, host: String, port: u16) -> Result<u32, SshError> {
        let removed = self.inner.remove(&host, port)?;
        Ok(u32::try_from(removed).unwrap_or(u32::MAX))
    }
}

/// Connection tuning (docs/SSH.md §2). Every field defaults to the documented value, so
/// `SshOptions()` in Swift is the normal choice.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SshOptions {
    /// Keepalive interval in milliseconds (`ServerAliveInterval`).
    #[uniffi(default = 15000)]
    pub keepalive_interval_ms: u64,
    /// Missed keepalives that declare the peer dead (`ServerAliveCountMax`).
    #[uniffi(default = 3)]
    pub keepalive_count_max: u32,
    /// Deadline for a fast probe (foreground, network change, typing after silence), ms.
    #[uniffi(default = 5000)]
    pub probe_timeout_ms: u64,
    /// TCP connect timeout per hop, ms.
    #[uniffi(default = 10000)]
    pub connect_timeout_ms: u64,
    /// Key exchange timeout per hop, ms.
    #[uniffi(default = 15000)]
    pub handshake_timeout_ms: u64,
    /// Authentication timeout per hop (host-key prompts excluded), ms.
    #[uniffi(default = 60000)]
    pub auth_timeout_ms: u64,
    /// Ask for zlib compression (slow links).
    #[uniffi(default = false)]
    pub compression: bool,
    /// In the background, go offline after this many failed redials (`nil`: never). In
    /// the foreground a session never gives up.
    #[uniffi(default = Some(3))]
    pub background_attempts: Option<u32>,
}

impl Default for SshOptions {
    fn default() -> Self {
        let millis = |d: Duration| u64::try_from(d.as_millis()).unwrap_or(u64::MAX);
        let keepalive = ssh::Keepalive::default();
        let timeouts = ssh::Timeouts::default();
        Self {
            keepalive_interval_ms: millis(keepalive.interval),
            keepalive_count_max: keepalive.count_max,
            probe_timeout_ms: millis(keepalive.probe_timeout),
            connect_timeout_ms: millis(timeouts.connect),
            handshake_timeout_ms: millis(timeouts.handshake),
            auth_timeout_ms: millis(timeouts.auth),
            compression: false,
            background_attempts: ssh::ReconnectPolicy::default().background_attempts,
        }
    }
}

/// The documented defaults (for code that builds options field by field).
#[uniffi::export]
pub fn default_ssh_options() -> SshOptions {
    SshOptions::default()
}

fn connect_options(
    auth: Vec<SshAuth>,
    jump_auth: Vec<Vec<SshAuth>>,
    known_hosts: &KnownHostsStore,
    host_keys: HostKeyPolicy,
    options: &SshOptions,
) -> Result<ssh::ConnectOptions, SshError> {
    let mut connect = ssh::ConnectOptions::new(
        credentials(auth)?,
        Arc::clone(&known_hosts.inner),
        host_keys.into(),
    );
    connect.jump_credentials = jump_auth
        .into_iter()
        .map(credentials)
        .collect::<Result<_, _>>()?;
    connect.keepalive = ssh::Keepalive {
        interval: Duration::from_millis(options.keepalive_interval_ms),
        count_max: options.keepalive_count_max,
        probe_timeout: Duration::from_millis(options.probe_timeout_ms),
    };
    connect.timeouts = ssh::Timeouts {
        connect: Duration::from_millis(options.connect_timeout_ms),
        handshake: Duration::from_millis(options.handshake_timeout_ms),
        auth: Duration::from_millis(options.auth_timeout_ms),
    };
    connect.compression = options.compression;
    Ok(connect)
}

/// Dials `target` once, signs in and hangs up: "Test Connection" before saving a host.
/// Host-key prompts and pinning work as for a session. Returns how long it took, ms.
///
/// # Errors
///
/// The first failure, unretried: unreachable, timeout, host key, authentication.
#[uniffi::export(default(jump_auth = []))]
pub async fn test_ssh_connection(
    target: SshTarget,
    auth: Vec<SshAuth>,
    known_hosts: Arc<KnownHostsStore>,
    host_keys: HostKeyPolicy,
    options: SshOptions,
    jump_auth: Vec<Vec<SshAuth>>,
) -> Result<u64, SshError> {
    let connect = connect_options(auth, jump_auth, &known_hosts, host_keys, &options)?;
    let target: ssh::Target = target.into();
    on_runtime(async move {
        let started = std::time::Instant::now();
        let connection = ssh::Connection::connect(&target, &connect).await?;
        let elapsed = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        connection.disconnect().await;
        Ok(elapsed)
    })
    .await
}

/// Where an [`SshSession`] is.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum SshConnectionState {
    /// Dialling.
    Connecting {
        /// Attempt since the last success.
        attempt: u32,
    },
    /// Authenticated and answering keepalives.
    Connected {
        /// A change means channels were lost.
        generation: u64,
    },
    /// The next attempt is scheduled.
    Reconnecting {
        /// Failed attempts since the last success.
        attempt: u32,
        /// Delay before the next attempt.
        retry_in: Duration,
        /// Why the last connection or attempt failed.
        reason: String,
    },
    /// Background with the attempt budget spent; waits for foreground, a network change
    /// or `reconnect_now`.
    Offline {
        /// The last failure.
        reason: String,
    },
    /// Needs the user (credentials, host key); not retried until `reconnect_now`.
    NeedsAttention {
        error: SshError,
    },
    Closed,
}

impl From<ssh::ConnectionState> for SshConnectionState {
    fn from(connection_state: ssh::ConnectionState) -> Self {
        use ssh::ConnectionState as S;
        match connection_state {
            S::Connecting { attempt } => Self::Connecting { attempt },
            S::Connected { generation } => Self::Connected { generation },
            S::Reconnecting {
                attempt,
                retry_in,
                reason,
            } => Self::Reconnecting {
                attempt,
                retry_in,
                reason,
            },
            S::Offline { reason } => Self::Offline { reason },
            S::NeedsAttention { error } => Self::NeedsAttention {
                error: error.into(),
            },
            S::Closed => Self::Closed,
        }
    }
}

/// Receives [`SshConnectionState`] changes; implemented in Swift. Called on a Rust runtime
/// thread, in order; return quickly.
#[uniffi::export(foreign)]
pub trait SshSessionListener: Send + Sync {
    fn on_state(&self, state: SshConnectionState);
}

struct SessionAdapter(Arc<dyn SshSessionListener>);

impl ssh::SessionListener for SessionAdapter {
    fn on_state(&self, state: ssh::ConnectionState) {
        self.0.on_state(state.into());
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SshExecOutput {
    pub stdout: Bytes,
    pub stderr: Bytes,
    pub exit_status: Option<u32>,
    /// Signal name, if killed.
    pub exit_signal: Option<String>,
}

/// A daemon build for one platform. Gzip data (the app bundles `.gz` builds) is detected by
/// its magic bytes and inflated before upload.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum HostdBinary {
    /// A file (e.g. in the app bundle).
    File { path: String },
    Data {
        /// The binary or its gzip.
        data: Bytes,
    },
}

fn inflate_if_gzip(data: Vec<u8>) -> Result<Vec<u8>, SshError> {
    if !data.starts_with(&[0x1f, 0x8b]) {
        return Ok(data);
    }
    let mut out = Vec::with_capacity(data.len() * 3);
    flate2::read::GzDecoder::new(data.as_slice())
        .read_to_end(&mut out)
        .map_err(|e| SshError::Bootstrap {
            message: format!("inflating the daemon build: {e}"),
        })?;
    Ok(out)
}

impl HostdBinary {
    fn load(self) -> Result<ssh::BinarySource, SshError> {
        let data = match self {
            Self::File { path } => {
                std::fs::read(&path).map_err(|e| SshError::io(format!("reading {path}: {e}")))?
            }
            Self::Data { data } => data.0,
        };
        Ok(ssh::BinarySource::Bytes(Arc::new(inflate_if_gzip(data)?)))
    }
}

/// The daemon builds the app carries, per platform.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct HostdBinaries {
    /// `aarch64-unknown-linux-musl`.
    #[uniffi(default = None)]
    pub linux_aarch64: Option<HostdBinary>,
    /// `x86_64-unknown-linux-musl`.
    #[uniffi(default = None)]
    pub linux_x86_64: Option<HostdBinary>,
    /// `aarch64-apple-darwin`.
    #[uniffi(default = None)]
    pub macos_aarch64: Option<HostdBinary>,
    /// `x86_64-apple-darwin`.
    #[uniffi(default = None)]
    pub macos_x86_64: Option<HostdBinary>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum BootstrapStep {
    /// Detecting the platform and any existing install.
    Probing,
    /// Uploading (`size` bytes of binary, `sent` on the wire so far).
    Uploading {
        size: u64,
        /// Compressed bytes sent.
        sent: u64,
    },
    /// Installing and starting the service.
    Starting,
    /// Waiting for the daemon and minting a ticket.
    Pairing,
}

/// Receives [`BootstrapStep`]s; implemented in Swift. Called on a Rust runtime thread.
#[uniffi::export(foreign)]
pub trait BootstrapListener: Send + Sync {
    fn on_step(&self, step: BootstrapStep);
}

struct BootstrapAdapter(Arc<dyn BootstrapListener>);

impl ssh::BootstrapListener for BootstrapAdapter {
    fn on_step(&self, step: ssh::BootstrapStep) {
        self.0.on_step(match step {
            ssh::BootstrapStep::Probing => BootstrapStep::Probing,
            ssh::BootstrapStep::Uploading { size, sent } => BootstrapStep::Uploading { size, sent },
            ssh::BootstrapStep::Starting => BootstrapStep::Starting,
            ssh::BootstrapStep::Pairing => BootstrapStep::Pairing,
        });
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HostPlatform {
    LinuxAarch64,
    LinuxX86_64,
    MacosAarch64,
    MacosX86_64,
}

/// What happened to the binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum InstallAction {
    /// Fresh install.
    Installed,
    /// Another build was replaced.
    Upgraded,
    /// The same build was kept.
    Reused,
    /// The host's helper is newer than the app's and was kept.
    KeptNewer,
}

/// How the daemon runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ServiceMode {
    /// systemd `--user` / launchd.
    Service,
    /// Detached (no service manager); gone after a reboot.
    Detached,
    /// Already running, left alone.
    AlreadyRunning,
}

/// The outcome of [`SshSession::bootstrap`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BootstrapReport {
    pub platform: HostPlatform,
    /// What happened to the binary.
    pub action: InstallAction,
    /// How the daemon runs.
    pub service: ServiceMode,
    /// Install path on the host.
    pub install_path: String,
    /// SHA-256 of the installed binary, hex.
    pub sha256: String,
    /// `gudo://pair/…`, for [`DaemonClient::connect`](crate::DaemonClient::connect).
    pub ticket: String,
    /// The daemon's endpoint id, hex.
    pub daemon_id: String,
    /// Things worth telling the user.
    pub notes: Vec<String>,
}

impl From<ssh::BootstrapReport> for BootstrapReport {
    fn from(bootstrap_report: ssh::BootstrapReport) -> Self {
        Self {
            platform: match bootstrap_report.platform {
                ssh::HostPlatform::LinuxAarch64 => HostPlatform::LinuxAarch64,
                ssh::HostPlatform::LinuxX86_64 => HostPlatform::LinuxX86_64,
                ssh::HostPlatform::MacosAarch64 => HostPlatform::MacosAarch64,
                ssh::HostPlatform::MacosX86_64 => HostPlatform::MacosX86_64,
            },
            action: match bootstrap_report.action {
                ssh::InstallAction::Installed => InstallAction::Installed,
                ssh::InstallAction::Upgraded => InstallAction::Upgraded,
                ssh::InstallAction::Reused => InstallAction::Reused,
                ssh::InstallAction::KeptNewer => InstallAction::KeptNewer,
            },
            service: match bootstrap_report.service {
                ssh::ServiceMode::Service => ServiceMode::Service,
                ssh::ServiceMode::Detached => ServiceMode::Detached,
                ssh::ServiceMode::AlreadyRunning => ServiceMode::AlreadyRunning,
            },
            install_path: bootstrap_report.install_path,
            sha256: bootstrap_report.sha256,
            ticket: bootstrap_report.ticket,
            daemon_id: bootstrap_report.daemon_id,
            notes: bootstrap_report.notes,
        }
    }
}

/// Settings for an [`SshPane`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct SshPaneOptions {
    /// The id its events carry; pick one that cannot clash with daemon panes.
    pub pane_id: u64,
    pub size: PaneSize,
    /// `TERM` on the remote side.
    #[uniffi(default = "xterm-256color")]
    pub term: String,
    /// Environment to request (servers accept only their `AcceptEnv` names).
    #[uniffi(default = [])]
    pub env: Vec<EnvVar>,
    /// A command instead of the login shell.
    #[uniffi(default = None)]
    pub command: Option<String>,
    /// Run inside `tmux new -A -s <name>` when tmux exists, so reconnects re-attach.
    #[uniffi(default = None)]
    pub tmux_session: Option<String>,
}

/// A self-healing SSH connection to one host (through any jump hosts): redials with
/// backoff when the connection dies and never gives up in the foreground. Panes, commands
/// and bootstraps share it. Releasing the last reference closes it.
///
/// Methods return at once; the `async` ones run on the core runtime and may be awaited
/// from any Swift context.
#[derive(uniffi::Object)]
pub struct SshSession {
    inner: ssh::Session,
}

#[uniffi::export]
impl SshSession {
    /// Starts connecting to `target` in the background. `auth` is tried in order on every
    /// hop; host keys are checked against `known_hosts` under `host_keys`.
    ///
    /// # Errors
    ///
    /// [`SshError::Key`] / [`SshError::KeyEncrypted`] if a key in `auth` cannot be decoded
    /// (nothing is dialled then). Connection problems arrive as states.
    #[uniffi::constructor(default(listener = None, jump_auth = []))]
    pub fn start(
        target: SshTarget,
        auth: Vec<SshAuth>,
        known_hosts: Arc<KnownHostsStore>,
        host_keys: HostKeyPolicy,
        options: SshOptions,
        listener: Option<Arc<dyn SshSessionListener>>,
        jump_auth: Vec<Vec<SshAuth>>,
    ) -> Result<Arc<Self>, SshError> {
        let connect = connect_options(auth, jump_auth, &known_hosts, host_keys, &options)?;
        let policy = ssh::ReconnectPolicy {
            background_attempts: options.background_attempts,
            ..ssh::ReconnectPolicy::default()
        };
        let listener =
            listener.map(|l| Arc::new(SessionAdapter(l)) as Arc<dyn ssh::SessionListener>);
        let inner =
            ssh::Session::start_on(runtime().handle(), target.into(), connect, policy, listener);
        Ok(Arc::new(Self { inner }))
    }

    pub fn target(&self) -> SshTarget {
        self.inner.target().clone().into()
    }

    pub fn state(&self) -> SshConnectionState {
        self.inner.state().into()
    }

    /// Foreground (`true`) probes the connection at once and cuts any backoff short;
    /// background limits redials (see [`SshOptions::background_attempts`]).
    pub fn set_foreground(&self, foreground: bool) {
        self.inner.set_foreground(foreground);
    }

    /// The network path changed: probe now, or redial now.
    pub fn network_changed(&self) {
        self.inner.network_changed();
    }

    /// Drops the connection and dials again now; also retries after `NeedsAttention`
    /// (e.g. once the user fixed the password or accepted a key).
    pub fn reconnect_now(&self) {
        self.inner.reconnect_now();
    }

    /// Closes the session for good.
    pub fn close(&self) {
        self.inner.close();
    }

    /// Round trip of the last keepalive.
    pub fn rtt(&self) -> Option<Duration> {
        self.inner.connection()?.rtt()
    }

    /// Waits until connected.
    ///
    /// # Errors
    ///
    /// The error that needs the user, or [`SshError::Closed`].
    pub async fn connected(&self) -> Result<(), SshError> {
        let session = self.inner.clone();
        on_runtime(async move { session.connected().await.map(drop) })
            .await
            .map_err(Into::into)
    }

    /// Runs a command (waiting for a connection first) and collects its output.
    ///
    /// # Errors
    ///
    /// Connection errors; a non-zero exit is not an error (see `exit_status`).
    pub async fn exec(&self, command: String) -> Result<SshExecOutput, SshError> {
        let session = self.inner.clone();
        let out =
            on_runtime(async move { session.connected().await?.exec(&command).await }).await?;
        Ok(SshExecOutput {
            stdout: out.stdout.into(),
            stderr: out.stderr.into(),
            exit_status: out.exit_status,
            exit_signal: out.exit_signal,
        })
    }

    /// Installs (or reuses) the daemon on the host, makes sure it runs, and returns a
    /// fresh pairing ticket (docs/SSH.md §3). Progress goes to `listener`.
    ///
    /// # Errors
    ///
    /// [`SshError::Bootstrap`] for an unsupported platform or a missing build,
    /// [`SshError::ChecksumMismatch`], [`SshError::Remote`], connection errors.
    #[uniffi::method(default(ticket_minutes = None, wait_secs = None, listener = None))]
    pub async fn bootstrap(
        &self,
        binaries: HostdBinaries,
        ticket_minutes: Option<u32>,
        wait_secs: Option<u32>,
        listener: Option<Arc<dyn BootstrapListener>>,
    ) -> Result<BootstrapReport, SshError> {
        let session = self.inner.clone();
        on_runtime(async move {
            // Reading and inflating ~20 MB is blocking work.
            let binaries = tokio::task::spawn_blocking(move || -> Result<_, SshError> {
                let load = |b: Option<HostdBinary>| b.map(HostdBinary::load).transpose();
                Ok(ssh::HostdBinaries {
                    linux_aarch64: load(binaries.linux_aarch64)?,
                    linux_x86_64: load(binaries.linux_x86_64)?,
                    macos_aarch64: load(binaries.macos_aarch64)?,
                    macos_x86_64: load(binaries.macos_x86_64)?,
                })
            })
            .await
            .map_err(|e| SshError::Bootstrap {
                message: e.to_string(),
            })??;
            let options = ssh::BootstrapOptions {
                ticket_minutes,
                wait_secs,
                listener: listener
                    .map(|l| Arc::new(BootstrapAdapter(l)) as Arc<dyn ssh::BootstrapListener>),
                ..ssh::BootstrapOptions::default()
            };
            let conn = session.connected().await?;
            Ok(ssh::bootstrap(&conn, &binaries, &options).await?.into())
        })
        .await
    }

    /// Opens a plain-SSH terminal pane on this session (one channel per pane). It emits the
    /// same [`ClientEvent`](crate::ClientEvent)s as daemon panes to `listener`: `Connected`,
    /// `PaneBytes` as one gap-free stream, `PaneResized`, `Disconnected`, `Refused`,
    /// `PaneClosed`. After a drop it opens a new shell (or re-attaches tmux).
    pub fn open_pane(
        self: Arc<Self>,
        options: SshPaneOptions,
        listener: Arc<dyn ClientEventListener>,
    ) -> Arc<SshPane> {
        let mut pane =
            client_core::SshPaneOptions::new(PaneId(options.pane_id), options.size.into());
        pane.term = options.term;
        pane.env = options
            .env
            .into_iter()
            .map(|var| (var.name, var.value))
            .collect();
        pane.command = options.command;
        pane.tmux_session = options.tmux_session;
        let _guard = runtime().enter();
        let inner =
            client_core::SshPane::open(self.inner.clone(), pane, Arc::new(Forward(listener)));
        Arc::new(SshPane {
            inner,
            _session: self,
        })
    }
}

impl Drop for SshSession {
    fn drop(&mut self) {
        // The session's supervisor task holds its own reference, so it has to be told.
        self.inner.close();
    }
}

/// A terminal over plain SSH. Releasing the last reference closes the remote shell. It
/// keeps its [`SshSession`] alive.
#[derive(uniffi::Object)]
pub struct SshPane {
    inner: client_core::SshPane,
    _session: Arc<SshSession>,
}

#[uniffi::export]
impl SshPane {
    /// The id its events carry.
    pub fn pane_id(&self) -> u64 {
        self.inner.pane_id().0
    }

    /// Sends keystrokes or paste (dropped while disconnected).
    pub fn send_input(&self, data: &[u8]) {
        self.inner.send_input(data.to_vec());
    }

    /// Resizes the remote PTY; `PaneResized` marks the point in the stream.
    pub fn resize(&self, size: PaneSize) {
        self.inner.resize(size.into());
    }

    /// Closes the remote shell; `PaneClosed` follows.
    pub fn close(&self) {
        self.inner.close();
    }
}
