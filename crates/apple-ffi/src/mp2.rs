//! policies (owner only, two-person rule, claims, risk caps) and scrollback since joining.
//!
//! A guest with a knock invite calls [`knock_invite`] and waits; the owner sees
//! `MultiplayerEvent.knockAdded` and answers with [`DaemonClient::admit_knock`] or
//! [`DaemonClient::deny_knock`]. Ids cross as numbers, keys as hex.

use std::sync::Arc;

use client_core::proto;

use crate::client::{ClientConfig, ClientError, ConnectOptions, DaemonClient};
use crate::mp::{
    Actor, GrantInfo, MultiplayerError, Role, Scope, hex, roles_from_ffi, roles_to_ffi,
};
use crate::{on_runtime, runtime};

// --- knocks -------------------------------------------------------------------------------

/// Someone waiting to be let in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Knock {
    /// The knock (answer with it).
    pub knock_id: u64,
    /// Who knocks.
    pub actor: Actor,
    /// The name they gave, or the invite's label.
    pub name: String,
    /// The invite they knock with.
    pub grant_id: String,
    /// The roles the invite offers.
    pub roles: Vec<Role>,
    /// What they would join.
    pub scope: Scope,
    /// When they knocked, Unix ms.
    pub at_ms: u64,
}

impl From<proto::Knock> for Knock {
    fn from(k: proto::Knock) -> Self {
        Self {
            knock_id: k.knock_id.0,
            actor: k.actor.into(),
            name: k.name,
            grant_id: hex(&k.grant_id.0),
            roles: roles_to_ffi(k.roles),
            scope: k.scope.into(),
            at_ms: k.at.0,
        }
    }
}

/// How a knock ended.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum KnockOutcome {
    /// Let in with these roles.
    Admitted {
        /// The roles.
        roles: Vec<Role>,
    },
    /// Turned away.
    Denied,
    /// They stopped waiting.
    Withdrawn,
}

impl From<proto::KnockOutcome> for KnockOutcome {
    fn from(o: proto::KnockOutcome) -> Self {
        match o {
            proto::KnockOutcome::Admitted { roles } => Self::Admitted {
                roles: roles_to_ffi(roles),
            },
            proto::KnockOutcome::Denied => Self::Denied,
            proto::KnockOutcome::Withdrawn => Self::Withdrawn,
        }
    }
}

/// What the knocker hears.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum KnockResult {
    /// Let in: join with this invite link (same host, a grant bound to this device).
    Admitted {
        /// The link to join with.
        invite: String,
    },
    /// Turned away.
    Denied,
}

/// Why knocking failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum KnockError {
    /// The invite does not parse, or the key is bad.
    #[error("{message}")]
    Invalid {
        /// Why.
        message: String,
    },
    /// The host could not be reached, or hung up while waiting.
    #[error("cannot reach the host: {message}")]
    Unreachable {
        /// Why.
        message: String,
    },
    /// The host refused the invite (expired, revoked, too many people waiting).
    #[error("refused: {reason}")]
    Refused {
        /// The daemon's reason (`InvalidGrant`, `Revoked`).
        reason: String,
    },
}

impl From<client_core::knock::KnockError> for KnockError {
    fn from(e: client_core::knock::KnockError) -> Self {
        use client_core::knock::KnockError as E;
        match e {
            E::Client(e) => Self::Invalid {
                message: ClientError::from(e).to_string(),
            },
            E::Unreachable(message) => Self::Unreachable { message },
            E::Refused(reason) => Self::Refused {
                reason: format!("{reason:?}"),
            },
        }
    }
}

/// Told when the owner has been asked; implemented in Swift.
#[uniffi::export(foreign)]
pub trait KnockListener: Send + Sync {
    /// The owner has the knock now.
    fn on_waiting(&self, knock_id: u64);
}

/// Aborts a spawned task when the awaiting future is dropped (a cancelled Swift task).
struct AbortOnDrop(tokio::task::AbortHandle);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Knocks with a knock invite and waits for the owner's answer, as long as it takes. Cancel
/// the Swift task to stop waiting; the owner's request then disappears.
///
/// # Errors
///
/// [`KnockError`].
#[uniffi::export]
pub async fn knock_invite(
    invite: String,
    config: ClientConfig,
    options: ConnectOptions,
    name: Option<String>,
    listener: Arc<dyn KnockListener>,
) -> Result<KnockResult, KnockError> {
    let task = runtime().spawn(async move {
        client_core::knock::knock(&invite, config.into(), options.into(), name, |id| {
            listener.on_waiting(id.0);
        })
        .await
    });
    let _guard = AbortOnDrop(task.abort_handle());
    match task.await {
        Ok(Ok(client_core::knock::KnockOutcome::Admitted(invite))) => Ok(KnockResult::Admitted {
            invite: invite.to_string(),
        }),
        Ok(Ok(client_core::knock::KnockOutcome::Denied)) => Ok(KnockResult::Denied),
        Ok(Err(e)) => Err(e.into()),
        Err(e) => Err(KnockError::Unreachable {
            message: e.to_string(),
        }),
    }
}

// --- approval policies --------------------------------------------------------------------

/// How risky an agent's tool call is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Risk {
    /// Reads only.
    ReadOnly,
    /// Edits files.
    Edits,
    /// Runs commands, or anything else.
    Any,
}

impl From<proto::Risk> for Risk {
    fn from(r: proto::Risk) -> Self {
        match r {
            proto::Risk::ReadOnly => Self::ReadOnly,
            proto::Risk::Edits => Self::Edits,
            proto::Risk::Any => Self::Any,
        }
    }
}

impl From<Risk> for proto::Risk {
    fn from(r: Risk) -> Self {
        match r {
            Risk::ReadOnly => Self::ReadOnly,
            Risk::Edits => Self::Edits,
            Risk::Any => Self::Any,
        }
    }
}

/// Who may answer a session's agent approvals.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ApprovalMode {
    /// Any approver; the first answer wins.
    AnyApprover,
    /// Only owners.
    OwnerOnly,
    /// Allowing a command takes two different people.
    TwoPerson,
    /// An approver claims a request, then only they (or an owner) answer it.
    Claim,
}

impl From<proto::ApprovalMode> for ApprovalMode {
    fn from(m: proto::ApprovalMode) -> Self {
        match m {
            proto::ApprovalMode::AnyApprover => Self::AnyApprover,
            proto::ApprovalMode::OwnerOnly => Self::OwnerOnly,
            proto::ApprovalMode::TwoPerson => Self::TwoPerson,
            proto::ApprovalMode::Claim => Self::Claim,
        }
    }
}

impl From<ApprovalMode> for proto::ApprovalMode {
    fn from(m: ApprovalMode) -> Self {
        match m {
            ApprovalMode::AnyApprover => Self::AnyApprover,
            ApprovalMode::OwnerOnly => Self::OwnerOnly,
            ApprovalMode::TwoPerson => Self::TwoPerson,
            ApprovalMode::Claim => Self::Claim,
        }
    }
}

/// A session's approval rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ApprovalPolicy {
    /// Who may answer.
    pub mode: ApprovalMode,
    /// The riskiest call a non-owner approver may allow.
    pub max_risk: Risk,
}

impl From<proto::ApprovalPolicy> for ApprovalPolicy {
    fn from(p: proto::ApprovalPolicy) -> Self {
        Self {
            mode: p.mode.into(),
            max_risk: p.max_risk.into(),
        }
    }
}

impl From<ApprovalPolicy> for proto::ApprovalPolicy {
    fn from(p: ApprovalPolicy) -> Self {
        Self {
            mode: p.mode.into(),
            max_risk: p.max_risk.into(),
        }
    }
}

/// One approval cast, or a claim.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApprovalVote {
    /// Who.
    pub actor: Actor,
    /// Their name.
    pub name: String,
    /// When, Unix ms.
    pub at_ms: u64,
}

impl From<proto::ApprovalVote> for ApprovalVote {
    fn from(v: proto::ApprovalVote) -> Self {
        Self {
            actor: v.actor.into(),
            name: v.name,
            at_ms: v.at.0,
        }
    }
}

/// Where an open approval request stands.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApprovalStatus {
    /// The agent's pane.
    pub pane_id: u64,
    /// The request.
    pub request_id: u64,
    /// The call's risk.
    pub risk: Risk,
    /// The session's mode.
    pub mode: ApprovalMode,
    /// Approvals cast that have not decided yet.
    pub approvals: Vec<ApprovalVote>,
    /// Approvals an "allow" needs.
    pub needed: u8,
    /// Who claimed it.
    pub claimed_by: Option<ApprovalVote>,
}

impl From<proto::ApprovalStatus> for ApprovalStatus {
    fn from(s: proto::ApprovalStatus) -> Self {
        Self {
            pane_id: s.pane_id.0,
            request_id: s.request_id.0,
            risk: s.risk.into(),
            mode: s.mode.into(),
            approvals: s.approvals.into_iter().map(Into::into).collect(),
            needed: s.needed,
            claimed_by: s.claimed_by.map(Into::into),
        }
    }
}

/// The risk class of an agent tool (`Read` → read-only, `Edit` → edits, `Bash` → any).
#[uniffi::export]
pub fn risk_of_tool(tool: Option<String>) -> Risk {
    proto::Risk::of_tool(tool.as_deref()).into()
}

#[uniffi::export]
impl DaemonClient {
    /// Knocks waiting for an owner, as last pushed (no round trip).
    pub fn pending_knocks(&self) -> Vec<Knock> {
        self.inner
            .pending_knocks()
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// Lets a knock in with `roles` (owner only). `since_join` shows them scrollback only
    /// from now; `ttl_secs` (default 7 days) bounds their access.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`] (`NotFound` once they stopped waiting).
    pub async fn admit_knock(
        &self,
        knock_id: u64,
        roles: Vec<Role>,
        since_join: bool,
        ttl_secs: Option<u64>,
    ) -> Result<GrantInfo, MultiplayerError> {
        let admit = proto::Admit {
            roles: roles_from_ffi(&roles),
            history: if since_join {
                proto::History::SinceJoin
            } else {
                proto::History::Full
            },
            expires: ttl_secs
                .map(|s| proto::UnixMillis(client_core::now_millis().0 + s.saturating_mul(1000))),
        };
        let core = self.core();
        let info = on_runtime(async move {
            core.answer_knock(proto::KnockId(knock_id), Some(admit))
                .await
        })
        .await?;
        info.map(Into::into).ok_or(MultiplayerError::Failed {
            message: "the host did not return a grant".into(),
        })
    }

    /// Turns a knock away (owner only).
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn deny_knock(&self, knock_id: u64) -> Result<(), MultiplayerError> {
        let core = self.core();
        on_runtime(async move { core.answer_knock(proto::KnockId(knock_id), None).await })
            .await
            .map(|_| ())
            .map_err(Into::into)
    }

    /// The attached session's approval rules, as last pushed (no round trip).
    pub fn approval_policy_cached(&self) -> Option<ApprovalPolicy> {
        self.inner.approval_policy_cached().map(|(_, p)| p.into())
    }

    /// Open requests with votes or a claim, as last pushed.
    pub fn approval_statuses(&self) -> Vec<ApprovalStatus> {
        self.inner
            .approval_statuses()
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// A session's approval rules, asked now.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`].
    pub async fn approval_policy(
        &self,
        session_id: u64,
    ) -> Result<ApprovalPolicy, MultiplayerError> {
        let core = self.core();
        on_runtime(async move { core.approval_policy(proto::SessionId(session_id)).await })
            .await
            .map(Into::into)
            .map_err(Into::into)
    }

    /// Sets a session's approval rules (owner only).
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`] (`Forbidden` for guests).
    pub async fn set_approval_policy(
        &self,
        session_id: u64,
        policy: ApprovalPolicy,
    ) -> Result<ApprovalPolicy, MultiplayerError> {
        let core = self.core();
        on_runtime(async move {
            core.set_approval_policy(proto::SessionId(session_id), policy.into())
                .await
        })
        .await
        .map(Into::into)
        .map_err(Into::into)
    }

    /// Claims an open approval request ("I'll take this one"), or releases the claim.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError`] (`Conflict` when someone else claimed it).
    pub async fn claim_approval(
        &self,
        request_id: u64,
        claim: bool,
    ) -> Result<ApprovalStatus, MultiplayerError> {
        let core = self.core();
        on_runtime(async move { core.claim(proto::RequestId(request_id), claim).await })
            .await
            .map(Into::into)
            .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn policies_and_risks_round_trip() {
        for mode in [
            ApprovalMode::AnyApprover,
            ApprovalMode::OwnerOnly,
            ApprovalMode::TwoPerson,
            ApprovalMode::Claim,
        ] {
            for max_risk in [Risk::ReadOnly, Risk::Edits, Risk::Any] {
                let policy = ApprovalPolicy { mode, max_risk };
                let wire: proto::ApprovalPolicy = policy.into();
                assert_eq!(ApprovalPolicy::from(wire), policy);
            }
        }
        assert_eq!(risk_of_tool(Some("Write".into())), Risk::Edits);
        assert_eq!(risk_of_tool(None), Risk::Any);
    }
}
