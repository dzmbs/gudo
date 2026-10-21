//! Approval extras beyond [`Decide`](crate::Decide): approving with edited input, and
//! "approve all like this for this task" rules.
//!
//! - **Edited input.** When an agent asked through a hook that lets the answer change the
//!   tool's input (Claude Code's `PermissionRequest` with `updatedInput`), the daemon says so
//!   in [`ApprovalInfo::input`]: the text a person may edit (the shell command). The client
//!   approves with [`ApprovalRequest::ApproveEdited`].
//! - **Auto-approve rules.** [`ApprovalRequest::AddRule`] adds an [`AutoApproveRule`]: while
//!   it lives, the daemon answers "allow once" for requests on that pane whose tool and input
//!   match its [`RuleMatch`]. A rule is signed by the deciding device (like a `Decide`),
//!   limited in time and in agent turns, lives only as long as the agent session it was made
//!   in, and can be revoked ([`ApprovalRequest::RevokeRule`]). Every automatic answer is in
//!   the audit log.
//!
//! Requests travel as [`ClientCtl::Approval`](crate::ClientCtl::Approval) and are answered
//! by [`ServerCtl::ApprovalResult`](crate::ServerCtl::ApprovalResult); pushes are
//! [`ServerCtl::Approval`](crate::ServerCtl::Approval), sent only to connections that
//! announced [`Caps::APPROVALS`](crate::Caps::APPROVALS) and can see the pane. Requests need
//! Approver on the pane.
//!
//! Same compatibility rules as the rest of the crate: append only.

use serde::{Deserialize, Serialize};

use crate::Decide;
use crate::ids::{Actor, DaemonId, PaneId, RequestId, UnixMillis};

/// The longest an auto-approve rule may live: 8 hours.
pub const MAX_RULE_LIFETIME_MS: u64 = 8 * 60 * 60 * 1000;

/// The most agent turns an auto-approve rule may span.
pub const MAX_RULE_TURNS: u32 = 50;

/// One auto-approve rule. Random, chosen by the client.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct RuleId(pub [u8; 16]);

/// What "like this" means for a rule: the same tool and, for shell commands, the same
/// command (the first word, or the first two for tools with subcommands such as `cargo test`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RuleMatch {
    /// The tool, e.g. `Bash`, `Edit`.
    pub tool: String,
    /// The input must be this or start with it followed by a space. Empty matches any input
    /// of the tool (never used for shell commands).
    pub prefix: String,
}

/// An auto-approve rule, signed by the device that made it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AutoApproveRule {
    /// The rule.
    pub rule_id: RuleId,
    /// The agent's pane (the task). The rule ends with the agent session running there now.
    pub pane_id: PaneId,
    /// An open request to approve with it ("approve this and all like it").
    pub request_id: Option<RequestId>,
    /// What it approves.
    pub matcher: RuleMatch,
    /// When it lapses. At most [`MAX_RULE_LIFETIME_MS`] after it is added.
    pub expires_at: UnixMillis,
    /// How many agent turns (prompts) it spans, counting the current one. At most
    /// [`MAX_RULE_TURNS`].
    pub max_turns: u32,
    /// Who made it. Must match the connection's principal and device.
    pub actor: Actor,
    /// Device signature over [`auto_approve_signing_bytes`].
    #[serde(with = "crate::serde_bytes")]
    pub sig: Vec<u8>,
}

/// A rule in force on a pane, as the daemon reports it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActiveRule {
    /// The rule as added.
    pub rule: AutoApproveRule,
    /// Agent turns started since it was added (the current turn counts as one).
    pub turns_used: u32,
    /// Requests it has approved.
    pub uses: u32,
    /// The display name of who added it.
    pub granted_by: String,
}

/// What a client may do with the request a pane is blocked on, beyond `Decide`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalInfo {
    /// The pane.
    pub pane_id: PaneId,
    /// The request (the one `AgentState::Blocked` names).
    pub request_id: RequestId,
    /// The tool asking, e.g. `Bash`.
    pub tool: String,
    /// The input a person may edit before approving (a shell command), when the agent takes
    /// edited input. `None`: approve or deny as asked.
    pub input: Option<String>,
    /// The rule "approve all like this" would add, when the request can be auto-approved.
    pub like: Option<RuleMatch>,
}

/// An approval request ([`ClientCtl::Approval`](crate::ClientCtl::Approval)).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ApprovalRequest {
    /// Approves an open request with its input replaced by `input` (signed like any
    /// decision; its option is the allow option).
    ApproveEdited {
        /// The decision.
        decide: Decide,
        /// The edited input (the command to run instead).
        input: String,
    },
    /// Adds an auto-approve rule, and approves `rule.request_id` if it is open and matches.
    AddRule(AutoApproveRule),
    /// Revokes a rule.
    RevokeRule {
        /// The rule.
        rule_id: RuleId,
    },
}

/// A successful [`ApprovalRequest`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ApprovalResponse {
    /// Done.
    Done,
}

/// Why an [`ApprovalRequest`] failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ApprovalError {
    /// No such request or rule (answered, gone, expired).
    NotFound,
    /// The connection may not do this (roles, scope, signature, actor).
    Forbidden(String),
    /// The agent cannot take edited input for this request.
    NotEditable,
    /// The rule is malformed or wider than the daemon allows.
    Invalid(String),
    /// Someone else decided first.
    AlreadyDecided,
    /// The connection dropped before the answer (client-side only).
    Disconnected,
}

impl std::fmt::Display for ApprovalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => f.write_str("the request or rule is gone"),
            Self::Forbidden(why) => write!(f, "not allowed: {why}"),
            Self::NotEditable => f.write_str("this agent cannot take an edited request"),
            Self::Invalid(why) => write!(f, "invalid rule: {why}"),
            Self::AlreadyDecided => f.write_str("someone else answered first"),
            Self::Disconnected => f.write_str("the connection dropped"),
        }
    }
}

impl std::error::Error for ApprovalError {}

/// Something about approvals changed ([`ServerCtl::Approval`](crate::ServerCtl::Approval)).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ApprovalPush {
    /// A pane is blocked on a request: what may be done with it.
    Request(ApprovalInfo),
    /// The rules in force on a pane, whole (empty when none are left).
    Rules {
        /// The pane.
        pane_id: PaneId,
        /// Its rules, oldest first.
        rules: Vec<ActiveRule>,
    },
}

/// The bytes a device signs to add an auto-approve rule ([`AutoApproveRule::sig`]).
///
/// Everything but the signature is covered, and the daemon id stops a rule from being
/// replayed on another host.
pub fn auto_approve_signing_bytes(daemon: DaemonId, rule: &AutoApproveRule) -> Vec<u8> {
    let mut out = b"auto-approve-v1\0".to_vec();
    out.extend(
        postcard::to_stdvec(&(
            daemon,
            rule.rule_id,
            rule.pane_id,
            rule.request_id,
            &rule.matcher,
            rule.expires_at,
            rule.max_turns,
            rule.actor,
        ))
        .expect("rules always encode"),
    );
    out
}
