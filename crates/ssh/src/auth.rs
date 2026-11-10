//! Authentication methods and the order they are tried in.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use russh::MethodKind;
use russh::client::{Handle, KeyboardInteractiveAuthResponse};
use russh::keys::agent::client::AgentClient;
use russh::keys::{Algorithm, PrivateKeyWithHashAlg, PublicKey};
use russh::{MethodSet, client::AuthResult};

use crate::SshError;
use crate::client::ClientHandler;
use crate::keys::{EncryptedKey, ExternalSigner, ExternalSignerAdapter, SecretKey};
use crate::target::HostSpec;

/// One keyboard-interactive prompt from the server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InteractivePrompt {
    /// The prompt text, e.g. `Verification code: `.
    pub prompt: String,
    /// Whether the answer may be shown while typing.
    pub echo: bool,
}

/// Answers keyboard-interactive challenges (2FA codes, Tailscale SSH check mode).
///
/// Called on a blocking thread, so it may wait for UI.
pub trait InteractiveResponder: Send + Sync {
    /// Returns one answer per prompt, or `None` to give up on this method.
    fn respond(
        &self,
        name: String,
        instructions: String,
        prompts: Vec<InteractivePrompt>,
    ) -> Option<Vec<String>>;
}

/// A way to prove who the user is. Tried in the order given in [`Credentials`].
#[derive(Clone)]
pub enum AuthMethod {
    /// Every identity in an ssh-agent: the socket at this path, or `$SSH_AUTH_SOCK`
    /// when `None` (skipped if neither exists).
    Agent(Option<PathBuf>),
    /// One identity of an ssh-agent, by `SHA256:` fingerprint: never offers the others,
    /// so an agent holding many keys cannot exhaust the server's `MaxAuthTries`.
    AgentKey {
        socket: Option<PathBuf>,
        fingerprint: String,
    },
    /// A decoded private key.
    Key(SecretKey),
    /// A key held by the app (Secure Enclave P-256).
    External(Arc<dyn ExternalSigner>),
    /// A password: `password` auth, then keyboard-interactive answering password prompts
    /// with it (macOS and PAM setups often allow only the latter).
    Password(String),
    /// Keyboard-interactive with arbitrary prompts.
    Interactive(Arc<dyn InteractiveResponder>),
    /// A passphrase-protected key, decrypted when it is first offered.
    EncryptedKey(EncryptedKey),
}

impl AuthMethod {
    /// A private key from PEM text. An encrypted key with a passphrase is decrypted when it
    /// is first offered, on a blocking thread, so building credentials never waits on its
    /// KDF; a wrong passphrase then fails authentication with [`SshError::Key`].
    ///
    /// # Errors
    ///
    /// [`SshError::KeyEncrypted`] if the key is encrypted and `passphrase` is `None`,
    /// [`SshError::Key`] if it is not a key this client reads.
    pub fn key(pem: &str, passphrase: Option<&str>) -> Result<Self, SshError> {
        match passphrase {
            Some(passphrase) if SecretKey::is_encrypted(pem) => {
                Ok(Self::EncryptedKey(EncryptedKey::new(pem, passphrase)))
            }
            _ => SecretKey::decode(pem, passphrase).map(Self::Key),
        }
    }

    /// As [`key`](Self::key), from a key file.
    ///
    /// # Errors
    ///
    /// As [`key`](Self::key), plus [`SshError::Io`] if the file cannot be read.
    pub fn key_file(path: impl AsRef<Path>, passphrase: Option<&str>) -> Result<Self, SshError> {
        let path = path.as_ref();
        let pem = std::fs::read_to_string(path)
            .map_err(|error| SshError::io(format!("reading {}", path.display()), error))?;
        Self::key(&pem, passphrase)
    }

    fn label(&self) -> &'static str {
        match self {
            Self::Agent(_) | Self::AgentKey { .. } => "agent",
            Self::Key(_) | Self::EncryptedKey(_) => "publickey",
            Self::External(_) => "external-key",
            Self::Password(_) => "password",
            Self::Interactive(_) => "keyboard-interactive",
        }
    }

    fn allowed_by(&self, methods: &MethodSet) -> bool {
        let has = |kind: MethodKind| methods.contains(&kind);
        match self {
            Self::Agent(_)
            | Self::AgentKey { .. }
            | Self::Key(_)
            | Self::EncryptedKey(_)
            | Self::External(_) => has(MethodKind::PublicKey),
            Self::Password(_) => has(MethodKind::Password) || has(MethodKind::KeyboardInteractive),
            Self::Interactive(_) => has(MethodKind::KeyboardInteractive),
        }
    }
}

impl std::fmt::Debug for AuthMethod {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Key(key) => write!(f, "Key({})", key.fingerprint()),
            Self::Agent(socket) => write!(f, "Agent({socket:?})"),
            Self::AgentKey {
                socket,
                fingerprint,
            } => write!(f, "AgentKey({socket:?}, {fingerprint})"),
            other => f.write_str(other.label()),
        }
    }
}

/// The authentication methods to try, in order, for every hop of a route.
#[derive(Debug, Clone, Default)]
pub struct Credentials {
    pub methods: Vec<AuthMethod>,
}

impl Credentials {
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn with(mut self, method: AuthMethod) -> Self {
        self.methods.push(method);
        self
    }

    /// The OpenSSH-like default on a desktop: the agent if `$SSH_AUTH_SOCK` is set, then
    /// each readable unencrypted key among `identity_files` (from ssh_config) and
    /// `~/.ssh/id_{ed25519,ecdsa,rsa}`.
    pub fn openssh_defaults(identity_files: &[String]) -> Self {
        let mut credentials = Self::new();
        if std::env::var_os("SSH_AUTH_SOCK").is_some() {
            credentials.methods.push(AuthMethod::Agent(None));
        }
        let mut files: Vec<PathBuf> = identity_files.iter().map(PathBuf::from).collect();
        if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
            for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
                files.push(home.join(".ssh").join(name));
            }
        }
        for file in files {
            if let Ok(key) = SecretKey::load(&file, None) {
                credentials.methods.push(AuthMethod::Key(key));
            }
        }
        credentials
    }
}

async fn publickey_auth(
    handle: &mut Handle<ClientHandler>,
    user: &str,
    key: &SecretKey,
) -> Result<AuthResult, SshError> {
    let hash = rsa_hash(handle, key.0.algorithm()).await?;
    Ok(handle
        .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::clone(&key.0), hash))
        .await?)
}

/// Runs the methods against one server until one succeeds.
pub(crate) async fn authenticate(
    handle: &mut Handle<ClientHandler>,
    spec: &HostSpec,
    credentials: &Credentials,
) -> Result<(), SshError> {
    let user = spec.user.as_str();
    let mut tried: Vec<&str> = Vec::new();
    let mut allowed: Option<MethodSet> = None;
    for method in &credentials.methods {
        if allowed
            .as_ref()
            .is_some_and(|methods| !method.allowed_by(methods))
        {
            continue;
        }
        if !tried.contains(&method.label()) {
            tried.push(method.label());
        }
        let result = match method {
            AuthMethod::Key(key) => publickey_auth(handle, user, key).await?,
            AuthMethod::EncryptedKey(key) => {
                publickey_auth(handle, user, &key.decrypted().await?).await?
            }
            AuthMethod::Agent(path) => match agent_auth(handle, user, path.as_ref(), None).await? {
                Some(result) => result,
                None => continue,
            },
            AuthMethod::AgentKey {
                socket,
                fingerprint,
            } => match agent_auth(handle, user, socket.as_ref(), Some(fingerprint)).await? {
                Some(result) => result,
                None => continue,
            },
            AuthMethod::External(signer) => {
                let public = PublicKey::from_openssh(signer.public_key().trim())
                    .map_err(|error| SshError::Signer(format!("bad public key: {error}")))?;
                let mut adapter = ExternalSignerAdapter {
                    signer: Arc::clone(signer),
                    algorithm: public.algorithm(),
                };
                match handle
                    .authenticate_publickey_with(user, public, None, &mut adapter)
                    .await
                {
                    Ok(result) => result,
                    // A failing signer (cancelled Face ID) fails this method, not the login.
                    Err(SshError::Signer(error)) => {
                        tracing::info!("external signer failed: {error}");
                        continue;
                    }
                    Err(error) => return Err(error),
                }
            }
            AuthMethod::Password(password) => {
                let allows_password = allowed
                    .as_ref()
                    .is_none_or(|methods| methods.contains(&MethodKind::Password));
                let mut result = None;
                if allows_password {
                    let response = handle
                        .authenticate_password(user, password.as_str())
                        .await?;
                    if let AuthResult::Failure {
                        remaining_methods, ..
                    } = &response
                    {
                        allowed = Some(remaining_methods.clone());
                    }
                    result = Some(response);
                }
                let allows_interactive = allowed
                    .as_ref()
                    .is_some_and(|methods| methods.contains(&MethodKind::KeyboardInteractive));
                if result.as_ref().is_none_or(|result| !result.success()) && allows_interactive {
                    let password = password.clone();
                    let answered = interactive(handle, user, move |_, _, prompts| {
                        // Only answer what looks like a password prompt; anything else
                        // (an OTP) needs a real responder.
                        prompts
                            .iter()
                            .all(|prompt| {
                                !prompt.echo
                                    && prompt.prompt.to_ascii_lowercase().contains("password")
                            })
                            .then(|| vec![password.clone(); prompts.len()])
                    })
                    .await?;
                    if answered.is_some() {
                        result = answered;
                    }
                }
                match result {
                    Some(result) => result,
                    None => continue,
                }
            }
            AuthMethod::Interactive(responder) => {
                let responder = Arc::clone(responder);
                match interactive(handle, user, move |name, instructions, prompts| {
                    responder.respond(name, instructions, prompts)
                })
                .await?
                {
                    Some(result) => result,
                    None => continue,
                }
            }
        };
        match result {
            AuthResult::Success => return Ok(()),
            AuthResult::Failure {
                remaining_methods, ..
            } => allowed = Some(remaining_methods),
        }
    }
    Err(SshError::AuthFailed {
        user: user.to_owned(),
        host: spec.host.clone(),
        tried: if tried.is_empty() {
            "nothing usable".into()
        } else {
            tried.join(", ")
        },
        allowed: allowed.map_or_else(
            || "?".into(),
            |methods| {
                methods
                    .iter()
                    .map(<&str>::from)
                    .collect::<Vec<_>>()
                    .join(", ")
            },
        ),
    })
}

async fn rsa_hash(
    handle: &Handle<ClientHandler>,
    algorithm: Algorithm,
) -> Result<Option<russh::keys::HashAlg>, SshError> {
    if !matches!(algorithm, Algorithm::Rsa { .. }) {
        return Ok(None);
    }
    // `None` from the server (no EXT_INFO) means legacy ssh-rsa (SHA-1).
    Ok(handle.best_supported_rsa_hash().await?.flatten())
}

/// Tries every agent identity. `None` if there is no agent to ask.
async fn agent_auth(
    handle: &mut Handle<ClientHandler>,
    user: &str,
    path: Option<&PathBuf>,
    only_fingerprint: Option<&str>,
) -> Result<Option<AuthResult>, SshError> {
    let path = match path {
        Some(path) => path.clone(),
        None => match std::env::var_os("SSH_AUTH_SOCK") {
            Some(socket) => PathBuf::from(socket),
            None => return Ok(None),
        },
    };
    let mut agent = match AgentClient::connect_uds(&path).await {
        Ok(agent) => agent,
        Err(error) => {
            tracing::info!("ssh-agent at {} unavailable: {error}", path.display());
            return Ok(None);
        }
    };
    let identities = agent
        .request_identities()
        .await
        .map_err(|error| SshError::Signer(format!("ssh-agent: {error}")))?;
    let mut last_result = None;
    for identity in identities {
        let key = identity.public_key().into_owned();
        if only_fingerprint.is_some_and(|wanted| crate::fingerprint(&key) != wanted) {
            continue;
        }
        let hash = rsa_hash(handle, key.algorithm()).await?;
        let result = handle
            .authenticate_publickey_with(user, key, hash, &mut agent)
            .await
            .map_err(|error| SshError::Signer(format!("ssh-agent: {error}")))?;
        if result.success() {
            return Ok(Some(result));
        }
        last_result = Some(result);
    }
    Ok(last_result)
}

/// Runs a keyboard-interactive exchange. `None` when `respond` gave up (the server's
/// method list is then unknown, so it must not narrow later methods).
async fn interactive<F>(
    handle: &mut Handle<ClientHandler>,
    user: &str,
    respond: F,
) -> Result<Option<AuthResult>, SshError>
where
    F: Fn(String, String, Vec<InteractivePrompt>) -> Option<Vec<String>> + Send + Sync + 'static,
{
    let respond = Arc::new(respond);
    let mut reply = handle
        .authenticate_keyboard_interactive_start(user, None)
        .await?;
    // Servers may send several rounds (PAM conversations); cap them.
    for _ in 0..8 {
        match reply {
            KeyboardInteractiveAuthResponse::Success => return Ok(Some(AuthResult::Success)),
            KeyboardInteractiveAuthResponse::Failure {
                remaining_methods,
                partial_success,
            } => {
                return Ok(Some(AuthResult::Failure {
                    remaining_methods,
                    partial_success,
                }));
            }
            KeyboardInteractiveAuthResponse::InfoRequest {
                name,
                instructions,
                prompts,
            } => {
                let prompts: Vec<InteractivePrompt> = prompts
                    .into_iter()
                    .map(|prompt| InteractivePrompt {
                        prompt: prompt.prompt,
                        echo: prompt.echo,
                    })
                    .collect();
                let answers = if prompts.is_empty() {
                    Some(Vec::new())
                } else {
                    let respond = Arc::clone(&respond);
                    tokio::task::spawn_blocking(move || respond(name, instructions, prompts))
                        .await
                        .map_err(|error| SshError::Protocol(error.to_string()))?
                };
                let Some(answers) = answers else {
                    return Ok(None);
                };
                reply = handle
                    .authenticate_keyboard_interactive_respond(answers)
                    .await?;
            }
        }
    }
    Err(SshError::Protocol(
        "too many keyboard-interactive rounds".into(),
    ))
}
