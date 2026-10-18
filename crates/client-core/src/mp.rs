//! presence, prompts through the composer path, revocation and the audit log.
//!
//! Join a daemon with an invite through [`Client::join`]; the paired-device path
//! ([`Client::connect`]) is unchanged. Requests are `async` like the workspace API. Pushes —
//! who is connected, leases, someone asking for control, refusals, decisions — go to a
//! [`MultiplayerListener`] set with [`Client::set_multiplayer_listener`], separate from
//! [`ClientListener`](crate::ClientListener) so existing event handling is unaffected.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use grants::{DeviceKey, GrantSpec};
use proto::{
    Actor, AuditPage, AuditQuery, Decided, DeviceInfo, GrantChain, GrantInfo, InputRejectReason,
    Invite, JoinInfo, Lease, LeaseOutcome, MpError, MpRequest, MpResponse, PaneId, Participant,
    Presence, PresenceState, PrincipalId, RequestId, RevokeTarget, ServerCtl, UnixMillis,
};
use tokio::sync::{mpsc, oneshot};

use crate::{Client, Inner, lock};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// A multiplayer push from the daemon.
#[derive(Debug, Clone)]
pub enum MultiplayerEvent {
    /// Who this connection is (after every handshake).
    Joined {
        /// Identity, roles, scope.
        info: JoinInfo,
    },
    /// Everyone connected (the whole list).
    Participants {
        /// One entry per device.
        participants: Vec<Participant>,
    },
    /// Another participant's presence (typing, cursor, focus).
    Presence {
        /// The update.
        presence: Presence,
    },
    /// A pane's control lease changed.
    Lease {
        /// The lease.
        lease: Lease,
    },
    /// Someone asks for a lease this principal holds; answer with
    /// [`Client::answer_control`].
    LeaseRequested {
        /// The pane.
        pane_id: PaneId,
        /// Who asks.
        by: Actor,
        /// Their name.
        name: String,
    },
    /// Input was refused (no lease, role, scope).
    InputRejected {
        /// The pane.
        pane_id: PaneId,
        /// Why.
        reason: InputRejectReason,
    },
    /// A ctl message was refused by policy.
    Forbidden {
        /// What.
        what: String,
        /// Why.
        reason: String,
    },
    /// An approval was decided (by anyone).
    Decided {
        /// The decision.
        decided: Decided,
    },
    /// This client's decision lost to an earlier one.
    AlreadyDecided {
        /// The request.
        request_id: RequestId,
        /// Who won.
        by: Actor,
    },
    /// This connection's grant was revoked; the daemon closes it.
    Revoked,
}

/// Receives [`MultiplayerEvent`]s. Must return quickly; it runs on the network threads.
pub trait MultiplayerListener: Send + Sync {
    /// Called once per event, in order.
    fn on_multiplayer_event(&self, event: MultiplayerEvent);
}

/// A [`MultiplayerListener`] that queues events for async Rust consumers (`un`, tests).
pub struct MultiplayerEventQueue {
    tx: mpsc::UnboundedSender<MultiplayerEvent>,
}

impl MultiplayerEventQueue {
    /// Returns the listener and the receiving end.
    pub fn channel() -> (
        Arc<dyn MultiplayerListener>,
        mpsc::UnboundedReceiver<MultiplayerEvent>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl MultiplayerListener for MultiplayerEventQueue {
    fn on_multiplayer_event(&self, event: MultiplayerEvent) {
        let _ = self.tx.send(event);
    }
}

/// Multiplayer state kept by the client.
#[derive(Default)]
pub(crate) struct MpState {
    pending: Mutex<HashMap<u64, oneshot::Sender<Result<MpResponse, MpError>>>>,
    listener: Mutex<Option<Arc<dyn MultiplayerListener>>>,
    me: Mutex<Option<JoinInfo>>,
    participants: Mutex<Vec<Participant>>,
    leases: Mutex<HashMap<PaneId, Lease>>,
    /// The invite this client joined with (guests).
    pub(crate) invite: Option<Invite>,
}

impl MpState {
    pub(crate) fn with_invite(invite: Option<Invite>) -> Self {
        Self {
            invite,
            ..Self::default()
        }
    }

    /// Handles a multiplayer message from `ctl`; returns it back if it is not one (or if the
    /// connection loop must see it too).
    pub(crate) fn dispatch(&self, msg: ServerCtl) -> Option<ServerCtl> {
        let (event, pass) = match msg {
            ServerCtl::MultiplayerResult { req_id, result } => {
                if let Some(tx) = lock(&self.pending).remove(&req_id) {
                    let _ = tx.send(result);
                }
                return None;
            }
            ServerCtl::Joined(info) => {
                *lock(&self.me) = Some(info.clone());
                (MultiplayerEvent::Joined { info }, None)
            }
            ServerCtl::Participants { participants } => {
                lock(&self.participants).clone_from(&participants);
                (MultiplayerEvent::Participants { participants }, None)
            }
            ServerCtl::Presence(presence) => (MultiplayerEvent::Presence { presence }, None),
            ServerCtl::Lease(lease) => {
                lock(&self.leases).insert(lease.pane_id, lease);
                (MultiplayerEvent::Lease { lease }, None)
            }
            ServerCtl::LeaseRequested { pane_id, by, name } => {
                (MultiplayerEvent::LeaseRequested { pane_id, by, name }, None)
            }
            ServerCtl::InputRejected {
                pane_id, reason, ..
            } => (MultiplayerEvent::InputRejected { pane_id, reason }, None),
            ServerCtl::Forbidden { what, reason } => {
                (MultiplayerEvent::Forbidden { what, reason }, None)
            }
            ServerCtl::Decided(decided) => (MultiplayerEvent::Decided { decided }, None),
            ServerCtl::AlreadyDecided { request_id, by } => {
                (MultiplayerEvent::AlreadyDecided { request_id, by }, None)
            }
            msg @ ServerCtl::Revoked { .. } => (MultiplayerEvent::Revoked, Some(msg)),
            other => return Some(other),
        };
        let listener = lock(&self.listener).clone();
        if let Some(l) = listener {
            l.on_multiplayer_event(event);
        }
        pass
    }

    /// The connection dropped: requests in flight will not be answered.
    pub(crate) fn fail_pending(&self) {
        for (_, tx) in lock(&self.pending).drain() {
            let _ = tx.send(Err(MpError::Disconnected));
        }
    }
}

macro_rules! expect {
    ($resp:expr, $pat:pat => $out:expr) => {
        match $resp {
            $pat => Ok($out),
            other => Err(MpError::Failed(format!("unexpected answer {other:?}"))),
        }
    };
}

/// Milliseconds since the Unix epoch, for grant expiries.
pub fn now_millis() -> UnixMillis {
    UnixMillis(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64),
    )
}

impl Client {
    /// Joins the daemon named by an invite (`<scheme>://join/…`) under its grant, and keeps
    /// the connection up like [`connect`](Self::connect). The guest's principal is derived
    /// from its device key (`grants::guest_principal`).
    ///
    /// # Errors
    ///
    /// As [`connect`](Self::connect): an unparsable invite or a bad key.
    pub fn join(
        invite: &str,
        config: crate::ClientConfig,
        listener: Arc<dyn crate::ClientListener>,
    ) -> Result<Self, crate::ClientError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("client-core")
            .enable_all()
            .build()?;
        let mut client = Self::join_on(runtime.handle(), invite, config, listener)?;
        client.runtime = Some(runtime);
        Ok(client)
    }

    /// Like [`join`](Self::join), on a shared runtime.
    ///
    /// # Errors
    ///
    /// An unparsable invite or a bad key.
    pub fn join_on(
        runtime: &tokio::runtime::Handle,
        invite: &str,
        config: crate::ClientConfig,
        listener: Arc<dyn crate::ClientListener>,
    ) -> Result<Self, crate::ClientError> {
        Self::join_on_with(
            runtime,
            invite,
            config,
            crate::ConnectOptions::default(),
            listener,
        )
    }

    /// Like [`join_on`](Self::join_on), with [`ConnectOptions`](crate::ConnectOptions)
    /// (extra relay CAs).
    ///
    /// # Errors
    ///
    /// An unparsable invite or a bad key.
    pub fn join_on_with(
        runtime: &tokio::runtime::Handle,
        invite: &str,
        config: crate::ClientConfig,
        options: crate::ConnectOptions,
        listener: Arc<dyn crate::ClientListener>,
    ) -> Result<Self, crate::ClientError> {
        let invite: Invite = invite.parse()?;
        Self::start(
            runtime,
            crate::Dial::Invite(invite),
            config,
            options,
            listener,
        )
    }

    /// Sets the receiver of [`MultiplayerEvent`]s (replacing any previous one).
    pub fn set_multiplayer_listener(&self, listener: Arc<dyn MultiplayerListener>) {
        *lock(&self.inner.mp.listener) = Some(listener);
    }

    /// Who this connection is, as of the last handshake.
    pub fn me(&self) -> Option<JoinInfo> {
        lock(&self.inner.mp.me).clone()
    }

    /// The last participant list the daemon pushed.
    pub fn participant_list(&self) -> Vec<Participant> {
        lock(&self.inner.mp.participants).clone()
    }

    /// The last lease the daemon pushed for a pane.
    pub fn lease(&self, pane_id: PaneId) -> Option<Lease> {
        lock(&self.inner.mp.leases).get(&pane_id).copied()
    }

    /// Sends any multiplayer request and waits for the answer.
    ///
    /// # Errors
    ///
    /// The daemon's [`MpError`], or [`MpError::Disconnected`].
    pub async fn multiplayer(&self, req: MpRequest) -> Result<MpResponse, MpError> {
        let req_id = self
            .inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        lock(&self.inner.mp.pending).insert(req_id, tx);
        self.inner
            .send(proto::ClientCtl::Multiplayer { req_id, req });
        let inner = Arc::clone(&self.inner);
        self.handle
            .spawn(async move {
                match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
                    Ok(Ok(result)) => result,
                    _ => {
                        lock(&inner.mp.pending).remove(&req_id);
                        Err(MpError::Disconnected)
                    }
                }
            })
            .await
            .unwrap_or(Err(MpError::Disconnected))
    }

    /// This connection's identity, asked now.
    pub async fn who_am_i(&self) -> Result<JoinInfo, MpError> {
        expect!(self.multiplayer(MpRequest::WhoAmI).await?, MpResponse::Me(i) => i)
    }

    /// Everyone connected, with presence.
    pub async fn participants(&self) -> Result<Vec<Participant>, MpError> {
        expect!(self.multiplayer(MpRequest::Participants).await?,
            MpResponse::Participants(p) => p)
    }

    /// Sets this connection's display name.
    pub async fn set_name(&self, name: String) -> Result<(), MpError> {
        expect!(self.multiplayer(MpRequest::SetName { name }).await?, MpResponse::Done => ())
    }

    /// Signs an invite with this device's key and registers it with the daemon.
    ///
    /// A paired owner device signs a root grant; a guest that joined with an invite signs a
    /// narrower child of its own grant (only if that grant allows delegation, and never
    /// wider; a later expiry or more uses than the parent's are capped). The invite carries the daemon's addresses from this client's ticket or invite.
    ///
    /// # Errors
    ///
    /// [`MpError::Invalid`] if the child would widen the guest's grant, or the daemon's
    /// refusal to register it.
    pub async fn create_invite(
        &self,
        mut spec: GrantSpec,
        inviter: String,
    ) -> Result<Invite, MpError> {
        let key = DeviceKey::from_seed(&self.inner.config.secret_key)
            .map_err(|e| MpError::Invalid(e.to_string()))?;
        let ticket = &self.inner.ticket;
        let chain = match &self.inner.mp.invite {
            Some(invite) => {
                // Expiry and uses are capped at the parent's rather than refused; roles and
                // scope must be narrowed by the caller.
                if let Some(parent) = invite.chain.leaf() {
                    spec.expires = match (parent.expires, spec.expires) {
                        (Some(p), Some(c)) => Some(p.min(c)),
                        (p, c) => p.or(c),
                    };
                    spec.max_uses = match (parent.max_uses, spec.max_uses) {
                        (Some(p), Some(c)) => Some(p.min(c)),
                        (p, c) => p.or(c),
                    };
                }
                grants::attenuate(&invite.chain, &key, &spec, now_millis())
                    .map_err(|e| MpError::Invalid(e.to_string()))?
            }
            None => grants::issue(&key, ticket.daemon_id, &spec, now_millis()),
        };
        self.register_grant(chain.clone()).await?;
        Ok(Invite {
            v: Invite::VERSION,
            daemon_id: ticket.daemon_id,
            addrs: ticket.addrs.clone(),
            relay_url: ticket.relay_url.clone(),
            inviter,
            chain,
        })
    }

    /// Records a signed grant with the daemon so it is listed and revocable before use.
    pub async fn register_grant(&self, chain: GrantChain) -> Result<GrantInfo, MpError> {
        expect!(self.multiplayer(MpRequest::RegisterGrant(chain)).await?,
            MpResponse::Grant(g) => g)
    }

    /// Grants the daemon knows (owner only).
    pub async fn list_grants(&self) -> Result<Vec<GrantInfo>, MpError> {
        expect!(self.multiplayer(MpRequest::ListGrants).await?, MpResponse::Grants(g) => g)
    }

    /// Owner and guest devices (owner only).
    pub async fn list_devices(&self) -> Result<Vec<DeviceInfo>, MpError> {
        expect!(self.multiplayer(MpRequest::ListDevices).await?, MpResponse::Devices(d) => d)
    }

    /// Revokes a grant (and its descendants), a device or a principal, disconnecting them
    /// at once (owner only). Returns the response's grants, devices and connection count.
    pub async fn revoke(&self, target: RevokeTarget) -> Result<MpResponse, MpError> {
        let r = self.multiplayer(MpRequest::Revoke(target)).await?;
        expect!(r, r @ MpResponse::Revoked { .. } => r)
    }

    /// Asks for a pane's control lease; `force` (owner) takes it now.
    pub async fn take_control(
        &self,
        pane_id: PaneId,
        force: bool,
    ) -> Result<LeaseOutcome, MpError> {
        expect!(self.multiplayer(MpRequest::TakeControl { pane_id, force }).await?,
            MpResponse::Lease(l) => l)
    }

    /// Gives up a lease this principal holds.
    pub async fn release_control(&self, pane_id: PaneId) -> Result<(), MpError> {
        expect!(self.multiplayer(MpRequest::ReleaseControl { pane_id }).await?,
            MpResponse::Done => ())
    }

    /// Answers a [`MultiplayerEvent::LeaseRequested`].
    pub async fn answer_control(
        &self,
        pane_id: PaneId,
        give: bool,
    ) -> Result<LeaseOutcome, MpError> {
        expect!(self.multiplayer(MpRequest::AnswerControl { pane_id, give }).await?,
            MpResponse::Lease(l) => l)
    }

    /// Hands a lease to another connected driver (holder or owner).
    pub async fn give_control(
        &self,
        pane_id: PaneId,
        to: PrincipalId,
    ) -> Result<LeaseOutcome, MpError> {
        expect!(self.multiplayer(MpRequest::GiveControl { pane_id, to }).await?,
            MpResponse::Lease(l) => l)
    }

    /// Every pane's lease within scope.
    pub async fn leases(&self) -> Result<Vec<Lease>, MpError> {
        expect!(self.multiplayer(MpRequest::Leases).await?, MpResponse::Leases(l) => l)
    }

    /// Sends a prompt to an agent pane through the composer path (bracketed paste, then
    /// Enter if `submit`). Returns the characters sent.
    pub async fn prompt(
        &self,
        pane_id: PaneId,
        text: String,
        submit: bool,
    ) -> Result<u32, MpError> {
        expect!(self.multiplayer(MpRequest::Prompt { pane_id, text, submit }).await?,
            MpResponse::Prompted { chars } => chars)
    }

    /// Audit log records (owner only).
    pub async fn audit(&self, after: Option<u64>, limit: u32) -> Result<AuditPage, MpError> {
        expect!(self.multiplayer(MpRequest::Audit(AuditQuery { after, limit })).await?,
            MpResponse::Audit(a) => a)
    }

    /// Tells the others whether this device is typing in a pane's composer, with its focus.
    pub fn set_typing(&self, pane_id: PaneId, typing: bool) {
        let actor = self.actor();
        self.inner.send(proto::ClientCtl::Presence(Presence {
            actor,
            state: PresenceState::Active,
            focus: Some(pane_id),
            typing,
            viewport: None,
            cursor: None,
        }));
    }

    /// Sends a full presence update (the actor is filled in).
    pub fn send_presence(&self, mut presence: Presence) {
        presence.actor = self.actor();
        self.inner.send(proto::ClientCtl::Presence(presence));
    }

    pub(crate) fn actor(&self) -> Actor {
        Actor {
            principal: self.inner.ticket.principal,
            device: crate::device_id(&self.inner.config),
        }
    }
}

/// Whether this client joined as a guest.
pub(crate) fn is_guest(inner: &Inner) -> bool {
    inner.mp.invite.is_some()
}
