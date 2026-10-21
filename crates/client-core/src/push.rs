//! Push notifications, app side (docs/PUSH.md).
//!
//! 1. The app gets its APNs token, asks the push relay for a capability (`POST
//!    /v1/register`), and registers that opaque capability plus its X25519 sealing key with
//!    each daemon over the normal connection ([`Client::push_register`]).
//! 2. The Notification Service Extension decrypts payloads (Swift `PushCrypto`, or
//!    [`open_notification`] here).
//! 3. A lock-screen Approve / Deny runs [`send_action`]: a short one-shot connection with the
//!    device key from the Keychain, no session, no UI.
//!
//! # Examples
//!
//! ```no_run
//! # fn demo(ticket: &str, key: Vec<u8>, token: Vec<u8>) -> Result<(), client_core::push::ActionError> {
//! use client_core::push::{Decision, send_action_blocking};
//! use client_core::{ClientConfig, ConnectOptions};
//!
//! let decided = send_action_blocking(
//!     ticket,
//!     ClientConfig::new(key),
//!     ConnectOptions::default(),
//!     token,
//!     Decision::Approve,
//!     std::time::Duration::from_secs(8),
//! )?;
//! println!("applied: option {:?}", decided.option_id);
//! # Ok(())
//! # }
//! ```

use std::time::Duration;

use iroh::endpoint::Connection;
use proto::{
    Caps, ClientCtl, Decided, Hello, LinkClass, PushActionRequest, PushActivityToken,
    PushRegistration, PushStatus, ServerCtl, SignedGrant, Ticket, WorkspaceRequest,
    WorkspaceResponse, WsError,
};

pub use push::{ActionOffer, Decision, Kind, Notification, PushError, x25519_keypair};

use crate::conn::{Route, endpoint_builder, recv, send, ticket_addr};
use crate::{Client, ClientConfig, ConnectOptions};

impl Client {
    /// Registers this device for push notifications from this daemon (or updates its
    /// registration). `reg.cap` comes from the push relay; the daemon cannot read it.
    ///
    /// # Errors
    ///
    /// The daemon's [`WsError`] (an invalid key or capability), or [`WsError::Disconnected`].
    pub async fn push_register(&self, reg: PushRegistration) -> Result<PushStatus, WsError> {
        status(self.workspace(WorkspaceRequest::PushRegister(reg)).await?)
    }

    /// Stops pushes from this daemon to this device.
    ///
    /// # Errors
    ///
    /// [`WsError::Disconnected`].
    pub async fn push_unregister(&self) -> Result<PushStatus, WsError> {
        status(self.workspace(WorkspaceRequest::PushUnregister).await?)
    }

    /// The daemon's push settings and this device's registration.
    ///
    /// # Errors
    ///
    /// [`WsError::Disconnected`].
    pub async fn push_status(&self) -> Result<PushStatus, WsError> {
        status(self.workspace(WorkspaceRequest::PushStatus).await?)
    }

    /// Hands the daemon the relay capability of this device's running agents Live Activity
    /// (its ActivityKit update token), or `None` once it ended. The daemon then sends
    /// `update` / `end` pushes to it instead of a push-to-start. Needs a push registration
    /// and a daemon offering [`proto::DaemonFeatures::LIVE_ACTIVITY`].
    ///
    /// # Errors
    ///
    /// [`WsError::NotFound`] without a push registration, [`WsError::Invalid`] for an
    /// oversized capability, [`WsError::Disconnected`].
    pub async fn push_activity(&self, cap: Option<String>) -> Result<PushStatus, WsError> {
        status(
            self.workspace(WorkspaceRequest::PushActivity(PushActivityToken { cap }))
                .await?,
        )
    }
}

fn status(resp: WorkspaceResponse) -> Result<PushStatus, WsError> {
    match resp {
        WorkspaceResponse::Push(s) => Ok(s),
        other => Err(WsError::Failed(format!("unexpected answer {other:?}"))),
    }
}

/// Decrypts a sealed notification with the device's X25519 secret and checks the daemon's
/// signature. The caller must still check `daemon` is a host it paired with.
///
/// # Errors
///
/// [`PushError`] if it does not open or verify.
pub fn open_notification(
    device_secret: &[u8; 32],
    sealed: &str,
) -> Result<Notification, PushError> {
    push::open(device_secret, sealed)?.notification()
}

/// Why a notification action failed.
#[derive(Debug, thiserror::Error)]
pub enum ActionError {
    /// The ticket or key is unusable.
    #[error(transparent)]
    Client(#[from] crate::ClientError),
    /// The token in the notification is not base64url.
    #[error("bad action token")]
    Token,
    /// The daemon could not be reached in time.
    #[error("cannot reach the host: {0}")]
    Unreachable(String),
    /// The daemon refused the connection (the device was unpaired).
    #[error("refused: {0:?}")]
    Refused(proto::RefuseReason),
    /// The daemon refused the decision (expired, already decided, no longer waiting).
    #[error(transparent)]
    Rejected(WsError),
}

/// Decodes the base64url token of an [`ActionOffer`].
///
/// # Errors
///
/// [`ActionError::Token`].
pub fn token_bytes(offer: &ActionOffer) -> Result<Vec<u8>, ActionError> {
    push::unb64(&offer.token).map_err(|_| ActionError::Token)
}

/// Sends a notification's decision to its daemon on a one-shot connection: dial, `Hello` as
/// the paired device, `PushAction` signed with the device key, wait for the answer, close.
/// No session is attached and nothing is streamed, so it fits a notification action's few
/// seconds in the background.
///
/// # Errors
///
/// [`ActionError`].
pub async fn send_action(
    ticket: &str,
    config: ClientConfig,
    options: ConnectOptions,
    token: Vec<u8>,
    decision: Decision,
    timeout: Duration,
) -> Result<Decided, ActionError> {
    let (ticket, extras) = Ticket::parse_with_extras(ticket).map_err(crate::ClientError::from)?;
    let key: [u8; 32] = config
        .secret_key
        .as_slice()
        .try_into()
        .map_err(|_| crate::ClientError::Key)?;
    let sig = push::sign_decision(&key, &token, decision).to_vec();
    let request = PushActionRequest {
        token,
        approve: decision == Decision::Approve,
        sig,
    };
    let unreachable = |e: &dyn std::fmt::Display| ActionError::Unreachable(e.to_string());
    let route = Route::new(config.relay, &extras.relays, &options);
    let endpoint = endpoint_builder(&route, &options)
        .map_err(|e| unreachable(&e))?
        .secret_key(iroh::SecretKey::from_bytes(&key))
        .bind()
        .await
        .map_err(|e| unreachable(&e))?;
    let result = tokio::time::timeout(timeout, async {
        let addr = ticket_addr(&ticket, &route).map_err(|e| unreachable(&e))?;
        let conn = endpoint
            .connect(addr, proto::ALPN)
            .await
            .map_err(|e| unreachable(&e))?;
        let answer = exchange(&conn, &ticket, &key, request).await;
        conn.close(0u32.into(), b"done");
        answer
    })
    .await
    .unwrap_or_else(|_| Err(ActionError::Unreachable("timed out".into())));
    endpoint.close().await;
    result
}

async fn exchange(
    conn: &Connection,
    ticket: &Ticket,
    key: &[u8; 32],
    request: PushActionRequest,
) -> Result<Decided, ActionError> {
    let unreachable = |e: &dyn std::fmt::Display| ActionError::Unreachable(e.to_string());
    let (mut tx, mut rx) = conn.open_bi().await.map_err(|e| unreachable(&e))?;
    let device = iroh::SecretKey::from_bytes(key).public();
    let hello = Hello {
        device_id: proto::DeviceId(*device.as_bytes()),
        principal_id: ticket.principal,
        grant: SignedGrant {
            v: SignedGrant::DEVICE,
            grant_id: proto::GrantId([0; 16]),
            token: Vec::new(),
        },
        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
        resume: Vec::new(),
        caps: Caps::EMPTY,
        link: LinkClass::Constrained,
        resume_token: None,
    };
    send(&mut tx, &ClientCtl::Hello(hello))
        .await
        .map_err(|e| unreachable(&e))?;
    match recv::<ServerCtl>(&mut rx)
        .await
        .map_err(|e| unreachable(&e))?
    {
        Some(ServerCtl::Welcome(_)) => {}
        Some(ServerCtl::Refused { reason }) => return Err(ActionError::Refused(reason)),
        other => return Err(ActionError::Unreachable(format!("unexpected {other:?}"))),
    }
    const REQ: u64 = 1;
    send(
        &mut tx,
        &ClientCtl::Workspace {
            req_id: REQ,
            req: WorkspaceRequest::PushAction(request),
        },
    )
    .await
    .map_err(|e| unreachable(&e))?;
    loop {
        match recv::<ServerCtl>(&mut rx)
            .await
            .map_err(|e| unreachable(&e))?
        {
            Some(ServerCtl::WorkspaceResult { req_id, result }) if req_id == REQ => {
                let _ = send(
                    &mut tx,
                    &ClientCtl::Bye {
                        reason: proto::ByeReason::Quit,
                    },
                )
                .await;
                let _ = tx.finish();
                return match result {
                    Ok(WorkspaceResponse::PushDecided(decided)) => Ok(decided),
                    Ok(other) => Err(ActionError::Rejected(WsError::Failed(format!(
                        "unexpected answer {other:?}"
                    )))),
                    Err(e) => Err(ActionError::Rejected(e)),
                };
            }
            Some(_) => {}
            None => {
                return Err(ActionError::Unreachable(
                    "the host closed the stream".into(),
                ));
            }
        }
    }
}

/// [`send_action`] on a runtime of its own, for callers without one (the FFI's notification
/// action handler).
///
/// # Errors
///
/// [`ActionError`].
pub fn send_action_blocking(
    ticket: &str,
    config: ClientConfig,
    options: ConnectOptions,
    token: Vec<u8>,
    decision: Decision,
    timeout: Duration,
) -> Result<Decided, ActionError> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(crate::ClientError::from)?;
    runtime.block_on(send_action(
        ticket, config, options, token, decision, timeout,
    ))
}
