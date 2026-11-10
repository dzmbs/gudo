//! Multiplayer API: invites and attenuated grants, roles, take control,
//! presence, prompts through the composer path, revocation and the audit log.
//!
//! Join a daemon with an invite through [`Client::join`]. Requests are `async` like the workspace API. Pushes —
//! who is connected, leases, someone asking for control, refusals, decisions — go to a
//! [`MultiplayerListener`] set with [`Client::set_multiplayer_listener`], separate from
//! [`ClientListener`](crate::ClientListener).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use grants::{DeviceKey, GrantSpec};
use proto::{
    Actor, Admit, ApprovalPolicy, ApprovalStatus, AuditPage, AuditQuery, Decided, DeviceInfo,
    GrantChain, GrantId, GrantInfo, InputRejectReason, Invite, InviteTerms, JoinInfo, Knock,
    KnockId, KnockUpdate, Lease, LeaseOutcome, MpError, MpRequest, MpResponse, PaneId, Participant,
    Peer, PeerId, Presence, PresenceState, PrincipalId, RequestId, RevokeTarget, ServerCtl,
    SessionId, UnixMillis,
};
use tokio::sync::{mpsc, oneshot};

use crate::{Client, Inner, lock};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// A multiplayer push from the daemon.
#[derive(Debug, Clone)]
pub enum MultiplayerEvent {
    /// Who this connection is (after every handshake).
    Joined { info: JoinInfo },
    /// Everyone connected (the whole list).
    Participants {
        /// One entry per device.
        participants: Vec<Participant>,
    },
    /// Another participant's presence (typing, cursor, focus).
    Presence { presence: Presence },
    /// A pane's control lease changed.
    Lease { lease: Lease },
    /// Someone asks for a lease this principal holds; answer with
    /// [`Client::answer_control`].
    LeaseRequested {
        pane_id: PaneId,
        /// Who asks.
        by: Actor,
        /// Their display name.
        name: String,
    },
    /// Input was refused (no lease, role, scope).
    InputRejected {
        pane_id: PaneId,
        reason: InputRejectReason,
    },
    /// A ctl message was refused by policy.
    Forbidden { what: String, reason: String },
    /// An approval was decided (by anyone).
    Decided { decided: Decided },
    /// This client's decision lost to an earlier one.
    AlreadyDecided {
        request_id: RequestId,
        /// Who won.
        by: Actor,
    },
    /// This connection's grant was revoked; the daemon closes it.
    Revoked,
    /// Another owner device just paired with the host (owner devices only). Show it: a
    /// pairing the owner did not make is revoked from the device list.
    DevicePaired { device: DeviceInfo },
    /// The host's access control needs its owner (owner devices only), e.g. its grant store
    /// was reset. Sent on every connection while it stands: show each alert once.
    HostAlert { alert: proto::HostAlert },
    /// Someone other than the owner answered an agent's request (owner devices only). Notify
    /// whatever was seen: no guest answers for the owner unnoticed.
    GuestAnswered { answer: proto::GuestAnswer },
    /// Someone knocked, or a knock ended (owner devices only). The current list is
    /// [`Client::pending_knocks`].
    Knock { update: KnockUpdate },
    /// The attached session's approval policy (after attaching and on every change).
    ApprovalPolicy {
        session_id: SessionId,
        policy: ApprovalPolicy,
    },
    /// An open approval request's votes or claim changed.
    ApprovalStatus { status: ApprovalStatus },
    /// Everyone's live presence, whole (after joining, and when someone joins or leaves).
    Peers {
        /// This connection.
        you: PeerId,
        /// Every connection, oldest first.
        peers: Vec<Peer>,
    },
    /// One connection's live presence changed (draft, viewport, focus, typing, state).
    PeerChanged { peer: Peer },
}

/// Receives [`MultiplayerEvent`]s. Must return quickly; it runs on the network threads.
pub trait MultiplayerListener: Send + Sync {
    /// Called once per event, in order.
    fn on_multiplayer_event(&self, event: MultiplayerEvent);
}

/// A [`MultiplayerListener`] that queues events for async Rust consumers (`gudo`, tests).
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
    knocks: Mutex<Vec<Knock>>,
    policy: Mutex<Option<(SessionId, ApprovalPolicy)>>,
    approvals: Mutex<HashMap<RequestId, ApprovalStatus>>,
    /// The invite this client joined with (guests).
    pub(crate) invite: Option<Invite>,
    pub(crate) peers: crate::peer::PeerState,
}

impl MpState {
    /// Whether a caller still waits for the answer to `req_id`.
    pub(crate) fn awaits(&self, req_id: u64) -> bool {
        lock(&self.pending)
            .get(&req_id)
            .is_some_and(|reply| !reply.is_closed())
    }

    pub(crate) fn with_invite(invite: Option<Invite>) -> Self {
        Self {
            invite,
            ..Self::default()
        }
    }

    /// Handles a multiplayer message from `ctl`; returns it back if it is not one (or if the
    /// connection loop must see it too).
    pub(crate) fn dispatch(&self, message: ServerCtl) -> Option<ServerCtl> {
        let (event, pass) = match message {
            ServerCtl::MultiplayerResult { req_id, result } => {
                if let Some(reply) = lock(&self.pending).remove(&req_id) {
                    let _ = reply.send(result);
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
            ServerCtl::Decided(decided) => {
                lock(&self.approvals).remove(&decided.request_id);
                (MultiplayerEvent::Decided { decided }, None)
            }
            ServerCtl::Knock(update) => {
                let mut knocks = lock(&self.knocks);
                match &update {
                    KnockUpdate::Added(knock) => {
                        knocks.retain(|known| known.knock_id != knock.knock_id);
                        knocks.push(knock.clone());
                    }
                    KnockUpdate::Gone { knock_id, .. } => {
                        knocks.retain(|known| known.knock_id != *knock_id)
                    }
                }
                (MultiplayerEvent::Knock { update }, None)
            }
            ServerCtl::ApprovalPolicy { session_id, policy } => {
                *lock(&self.policy) = Some((session_id, policy));
                (
                    MultiplayerEvent::ApprovalPolicy { session_id, policy },
                    None,
                )
            }
            ServerCtl::ApprovalStatus(status) => {
                lock(&self.approvals).insert(status.request_id, status.clone());
                (MultiplayerEvent::ApprovalStatus { status }, None)
            }
            ServerCtl::AlreadyDecided { request_id, by } => {
                (MultiplayerEvent::AlreadyDecided { request_id, by }, None)
            }
            ServerCtl::Peers(push) => (self.peers.apply(push)?, None),
            revoked @ ServerCtl::Revoked { .. } => (MultiplayerEvent::Revoked, Some(revoked)),
            ServerCtl::DevicePaired(device) => (MultiplayerEvent::DevicePaired { device }, None),
            ServerCtl::HostAlert(alert) => (MultiplayerEvent::HostAlert { alert }, None),
            ServerCtl::GuestAnswered(answer) => (MultiplayerEvent::GuestAnswered { answer }, None),
            other => return Some(other),
        };
        let listener = lock(&self.listener).clone();
        if let Some(listener) = listener {
            listener.on_multiplayer_event(event);
        }
        pass
    }

    /// A new connection: knocks are re-sent by the daemon after `Joined`.
    pub(crate) fn reset_for_connection(&self) {
        lock(&self.knocks).clear();
        lock(&self.approvals).clear();
        self.peers.reset_for_connection();
    }

    /// The connection dropped: requests in flight will not be answered.
    pub(crate) fn fail_pending(&self) {
        for (_, reply) in lock(&self.pending).drain() {
            let _ = reply.send(Err(MpError::Disconnected));
        }
    }
}

macro_rules! expect {
    ($response:expr, $pat:pat => $out:expr) => {
        match $response {
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
            .map_or(0, |elapsed| elapsed.as_millis() as u64),
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

    /// Like [`join`](Self::join), with [`ConnectOptions`](crate::ConnectOptions).
    ///
    /// # Errors
    ///
    /// An unparsable invite or a bad key.
    pub fn join_with(
        invite: &str,
        config: crate::ClientConfig,
        options: crate::ConnectOptions,
        listener: Arc<dyn crate::ClientListener>,
    ) -> Result<Self, crate::ClientError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("client-core")
            .enable_all()
            .build()?;
        let mut client = Self::join_on_with(runtime.handle(), invite, config, options, listener)?;
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

    /// The device that signed the invite this client joined with (`None` for paired
    /// devices): whom a guest follows by default.
    pub fn inviter_device(&self) -> Option<proto::DeviceId> {
        self.inner
            .mp
            .invite
            .as_ref()?
            .chain
            .leaf()
            .map(|grant| grant.issuer)
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
    pub async fn multiplayer(&self, request: MpRequest) -> Result<MpResponse, MpError> {
        let req_id = self
            .inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (reply_tx, reply_rx) = oneshot::channel();
        lock(&self.inner.mp.pending).insert(req_id, reply_tx);
        self.inner.send(proto::ClientCtl::Multiplayer {
            req_id,
            req: request,
        });
        let inner = Arc::clone(&self.inner);
        self.handle
            .spawn(async move {
                match tokio::time::timeout(REQUEST_TIMEOUT, reply_rx).await {
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
        expect!(self.multiplayer(MpRequest::WhoAmI).await?, MpResponse::Me(info) => info)
    }

    /// Everyone connected, with presence.
    pub async fn participants(&self) -> Result<Vec<Participant>, MpError> {
        expect!(self.multiplayer(MpRequest::Participants).await?,
            MpResponse::Participants(participants) => participants)
    }

    /// Sets this connection's display name.
    pub async fn set_name(&self, name: String) -> Result<(), MpError> {
        expect!(self.multiplayer(MpRequest::SetName { name }).await?, MpResponse::Done => ())
    }

    /// Signs an invite with this device's key and registers it with the daemon.
    ///
    /// A paired owner device signs a root grant; a guest that joined with an invite signs a
    /// narrower child of its own grant (only if that grant allows delegation, and never
    /// wider; a later expiry or more uses than the parent's are capped). The invite carries
    /// the daemon's addresses from this client's ticket or invite.
    ///
    /// # Errors
    ///
    /// [`MpError::Invalid`] if the child would widen the guest's grant, or the daemon's
    /// refusal to register it.
    pub async fn create_invite(&self, spec: GrantSpec, inviter: String) -> Result<Invite, MpError> {
        self.create_invite_with_terms(spec, inviter, InviteTerms::default())
            .await
    }

    /// Like [`create_invite`](Self::create_invite), with terms the daemon enforces on the
    /// invite: knock to join, and scrollback only from joining. Share the invite as
    /// [`Invite::to_string_with_terms`] so the join card can say what will happen.
    ///
    /// # Errors
    ///
    /// As [`create_invite`](Self::create_invite); [`MpError::Failed`] when the daemon is too
    /// old for invite terms.
    pub async fn create_invite_with_terms(
        &self,
        mut spec: GrantSpec,
        inviter: String,
        terms: InviteTerms,
    ) -> Result<Invite, MpError> {
        if terms != InviteTerms::default() && !self.daemon_has(proto::DaemonFeatures::MP2) {
            return Err(MpError::Failed(
                "the host's helper is too old for knock or since-joining invites; update it".into(),
            ));
        }
        let key = DeviceKey::from_seed(&self.inner.config.secret_key)
            .map_err(|err| MpError::Invalid(err.to_string()))?;
        let ticket = &self.inner.ticket;
        let chain = match &self.inner.mp.invite {
            Some(invite) => {
                // Expiry and uses are capped at the parent's rather than refused; roles and
                // scope must be narrowed by the caller.
                if let Some(parent) = invite.chain.leaf() {
                    spec.expires = match (parent.expires, spec.expires) {
                        (Some(parent), Some(child)) => Some(parent.min(child)),
                        (parent, child) => parent.or(child),
                    };
                    spec.max_uses = match (parent.max_uses, spec.max_uses) {
                        (Some(parent), Some(child)) => Some(parent.min(child)),
                        (parent, child) => parent.or(child),
                    };
                }
                grants::attenuate(&invite.chain, &key, &spec, now_millis())
                    .map_err(|err| MpError::Invalid(err.to_string()))?
            }
            None => grants::issue(&key, ticket.daemon_id, &spec, now_millis()),
        };
        if terms == InviteTerms::default() {
            self.register_grant(chain.clone()).await?;
        } else {
            expect!(self.multiplayer(MpRequest::RegisterInvite { chain: chain.clone(), terms }).await?,
                MpResponse::Grant(_) => ())?;
        }
        Ok(Invite {
            v: Invite::VERSION,
            daemon_id: ticket.daemon_id,
            addrs: ticket.addrs.clone(),
            relay_url: ticket.relay_url.clone(),
            inviter,
            chain,
        })
    }

    /// Whether the daemon announced `feature` on this connection.
    pub(crate) fn daemon_has(&self, feature: proto::DaemonFeatures) -> bool {
        lock(&self.inner.daemon_info)
            .as_ref()
            .is_some_and(|info| info.features.contains(feature))
    }

    /// Knocks waiting for an owner, as last pushed (owner devices).
    pub fn pending_knocks(&self) -> Vec<Knock> {
        lock(&self.inner.mp.knocks).clone()
    }

    /// The attached session's approval policy, as last pushed.
    pub fn approval_policy_cached(&self) -> Option<(SessionId, ApprovalPolicy)> {
        *lock(&self.inner.mp.policy)
    }

    /// Open approval requests with votes or a claim, as last pushed.
    pub fn approval_statuses(&self) -> Vec<ApprovalStatus> {
        lock(&self.inner.mp.approvals).values().cloned().collect()
    }

    /// Knocks waiting for an owner, asked now (owner only).
    pub async fn knocks(&self) -> Result<Vec<Knock>, MpError> {
        expect!(self.multiplayer(MpRequest::Knocks).await?, MpResponse::Knocks(knocks) => knocks)
    }

    /// Admits a knock with `admit`'s roles (`Some`), or turns it away (`None`). Returns the
    /// grant the guest joins with, if admitted.
    pub async fn answer_knock(
        &self,
        knock_id: KnockId,
        admit: Option<Admit>,
    ) -> Result<Option<GrantInfo>, MpError> {
        match self
            .multiplayer(MpRequest::AnswerKnock { knock_id, admit })
            .await?
        {
            MpResponse::Admitted(info) => Ok(Some(info)),
            MpResponse::Done => Ok(None),
            other => Err(MpError::Failed(format!("unexpected answer {other:?}"))),
        }
    }

    /// A session's approval policy, asked now.
    pub async fn approval_policy(&self, session_id: SessionId) -> Result<ApprovalPolicy, MpError> {
        expect!(self.multiplayer(MpRequest::GetApprovalPolicy { session_id }).await?,
            MpResponse::ApprovalPolicy(policy) => policy)
    }

    /// Sets a session's approval policy (owner only).
    pub async fn set_approval_policy(
        &self,
        session_id: SessionId,
        policy: ApprovalPolicy,
    ) -> Result<ApprovalPolicy, MpError> {
        expect!(self.multiplayer(MpRequest::SetApprovalPolicy { session_id, policy }).await?,
            MpResponse::ApprovalPolicy(policy) => policy)
    }

    /// Claims an open approval request ("I'll take this one"), or releases the claim.
    pub async fn claim(
        &self,
        request_id: RequestId,
        claim: bool,
    ) -> Result<ApprovalStatus, MpError> {
        expect!(self.multiplayer(MpRequest::Claim { request_id, claim }).await?,
            MpResponse::Approval(status) => status)
    }

    /// Records a signed grant with the daemon so it is listed and revocable before use.
    pub async fn register_grant(&self, chain: GrantChain) -> Result<GrantInfo, MpError> {
        expect!(self.multiplayer(MpRequest::RegisterGrant(chain)).await?,
            MpResponse::Grant(grant) => grant)
    }

    /// Grants the daemon knows (owner only).
    pub async fn list_grants(&self) -> Result<Vec<GrantInfo>, MpError> {
        expect!(self.multiplayer(MpRequest::ListGrants).await?, MpResponse::Grants(grants) => grants)
    }

    /// The shareable link of a registered grant, as [`create_invite_with_terms`] made it,
    /// signed by `inviter` (owner only).
    ///
    /// # Errors
    ///
    /// [`MpError::Failed`] when the daemon is too old to answer; [`MpError::NotFound`] for a
    /// grant it does not know.
    ///
    /// [`create_invite_with_terms`]: Self::create_invite_with_terms
    pub async fn invite_link(&self, grant_id: GrantId, inviter: String) -> Result<String, MpError> {
        if !self.daemon_has(proto::DaemonFeatures::INVITE_LINKS) {
            return Err(MpError::Failed(
                "the host's helper is too old to share a link again; update it".into(),
            ));
        }
        let (chain, terms) = expect!(self.multiplayer(MpRequest::InviteLink(grant_id)).await?,
            MpResponse::InviteLink { chain, terms } => (chain, terms))?;
        let ticket = &self.inner.ticket;
        let invite = Invite {
            v: Invite::VERSION,
            daemon_id: ticket.daemon_id,
            addrs: ticket.addrs.clone(),
            relay_url: ticket.relay_url.clone(),
            inviter,
            chain,
        };
        Ok(invite.to_string_with_terms(terms))
    }

    /// Whether the daemon makes pairing tickets and renames devices for its owner devices
    /// ([`Self::pairing_ticket`], [`Self::rename_device`]).
    pub fn can_manage_devices(&self) -> bool {
        self.daemon_has(proto::DaemonFeatures::DEVICE_MANAGEMENT)
    }

    /// A one-time pairing ticket (`<scheme>://pair/…`) for another device, and when it
    /// expires (paired owner devices only).
    ///
    /// # Errors
    ///
    /// [`MpError::Failed`] when the daemon is too old; [`MpError::Forbidden`] for guests.
    pub async fn pairing_ticket(&self) -> Result<(String, proto::UnixMillis), MpError> {
        if !self.can_manage_devices() {
            return Err(MpError::Failed(
                "the host's helper is too old to pair from here; update it".into(),
            ));
        }
        expect!(self.multiplayer(MpRequest::PairingTicket).await?,
            MpResponse::PairingTicket { ticket, expires } => (ticket, expires))
    }

    /// Names a paired owner device for everyone; an empty name goes back to the device's own
    /// (paired owner devices only).
    ///
    /// # Errors
    ///
    /// As [`Self::pairing_ticket`], and [`MpError::NotFound`] for a device that is not paired.
    pub async fn rename_device(
        &self,
        device: proto::DeviceId,
        name: String,
    ) -> Result<(), MpError> {
        if !self.can_manage_devices() {
            return Err(MpError::Failed(
                "the host's helper is too old to rename devices; update it".into(),
            ));
        }
        expect!(self.multiplayer(MpRequest::RenameDevice { device, name }).await?,
            MpResponse::Done => ())
    }

    /// Owner and guest devices (owner only).
    pub async fn list_devices(&self) -> Result<Vec<DeviceInfo>, MpError> {
        expect!(self.multiplayer(MpRequest::ListDevices).await?, MpResponse::Devices(devices) => devices)
    }

    /// Revokes a grant (and its descendants), a device or a principal, disconnecting them
    /// at once (owner only). Returns the response's grants, devices and connection count.
    pub async fn revoke(&self, target: RevokeTarget) -> Result<MpResponse, MpError> {
        let response = self.multiplayer(MpRequest::Revoke(target)).await?;
        expect!(response, revoked @ MpResponse::Revoked { .. } => revoked)
    }

    /// Asks for a pane's control lease; `force` (owner) takes it now.
    pub async fn take_control(
        &self,
        pane_id: PaneId,
        force: bool,
    ) -> Result<LeaseOutcome, MpError> {
        expect!(self.multiplayer(MpRequest::TakeControl { pane_id, force }).await?,
            MpResponse::Lease(outcome) => outcome)
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
            MpResponse::Lease(outcome) => outcome)
    }

    /// Hands a lease to another connected driver (holder or owner).
    pub async fn give_control(
        &self,
        pane_id: PaneId,
        to: PrincipalId,
    ) -> Result<LeaseOutcome, MpError> {
        expect!(self.multiplayer(MpRequest::GiveControl { pane_id, to }).await?,
            MpResponse::Lease(outcome) => outcome)
    }

    /// Every pane's lease within scope.
    pub async fn leases(&self) -> Result<Vec<Lease>, MpError> {
        expect!(self.multiplayer(MpRequest::Leases).await?, MpResponse::Leases(leases) => leases)
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
            MpResponse::Audit(page) => page)
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
