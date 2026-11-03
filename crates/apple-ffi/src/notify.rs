//! Push notifications, app side (docs/PUSH.md): the device's sealing key, the relay
//! registration body, registering with each daemon, opening sealed payloads in the
//! Notification Service Extension, and answering an approval from the lock screen. The module
//! is `notify` so it does not shadow the `push` crate.

use std::time::Duration;

use client_core::proto;

use crate::bytes::Bytes;
use crate::client::{ClientConfig, ConnectOptions, DaemonClient};
use crate::mp::Decided;
use crate::on_runtime;
use crate::ws_types::{PushRegistration, PushStatus, WorkspaceError};

/// Why push data could not be produced or read.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum PushError {
    /// Not base64url, too short, an unknown version, or a key that is not 32 bytes.
    #[error("malformed push data")]
    Malformed,
    /// Decryption failed: wrong key, or the data was changed.
    #[error("the payload does not open with this key")]
    Open,
    /// The daemon's signature did not verify.
    #[error("bad signature")]
    Signature,
    /// The payload is not the expected JSON.
    #[error("payload: {message}")]
    Json { message: String },
    /// Too large to seal.
    #[error("payload too large ({size} bytes)")]
    TooLarge { size: u64 },
    #[error("expired")]
    Expired,
}

impl From<client_core::push::PushError> for PushError {
    fn from(push_error: client_core::push::PushError) -> Self {
        use client_core::push::PushError as E;
        match push_error {
            E::Malformed => Self::Malformed,
            E::Open(_) => Self::Open,
            E::Signature => Self::Signature,
            E::Json(push_error) => Self::Json {
                message: push_error.to_string(),
            },
            E::TooLarge(size) => Self::TooLarge { size: size as u64 },
            E::Expired => Self::Expired,
        }
    }
}

/// Why a notification action (Approve / Deny) failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum PushActionError {
    /// The ticket or device key is unusable.
    #[error("bad ticket or key: {message}")]
    Client { message: String },
    /// The action token is not base64url.
    #[error("bad action token")]
    Token,
    /// The host could not be reached in time.
    #[error("cannot reach the host: {message}")]
    Unreachable { message: String },
    /// The host refused the connection (the device was unpaired).
    #[error("refused: {reason}")]
    Refused { reason: String },
    /// The host refused the decision (expired, already decided, no longer waiting).
    #[error("rejected: {message}")]
    Rejected { message: String },
}

impl From<client_core::push::ActionError> for PushActionError {
    fn from(action_error: client_core::push::ActionError) -> Self {
        use client_core::push::ActionError as E;
        match action_error {
            E::Client(action_error) => Self::Client {
                message: action_error.to_string(),
            },
            E::Token => Self::Token,
            E::Unreachable(message) => Self::Unreachable { message },
            E::Refused(reason) => Self::Refused {
                reason: format!("{reason:?}"),
            },
            E::Rejected(action_error) => Self::Rejected {
                message: action_error.to_string(),
            },
        }
    }
}

/// The device's X25519 sealing key pair (one per device; keep the secret in the Keychain
/// group shared with the NSE, `AfterFirstUnlock`). `Debug` leaves the secret out.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushSealKey {
    /// 32-byte secret (for `open_push_notification`).
    pub secret: Bytes,
    /// 32-byte public key (for `PushRegistration.seal_key`).
    pub public_key: Bytes,
}

impl std::fmt::Debug for PushSealKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PushSealKey")
            .field("secret", &"<redacted>")
            .field("public_key", &self.public_key)
            .finish()
    }
}

/// A fresh X25519 sealing key pair.
#[uniffi::export]
pub fn generate_push_seal_key() -> PushSealKey {
    let (secret, public) = client_core::push::x25519_keypair();
    PushSealKey {
        secret: secret.to_vec().into(),
        public_key: public.to_vec().into(),
    }
}

fn key32(bytes: &[u8]) -> Result<[u8; 32], PushError> {
    bytes.try_into().map_err(|_| PushError::Malformed)
}

/// The public key of a stored sealing secret.
///
/// # Errors
///
/// [`PushError::Malformed`] unless `secret` is 32 bytes.
#[uniffi::export]
pub fn push_seal_public_key(secret: Bytes) -> Result<Bytes, PushError> {
    Ok(push::hpke::public_key(&key32(&secret)?).to_vec().into())
}

/// The APNs environment of the token.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ApnsEnvironment {
    /// App Store / TestFlight builds.
    Production,
    /// Development builds.
    Sandbox,
}

/// What a relay capability is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PushCapKind {
    /// Notifications (`PushRegistration.cap`).
    Alert,
    /// The agents Live Activity: a push-to-start token (`PushRegistration.activity_cap`) or
    /// a running activity's update token (`DaemonClient::push_activity`).
    Activity,
}

/// The product's push relay (`POST <url>/v1/register` returns `{"cap", "expires"}`).
#[uniffi::export]
pub fn default_push_relay_url() -> String {
    brand::PUSH_RELAY_URL.to_owned()
}

/// The JSON body for `POST <relay>/v1/register`: the APNs token (hex), environment, the
/// daemon it is for (`PairTicketInfo.daemon_id`) and the kind. The response's `cap` goes into
/// [`PushRegistration::cap`] for that daemon.
#[uniffi::export]
pub fn push_relay_register_body(
    apns_token: Bytes,
    environment: ApnsEnvironment,
    daemon_id: String,
    kind: PushCapKind,
) -> String {
    serde_json::json!({
        "token": push::hex(&apns_token),
        "env": match environment {
            ApnsEnvironment::Production => "production",
            ApnsEnvironment::Sandbox => "sandbox",
        },
        "daemon": daemon_id.to_ascii_lowercase(),
        "kind": match kind {
            PushCapKind::Alert => "alert",
            PushCapKind::Activity => "activity",
        },
    })
    .to_string()
}

/// What a notification is about (the NSE picks the category from this, never the relay's).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PushKind {
    /// Approve / Deny / Open (`AGENT_APPROVAL`).
    Approval,
    /// Open (`AGENT_BLOCKED`).
    Blocked,
    /// `AGENT_DONE`.
    Done,
    /// `AGENT_DONE`.
    Failed,
    /// `COMMAND_DONE`.
    Command,
}

/// The decision an approval notification offers. `Debug` leaves the token out.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushActionOffer {
    /// The action token, base64url; `push_action_token` decodes it for `send_push_action`.
    pub token: String,
    pub approve: String,
    pub deny: String,
    /// Expiry, Unix ms.
    pub expires_ms: u64,
}

impl std::fmt::Debug for PushActionOffer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PushActionOffer")
            .field("token", &"<redacted>")
            .field("approve", &self.approve)
            .field("deny", &self.deny)
            .field("expires_ms", &self.expires_ms)
            .finish()
    }
}

/// A decrypted, signature-checked notification. The caller must still check `daemon` is a
/// paired host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushNotification {
    /// The daemon's key, hex.
    pub daemon: String,
    pub host: String,
    pub kind: PushKind,
    /// `UNNotificationCategory` identifier for `kind`.
    pub category: String,
    /// Attention item id (mark seen with `attention_seen`).
    pub item: u64,
    pub pane: u64,
    pub session: Option<u64>,
    pub title: String,
    pub body: String,
    /// When, Unix ms.
    pub at_ms: u64,
    /// Approve / Deny, for approvals.
    pub action: Option<PushActionOffer>,
}

/// Decrypts a sealed payload with the device's sealing secret and checks the daemon's
/// signature (the Rust twin of PushCrypto, for the NSE).
///
/// # Errors
///
/// [`PushError`] if it does not open or verify.
#[uniffi::export]
pub fn open_push_notification(
    device_secret: Bytes,
    sealed: String,
) -> Result<PushNotification, PushError> {
    let notification = client_core::push::open_notification(&key32(&device_secret)?, &sealed)?;
    let kind = match notification.kind {
        client_core::push::Kind::Approval => PushKind::Approval,
        client_core::push::Kind::Blocked => PushKind::Blocked,
        client_core::push::Kind::Done => PushKind::Done,
        client_core::push::Kind::Failed => PushKind::Failed,
        client_core::push::Kind::Command => PushKind::Command,
    };
    Ok(PushNotification {
        category: notification.kind.category().apns_category().to_owned(),
        daemon: notification.daemon,
        host: notification.host,
        kind,
        item: notification.item,
        pane: notification.pane,
        session: notification.session,
        title: notification.title,
        body: notification.body,
        at_ms: notification.at,
        action: notification.action.map(|action| PushActionOffer {
            token: action.token,
            approve: action.approve,
            deny: action.deny,
            expires_ms: action.expires,
        }),
    })
}

/// Decodes an action offer's base64url token.
///
/// # Errors
///
/// [`PushError::Malformed`].
#[uniffi::export]
pub fn push_action_token(token: String) -> Result<Bytes, PushError> {
    Ok(push::unb64(&token)?.into())
}

/// The lock-screen answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PushDecision {
    Approve,
    Deny,
}

fn decision(answer: PushDecision) -> client_core::push::Decision {
    match answer {
        PushDecision::Approve => client_core::push::Decision::Approve,
        PushDecision::Deny => client_core::push::Decision::Deny,
    }
}

/// Sends a notification's decision on a one-shot connection (dial, `Hello` as the paired
/// device, `PushAction` signed with the device key, wait, close). No session, no UI: for the
/// notification action handler.
///
/// # Errors
///
/// [`PushActionError`].
#[uniffi::export]
pub async fn send_push_action(
    ticket: String,
    config: ClientConfig,
    options: ConnectOptions,
    token: Bytes,
    decision: PushDecision,
    timeout_ms: u64,
) -> Result<Decided, PushActionError> {
    let decision = self::decision(decision);
    on_runtime(async move {
        client_core::push::send_action(
            &ticket,
            config.into(),
            options.into(),
            token.into(),
            decision,
            Duration::from_millis(timeout_ms),
        )
        .await
    })
    .await
    .map(Into::into)
    .map_err(Into::into)
}

/// [`send_push_action`], blocking the calling thread (for a handler that cannot await).
/// Never call it on the main thread.
///
/// # Errors
///
/// [`PushActionError`].
#[uniffi::export]
pub fn send_push_action_blocking(
    ticket: String,
    config: ClientConfig,
    options: ConnectOptions,
    token: Bytes,
    decision: PushDecision,
    timeout_ms: u64,
) -> Result<Decided, PushActionError> {
    client_core::push::send_action_blocking(
        &ticket,
        config.into(),
        options.into(),
        token.into(),
        self::decision(decision),
        Duration::from_millis(timeout_ms),
    )
    .map(Into::into)
    .map_err(Into::into)
}

#[uniffi::export]
impl DaemonClient {
    /// Registers this device for pushes from this daemon (or updates it). Re-register on
    /// launch, when the APNs token changes and before the capability expires.
    ///
    /// # Errors
    ///
    /// `Invalid` for a key that is not 32 bytes; the daemon's [`WorkspaceError`].
    pub async fn push_register(
        &self,
        registration: PushRegistration,
    ) -> Result<PushStatus, WorkspaceError> {
        let seal_key: [u8; 32] =
            registration
                .seal_key
                .as_ref()
                .try_into()
                .map_err(|_| WorkspaceError::Invalid {
                    message: "the sealing key must be 32 bytes".into(),
                })?;
        let reg = proto::PushRegistration {
            cap: registration.cap,
            seal_key,
            relay_url: registration.relay_url,
            prefs: registration.prefs.into(),
            activity_cap: registration.activity_cap,
        };
        self.ws_call(|client| async move { client.push_register(reg).await })
            .await
    }

    /// Stops pushes from this daemon to this device.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn push_unregister(&self) -> Result<PushStatus, WorkspaceError> {
        self.ws_call(|client| async move { client.push_unregister().await })
            .await
    }

    /// The daemon's push settings and this device's registration.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn push_status(&self) -> Result<PushStatus, WorkspaceError> {
        self.ws_call(|client| async move { client.push_status().await })
            .await
    }

    /// The relay capability of this device's running agents Live Activity (its update
    /// token), or `None` once it ended or was dismissed: the daemon sends `update` / `end`
    /// pushes to it. Only for daemons that [`offers_live_activity`](Self::offers_live_activity).
    ///
    /// # Errors
    ///
    /// `NotFound` without a push registration; the daemon's other [`WorkspaceError`]s.
    pub async fn push_activity(&self, cap: Option<String>) -> Result<PushStatus, WorkspaceError> {
        self.ws_call(|client| async move { client.push_activity(cap).await })
            .await
    }

    /// Which agents this device wants pushed, after [`push_register`](Self::push_register).
    /// Only for daemons that [`offers_push_agents`](Self::offers_push_agents).
    ///
    /// # Errors
    ///
    /// `NotFound` without a push registration; the daemon's other [`WorkspaceError`]s.
    pub async fn push_agents(
        &self,
        rules: Vec<crate::ws_types::PushAgentRule>,
    ) -> Result<PushStatus, WorkspaceError> {
        let rules = rules.into_iter().map(Into::into).collect();
        self.ws_call(|client| async move { client.push_agents(rules).await })
            .await
    }

    /// Whether the daemon answers [`push_agents`](Self::push_agents).
    pub fn offers_push_agents(&self) -> bool {
        self.inner
            .daemon_info()
            .is_some_and(|i| i.features.contains(proto::DaemonFeatures::PUSH_AGENTS))
    }

    /// Whether the daemon sends the agents Live Activity and answers
    /// [`push_activity`](Self::push_activity).
    pub fn offers_live_activity(&self) -> bool {
        self.inner
            .daemon_info()
            .is_some_and(|i| i.features.contains(proto::DaemonFeatures::LIVE_ACTIVITY))
    }
}
