//! Approval extras on [`DaemonClient`] (`proto::approve`, docs/DAEMON.md §6.9): approve with
//! an edited command, and "approve all like this for this task" rules.
//!
//! Pushes go to an [`ApprovalListener`]; the latest are also kept
//! ([`DaemonClient::approval_info`], [`DaemonClient::auto_approve_rules`]).

use std::sync::Arc;
use std::time::Duration;

use client_core::proto;

use crate::client::DaemonClient;
use crate::on_runtime;

/// Why an approval request failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ApprovalError {
    /// The request or rule is gone (answered, expired, revoked).
    #[error("the request or rule is gone")]
    NotFound,
    /// The connection's roles or scope do not allow it.
    #[error("not allowed: {message}")]
    Forbidden {
        /// Why.
        message: String,
    },
    /// The agent cannot take an edited request.
    #[error("this agent cannot take an edited request")]
    NotEditable,
    /// The rule is wider or longer than the daemon allows, or the edit is empty.
    #[error("{message}")]
    Invalid {
        /// Why.
        message: String,
    },
    /// Someone else answered first.
    #[error("someone else answered first")]
    AlreadyDecided,
    /// The connection dropped before the daemon answered.
    #[error("disconnected before the daemon answered")]
    Disconnected,
}

impl From<proto::ApprovalError> for ApprovalError {
    fn from(e: proto::ApprovalError) -> Self {
        use proto::ApprovalError as E;
        match e {
            E::NotFound => Self::NotFound,
            E::Forbidden(message) => Self::Forbidden { message },
            E::NotEditable => Self::NotEditable,
            E::Invalid(message) => Self::Invalid { message },
            E::AlreadyDecided => Self::AlreadyDecided,
            E::Disconnected => Self::Disconnected,
        }
    }
}

/// What "like this" covers: a tool, and for shell commands the command's start.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApprovalRuleMatch {
    /// The tool (`Bash`, `Edit`).
    pub tool: String,
    /// The command it starts with (`cargo test`); empty: any input of the tool.
    pub prefix: String,
}

impl From<proto::RuleMatch> for ApprovalRuleMatch {
    fn from(m: proto::RuleMatch) -> Self {
        Self {
            tool: m.tool,
            prefix: m.prefix,
        }
    }
}

impl From<ApprovalRuleMatch> for proto::RuleMatch {
    fn from(m: ApprovalRuleMatch) -> Self {
        Self {
            tool: m.tool,
            prefix: m.prefix,
        }
    }
}

/// What may be done with the request a pane is blocked on, beyond approve and deny.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApprovalInfo {
    /// The pane.
    pub pane_id: u64,
    /// The request (compare with the pane's blocked request: this may be stale).
    pub request_id: u64,
    /// The tool asking.
    pub tool: String,
    /// The command a person may edit before approving; `None`: not editable.
    pub editable_input: Option<String>,
    /// What "approve all like this" would cover; `None`: not offered.
    pub like: Option<ApprovalRuleMatch>,
}

impl From<proto::ApprovalInfo> for ApprovalInfo {
    fn from(i: proto::ApprovalInfo) -> Self {
        Self {
            pane_id: i.pane_id.0,
            request_id: i.request_id.0,
            tool: i.tool,
            editable_input: i.input,
            like: i.like.map(Into::into),
        }
    }
}

/// An auto-approve rule in force.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AutoApproveRule {
    /// The rule (32 hex digits), for revoking.
    pub id: String,
    /// The agent's pane.
    pub pane_id: u64,
    /// What it approves.
    pub matcher: ApprovalRuleMatch,
    /// When it lapses (Unix ms).
    pub expires_at_ms: u64,
    /// Turns it spans in all.
    pub max_turns: u32,
    /// Turns started since it was added (the one it was added in counts).
    pub turns_used: u32,
    /// Requests it approved.
    pub uses: u32,
    /// Who added it.
    pub granted_by: String,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn rule_id(hex: &str) -> Option<proto::RuleId> {
    if hex.len() != 32 {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(hex.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(proto::RuleId(out))
}

impl From<proto::ActiveRule> for AutoApproveRule {
    fn from(r: proto::ActiveRule) -> Self {
        Self {
            id: hex(&r.rule.rule_id.0),
            pane_id: r.rule.pane_id.0,
            matcher: r.rule.matcher.into(),
            expires_at_ms: r.rule.expires_at.0,
            max_turns: r.rule.max_turns,
            turns_used: r.turns_used,
            uses: r.uses,
            granted_by: r.granted_by,
        }
    }
}

/// A change in approvals.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ApprovalEvent {
    /// A pane is blocked on a request: what may be done with it.
    Request {
        /// The extras.
        info: ApprovalInfo,
    },
    /// The rules in force on a pane (empty when none are left).
    Rules {
        /// The pane.
        pane_id: u64,
        /// Its rules, oldest first.
        rules: Vec<AutoApproveRule>,
    },
    /// The connection dropped: forget everything; the daemon says it again on reconnect.
    Reset,
}

impl From<client_core::ApprovalEvent> for ApprovalEvent {
    fn from(e: client_core::ApprovalEvent) -> Self {
        use client_core::ApprovalEvent as E;
        match e {
            E::Request(info) => Self::Request { info: info.into() },
            E::Rules { pane_id, rules } => Self::Rules {
                pane_id: pane_id.0,
                rules: rules.into_iter().map(Into::into).collect(),
            },
            E::Reset => Self::Reset,
        }
    }
}

/// Receives [`ApprovalEvent`]s; implemented in Swift.
///
/// Called on a runtime thread, in order, one at a time per client. Return quickly.
#[uniffi::export(foreign)]
pub trait ApprovalListener: Send + Sync {
    /// One event.
    fn on_approval_event(&self, event: ApprovalEvent);
}

struct ApprovalForward(Arc<dyn ApprovalListener>);

impl client_core::ApprovalListener for ApprovalForward {
    fn on_approval_event(&self, event: client_core::ApprovalEvent) {
        self.0.on_approval_event(event.into());
    }
}

/// What "approve all like this" would cover for `tool` running `input`, or `None` when a rule
/// should not cover it (the daemon's rule; the daemon also says it in [`ApprovalInfo::like`]).
#[uniffi::export]
pub fn approval_like_this(tool: String, input: String) -> Option<ApprovalRuleMatch> {
    client_core::grants::like_this(&tool, &input).map(Into::into)
}

#[uniffi::export]
impl DaemonClient {
    /// Sets the receiver of [`ApprovalEvent`]s, replacing any previous one.
    pub fn set_approval_listener(&self, listener: Arc<dyn ApprovalListener>) {
        self.inner
            .set_approval_listener(Arc::new(ApprovalForward(listener)));
    }

    /// The extras for the request a pane is blocked on, if the daemon said (no round trip).
    pub fn approval_info(&self, pane_id: u64) -> Option<ApprovalInfo> {
        self.inner
            .approval_info(proto::PaneId(pane_id))
            .map(Into::into)
    }

    /// The auto-approve rules in force on a pane (no round trip).
    pub fn auto_approve_rules(&self, pane_id: u64) -> Vec<AutoApproveRule> {
        self.inner
            .auto_approve_rules(proto::PaneId(pane_id))
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// Approves `request_id` with its allow option `option_id`, running `input` instead.
    ///
    /// # Errors
    ///
    /// [`ApprovalError::NotEditable`] if the agent cannot take it.
    pub async fn approve_edited(
        &self,
        request_id: u64,
        option_id: u32,
        input: String,
    ) -> Result<(), ApprovalError> {
        let core = self.core();
        on_runtime(async move {
            core.approve_edited(
                proto::RequestId(request_id),
                proto::OptionId(option_id),
                input,
            )
            .await
        })
        .await
        .map_err(Into::into)
    }

    /// Adds a rule approving what `matcher` covers on `pane_id` for `minutes` and at most
    /// `max_turns` turns, and approves `request_id` with it when given. Returns the rule id.
    ///
    /// # Errors
    ///
    /// [`ApprovalError::Invalid`] if it is wider or longer than allowed (8 h, 50 turns).
    pub async fn add_auto_approve(
        &self,
        pane_id: u64,
        request_id: Option<u64>,
        matcher: ApprovalRuleMatch,
        minutes: u32,
        max_turns: u32,
    ) -> Result<String, ApprovalError> {
        let core = self.core();
        on_runtime(async move {
            core.add_auto_approve(
                proto::PaneId(pane_id),
                request_id.map(proto::RequestId),
                matcher.into(),
                Duration::from_secs(u64::from(minutes) * 60),
                max_turns,
            )
            .await
        })
        .await
        .map(|id| hex(&id.0))
        .map_err(Into::into)
    }

    /// Revokes rule `id` (as [`AutoApproveRule::id`]).
    ///
    /// # Errors
    ///
    /// [`ApprovalError::NotFound`] if it already ended.
    pub async fn revoke_auto_approve(&self, id: String) -> Result<(), ApprovalError> {
        let id = rule_id(&id).ok_or(ApprovalError::NotFound)?;
        let core = self.core();
        on_runtime(async move { core.revoke_auto_approve(id).await })
            .await
            .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rule_ids_round_trip_as_hex() {
        let id = proto::RuleId([0xab; 16]);
        assert_eq!(rule_id(&hex(&id.0)), Some(id));
        assert_eq!(rule_id("zz"), None);
    }

    #[test]
    fn like_this_is_the_daemons_rule() {
        let m = approval_like_this("Bash".into(), "cargo test -p x".into()).unwrap();
        assert_eq!(m.prefix, "cargo test");
        assert_eq!(approval_like_this("Bash".into(), "a; b".into()), None);
    }
}
