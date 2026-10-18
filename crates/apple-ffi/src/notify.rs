//! Push notifications (module `notify`, to keep the `push` crate name free), app side (docs/PUSH.md): the device's sealing key, the relay
//! registration body, registering with each daemon, opening sealed payloads in the
//! Notification Service Extension, and answering an approval from the lock screen.

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
    Json {
        /// Why.
        message: String,
    },
    /// Too large to seal.
    #[error("payload too large ({size} bytes)")]
    TooLarge {
        /// Sealed size.
        size: u64,
    },
    /// Expired.
    #[error("expired")]
    Expired,
}

impl From<client_core::push::PushError> for PushError {
    fn from(e: client_core::push::PushError) -> Self {
        use client_core::push::PushError as E;
        match e {
            E::Malformed => Self::Malformed,
            E::Open(_) => Self::Open,
            E::Signature => Self::Signature,
            E::Json(e) => Self::Json {
                message: e.to_string(),
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
    Client {
        /// Why.
        message: String,
    },
    /// The action token is not base64url.
    #[error("bad action token")]
    Token,
    /// The host could not be reached in time.
    #[error("cannot reach the host: {message}")]
    Unreachable {
        /// Why.
        message: String,
    },
    /// The host refused the connection (the device was unpaired).
    #[error("refused: {reason}")]
    Refused {
        /// Why.
        reason: String,
    },
    /// The host refused the decision (expired, already decided, no longer waiting).
    #[error("rejected: {message}")]
    Rejected {
        /// Why.
        message: String,
    },
}

impl From<client_core::push::ActionError> for PushActionError {
    fn from(e: client_core::push::ActionError) -> Self {
        use client_core::push::ActionError as E;
        match e {
            E::Client(e) => Self::Client {
                message: e.to_string(),
            },
            E::Token => Self::Token,
            E::Unreachable(message) => Self::Unreachable { message },
            E::Refused(reason) => Self::Refused {
                reason: format!("{reason:?}"),
            },
            E::Rejected(e) => Self::Rejected {
                message: e.to_string(),
            },
        }
    }
}

/// The device's X25519 sealing key pair (one per device; keep the secret in the Keychain
/// group shared with the NSE, `AfterFirstUnlock`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushSealKey {
    /// 32-byte secret (for `open_push_notification`).
    pub secret: Bytes,
    /// 32-byte public key (for `PushRegistration.seal_key`).
    pub public_key: Bytes,
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
    /// The agents Live Activity (`PushRegistration.activity_cap`).
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

/// The decision an approval notification offers.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushActionOffer {
    /// The action token, base64url; `push_action_token` decodes it for `send_push_action`.
    pub token: String,
    /// Approve label.
    pub approve: String,
    /// Deny label.
    pub deny: String,
    /// Expiry, Unix ms.
    pub expires_ms: u64,
}

/// A decrypted, signature-checked notification. The caller must still check `daemon` is a
/// paired host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushNotification {
    /// The daemon's key, hex.
    pub daemon: String,
    /// The host's name.
    pub host: String,
    /// What happened.
    pub kind: PushKind,
    /// `UNNotificationCategory` identifier for `kind`.
    pub category: String,
    /// Attention item id (mark seen with `attention_seen`).
    pub item: u64,
    /// The pane.
    pub pane: u64,
    /// Its session.
    pub session: Option<u64>,
    /// Title.
    pub title: String,
    /// Body.
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
    let n = client_core::push::open_notification(&key32(&device_secret)?, &sealed)?;
    let kind = match n.kind {
        client_core::push::Kind::Approval => PushKind::Approval,
        client_core::push::Kind::Blocked => PushKind::Blocked,
        client_core::push::Kind::Done => PushKind::Done,
        client_core::push::Kind::Failed => PushKind::Failed,
        client_core::push::Kind::Command => PushKind::Command,
    };
    Ok(PushNotification {
        category: n.kind.category().apns_category().to_owned(),
        daemon: n.daemon,
        host: n.host,
        kind,
        item: n.item,
        pane: n.pane,
        session: n.session,
        title: n.title,
        body: n.body,
        at_ms: n.at,
        action: n.action.map(|a| PushActionOffer {
            token: a.token,
            approve: a.approve,
            deny: a.deny,
            expires_ms: a.expires,
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
    /// Approve.
    Approve,
    /// Deny.
    Deny,
}

fn decision(d: PushDecision) -> client_core::push::Decision {
    match d {
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
        self.ws_call(|c| async move { c.push_register(reg).await })
            .await
    }

    /// Stops pushes from this daemon to this device.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn push_unregister(&self) -> Result<PushStatus, WorkspaceError> {
        self.ws_call(|c| async move { c.push_unregister().await })
            .await
    }

    /// The daemon's push settings and this device's registration.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn push_status(&self) -> Result<PushStatus, WorkspaceError> {
        self.ws_call(|c| async move { c.push_status().await }).await
    }
}
