//! pi: Chat reads its session file; Send pastes into the pi the daemon launched. pi has no
//! hooks, approvals or interrupt the daemon can drive.

mod session;
mod tail;

use proto::{PaneId, WsError};
use tokio::sync::mpsc;

use super::{
    AgentCapabilities, AgentDriver, AgentSession, ApprovalAuthority, ApprovalDecision, InputEvent,
    PendingApproval, StopDelivery, UnconfirmedSend,
};
use crate::core::Core;
use crate::pane::Pane;

pub(super) struct PiDriver;

impl AgentDriver for PiDriver {
    fn pending_approval(&self, _core: &Core, _pane: PaneId) -> Option<PendingApproval> {
        None
    }

    fn approval_is_pending(
        &self,
        _core: &Core,
        _pane: PaneId,
        _request: &agents::RequestId,
    ) -> bool {
        false
    }

    fn input_event<'a>(&self, _request: &'a crate::HookRequest) -> InputEvent<'a> {
        InputEvent::Ignored
    }

    // Send also needs the pane's exit fence open, which the caller checks under its lock: a pi
    // started by hand has none.
    fn capabilities(&self) -> AgentCapabilities {
        AgentCapabilities::SEND | AgentCapabilities::ACKNOWLEDGED_SEND
    }

    fn check_prompt(&self, text: &str) -> Result<(), WsError> {
        super::terminal::check_prompt(text)
    }

    fn open(
        &self,
        core: &Core,
        pane: PaneId,
        epoch: u64,
        wake: mpsc::Sender<()>,
    ) -> Result<Box<dyn AgentSession>, WsError> {
        tail::open(core, pane, epoch, wake)
    }

    fn send(
        &self,
        _core: &Core,
        pane: &Pane,
        _session: Option<&str>,
        text: &str,
        _acknowledgement: Option<super::SendAcknowledgement>,
    ) -> Result<UnconfirmedSend, WsError> {
        super::terminal::send(pane, text)?;
        Ok(UnconfirmedSend::SentNotConfirmed)
    }

    fn stop(
        &self,
        _core: &Core,
        _pane: &Pane,
        _session: Option<&str>,
        _revision: u64,
        _actor: proto::Actor,
    ) -> Result<StopDelivery, WsError> {
        Err(WsError::Failed(
            "Chat cannot interrupt pi. Press Escape in Terminal.".into(),
        ))
    }

    fn approve(
        &self,
        _core: &Core,
        _pane: PaneId,
        _request: &agents::RequestId,
        _decision: ApprovalDecision<'_>,
        _authority: ApprovalAuthority,
    ) -> bool {
        false
    }
}
