mod claude;
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
    fn snapshot(&self, since: Option<UnixMillis>) -> TimelineSnapshot;
    fn refresh(&mut self, core: &Core, pane: PaneId) -> Result<Vec<TimelineOp>, WsError>;
    fn check_current(&self, core: &Core, pane: PaneId) -> Result<(), WsError>;
    // Owned futures let an RPC reader wait after the service releases its state mutex.
    fn read(&mut self, request: TimelineRead, since: Option<UnixMillis>) -> ReadFuture;
    fn wake(&self) -> mpsc::Sender<()>;
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
    ) -> Result<UnconfirmedSend, WsError>;
    fn stop(&self, core: &Core, pane: &Pane, session: Option<&str>) -> Result<(), WsError>;
    // Role, signature, policy, pending request and audit checks precede delivery.
    fn approve(
        &self,
        core: &Core,
        pane: PaneId,
        request: &agents::RequestId,
        decision: ApprovalDecision<'_>,
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
