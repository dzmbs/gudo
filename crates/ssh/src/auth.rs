//! Authentication methods and the order they are tried in.

use std::path::PathBuf;
use std::sync::Arc;

use russh::MethodKind;
use russh::client::{Handle, KeyboardInteractiveAuthResponse};
use russh::keys::agent::client::AgentClient;
use russh::keys::{Algorithm, PrivateKeyWithHashAlg, PublicKey};
use russh::{MethodSet, client::AuthResult};

use crate::SshError;
use crate::client::ClientHandler;
use crate::keys::{ExternalSigner, ExternalSignerAdapter, SecretKey};
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
    /// A decoded private key.
    Key(SecretKey),
    /// A key held by the app (Secure Enclave P-256).
    External(Arc<dyn ExternalSigner>),
    /// A password: `password` auth, then keyboard-interactive answering password prompts
    /// with it (macOS and PAM setups often allow only the latter).
    Password(String),
    /// Keyboard-interactive with arbitrary prompts.
    Interactive(Arc<dyn InteractiveResponder>),
}

impl AuthMethod {
    fn label(&self) -> &'static str {
        match self {
            Self::Agent(_) => "agent",
            Self::Key(_) => "publickey",
            Self::External(_) => "external-key",
            Self::Password(_) => "password",
            Self::Interactive(_) => "keyboard-interactive",
        }
    }

    fn allowed_by(&self, methods: &MethodSet) -> bool {
        let has = |k: MethodKind| methods.contains(&k);
        match self {
            Self::Agent(_) | Self::Key(_) | Self::External(_) => has(MethodKind::PublicKey),
            Self::Password(_) => has(MethodKind::Password) || has(MethodKind::KeyboardInteractive),
            Self::Interactive(_) => has(MethodKind::KeyboardInteractive),
        }
    }
}

impl std::fmt::Debug for AuthMethod {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Key(k) => write!(f, "Key({})", k.fingerprint()),
            Self::Agent(p) => write!(f, "Agent({p:?})"),
            other => f.write_str(other.label()),
        }
    }
}

/// The authentication methods to try, in order, for every hop of a route.
#[derive(Debug, Clone, Default)]
pub struct Credentials {
    /// Methods in order.
    pub methods: Vec<AuthMethod>,
}

impl Credentials {
    /// No methods.
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds a method.
    #[must_use]
    pub fn with(mut self, method: AuthMethod) -> Self {
        self.methods.push(method);
        self
    }

    /// The OpenSSH-like default on a desktop: the agent if `$SSH_AUTH_SOCK` is set, then
    /// each readable unencrypted key among `identity_files` (from ssh_config) and
    /// `~/.ssh/id_{ed25519,ecdsa,rsa}`.
    pub fn openssh_defaults(identity_files: &[String]) -> Self {
        let mut creds = Self::new();
        if std::env::var_os("SSH_AUTH_SOCK").is_some() {
            creds.methods.push(AuthMethod::Agent(None));
        }
        let mut files: Vec<PathBuf> = identity_files.iter().map(PathBuf::from).collect();
        if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
            for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
                files.push(home.join(".ssh").join(name));
            }
        }
        for file in files {
            if let Ok(key) = SecretKey::load(&file, None) {
                creds.methods.push(AuthMethod::Key(key));
            }
        }
        creds
    }
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
        if allowed.as_ref().is_some_and(|a| !method.allowed_by(a)) {
            continue;
        }
        if !tried.contains(&method.label()) {
            tried.push(method.label());
        }
        let result = match method {
            AuthMethod::Key(key) => {
                let hash = rsa_hash(handle, key.0.algorithm()).await?;
                handle
                    .authenticate_publickey(user, PrivateKeyWithHashAlg::new(key.0.clone(), hash))
                    .await?
            }
            AuthMethod::Agent(path) => match agent_auth(handle, user, path.as_ref()).await? {
                Some(r) => r,
                None => continue,
            },
            AuthMethod::External(signer) => {
                let public = PublicKey::from_openssh(signer.public_key().trim())
                    .map_err(|e| SshError::Signer(format!("bad public key: {e}")))?;
                let mut adapter = ExternalSignerAdapter {
                    signer: Arc::clone(signer),
                    algorithm: public.algorithm(),
                };
                match handle
                    .authenticate_publickey_with(user, public, None, &mut adapter)
                    .await
                {
                    Ok(r) => r,
                    // A failing signer (cancelled Face ID) fails this method, not the login.
                    Err(SshError::Signer(e)) => {
                        tracing::info!("external signer failed: {e}");
                        continue;
                    }
                    Err(e) => return Err(e),
                }
            }
            AuthMethod::Password(password) => {
                let allows_password = allowed
                    .as_ref()
                    .is_none_or(|a| a.contains(&MethodKind::Password));
                let mut result = None;
                if allows_password {
                    let r = handle
                        .authenticate_password(user, password.as_str())
                        .await?;
                    if let AuthResult::Failure {
                        remaining_methods, ..
                    } = &r
                    {
                        allowed = Some(remaining_methods.clone());
                    }
                    result = Some(r);
                }
                let kbd = allowed
                    .as_ref()
                    .is_some_and(|a| a.contains(&MethodKind::KeyboardInteractive));
                if result.as_ref().is_none_or(|r| !r.success()) && kbd {
                    let password = password.clone();
                    let answered = interactive(handle, user, move |_, _, prompts| {
                        // Only answer what looks like a password prompt; anything else
                        // (an OTP) needs a real responder.
                        prompts
                            .iter()
                            .all(|p| !p.echo && p.prompt.to_ascii_lowercase().contains("password"))
                            .then(|| vec![password.clone(); prompts.len()])
                    })
                    .await?;
                    if answered.is_some() {
                        result = answered;
                    }
                }
                match result {
                    Some(r) => r,
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
                    Some(r) => r,
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
            |a| a.iter().map(<&str>::from).collect::<Vec<_>>().join(", "),
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
) -> Result<Option<AuthResult>, SshError> {
    let path = match path {
        Some(p) => p.clone(),
        None => match std::env::var_os("SSH_AUTH_SOCK") {
            Some(p) => PathBuf::from(p),
            None => return Ok(None),
        },
    };
    let mut agent = match AgentClient::connect_uds(&path).await {
        Ok(agent) => agent,
        Err(e) => {
            tracing::info!("ssh-agent at {} unavailable: {e}", path.display());
            return Ok(None);
        }
    };
    let identities = agent
        .request_identities()
        .await
        .map_err(|e| SshError::Signer(format!("ssh-agent: {e}")))?;
    let mut last = None;
    for identity in identities {
        let key = identity.public_key().into_owned();
        let hash = rsa_hash(handle, key.algorithm()).await?;
        let r = handle
            .authenticate_publickey_with(user, key, hash, &mut agent)
            .await
            .map_err(|e| SshError::Signer(format!("ssh-agent: {e}")))?;
        if r.success() {
            return Ok(Some(r));
        }
        last = Some(r);
    }
    Ok(last)
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
                    .map(|p| InteractivePrompt {
                        prompt: p.prompt,
                        echo: p.echo,
                    })
                    .collect();
                let answers = if prompts.is_empty() {
                    Some(Vec::new())
                } else {
                    let respond = Arc::clone(&respond);
                    tokio::task::spawn_blocking(move || respond(name, instructions, prompts))
                        .await
                        .map_err(|e| SshError::Protocol(e.to_string()))?
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
