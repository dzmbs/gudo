//! control leases, composer prompts, grants, revocation and the audit log.
//!
//! Join with [`DaemonClient::join`] (an invite link or QR code). Keys and ids of principals,
//! devices and grants cross as lowercase hex strings.

use std::sync::Arc;

use client_core::grants::GrantSpec;
use client_core::proto;

use crate::bytes::Bytes;
use crate::client::{ClientError, DaemonClient};
use crate::on_runtime;

// --- hex ids --------------------------------------------------------------------------------

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub(crate) fn unhex<const N: usize>(what: &str, text: &str) -> Result<[u8; N], MultiplayerError> {
    let text = text.trim();
    let invalid = || MultiplayerError::Invalid {
        message: format!("{what}: expected {} hex digits, got {text:?}", N * 2),
    };
    if text.len() != N * 2 || !text.is_ascii() {
        return Err(invalid());
    }
    let mut out = [0; N];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).map_err(|_| invalid())?;
    }
    Ok(out)
}

// --- errors ---------------------------------------------------------------------------------

/// Why a multiplayer request failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum MultiplayerError {
    /// The connection's roles or scope do not allow it (the message names the role).
    #[error("forbidden: {message}")]
    Forbidden {
        /// Why.
        message: String,
    },
    /// No such pane, grant or device (or outside the scope).
    #[error("not found: {message}")]
    NotFound {
        /// What.
        message: String,
    },
    /// Malformed: a wider child grant, a refused prompt, a bad id.
    #[error("invalid: {message}")]
    Invalid {
        /// Why.
        message: String,
    },
    /// Someone else holds the lease, or the state changed.
    #[error("conflict: {message}")]
    Conflict {
        /// Why.
        message: String,
    },
    /// Anything else.
    #[error("{message}")]
    Failed {
        /// Why.
        message: String,
    },
    /// The connection dropped before the daemon answered.
    #[error("disconnected before the daemon answered")]
    Disconnected,
}

impl From<proto::MpError> for MultiplayerError {
    fn from(e: proto::MpError) -> Self {
        use proto::MpError as E;
        match e {
            E::Forbidden(message) => Self::Forbidden { message },
            E::NotFound(message) => Self::NotFound { message },
            E::Invalid(message) => Self::Invalid { message },
            E::Conflict(message) => Self::Conflict { message },
            E::Failed(message) => Self::Failed { message },
            E::Disconnected => Self::Disconnected,
        }
    }
}

// --- types ----------------------------------------------------------------------------------

/// A role a grant confers. Owner implies every other role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Role {
    /// Sees output, scrollback and agent state.
    Viewer,
    /// Sends prompts to agents through the composer.
    Prompter,
    /// Types (holding the lease), resizes, takes control.
    Driver,
    /// Answers agent approvals.
    Approver,
    /// Everything, plus grants and killing panes.
    Owner,
}

const ROLES: [(Role, proto::Roles); 5] = [
    (Role::Viewer, proto::Roles::VIEWER),
    (Role::Prompter, proto::Roles::PROMPTER),
    (Role::Driver, proto::Roles::DRIVER),
    (Role::Approver, proto::Roles::APPROVER),
    (Role::Owner, proto::Roles::OWNER),
];

pub(crate) fn roles_to_ffi(roles: proto::Roles) -> Vec<Role> {
    ROLES
        .iter()
        .filter(|(_, bit)| roles.contains(*bit))
        .map(|(r, _)| *r)
        .collect()
}

pub(crate) fn roles_from_ffi(roles: &[Role]) -> proto::Roles {
    ROLES
        .iter()
        .filter(|(r, _)| roles.contains(r))
        .fold(proto::Roles::EMPTY, |acc, (_, bit)| acc | *bit)
}

/// What a grant covers: `daemon ⊇ session ⊇ tab ⊇ pane`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Scope {
    /// Every session, and host-wide requests (files, git, forwards).
    Daemon,
    /// One session.
    Session {
        /// The session.
        session_id: u64,
    },
    /// One tab.
    Tab {
        /// The tab.
        tab_id: u64,
    },
    /// One pane.
    Pane {
        /// The pane.
        pane_id: u64,
    },
}

impl From<proto::Scope> for Scope {
    fn from(s: proto::Scope) -> Self {
        match s {
            proto::Scope::Daemon => Self::Daemon,
            proto::Scope::Session(s) => Self::Session { session_id: s.0 },
            proto::Scope::Tab(t) => Self::Tab { tab_id: t.0 },
            proto::Scope::Pane(p) => Self::Pane { pane_id: p.0 },
        }
    }
}

impl From<Scope> for proto::Scope {
    fn from(s: Scope) -> Self {
        match s {
            Scope::Daemon => Self::Daemon,
            Scope::Session { session_id } => Self::Session(proto::SessionId(session_id)),
            Scope::Tab { tab_id } => Self::Tab(proto::TabId(tab_id)),
            Scope::Pane { pane_id } => Self::Pane(proto::PaneId(pane_id)),
        }
    }
}

/// Who did something: a principal (person) and the device.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct Actor {
    /// Principal id, 32 hex digits.
    pub principal: String,
    /// Device key, 64 hex digits.
    pub device: String,
}

impl From<proto::Actor> for Actor {
    fn from(a: proto::Actor) -> Self {
        Self {
            principal: hex(&a.principal.0),
            device: hex(&a.device.0),
        }
    }
}

/// This connection's identity.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct JoinInfo {
    /// Principal and device.
    pub actor: Actor,
    /// Display name.
    pub name: String,
    /// Effective roles.
    pub roles: Vec<Role>,
    /// Effective scope.
    pub scope: Scope,
    /// The leaf grant; `nil` for a paired owner device.
    pub grant_id: Option<String>,
    /// When the grant expires, Unix ms.
    pub expires_ms: Option<u64>,
}

impl From<proto::JoinInfo> for JoinInfo {
    fn from(i: proto::JoinInfo) -> Self {
        Self {
            actor: i.actor.into(),
            name: i.name,
            roles: roles_to_ffi(i.roles),
            scope: i.scope.into(),
            grant_id: i.grant_id.map(|g| hex(&g.0)),
            expires_ms: i.expires.map(|e| e.0),
        }
    }
}

/// Activity level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PresenceState {
    /// Interacting now.
    Active,
    /// Connected, idle.
    Idle,
    /// Disconnected within the grace period.
    Away,
}

impl From<proto::PresenceState> for PresenceState {
    fn from(s: proto::PresenceState) -> Self {
        match s {
            proto::PresenceState::Active => Self::Active,
            proto::PresenceState::Idle => Self::Idle,
            proto::PresenceState::Away => Self::Away,
        }
    }
}

/// A shared cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct CursorPos {
    /// The pane.
    pub pane_id: u64,
    /// Row within the viewport.
    pub row: u16,
    /// Column.
    pub col: u16,
}

impl From<proto::CursorPos> for CursorPos {
    fn from(c: proto::CursorPos) -> Self {
        Self {
            pane_id: c.pane_id.0,
            row: c.row,
            col: c.col,
        }
    }
}

/// One connected device.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Participant {
    /// Who.
    pub actor: Actor,
    /// Display name.
    pub name: String,
    /// Effective roles.
    pub roles: Vec<Role>,
    /// Effective scope.
    pub scope: Scope,
    /// The grant; `nil` for an owner device.
    pub grant_id: Option<String>,
    /// Connected since, Unix ms.
    pub since_ms: u64,
    /// Activity.
    pub state: PresenceState,
    /// Focused pane.
    pub focus: Option<u64>,
    /// Typing in an agent composer.
    pub typing: bool,
    /// Cursor, if shared.
    pub cursor: Option<CursorPos>,
}

impl From<proto::Participant> for Participant {
    fn from(p: proto::Participant) -> Self {
        Self {
            actor: p.actor.into(),
            name: p.name,
            roles: roles_to_ffi(p.roles),
            scope: p.scope.into(),
            grant_id: p.grant_id.map(|g| hex(&g.0)),
            since_ms: p.since.0,
            state: p.state.into(),
            focus: p.focus.map(|f| f.0),
            typing: p.typing,
            cursor: p.cursor.map(Into::into),
        }
    }
}

/// Another participant's presence update.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Presence {
    /// Who.
    pub actor: Actor,
    /// Activity.
    pub state: PresenceState,
    /// Focused pane.
    pub focus: Option<u64>,
    /// Typing in an agent composer.
    pub typing: bool,
    /// Cursor, if shared.
    pub cursor: Option<CursorPos>,
}

impl From<proto::Presence> for Presence {
    fn from(p: proto::Presence) -> Self {
        Self {
            actor: p.actor.into(),
            state: p.state.into(),
            focus: p.focus.map(|f| f.0),
            typing: p.typing,
            cursor: p.cursor.map(Into::into),
        }
    }
}

/// Input arbitration on a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LeaseMode {
    /// Any driver may type.
    Free,
    /// Only the holder types.
    Leased,
}

/// A pane's control lease.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Lease {
    /// The pane.
    pub pane_id: u64,
    /// The holding principal; `nil` when free.
    pub holder: Option<String>,
    /// Held since, Unix ms.
    pub since_ms: u64,
    /// Mode.
    pub mode: LeaseMode,
}

impl From<proto::Lease> for Lease {
    fn from(l: proto::Lease) -> Self {
        Self {
            pane_id: l.pane_id.0,
            holder: l.holder.map(|h| hex(&h.0)),
            since_ms: l.since.0,
            mode: match l.mode {
                proto::LeaseMode::Free => LeaseMode::Free,
                proto::LeaseMode::Leased => LeaseMode::Leased,
            },
        }
    }
}

/// The answer to take / give / answer control.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LeaseOutcome {
    /// Held now.
    Granted {
        /// The lease.
        lease: Lease,
    },
    /// The holder was asked; it moves when they give it or go idle.
    Pending {
        /// The current holder.
        holder: String,
    },
    /// The holder kept it.
    Kept {
        /// The lease.
        lease: Lease,
    },
}

impl From<proto::LeaseOutcome> for LeaseOutcome {
    fn from(o: proto::LeaseOutcome) -> Self {
        match o {
            proto::LeaseOutcome::Granted(lease) => Self::Granted {
                lease: lease.into(),
            },
            proto::LeaseOutcome::Pending { holder } => Self::Pending {
                holder: hex(&holder.0),
            },
            proto::LeaseOutcome::Kept(lease) => Self::Kept {
                lease: lease.into(),
            },
        }
    }
}

/// Why input was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum InputRejectReason {
    /// Someone else holds the lease.
    NoLease,
    /// The roles do not allow this input (a viewer typing).
    Role,
    /// Refused by policy.
    Blocked,
    /// No such pane in scope.
    UnknownPane,
}

impl From<proto::InputRejectReason> for InputRejectReason {
    fn from(r: proto::InputRejectReason) -> Self {
        match r {
            proto::InputRejectReason::NoLease => Self::NoLease,
            proto::InputRejectReason::Role => Self::Role,
            proto::InputRejectReason::Blocked => Self::Blocked,
            proto::InputRejectReason::UnknownPane => Self::UnknownPane,
        }
    }
}

/// A decided approval.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Decided {
    /// The agent's pane.
    pub pane_id: u64,
    /// The request.
    pub request_id: u64,
    /// The winning option.
    pub option_id: u32,
    /// Who decided.
    pub decided_by: Actor,
    /// When, Unix ms.
    pub at_ms: u64,
}

impl From<proto::Decided> for Decided {
    fn from(d: proto::Decided) -> Self {
        Self {
            pane_id: d.pane_id.0,
            request_id: d.request_id.0,
            option_id: d.option_id.0,
            decided_by: d.decided_by.into(),
            at_ms: d.at.0,
        }
    }
}

/// A grant.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Grant {
    /// Its id.
    pub grant_id: String,
    /// The signing device.
    pub issuer: String,
    /// Roles.
    pub roles: Vec<Role>,
    /// Scope.
    pub scope: Scope,
    /// Signed at, Unix ms.
    pub issued_at_ms: u64,
    /// Expiry, Unix ms.
    pub expires_ms: Option<u64>,
    /// Distinct devices that may redeem it.
    pub max_uses: Option<u32>,
    /// The only device that may present it.
    pub bind: Option<String>,
    /// The holder may delegate narrower grants.
    pub delegate: bool,
    /// Who it is for.
    pub label: String,
}

impl From<proto::Grant> for Grant {
    fn from(g: proto::Grant) -> Self {
        Self {
            grant_id: hex(&g.grant_id.0),
            issuer: hex(&g.issuer.0),
            roles: roles_to_ffi(g.roles),
            scope: g.scope.into(),
            issued_at_ms: g.issued_at.0,
            expires_ms: g.expires.map(|e| e.0),
            max_uses: g.max_uses,
            bind: g.bind.map(|d| hex(&d.0)),
            delegate: g.delegate,
            label: g.label,
        }
    }
}

/// A grant as the daemon tracks it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GrantInfo {
    /// The grant.
    pub grant: Grant,
    /// Its parent, for an attenuated grant.
    pub parent: Option<String>,
    /// Devices that redeemed it.
    pub bound: Vec<String>,
    /// Revoked (itself or an ancestor).
    pub revoked: bool,
}

impl From<proto::GrantInfo> for GrantInfo {
    fn from(g: proto::GrantInfo) -> Self {
        Self {
            grant: g.grant.into(),
            parent: g.parent.map(|p| hex(&p.0)),
            bound: g.bound.iter().map(|d| hex(&d.0)).collect(),
            revoked: g.revoked,
        }
    }
}

/// Owner or guest device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum DeviceKind {
    /// Paired with a pairing ticket.
    Owner,
    /// Joined with an invite.
    Guest,
}

/// Something about a host's access control its owner should act on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostAlert {
    /// What happened.
    pub kind: HostAlertKind,
    /// When, Unix ms; identifies the alert.
    pub at_ms: u64,
    /// One line for a notification.
    pub title: String,
    /// What it means and what to do.
    pub body: String,
}

/// Kinds of [`HostAlert`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HostAlertKind {
    /// The grant store could not be read; earlier invites no longer work.
    GrantStoreReset,
}

impl From<proto::HostAlert> for HostAlert {
    fn from(a: proto::HostAlert) -> Self {
        Self {
            kind: match a.kind {
                proto::HostAlertKind::GrantStoreReset => HostAlertKind::GrantStoreReset,
            },
            at_ms: a.at.0,
            title: a.title,
            body: a.body,
        }
    }
}

/// A device the daemon knows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeviceInfo {
    /// The key.
    pub device: String,
    /// Its principal.
    pub principal: String,
    /// Owner or guest.
    pub kind: DeviceKind,
    /// Display name.
    pub name: String,
    /// First seen, Unix ms.
    pub first_seen_ms: u64,
    /// The grant it last joined with.
    pub grant_id: Option<String>,
    /// Revoked.
    pub revoked: bool,
    /// Live connections.
    pub connected: u32,
}

impl From<proto::DeviceInfo> for DeviceInfo {
    fn from(d: proto::DeviceInfo) -> Self {
        Self {
            device: hex(&d.device.0),
            principal: hex(&d.principal.0),
            kind: match d.kind {
                proto::DeviceKind::Owner => DeviceKind::Owner,
                proto::DeviceKind::Guest => DeviceKind::Guest,
            },
            name: d.name,
            first_seen_ms: d.first_seen.0,
            grant_id: d.grant_id.map(|g| hex(&g.0)),
            revoked: d.revoked,
            connected: d.connected,
        }
    }
}

/// What to revoke (hex ids).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RevokeTarget {
    /// A grant and everything attenuated from it.
    Grant {
        /// Grant id.
        grant_id: String,
    },
    /// A device: its pairing and every grant it holds or issued.
    Device {
        /// Device key.
        device: String,
    },
    /// Every device and grant of a principal.
    Principal {
        /// Principal id.
        principal: String,
    },
}

impl TryFrom<RevokeTarget> for proto::RevokeTarget {
    type Error = MultiplayerError;

    fn try_from(t: RevokeTarget) -> Result<Self, Self::Error> {
        Ok(match t {
            RevokeTarget::Grant { grant_id } => {
                Self::Grant(proto::GrantId(unhex("grant id", &grant_id)?))
            }
            RevokeTarget::Device { device } => {
                Self::Device(proto::DeviceId(unhex("device", &device)?))
            }
            RevokeTarget::Principal { principal } => {
                Self::Principal(proto::PrincipalId(unhex("principal", &principal)?))
            }
        })
    }
}

/// What a revocation hit.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RevokeResult {
    /// Grants now revoked.
    pub grants: Vec<String>,
    /// Devices now revoked.
    pub devices: Vec<String>,
    /// Connections closed.
    pub disconnected: u32,
}

/// What an audit record records.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AuditKind {
    /// Connected.
    Join,
    /// Disconnected.
    Leave,
    /// Paired with a ticket.
    Paired,
    /// A grant was registered.
    GrantRegistered,
    /// A grant was first redeemed.
    GrantRedeemed,
    /// Something was revoked.
    Revoked,
    /// A lease moved.
    Lease,
    /// A composer prompt (length and hash only).
    Prompt,
    /// An approval was decided.
    Approval,
    /// Refused by policy.
    Denied,
    /// Someone knocked with a knock invite.
    Knock,
    /// An owner admitted or turned away a knock (or the knocker left).
    KnockAnswered,
    /// A session's approval rules changed.
    Policy,
    /// An approval request was claimed or released.
    Claim,
}

impl From<proto::AuditKind> for AuditKind {
    fn from(k: proto::AuditKind) -> Self {
        use proto::AuditKind as K;
        match k {
            K::Join => Self::Join,
            K::Leave => Self::Leave,
            K::Paired => Self::Paired,
            K::GrantRegistered => Self::GrantRegistered,
            K::GrantRedeemed => Self::GrantRedeemed,
            K::Revoked => Self::Revoked,
            K::Lease => Self::Lease,
            K::Prompt => Self::Prompt,
            K::Approval => Self::Approval,
            K::Denied => Self::Denied,
            K::Knock => Self::Knock,
            K::KnockAnswered => Self::KnockAnswered,
            K::Policy => Self::Policy,
            K::Claim => Self::Claim,
        }
    }
}

/// A signed approval in the audit log.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApprovalAudit {
    /// The daemon's request id.
    pub request_id: u64,
    /// The agent's own id for the tool call.
    pub agent_request: String,
    /// The chosen option.
    pub option_id: u32,
    /// Its label.
    pub option: String,
    /// The tool.
    pub tool: Option<String>,
    /// What the agent wanted.
    pub summary: String,
    /// The signed bytes.
    pub signed: Bytes,
    /// The approver's Ed25519 signature.
    pub sig: Bytes,
}

/// One audit record.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AuditRecord {
    /// Position, from 1.
    pub seq: u64,
    /// When, Unix ms.
    pub at_ms: u64,
    /// What.
    pub kind: AuditKind,
    /// Who.
    pub actor: Option<Actor>,
    /// Under which grant.
    pub grant_id: Option<String>,
    /// The pane.
    pub pane_id: Option<u64>,
    /// One line for people.
    pub detail: String,
    /// The signed approval.
    pub approval: Option<ApprovalAudit>,
    /// Previous record's hash.
    pub prev_hash: Bytes,
    /// This record's hash.
    pub hash: Bytes,
}

/// A page of the audit log.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AuditPage {
    /// Records, oldest first.
    pub records: Vec<AuditRecord>,
    /// Records in the log.
    pub total: u64,
    /// The whole chain and every approval signature verified.
    pub chain_ok: bool,
}

impl From<proto::AuditPage> for AuditPage {
    fn from(p: proto::AuditPage) -> Self {
        Self {
            total: p.total,
            chain_ok: p.chain_ok,
            records: p
                .records
                .into_iter()
                .map(|r| AuditRecord {
                    seq: r.seq,
                    at_ms: r.at.0,
                    kind: r.kind.into(),
                    actor: r.actor.map(Into::into),
                    grant_id: r.grant_id.map(|g| hex(&g.0)),
                    pane_id: r.pane_id.map(|p| p.0),
                    detail: r.detail,
                    approval: r.approval.map(|a| ApprovalAudit {
                        request_id: a.request_id.0,
                        agent_request: a.agent_request,
                        option_id: a.option_id.0,
                        option: a.option,
                        tool: a.tool,
                        summary: a.summary,
                        signed: a.signed.into(),
                        sig: a.sig.into(),
                    }),
                    prev_hash: r.prev_hash.into(),
                    hash: r.hash.into(),
                })
                .collect(),
        }
    }
}

/// What an invite grants.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct InviteOptions {
    /// Roles (e.g. `[.driver, .approver]` for a pair, `[.viewer]` to watch).
    pub roles: Vec<Role>,
    /// What it covers.
    pub scope: Scope,
    /// Valid for this long; `nil` never expires (a guest's child is capped at its parent's).
    #[uniffi(default = None)]
    pub ttl_secs: Option<u64>,
    /// Distinct devices that may redeem it; `nil` is unlimited.
    pub max_uses: Option<u32>,
    /// The guest may delegate narrower invites.
    #[uniffi(default = false)]
    pub delegate: bool,
    /// Who it is for, shown to the others ("Bob").
    pub label: String,
    /// Who invites, for the join card.
    pub inviter: String,
    /// Joining asks the owner first (knock to join).
    #[uniffi(default = false)]
    pub knock: bool,
    /// The guest sees scrollback only from when they joined.
    #[uniffi(default = false)]
    pub since_join: bool,
}

/// A created invite.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CreatedInvite {
    /// The link (`unnamed://join/…`) to share.
    pub link: String,
    /// The text to encode as a QR code: the link upper-cased, so the code can use the
    /// compact alphanumeric mode (parsing ignores case).
    pub qr_payload: String,
    /// The leaf grant (for `revoke`).
    pub grant_id: String,
    /// Expiry, Unix ms.
    pub expires_ms: Option<u64>,
}

/// A multiplayer push.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MultiplayerEvent {
    /// Who this connection is (after every handshake).
    Joined {
        /// Identity, roles, scope.
        info: JoinInfo,
    },
    /// Everyone connected (the whole list).
    Participants {
        /// One per device.
        participants: Vec<Participant>,
    },
    /// Another participant's presence (typing, focus, cursor).
    Presence {
        /// The update.
        presence: Presence,
    },
    /// A pane's lease changed.
    Lease {
        /// The lease.
        lease: Lease,
    },
    /// Someone asks for a lease this principal holds: answer with `answer_control`.
    LeaseRequested {
        /// The pane.
        pane_id: u64,
        /// Who.
        by: Actor,
        /// Their name.
        name: String,
    },
    /// Input was refused.
    InputRejected {
        /// The pane.
        pane_id: u64,
        /// Why.
        reason: InputRejectReason,
    },
    /// A request was refused by policy.
    Forbidden {
        /// What.
        what: String,
        /// Why (names the missing role).
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
        request_id: u64,
        /// Who won.
        by: Actor,
    },
    /// This connection's grant was revoked; the daemon closes it.
    Revoked,
    /// Another owner device just paired with the host (owner devices only): say so, so a
    /// pairing the owner did not make is noticed and revoked.
    DevicePaired {
        /// The new device.
        device: DeviceInfo,
    },
    /// The host's access control needs its owner (owner devices only). Sent on every
    /// connection while it stands: notify once per `at_ms`.
    HostAlert {
        /// The alert.
        alert: HostAlert,
    },
    /// Someone knocked, or a knock changed (owner devices): replace any entry with its id.
    KnockAdded {
        /// The knock.
        knock: crate::mp2::Knock,
    },
    /// A knock is no longer waiting.
    KnockGone {
        /// The knock.
        knock_id: u64,
        /// How it ended.
        outcome: crate::mp2::KnockOutcome,
        /// Who answered it.
        by: Option<Actor>,
    },
    /// The attached session's approval rules (after attaching and on every change).
    ApprovalPolicy {
        /// The session.
        session_id: u64,
        /// The rules.
        policy: crate::mp2::ApprovalPolicy,
    },
    /// An open approval request's votes or claim changed.
    ApprovalStatus {
        /// Where it stands.
        status: crate::mp2::ApprovalStatus,
    },
    /// Everyone's live presence, whole (after joining, when someone joins or leaves).
    Peers {
        /// This connection.
        you: u64,
        /// Every connection, oldest first.
        peers: Vec<crate::peer::Peer>,
    },
    /// One connection's live presence changed: replace it when `rev` is newer.
    PeerChanged {
        /// Its new state.
        peer: crate::peer::Peer,
    },
}

impl From<client_core::MultiplayerEvent> for MultiplayerEvent {
    fn from(e: client_core::MultiplayerEvent) -> Self {
        use client_core::MultiplayerEvent as E;
        match e {
            E::Joined { info } => Self::Joined { info: info.into() },
            E::Peers { you, peers } => Self::Peers {
                you: you.0,
                peers: peers.into_iter().map(Into::into).collect(),
            },
            E::PeerChanged { peer } => Self::PeerChanged { peer: peer.into() },
            E::Participants { participants } => Self::Participants {
                participants: participants.into_iter().map(Into::into).collect(),
            },
            E::Presence { presence } => Self::Presence {
                presence: presence.into(),
            },
            E::Lease { lease } => Self::Lease {
                lease: lease.into(),
            },
            E::LeaseRequested { pane_id, by, name } => Self::LeaseRequested {
                pane_id: pane_id.0,
                by: by.into(),
                name,
            },
            E::InputRejected { pane_id, reason } => Self::InputRejected {
                pane_id: pane_id.0,
                reason: reason.into(),
            },
            E::Forbidden { what, reason } => Self::Forbidden { what, reason },
            E::Decided { decided } => Self::Decided {
                decided: decided.into(),
            },
            E::AlreadyDecided { request_id, by } => Self::AlreadyDecided {
                request_id: request_id.0,
                by: by.into(),
            },
            E::Revoked => Self::Revoked,
            E::DevicePaired { device } => Self::DevicePaired {
                device: device.into(),
            },
            E::HostAlert { alert } => Self::HostAlert {
                alert: alert.into(),
            },
            E::Knock {
                update: proto::KnockUpdate::Added(knock),
            } => Self::KnockAdded {
                knock: knock.into(),
            },
            E::Knock {
                update:
                    proto::KnockUpdate::Gone {
                        knock_id,
                        outcome,
                        by,
                    },
            } => Self::KnockGone {
                knock_id: knock_id.0,
                outcome: outcome.into(),
                by: by.map(Into::into),
            },
            E::ApprovalPolicy { session_id, policy } => Self::ApprovalPolicy {
                session_id: session_id.0,
                policy: policy.into(),
            },
            E::ApprovalStatus { status } => Self::ApprovalStatus {
                status: status.into(),
            },
        }
    }
}

/// Receives [`MultiplayerEvent`]s; implemented in Swift. Called on a runtime thread, in
/// order. Return quickly.
#[uniffi::export(foreign)]
pub trait MultiplayerListener: Send + Sync {
    /// One event.
    fn on_multiplayer_event(&self, event: MultiplayerEvent);
}

struct MpForward(Arc<dyn MultiplayerListener>);

impl client_core::MultiplayerListener for MpForward {
    fn on_multiplayer_event(&self, event: client_core::MultiplayerEvent) {
        self.0.on_multiplayer_event(event.into());
    }
}

/// What an invite says, read without dialling (for the join card).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct InviteInfo {
    /// The daemon's endpoint id, hex.
    pub daemon_id: String,
    /// Direct addresses.
    pub addrs: Vec<String>,
    /// The daemon's home relay.
    pub relay_url: Option<String>,
    /// Who invited.
    pub inviter: String,
    /// Who it is for.
    pub label: String,
    /// Roles it grants.
    pub roles: Vec<Role>,
    /// What it covers.
    pub scope: Scope,
    /// Expiry, Unix ms.
    pub expires_ms: Option<u64>,
    /// Distinct devices that may redeem it.
    pub max_uses: Option<u32>,
    /// Joining asks the owner first.
    pub knock: bool,
    /// Scrollback is shown only from joining.
    pub since_join: bool,
}

/// Reads an invite link (`unnamed://join/…` or `#…`, any case) without dialling.
///
/// # Errors
///
/// [`ClientError::Ticket`] if it does not parse.
#[uniffi::export]
pub fn inspect_invite(invite: String) -> Result<InviteInfo, ClientError> {
    let (parsed, terms) =
        proto::Invite::parse_with_terms(&invite).map_err(|e| ClientError::Ticket {
            message: e.to_string(),
        })?;
    let leaf = parsed.chain.leaf().cloned();
    Ok(InviteInfo {
        daemon_id: hex(&parsed.daemon_id.0),
        addrs: parsed.addrs.iter().map(ToString::to_string).collect(),
        relay_url: parsed.relay_url,
        inviter: parsed.inviter,
        label: leaf.as_ref().map(|g| g.label.clone()).unwrap_or_default(),
        roles: leaf
            .as_ref()
            .map(|g| roles_to_ffi(g.roles))
            .unwrap_or_default(),
        scope: leaf.as_ref().map_or(Scope::Daemon, |g| g.scope.into()),
        expires_ms: leaf.as_ref().and_then(|g| g.expires.map(|e| e.0)),
        max_uses: leaf.and_then(|g| g.max_uses),
        knock: terms.knock,
        since_join: terms.history == proto::History::SinceJoin,
    })
}

impl DaemonClient {
    async fn mp_call<T, U, F, Fut>(&self, f: F) -> Result<U, MultiplayerError>
    where
        F: FnOnce(Arc<client_core::Client>) -> Fut,
        Fut: Future<Output = Result<T, proto::MpError>> + Send + 'static,
        T: Send + 'static,
        U: From<T>,
    {
        let fut = f(self.core());
        on_runtime(fut).await.map(U::from).map_err(Into::into)
    }
}

#[uniffi::export]
impl DaemonClient {
    /// Sets the receiver of [`MultiplayerEvent`]s, replacing any previous one.
    pub fn set_multiplayer_listener(&self, listener: Arc<dyn MultiplayerListener>) {
        self.inner
            .set_multiplayer_listener(Arc::new(MpForward(listener)));
    }

    /// Who this connection is, as of the last handshake (no round trip).
    pub fn me(&self) -> Option<JoinInfo> {
        self.inner.me().map(Into::into)
    }

    /// The device key (hex) that signed the invite this client joined with, `None` for a
    /// paired device.
    pub fn inviter_device(&self) -> Option<String> {
        self.inner.inviter_device().map(|d| hex(&d.0))
    }

    /// The last participant list pushed (no round trip).
    pub fn participant_list(&self) -> Vec<Participant> {
        self.inner
            .participant_list()
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// The last lease pushed for a pane (no round trip).
    pub fn lease(&self, pane_id: u64) -> Option<Lease> {
        self.inner.lease(proto::PaneId(pane_id)).map(Into::into)
    }

    /// Tells the others whether this device is typing in a pane's composer.
    pub fn set_typing(&self, pane_id: u64, typing: bool) {
        self.inner.set_typing(proto::PaneId(pane_id), typing);
    }

    /// This connection's identity, asked now.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn who_am_i(&self) -> Result<JoinInfo, MultiplayerError> {
        self.mp_call(|c| async move { c.who_am_i().await }).await
    }

    /// Everyone connected, with presence.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn participants(&self) -> Result<Vec<Participant>, MultiplayerError> {
        let all: Vec<proto::Participant> = self
            .mp_call(|c| async move { c.participants().await })
            .await?;
        Ok(all.into_iter().map(Into::into).collect())
    }

    /// Sets this connection's display name.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn set_name(&self, name: String) -> Result<(), MultiplayerError> {
        self.mp_call(|c| async move { c.set_name(name).await })
            .await
    }

    /// Signs an invite with this device's key (an owner signs a root grant; a guest with
    /// `delegate` a narrower child of its own) and registers it, so it is listed and
    /// revocable before use. Returns the link and its QR payload.
    ///
    /// # Errors
    ///
    /// `Invalid` for a child wider than the guest's grant; the daemon's refusal.
    pub async fn create_invite(
        &self,
        options: InviteOptions,
    ) -> Result<CreatedInvite, MultiplayerError> {
        let mut spec = GrantSpec::new(roles_from_ffi(&options.roles), options.scope.into());
        spec.expires = options
            .ttl_secs
            .map(|s| proto::UnixMillis(client_core::now_millis().0 + s.saturating_mul(1000)));
        spec.max_uses = options.max_uses;
        spec.delegate = options.delegate;
        spec.label = options.label;
        let inviter = options.inviter;
        let terms = proto::InviteTerms {
            knock: options.knock,
            history: if options.since_join {
                proto::History::SinceJoin
            } else {
                proto::History::Full
            },
        };
        let invite: proto::Invite = self
            .mp_call(|c| async move { c.create_invite_with_terms(spec, inviter, terms).await })
            .await?;
        let link = invite.to_string_with_terms(terms);
        let leaf = invite.chain.leaf();
        Ok(CreatedInvite {
            qr_payload: link.to_ascii_uppercase(),
            grant_id: hex(&invite.chain.grant_id().0),
            expires_ms: leaf.and_then(|g| g.expires.map(|e| e.0)),
            link,
        })
    }

    /// Grants the daemon knows (owner only).
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn list_grants(&self) -> Result<Vec<GrantInfo>, MultiplayerError> {
        let all: Vec<proto::GrantInfo> = self
            .mp_call(|c| async move { c.list_grants().await })
            .await?;
        Ok(all.into_iter().map(Into::into).collect())
    }

    /// A registered grant's shareable link, again (owner only).
    ///
    /// # Errors
    ///
    /// `Invalid` for a malformed id; `Failed` when the host is too old; the daemon's refusal.
    pub async fn invite_link(
        &self,
        grant_id: String,
        inviter: String,
    ) -> Result<String, MultiplayerError> {
        let id = proto::GrantId(unhex("grant id", &grant_id)?);
        self.mp_call(|c| async move { c.invite_link(id, inviter).await })
            .await
    }

    /// Owner and guest devices (owner only).
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn list_devices(&self) -> Result<Vec<DeviceInfo>, MultiplayerError> {
        let all: Vec<proto::DeviceInfo> = self
            .mp_call(|c| async move { c.list_devices().await })
            .await?;
        Ok(all.into_iter().map(Into::into).collect())
    }

    /// Revokes a grant (and its descendants), a device or a principal, disconnecting them
    /// at once (owner only).
    ///
    /// # Errors
    ///
    /// `Invalid` for a malformed id; the daemon's refusal.
    pub async fn revoke(&self, target: RevokeTarget) -> Result<RevokeResult, MultiplayerError> {
        let target = proto::RevokeTarget::try_from(target)?;
        let r: proto::MpResponse = self
            .mp_call(|c| async move { c.revoke(target).await })
            .await?;
        match r {
            proto::MpResponse::Revoked {
                grants,
                devices,
                disconnected,
            } => Ok(RevokeResult {
                grants: grants.iter().map(|g| hex(&g.0)).collect(),
                devices: devices.iter().map(|d| hex(&d.0)).collect(),
                disconnected,
            }),
            other => Err(MultiplayerError::Failed {
                message: format!("unexpected answer {other:?}"),
            }),
        }
    }

    /// Asks for a pane's control lease; `force` (owner) takes it now.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`] (`Forbidden` without the driver role).
    pub async fn take_control(
        &self,
        pane_id: u64,
        force: bool,
    ) -> Result<LeaseOutcome, MultiplayerError> {
        self.mp_call(|c| async move { c.take_control(proto::PaneId(pane_id), force).await })
            .await
    }

    /// Gives up a lease this principal holds.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn release_control(&self, pane_id: u64) -> Result<(), MultiplayerError> {
        self.mp_call(|c| async move { c.release_control(proto::PaneId(pane_id)).await })
            .await
    }

    /// Answers [`MultiplayerEvent::LeaseRequested`].
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn answer_control(
        &self,
        pane_id: u64,
        give: bool,
    ) -> Result<LeaseOutcome, MultiplayerError> {
        self.mp_call(|c| async move { c.answer_control(proto::PaneId(pane_id), give).await })
            .await
    }

    /// Hands a lease to another connected driver (holder or owner); `to` is a principal id.
    ///
    /// # Errors
    ///
    /// `Invalid` for a malformed id; [`MultiplayerError`].
    pub async fn give_control(
        &self,
        pane_id: u64,
        to: String,
    ) -> Result<LeaseOutcome, MultiplayerError> {
        let to = proto::PrincipalId(unhex("principal", &to)?);
        self.mp_call(|c| async move { c.give_control(proto::PaneId(pane_id), to).await })
            .await
    }

    /// Every pane's lease within scope.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn leases(&self) -> Result<Vec<Lease>, MultiplayerError> {
        let all: Vec<proto::Lease> = self.mp_call(|c| async move { c.leases().await }).await?;
        Ok(all.into_iter().map(Into::into).collect())
    }

    /// Sends a prompt to an agent pane through the composer path (bracketed paste, then
    /// Enter if `submit`); the prompter role's only input. Returns the characters sent.
    ///
    /// # Errors
    ///
    /// `Invalid` for refused text (control characters, `!`, most `/` commands),
    /// `Forbidden` without a prompting role.
    pub async fn prompt(
        &self,
        pane_id: u64,
        text: String,
        submit: bool,
    ) -> Result<u32, MultiplayerError> {
        self.mp_call(|c| async move { c.prompt(proto::PaneId(pane_id), text, submit).await })
            .await
    }

    /// Audit log records after `after` (`nil`: the newest `limit`), owner only.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn audit(
        &self,
        after: Option<u64>,
        limit: u32,
    ) -> Result<AuditPage, MultiplayerError> {
        self.mp_call(|c| async move { c.audit(after, limit).await })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roles_and_ids_round_trip() {
        let roles = [Role::Driver, Role::Approver];
        let bits = roles_from_ffi(&roles);
        assert_eq!(bits, proto::Roles::DRIVER | proto::Roles::APPROVER);
        assert_eq!(roles_to_ffi(bits), roles);
        let id = unhex::<16>("principal", &hex(&[7; 16])).unwrap();
        assert_eq!(id, [7; 16]);
        assert!(matches!(
            unhex::<16>("principal", "zz"),
            Err(MultiplayerError::Invalid { .. })
        ));
    }
}
