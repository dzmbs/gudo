//! Multiplayer: signed attenuable grants, invites, roles,
//! control leases, presence, signed approvals and the audit log.
//!
//! # Grants
//!
//! A [`Grant`] is signed by its `issuer` device key (Ed25519, the device's iroh key). A
//! [`GrantChain`] is a root grant, signed by an owner device (or the daemon key), followed by
//! zero or more attenuated children: each child is signed by the device that holds its parent
//! and may only narrow it (fewer roles, a smaller scope, an earlier expiry, fewer uses), and
//! only when the parent allows delegation. The daemon verifies the whole chain on connect and
//! re-checks revocation and expiry on every message. Signing and verification live in the
//! `grants` crate; this module holds the wire types and the exact bytes that are signed.
//!
//! A connection presents a chain as `Hello.grant` with [`SignedGrant::CHAIN`]
//! (`token` = postcard of the [`GrantChain`], `grant_id` = the leaf's id).
//!
//! # Invites
//!
//! An [`Invite`] is the daemon's dial info (like a pairing [`Ticket`](crate::Ticket)) plus a
//! grant chain, written as `<scheme>://join/<base32>` ([`brand::URL_SCHEME`]) and shown as a
//! QR code.
//!
//! # Requests
//!
//! Multiplayer requests are [`ClientCtl::Multiplayer`](crate::ClientCtl::Multiplayer) →
//! [`ServerCtl::MultiplayerResult`](crate::ServerCtl::MultiplayerResult), keyed by a
//! client-chosen `req_id`, like workspace requests.

use std::fmt;
use std::net::SocketAddr;
use std::str::FromStr;

use data_encoding::BASE32_NOPAD;
use serde::{Deserialize, Serialize};

use crate::ids::{
    Actor, DaemonId, DeviceId, GrantId, OptionId, PaneId, PrincipalId, RequestId, Roles, SessionId,
    TabId, UnixMillis,
};
use crate::msg::{CursorPos, Lease, PresenceState};
use crate::ticket::TicketError;

/// What a grant covers. Narrower scopes are contained in wider ones:
/// `Daemon ⊇ Session ⊇ Tab ⊇ Pane`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Scope {
    /// Every session on the daemon, and host-wide requests (files, git, forwards).
    Daemon,
    /// One session and everything in it.
    Session(SessionId),
    /// One tab and its panes.
    Tab(TabId),
    Pane(PaneId),
}

impl fmt::Display for Scope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Daemon => f.write_str("daemon"),
            Self::Session(session) => write!(f, "session:{session}"),
            Self::Tab(tab) => write!(f, "tab:{tab}"),
            Self::Pane(pane) => write!(f, "pane:{pane}"),
        }
    }
}

/// One capability grant. Signed by `issuer`; see the module docs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Grant {
    /// Format version; [`Grant::VERSION`].
    pub v: u16,
    /// Random id. Revocation and use counting go by it.
    pub grant_id: GrantId,
    /// The only daemon that accepts it.
    pub daemon_id: DaemonId,
    /// The device key that signed it: an owner device or the daemon for a root grant, the
    /// parent's holder for an attenuated one.
    pub issuer: DeviceId,
    /// Roles conferred. [`Roles::OWNER`] implies every other role.
    pub roles: Roles,
    /// What it covers.
    pub scope: Scope,
    /// When it was signed.
    pub issued_at: UnixMillis,
    /// After this instant it is invalid; `None` never expires (paired own devices).
    pub expires: Option<UnixMillis>,
    /// How many distinct devices may redeem it; `None` is unlimited.
    pub max_uses: Option<u32>,
    /// The only device that may present it; `None` binds to each redeeming device on first
    /// use.
    pub bind: Option<DeviceId>,
    /// Whether the holder may sign narrower child grants.
    pub delegate: bool,
    /// Who it is for, shown to other participants ("Bob").
    pub label: String,
}

impl Grant {
    /// The format version this crate writes and reads.
    pub const VERSION: u16 = 1;
    /// Domain separation for grant signatures.
    pub const SIGNING_CONTEXT: &'static [u8] = b"grant-v1\0";

    /// The exact bytes the issuer signs: [`SIGNING_CONTEXT`](Self::SIGNING_CONTEXT) followed by
    /// the postcard encoding of the grant.
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut signed = Self::SIGNING_CONTEXT.to_vec();
        signed.extend(postcard::to_stdvec(self).expect("grants always encode"));
        signed
    }
}

/// A grant and its issuer's signature.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GrantLink {
    pub grant: Grant,
    /// Ed25519 signature by `grant.issuer` over [`Grant::signing_bytes`].
    #[serde(with = "crate::serde_bytes")]
    pub sig: Vec<u8>,
}

/// A root grant followed by attenuated children, root first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GrantChain {
    /// The links, root first; the last one is the grant being exercised.
    pub links: Vec<GrantLink>,
}

impl GrantChain {
    /// The grant being exercised (the last link).
    pub fn leaf(&self) -> Option<&Grant> {
        self.links.last().map(|link| &link.grant)
    }

    /// The leaf's id, or all zeroes for an empty chain.
    pub fn grant_id(&self) -> GrantId {
        self.leaf().map_or(GrantId([0; 16]), |grant| grant.grant_id)
    }

    /// The postcard encoding carried in [`SignedGrant::token`](crate::SignedGrant::token).
    pub fn to_token(&self) -> Vec<u8> {
        postcard::to_stdvec(self).expect("chains always encode")
    }

    /// Decodes a [`SignedGrant::token`](crate::SignedGrant::token).
    ///
    /// # Errors
    ///
    /// Returns the postcard error for malformed bytes.
    pub fn from_token(token: &[u8]) -> Result<Self, postcard::Error> {
        postcard::from_bytes(token)
    }
}

/// An invitation to join a daemon under a grant: dial info plus a signed grant chain.
///
/// # Examples
///
/// ```
/// use proto::{DaemonId, GrantChain, Invite};
///
/// let invite = Invite {
///     v: Invite::VERSION,
///     daemon_id: DaemonId([7; 32]),
///     addrs: vec!["127.0.0.1:4433".parse().unwrap()],
///     relay_url: None,
///     inviter: "alice".into(),
///     chain: GrantChain { links: vec![] },
/// };
/// let text = invite.to_string();
/// assert!(text.starts_with(&format!("{}://join/", brand::URL_SCHEME)));
/// assert_eq!(text.parse::<Invite>()?, invite);
/// # Ok::<(), proto::TicketError>(())
/// ```
///
/// `Debug` leaves the grant chain out: whoever holds it can join.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Invite {
    /// Invite format version; [`Invite::VERSION`].
    pub v: u16,
    /// The daemon's iroh endpoint id (pinned by the TLS handshake).
    pub daemon_id: DaemonId,
    /// Direct addresses to try.
    pub addrs: Vec<SocketAddr>,
    /// The daemon's home relay, if it uses one.
    pub relay_url: Option<String>,
    /// Who invited, for the join card.
    pub inviter: String,
    /// The grant to present.
    pub chain: GrantChain,
}

impl Invite {
    /// The format version this crate writes and reads.
    pub const VERSION: u16 = 1;

    fn prefix() -> String {
        format!("{}://join/", brand::URL_SCHEME)
    }
}

impl fmt::Debug for Invite {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Invite")
            .field("v", &self.v)
            .field("daemon_id", &self.daemon_id)
            .field("addrs", &self.addrs)
            .field("relay_url", &self.relay_url)
            .field("inviter", &self.inviter)
            .finish_non_exhaustive()
    }
}

impl fmt::Display for Invite {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bytes = postcard::to_stdvec(self).map_err(|_| fmt::Error)?;
        write!(f, "{}{}", Self::prefix(), BASE32_NOPAD.encode(&bytes))
    }
}

impl FromStr for Invite {
    type Err = TicketError;

    /// Parses the URL form (also with `#` instead of `/` before the payload, so the payload
    /// can travel in a URL fragment, and as the universal link `https://<web domain>/join#…`)
    /// or the bare base32. Whitespace and case are ignored.
    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let bytes = invite_bytes(text)?;
        let (version, _) = postcard::take_from_bytes::<u16>(&bytes).map_err(TicketError::Decode)?;
        if version != Self::VERSION {
            return Err(TicketError::Version(version));
        }
        postcard::from_bytes(&bytes).map_err(TicketError::Decode)
    }
}

/// The bytes a device signs to answer an approval request ([`Decide::sig`](crate::Decide)).
///
/// Binding the daemon id stops a signature from being replayed on another host.
pub fn approval_signing_bytes(
    daemon: DaemonId,
    request_id: RequestId,
    option_id: OptionId,
    actor: Actor,
) -> Vec<u8> {
    let mut signed = b"approval-v1\0".to_vec();
    signed.extend(
        postcard::to_stdvec(&(daemon, request_id, option_id, actor))
            .expect("approvals always encode"),
    );
    signed
}

/// What to revoke.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RevokeTarget {
    /// A grant and every grant attenuated from it.
    Grant(GrantId),
    /// A device: its pairing (owner devices) and every grant it holds or issued.
    Device(DeviceId),
    /// Every device and grant of a principal.
    Principal(PrincipalId),
}

/// A page of the audit log.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditQuery {
    /// Records with `seq` greater than this; `None` for the newest `limit` records.
    pub after: Option<u64>,
    /// At most this many records.
    pub limit: u32,
}

/// A multiplayer request (see the module docs).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum MpRequest {
    /// Who this connection is → [`MpResponse::Me`].
    WhoAmI,
    /// Everyone connected, with presence → [`MpResponse::Participants`].
    Participants,
    /// Records a grant the owner (or a delegating holder) signed, so it can be listed and
    /// revoked before first use → [`MpResponse::Grant`].
    RegisterGrant(GrantChain),
    /// Grants the daemon knows → [`MpResponse::Grants`]. Owner only.
    ListGrants,
    /// Paired owner devices and guest devices → [`MpResponse::Devices`]. Owner only.
    ListDevices,
    /// Revokes at once and disconnects whoever used it → [`MpResponse::Revoked`]. Owner only.
    Revoke(RevokeTarget),
    /// Asks for a pane's control lease → [`MpResponse::Lease`]. `force` (owner only) takes it
    /// from the holder.
    TakeControl {
        pane_id: PaneId,
        /// Take it now, whatever the holder is doing.
        force: bool,
    },
    /// Gives up the lease → [`MpResponse::Done`].
    ReleaseControl { pane_id: PaneId },
    /// The holder answers a pending take-control request → [`MpResponse::Lease`].
    AnswerControl {
        pane_id: PaneId,
        /// Hand it over (`true`) or keep it.
        give: bool,
    },
    /// The holder or an owner hands the lease to a principal → [`MpResponse::Lease`].
    GiveControl {
        pane_id: PaneId,
        /// The new holder; must be connected with the Driver role on the pane.
        to: PrincipalId,
    },
    /// Every pane's lease within scope → [`MpResponse::Leases`].
    Leases,
    /// Sends a prompt to an agent pane through the composer path (bracketed paste, then
    /// Enter if `submit`) → [`MpResponse::Prompted`]. The Prompter role's only input.
    Prompt {
        /// The agent pane.
        pane_id: PaneId,
        /// The prompt. Control characters, `!` shell escapes and `/` commands are refused.
        text: String,
        /// Press Enter after the paste.
        submit: bool,
    },
    /// Audit log records → [`MpResponse::Audit`]. Owner only.
    Audit(AuditQuery),
    /// This connection's display name → [`MpResponse::Done`].
    SetName { name: String },
    /// Like [`RegisterGrant`](Self::RegisterGrant), with terms the daemon enforces on the
    /// chain and everything attenuated from it (knock, history) → [`MpResponse::Grant`].
    /// A delegating holder may only add terms to what its own grant carries.
    RegisterInvite {
        chain: GrantChain,
        terms: InviteTerms,
    },
    /// Pending knocks → [`MpResponse::Knocks`]. Owner only.
    Knocks,
    /// Admits (with roles) or denies a knock → [`MpResponse::Admitted`] or
    /// [`MpResponse::Done`]. Owner only.
    AnswerKnock {
        knock_id: KnockId,
        /// `None` denies.
        admit: Option<Admit>,
    },
    /// A session's approval policy → [`MpResponse::ApprovalPolicy`]. Any role in scope.
    GetApprovalPolicy { session_id: SessionId },
    /// Sets a session's approval policy → [`MpResponse::ApprovalPolicy`]. Owner only.
    SetApprovalPolicy {
        session_id: SessionId,
        policy: ApprovalPolicy,
    },
    /// Claims an open approval request (or gives a claim up) → [`MpResponse::Approval`].
    /// Approver role on the request's pane.
    Claim {
        request_id: RequestId,
        /// `false` releases this principal's claim (an owner may release anyone's).
        claim: bool,
    },
    /// A registered grant's chain and terms, to share its link again →
    /// [`MpResponse::InviteLink`]. Owner only; daemons with
    /// [`DaemonFeatures::INVITE_LINKS`](crate::DaemonFeatures::INVITE_LINKS).
    InviteLink(GrantId),
    /// Mints a one-time pairing ticket, as `hostd pair` does, for the owner to show another
    /// of their devices → [`MpResponse::PairingTicket`]. Paired owner devices only, never
    /// guests; daemons with
    /// [`DaemonFeatures::DEVICE_MANAGEMENT`](crate::DaemonFeatures::DEVICE_MANAGEMENT).
    PairingTicket,
    /// Names a paired owner device for everyone who lists devices, over what the device calls
    /// itself; an empty name goes back to that → [`MpResponse::Done`]. Paired owner devices
    /// only; daemons with
    /// [`DaemonFeatures::DEVICE_MANAGEMENT`](crate::DaemonFeatures::DEVICE_MANAGEMENT).
    RenameDevice { device: DeviceId, name: String },
}

/// Answer to [`MpRequest::TakeControl`] and friends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LeaseOutcome {
    /// The caller (or the named principal) holds the lease now.
    Granted(Lease),
    /// The holder was asked ([`ServerCtl::LeaseRequested`](crate::ServerCtl::LeaseRequested));
    /// the lease moves when they give it or once they have been idle long enough.
    Pending {
        /// The current holder.
        holder: PrincipalId,
    },
    /// The holder kept it.
    Kept(Lease),
}

/// The answer to an [`MpRequest`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum MpResponse {
    /// Done; nothing to return.
    Done,
    /// This connection's identity.
    Me(JoinInfo),
    /// Everyone connected.
    Participants(Vec<Participant>),
    Grant(GrantInfo),
    Grants(Vec<GrantInfo>),
    Devices(Vec<DeviceInfo>),
    /// What a revocation hit.
    Revoked {
        /// Grants now revoked (the target and its descendants).
        grants: Vec<GrantId>,
        /// Devices now revoked.
        devices: Vec<DeviceId>,
        /// Connections closed.
        disconnected: u32,
    },
    /// A lease change.
    Lease(LeaseOutcome),
    Leases(Vec<Lease>),
    /// A prompt was written.
    Prompted {
        /// Characters sent.
        chars: u32,
    },
    Audit(AuditPage),
    Knocks(Vec<Knock>),
    /// The grant a knock was admitted with.
    Admitted(GrantInfo),
    /// A session's approval policy.
    ApprovalPolicy(ApprovalPolicy),
    /// An approval request's state after a claim.
    Approval(ApprovalStatus),
    /// A registered grant's chain and the terms it was registered with.
    InviteLink {
        /// The chain, root first.
        chain: GrantChain,
        terms: InviteTerms,
    },
    /// A one-time pairing ticket (`<scheme>://pair/…`) and when it stops working.
    PairingTicket {
        ticket: String,
        expires: UnixMillis,
    },
}

/// Why a multiplayer request (or any request refused by policy) failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum MpError {
    /// The connection's roles or scope do not allow it; the text says which role is needed.
    Forbidden(String),
    /// No such pane, grant or device (or outside the grant's scope).
    NotFound(String),
    /// The request was malformed (an invalid grant chain, a refused prompt).
    Invalid(String),
    /// Someone else holds the lease, or the state changed.
    Conflict(String),
    /// Anything else.
    Failed(String),
    /// The connection dropped before the answer arrived (client side only).
    Disconnected,
}

impl fmt::Display for MpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Forbidden(why) => write!(f, "forbidden: {why}"),
            Self::NotFound(what) => write!(f, "not found: {what}"),
            Self::Invalid(why) => write!(f, "invalid: {why}"),
            Self::Conflict(why) => write!(f, "conflict: {why}"),
            Self::Failed(why) => f.write_str(why),
            Self::Disconnected => f.write_str("disconnected before the daemon answered"),
        }
    }
}

impl std::error::Error for MpError {}

/// A connection's identity, sent as [`ServerCtl::Joined`](crate::ServerCtl::Joined) right
/// after `Welcome`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JoinInfo {
    /// The principal and device.
    pub actor: Actor,
    pub name: String,
    /// Effective roles.
    pub roles: Roles,
    /// Effective scope.
    pub scope: Scope,
    /// The leaf grant, `None` for a paired owner device.
    pub grant_id: Option<GrantId>,
    /// When the grant (or the earliest link of its chain) expires.
    pub expires: Option<UnixMillis>,
}

/// One connected device and what it is doing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Participant {
    pub actor: Actor,
    pub name: String,
    /// Effective roles.
    pub roles: Roles,
    /// Effective scope.
    pub scope: Scope,
    /// The grant, `None` for a paired owner device.
    pub grant_id: Option<GrantId>,
    /// When it connected.
    pub since: UnixMillis,
    pub state: PresenceState,
    /// The pane it focuses (hidden when outside the recipient's scope).
    pub focus: Option<PaneId>,
    /// Typing in an agent composer.
    pub typing: bool,
    /// Cursor, if shared.
    pub cursor: Option<CursorPos>,
}

/// A grant as the daemon tracks it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GrantInfo {
    pub grant: Grant,
    /// Its parent, for an attenuated grant.
    pub parent: Option<GrantId>,
    /// Devices that redeemed it.
    pub bound: Vec<DeviceId>,
    /// Revoked (itself or an ancestor).
    pub revoked: bool,
}

/// What kind of device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeviceKind {
    /// Paired with a pairing ticket: the owner principal, owner role.
    Owner,
    /// Joined with an invite.
    Guest,
}

/// A device the daemon knows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub device: DeviceId,
    /// The principal it acts as.
    pub principal: PrincipalId,
    pub kind: DeviceKind,
    pub name: String,
    /// First pairing or redemption.
    pub first_seen: UnixMillis,
    /// The grant it last joined with (guests).
    pub grant_id: Option<GrantId>,
    pub revoked: bool,
    /// Live connections.
    pub connected: u32,
}

/// What an audit record records.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AuditKind {
    /// A device connected.
    Join,
    /// A device disconnected.
    Leave,
    /// A device was paired with a pairing ticket.
    Paired,
    /// A grant was registered with the daemon.
    GrantRegistered,
    /// A device redeemed a grant for the first time (bound to it).
    GrantRedeemed,
    /// A grant, device or principal was revoked.
    Revoked,
    /// A pane's lease moved.
    Lease,
    /// A prompt was sent through the composer path (length and hash only, not the text).
    Prompt,
    /// An approval request was decided.
    Approval,
    /// A connection was refused or a request denied by policy.
    Denied,
    /// Someone knocked with a knock invite.
    Knock,
    /// An owner admitted or denied a knock.
    KnockAnswered,
    /// A session's approval policy changed.
    Policy,
    /// An approval request was claimed or released, or an approval was held for a second
    /// person.
    Claim,
}

/// A decided approval, as the audit log keeps it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalAudit {
    /// The daemon's request id.
    pub request_id: RequestId,
    /// The agent's own id for the blocked tool call (the arbiter's request id).
    pub agent_request: String,
    /// The chosen option.
    pub option_id: OptionId,
    /// Its label ("Yes", "No").
    pub option: String,
    /// The tool, e.g. `Bash`.
    pub tool: Option<String>,
    /// What the agent wanted to do.
    pub summary: String,
    /// The bytes the approver signed ([`approval_signing_bytes`]).
    #[serde(with = "crate::serde_bytes")]
    pub signed: Vec<u8>,
    /// The approver's Ed25519 signature over `signed`, by `actor.device`.
    #[serde(with = "crate::serde_bytes")]
    pub sig: Vec<u8>,
}

/// One append-only audit log record. `hash` is SHA-256 over `prev_hash` and the record's
/// other fields, so editing or dropping a record breaks the chain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditRecord {
    /// Position in the log, from 1.
    pub seq: u64,
    pub at: UnixMillis,
    pub kind: AuditKind,
    /// Who did it, if anyone.
    pub actor: Option<Actor>,
    /// The grant they acted under.
    pub grant_id: Option<GrantId>,
    /// The pane involved.
    pub pane_id: Option<PaneId>,
    /// One line for people.
    pub detail: String,
    /// The signed approval, for [`AuditKind::Approval`].
    pub approval: Option<ApprovalAudit>,
    /// The previous record's hash (zeroes for the first).
    #[serde(with = "crate::serde_bytes")]
    pub prev_hash: Vec<u8>,
    /// This record's hash.
    #[serde(with = "crate::serde_bytes")]
    pub hash: Vec<u8>,
}

/// Answer to [`MpRequest::Audit`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditPage {
    /// Records, oldest first.
    pub records: Vec<AuditRecord>,
    /// Records in the log.
    pub total: u64,
    /// The whole log's hash chain and approval signatures verified.
    pub chain_ok: bool,
}

/// How much of a pane's past a guest sees.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub enum History {
    /// Everything still in scrollback.
    #[default]
    Full,
    /// Only output written after the guest first joined: scrollback from before is withheld
    /// (snapshots, history pages, search, links and command output). The screen as it was at
    /// that moment stays visible, because it is the live session they join.
    SinceJoin,
}

/// Conditions the daemon enforces on an invite and every grant attenuated from it. The owner
/// (or the delegating holder) sets them when registering the invite
/// ([`MpRequest::RegisterInvite`]); they live in the daemon's grant table, not in the signed
/// grant, so a guest cannot strip them. A copy rides in the invite text
/// ([`Invite::to_string_with_terms`]) only so the join card can say what will happen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct InviteTerms {
    /// Redeeming does not join: it asks the owner, who admits with a role or denies
    /// ([`Knock`]).
    pub knock: bool,
    /// How much scrollback the guest sees.
    pub history: History,
}

impl InviteTerms {
    /// The format version of the terms appended to an invite's text.
    pub const VERSION: u16 = 1;
    /// Marks the start of the terms after an invite's bytes.
    const MAGIC: u8 = 0xE9;

    /// The stricter of two sets of terms: a child can only add conditions.
    #[must_use]
    pub fn strictest(self, other: Self) -> Self {
        let since_join = self.history == History::SinceJoin || other.history == History::SinceJoin;
        Self {
            knock: self.knock || other.knock,
            history: if since_join {
                History::SinceJoin
            } else {
                History::Full
            },
        }
    }
}

impl Invite {
    /// The invite's text with `terms` appended for the join card. Readers that predate terms
    /// ignore the trailing bytes, as with [`TicketExtras`](crate::TicketExtras); default terms
    /// append nothing.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::{DaemonId, GrantChain, History, Invite, InviteTerms};
    ///
    /// let invite = Invite {
    ///     v: Invite::VERSION,
    ///     daemon_id: DaemonId([7; 32]),
    ///     addrs: vec![],
    ///     relay_url: None,
    ///     inviter: "alice".into(),
    ///     chain: GrantChain { links: vec![] },
    /// };
    /// let terms = InviteTerms { knock: true, history: History::SinceJoin };
    /// let text = invite.to_string_with_terms(terms);
    /// assert_eq!(Invite::parse_with_terms(&text)?, (invite.clone(), terms));
    /// // Older readers still parse it.
    /// assert_eq!(text.parse::<Invite>()?, invite);
    /// # Ok::<(), proto::TicketError>(())
    /// ```
    pub fn to_string_with_terms(&self, terms: InviteTerms) -> String {
        if terms == InviteTerms::default() {
            return self.to_string();
        }
        let mut bytes = postcard::to_stdvec(self).expect("invites always encode");
        bytes.push(InviteTerms::MAGIC);
        bytes.extend(
            postcard::to_stdvec(&(InviteTerms::VERSION, terms)).expect("terms always encode"),
        );
        format!("{}{}", Self::prefix(), BASE32_NOPAD.encode(&bytes))
    }

    /// Parses an invite and the terms appended to it (default terms when there are none, or
    /// when they are of a newer version).
    ///
    /// # Errors
    ///
    /// As [`Invite::from_str`].
    pub fn parse_with_terms(text: &str) -> Result<(Self, InviteTerms), TicketError> {
        let invite: Self = text.parse()?;
        let bytes = invite_bytes(text)?;
        let (_, rest) = postcard::take_from_bytes::<Self>(&bytes).map_err(TicketError::Decode)?;
        let terms = match rest.split_first() {
            Some((&InviteTerms::MAGIC, terms_bytes)) => {
                postcard::from_bytes::<(u16, InviteTerms)>(terms_bytes)
                    .ok()
                    .filter(|(version, _)| *version == InviteTerms::VERSION)
                    .map(|(_, terms)| terms)
                    .unwrap_or_default()
            }
            _ => InviteTerms::default(),
        };
        Ok((invite, terms))
    }
}

/// The base32 payload of an invite's text, decoded.
fn invite_bytes(text: &str) -> Result<Vec<u8>, TicketError> {
    let text = text.trim();
    let payload = crate::ticket::link_payload(text, "join").unwrap_or(text);
    let cleaned: String = payload
        .chars()
        .filter(|ch| !ch.is_whitespace())
        .map(|ch| ch.to_ascii_uppercase())
        .collect();
    BASE32_NOPAD
        .decode(cleaned.as_bytes())
        .map_err(|_| TicketError::Encoding)
}

/// Identifies a pending knock on one daemon run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct KnockId(pub u64);

impl fmt::Display for KnockId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Someone holding a knock invite asks to join.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Knock {
    pub knock_id: KnockId,
    /// Who knocks (their guest principal and device).
    pub actor: Actor,
    /// The name they gave, or the invite's label.
    pub name: String,
    /// The invite (leaf grant) they knock with.
    pub grant_id: GrantId,
    /// The roles the invite offers; the owner may admit with others.
    pub roles: Roles,
    /// What they would join.
    pub scope: Scope,
    /// When they knocked.
    pub at: UnixMillis,
}

/// How a knock ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum KnockOutcome {
    /// An owner let them in with these roles.
    Admitted {
        /// The roles granted.
        roles: Roles,
    },
    /// An owner said no.
    Denied,
    /// They stopped waiting (disconnected).
    Withdrawn,
}

/// A change to the pending knocks, sent to owner devices with
/// [`Caps::KNOCK`](crate::Caps::KNOCK).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum KnockUpdate {
    /// Someone knocks (or a knock changed, e.g. its name): replace any entry with this id.
    Added(Knock),
    /// A knock is no longer pending.
    Gone {
        knock_id: KnockId,
        outcome: KnockOutcome,
        /// Who answered it, for admitted and denied knocks.
        by: Option<Actor>,
    },
}

/// What the knocking connection hears
/// ([`ServerCtl::KnockAnswer`](crate::ServerCtl::KnockAnswer)).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum KnockAnswer {
    /// The owner has been asked; keep the connection open.
    Waiting { knock_id: KnockId },
    /// Admitted: a grant chain bound to this device, signed by the daemon. Reconnect with it
    /// (`SignedGrant::CHAIN`); the daemon closes this connection.
    Admitted(GrantChain),
    /// Refused; the daemon closes this connection.
    Denied,
}

/// An owner's "Admit as…" for a knock.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Admit {
    /// Roles to grant (within the knock invite's scope).
    pub roles: Roles,
    /// How much scrollback they see.
    pub history: History,
    /// When their access ends; `None` takes the daemon's default (7 days).
    pub expires: Option<UnixMillis>,
}

/// How risky an agent's tool call is, for [`ApprovalPolicy::max_risk`]. Ordered: a cap
/// allows everything up to and including it.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default, Serialize, Deserialize,
)]
pub enum Risk {
    /// Reads files or the web; changes nothing.
    ReadOnly,
    /// Edits files in the workspace.
    Edits,
    /// Runs commands, or anything not known to be safer.
    #[default]
    Any,
}

impl Risk {
    /// Classifies a tool by name (Claude Code's and Codex's tools; case-insensitive).
    /// Unknown or missing tools are [`Risk::Any`].
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::Risk;
    ///
    /// assert_eq!(Risk::of_tool(Some("Read")), Risk::ReadOnly);
    /// assert_eq!(Risk::of_tool(Some("MultiEdit")), Risk::Edits);
    /// assert_eq!(Risk::of_tool(Some("Bash")), Risk::Any);
    /// assert_eq!(Risk::of_tool(None), Risk::Any);
    /// ```
    pub fn of_tool(tool: Option<&str>) -> Self {
        const READ_ONLY: &[&str] = &[
            "read",
            "glob",
            "grep",
            "ls",
            "webfetch",
            "websearch",
            "web_search",
            "notebookread",
            "todoread",
            "todowrite",
            "view_image",
        ];
        const EDITS: &[&str] = &[
            "edit",
            "multiedit",
            "write",
            "notebookedit",
            "apply_patch",
            "applypatch",
        ];
        let Some(tool) = tool.map(|name| name.trim().to_ascii_lowercase()) else {
            return Self::Any;
        };
        if READ_ONLY.contains(&tool.as_str()) {
            Self::ReadOnly
        } else if EDITS.contains(&tool.as_str()) {
            Self::Edits
        } else {
            Self::Any
        }
    }
}

impl fmt::Display for Risk {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ReadOnly => "read-only",
            Self::Edits => "edits",
            Self::Any => "commands",
        })
    }
}

/// Who may answer a session's agent approvals.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub enum ApprovalMode {
    /// Any approver; the first valid decision wins.
    #[default]
    AnyApprover,
    /// Only owners answer.
    OwnerOnly,
    /// Allowing a [`Risk::Any`] call needs two different people; the agent stays blocked
    /// until the second approves. One "deny" ends it.
    TwoPerson,
    /// An approver claims a request ("I'll take this one"); then only they (or an owner)
    /// answer it, and its notification is withdrawn for everyone else.
    Claim,
}

/// A session's approval rules. Owners are never held back by `max_risk`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct ApprovalPolicy {
    /// Who may answer.
    pub mode: ApprovalMode,
    /// The riskiest call a non-owner approver may allow; above it only an owner can (anyone
    /// with the approver role may still deny).
    pub max_risk: Risk,
}

/// One person's part in an approval: an approval cast, or a claim.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalVote {
    pub actor: Actor,
    /// Their display name.
    pub name: String,
    pub at: UnixMillis,
}

/// Where an open approval request stands under its session's policy. Sent while it is open,
/// whenever a vote or claim changes, to clients with
/// [`Caps::APPROVAL_POLICY`](crate::Caps::APPROVAL_POLICY).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalStatus {
    /// The agent's pane.
    pub pane_id: PaneId,
    pub request_id: RequestId,
    /// The call's risk class.
    pub risk: Risk,
    /// The session's mode.
    pub mode: ApprovalMode,
    /// Approvals cast that have not decided yet (two-person rule).
    pub approvals: Vec<ApprovalVote>,
    /// Distinct approvals an "allow" needs (2 under the two-person rule for risky calls).
    pub needed: u8,
    /// Who claimed it.
    pub claimed_by: Option<ApprovalVote>,
}

/// Something about the host's access control its owner should know and act on. Sent to owner
/// devices with [`Caps::HOST_ALERTS`](crate::Caps::HOST_ALERTS) when they connect, while it
/// stands.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostAlert {
    /// What happened.
    pub kind: HostAlertKind,
    pub at: UnixMillis,
    /// One line for a notification.
    pub title: String,
    /// What it means and what to do.
    pub body: String,
}

/// Kinds of [`HostAlert`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HostAlertKind {
    /// The grant store could not be read at startup. It was kept aside, and every invite
    /// issued before then is refused, since its revocations and use counts are unknown.
    GrantStoreReset,
}
