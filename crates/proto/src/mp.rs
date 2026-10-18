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
    /// One pane.
    Pane(PaneId),
}

impl fmt::Display for Scope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Daemon => f.write_str("daemon"),
            Self::Session(s) => write!(f, "session:{s}"),
            Self::Tab(t) => write!(f, "tab:{t}"),
            Self::Pane(p) => write!(f, "pane:{p}"),
        }
    }
}

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
        let mut out = Self::SIGNING_CONTEXT.to_vec();
        out.extend(postcard::to_stdvec(self).expect("grants always encode"));
        out
    }
}

/// A grant and its issuer's signature.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GrantLink {
    /// The grant.
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
        self.links.last().map(|l| &l.grant)
    }

    /// The leaf's id, or all zeroes for an empty chain.
    pub fn grant_id(&self) -> GrantId {
        self.leaf().map_or(GrantId([0; 16]), |g| g.grant_id)
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

impl fmt::Display for Invite {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bytes = postcard::to_stdvec(self).map_err(|_| fmt::Error)?;
        write!(f, "{}{}", Self::prefix(), BASE32_NOPAD.encode(&bytes))
    }
}

impl FromStr for Invite {
    type Err = TicketError;

    /// Parses the URL form (also with `#` instead of `/` before the payload, so the payload
    /// can travel in a URL fragment) or the bare base32. Whitespace and case are ignored.
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let s = s.trim();
        let prefix = Self::prefix();
        let head = &prefix[..prefix.len() - 1];
        let payload = match s.get(..head.len()) {
            Some(h) if h.eq_ignore_ascii_case(head) => s[head.len()..]
                .strip_prefix(['/', '#'])
                .ok_or(TicketError::Encoding)?,
            _ => s,
        };
        let cleaned: String = payload
            .chars()
            .filter(|c| !c.is_whitespace())
            .map(|c| c.to_ascii_uppercase())
            .collect();
        let bytes = BASE32_NOPAD
            .decode(cleaned.as_bytes())
            .map_err(|_| TicketError::Encoding)?;
        let (v, _) = postcard::take_from_bytes::<u16>(&bytes).map_err(TicketError::Decode)?;
        if v != Self::VERSION {
            return Err(TicketError::Version(v));
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
    let mut out = b"approval-v1\0".to_vec();
    out.extend(
        postcard::to_stdvec(&(daemon, request_id, option_id, actor))
            .expect("approvals always encode"),
    );
    out
}

// ---------------------------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------------------------

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
        /// The pane.
        pane_id: PaneId,
        /// Take it now, whatever the holder is doing.
        force: bool,
    },
    /// Gives up the lease → [`MpResponse::Done`].
    ReleaseControl {
        /// The pane.
        pane_id: PaneId,
    },
    /// The holder answers a pending take-control request → [`MpResponse::Lease`].
    AnswerControl {
        /// The pane.
        pane_id: PaneId,
        /// Hand it over (`true`) or keep it.
        give: bool,
    },
    /// The holder or an owner hands the lease to a principal → [`MpResponse::Lease`].
    GiveControl {
        /// The pane.
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
    SetName {
        /// The name.
        name: String,
    },
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
    /// A grant.
    Grant(GrantInfo),
    /// Grants.
    Grants(Vec<GrantInfo>),
    /// Devices.
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
    /// Leases.
    Leases(Vec<Lease>),
    /// A prompt was written.
    Prompted {
        /// Characters sent.
        chars: u32,
    },
    /// Audit records.
    Audit(AuditPage),
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

// ---------------------------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------------------------

/// A connection's identity, sent as [`ServerCtl::Joined`](crate::ServerCtl::Joined) right
/// after `Welcome`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JoinInfo {
    /// The principal and device.
    pub actor: Actor,
    /// Display name.
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Participant {
    /// Who.
    pub actor: Actor,
    /// Display name.
    pub name: String,
    /// Effective roles.
    pub roles: Roles,
    /// Effective scope.
    pub scope: Scope,
    /// The grant, `None` for a paired owner device.
    pub grant_id: Option<GrantId>,
    /// When it connected.
    pub since: UnixMillis,
    /// Activity.
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
    /// The grant.
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
    /// The key.
    pub device: DeviceId,
    /// The principal it acts as.
    pub principal: PrincipalId,
    /// Owner or guest.
    pub kind: DeviceKind,
    /// Display name.
    pub name: String,
    /// First pairing or redemption.
    pub first_seen: UnixMillis,
    /// The grant it last joined with (guests).
    pub grant_id: Option<GrantId>,
    /// Revoked.
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
    /// When.
    pub at: UnixMillis,
    /// What.
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
