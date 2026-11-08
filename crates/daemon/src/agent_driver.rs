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

bitflags::bitflags! {
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(crate) struct AgentCapabilities: u16 {
        const READ = 1 << 0;
        const SEND = 1 << 1;
        const ACKNOWLEDGED_SEND = 1 << 2;
        const STOP = 1 << 3;
        const APPROVALS = 1 << 4;
        const DIFFS = 1 << 5;
        const STREAMING_DELTAS = 1 << 6;
        const THINKING = 1 << 7;
        const PLANS = 1 << 8;
    }
}

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

pub(crate) trait AgentDriver: Send + Sync {
    fn input_event<'a>(&self, request: &'a crate::HookRequest) -> InputEvent<'a>;
    fn editable_command<'a>(&self, _: &'a crate::agent::HeldRequest) -> Option<&'a str> {
        None
    }
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
