mod claude;
pub(crate) mod codex;
mod terminal;

use std::future::Future;
use std::pin::Pin;

use agents::ApprovalChoice;
use proto::{
    AgentKind, ChatSendStatus, PaneId, TimelineCursor, TimelineOp, TimelineSnapshot, UnixMillis,
    WorkspaceResponse, WsError,
};
use tokio::sync::mpsc;

use crate::core::Core;
use crate::pane::Pane;

pub(crate) use proto::AgentCapabilities;

pub(crate) enum TimelineRead {
    ItemsBefore {
        before: u64,
        limit: u16,
    },
    ToolOutput {
        handle: String,
        offset: u64,
        length: u32,
    },
    ToolDiff {
        handle: String,
    },
}

pub(crate) type ReadFuture =
    Pin<Box<dyn Future<Output = Result<WorkspaceResponse, WsError>> + Send>>;

pub(crate) trait AgentSession: Send {
    fn capabilities(&self) -> AgentCapabilities;
    fn cursor(&self) -> TimelineCursor;
    fn check_history_scope(&self, since: Option<UnixMillis>) -> Result<(), WsError>;
    fn snapshot(&self, since: Option<UnixMillis>) -> TimelineSnapshot;
    fn refresh(&mut self, core: &Core, pane: PaneId) -> Result<Vec<TimelineOp>, WsError>;
    fn check_current(&self, core: &Core, pane: PaneId) -> Result<(), WsError>;
    // Owned futures let an RPC reader wait after the service releases its state mutex.
    fn read(&mut self, request: TimelineRead, since: Option<UnixMillis>) -> ReadFuture;
    fn wake(&self) -> mpsc::Sender<()>;
}

/// How an accepted stop reaches the agent, which decides whether Terminal saw a key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StopDelivery {
    TerminalEscape,
    AgentRequest,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum UnconfirmedSend {
    NotConfirmed,
    SentNotConfirmed,
}

impl UnconfirmedSend {
    pub fn status(self) -> ChatSendStatus {
        match self {
            Self::NotConfirmed => ChatSendStatus::NotConfirmed,
            Self::SentNotConfirmed => ChatSendStatus::SentNotConfirmed,
        }
    }
}

pub(crate) struct SendAcknowledgement {
    pub revision: u64,
    pub actor: proto::Actor,
    pub receipt: tokio::sync::watch::Sender<crate::agent_input::Receipt>,
}

pub(crate) enum ApprovalDecision<'a> {
    Choice(ApprovalChoice),
    Edited(&'a str),
}

pub(crate) enum InputEvent<'a> {
    Submitted { session: &'a str, prompt: &'a str },
    TurnStarted { session: &'a str, prompt: &'a str },
    TurnEnded,
    SessionEnded,
    Ignored,
}

#[derive(Clone, Copy)]
pub(crate) enum ApprovalEvidence<'a> {
    Device(&'a crate::mp::Authz),
    Rule(&'a proto::ActiveRule),
}

/// Retains already-checked admission evidence; never replaces signed-policy admission.
pub(crate) struct ApprovalAuthority {
    pub actor: proto::Actor,
    pub policy: proto::ApprovalPolicy,
    pub signers: Vec<crate::mp::Authz>,
    pub rule: Option<proto::AutoApproveRule>,
}

impl ApprovalAuthority {
    pub(crate) fn for_decision(
        core: &Core,
        pane: PaneId,
        request: proto::RequestId,
        choice: agents::ApprovalChoice,
        actor: proto::Actor,
        evidence: Option<ApprovalEvidence<'_>>,
    ) -> Self {
        let policy = core.mp.policy_of_pane(core, pane);
        let owner = || {
            core.identity
                .is_owner_device(actor.device)
                .then(|| crate::mp::Authz::owner(actor))
        };
        let (authorization, rule) = match evidence {
            Some(ApprovalEvidence::Device(authz)) => (Some(authz.clone()), None),
            Some(ApprovalEvidence::Rule(rule)) => (
                (rule.rule.actor == actor).then(owner).flatten(),
                Some(rule.rule.clone()),
            ),
            None => (owner(), None),
        };
        let signers = authorization
            .as_ref()
            .and_then(|authz| {
                core.mp.approvals.delivery_signers(
                    policy,
                    request,
                    choice != agents::ApprovalChoice::Deny,
                    crate::mp::approvals::Ballot {
                        actor,
                        name: &authz.name,
                        owner: authz.is_owner_device(core),
                        authorization: Some(authz),
                    },
                )
            })
            .unwrap_or_default();
        Self {
            actor,
            policy,
            signers,
            rule,
        }
    }
}

pub(crate) struct PendingApproval {
    pub request: agents::RequestId,
    pub tool: String,
    pub command: Option<String>,
    pub editable: Option<String>,
}

impl PendingApproval {
    pub fn command(&self) -> Option<&str> {
        self.command.as_deref()
    }
    pub fn editable(&self) -> Option<&str> {
        self.editable.as_deref()
    }
}

pub(crate) fn pending_approval(core: &Core, pane: PaneId) -> Option<PendingApproval> {
    let entry = core.pane(pane)?;
    let kind = crate::core::lock(&entry.agent).as_ref()?.kind();
    driver(kind).pending_approval(core, pane)
}

pub(crate) fn approval_is_pending(core: &Core, pane: PaneId, request: &agents::RequestId) -> bool {
    let Some(entry) = core.pane(pane) else {
        return false;
    };
    let kind = crate::core::lock(&entry.agent)
        .as_ref()
        .map(|runtime| runtime.kind());
    kind.is_some_and(|kind| driver(kind).approval_is_pending(core, pane, request))
}

pub(crate) trait AgentDriver: Send + Sync {
    fn pending_approval(&self, core: &Core, pane: PaneId) -> Option<PendingApproval>;
    fn approval_is_pending(&self, core: &Core, pane: PaneId, request: &agents::RequestId) -> bool;
    fn input_event<'a>(&self, request: &'a crate::HookRequest) -> InputEvent<'a>;
    fn capabilities(&self) -> AgentCapabilities;
    fn current_capabilities(&self, _core: &Core, _pane: PaneId) -> AgentCapabilities {
        self.capabilities()
    }
    fn check_prompt(&self, text: &str) -> Result<(), WsError>;
    fn open(
        &self,
        core: &Core,
        pane: PaneId,
        epoch: u64,
        wake: mpsc::Sender<()>,
    ) -> Result<Box<dyn AgentSession>, WsError>;
    // The caller holds the input/exit gate through this bounded queue admission. No I/O wait.
    fn send(
        &self,
        core: &Core,
        pane: &Pane,
        session: Option<&str>,
        text: &str,
        acknowledgement: Option<SendAcknowledgement>,
    ) -> Result<UnconfirmedSend, WsError>;
    fn stop(
        &self,
        core: &Core,
        pane: &Pane,
        session: Option<&str>,
        revision: u64,
        actor: proto::Actor,
    ) -> Result<StopDelivery, WsError>;
    // Role, signature, policy, pending request and audit checks precede delivery.
    fn approve(
        &self,
        core: &Core,
        pane: PaneId,
        request: &agents::RequestId,
        decision: ApprovalDecision<'_>,
        authority: ApprovalAuthority,
    ) -> bool;
}

pub(crate) fn driver(kind: AgentKind) -> &'static dyn AgentDriver {
    match kind {
        AgentKind::Claude => &claude::ClaudeDriver,
        AgentKind::Codex => &terminal::TerminalDriver,
    }
}

#[cfg(test)]
mod conformance;
