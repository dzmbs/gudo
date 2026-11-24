//! pi: Chat reads its session file. A pi the daemon launched also connects through its bridge
//! extension: Chat then streams its replies, and Send, Stop and setting changes go to pi
//! directly. Without the bridge, Send pastes into the pi the daemon launched.

pub(crate) mod bridge;
#[cfg_attr(
    not(test),
    expect(dead_code, reason = "the agent-configuration requests call it")
)]
pub(crate) mod config;
mod live;
mod session;
mod tail;

use proto::{PaneId, WsError};
use tokio::sync::mpsc;

use super::{
    AgentCapabilities, AgentDriver, AgentSession, ApprovalAuthority, ApprovalDecision, InputEvent,
    PendingApproval, StopDelivery, UnconfirmedSend,
};
use crate::core::{Core, PaneEntry, lock};
use crate::pane::Pane;

pub(super) struct PiDriver;

/// Sends a prompt to the pane's connected pi; its answer confirms the send.
fn prompt(
    core: &Core,
    pane: &Pane,
    session: Option<&str>,
    text: &str,
    images: &[std::path::PathBuf],
    acknowledgement: Option<super::SendAcknowledgement>,
) -> Result<UnconfirmedSend, WsError> {
    let (entry, bridge) = connected(core, pane.id).ok_or_else(|| {
        WsError::Unavailable("This pi is not connected to the helper. Use Terminal.".into())
    })?;
    let reply = bridge.request(&bridge::Request::Prompt { text, images })?;
    let session = session.unwrap_or_default().to_owned();
    tokio::spawn(async move {
        let accepted = reply.await.is_ok();
        if let Some(acknowledgement) = acknowledgement {
            if accepted {
                lock(&entry.pane.agent_input_gate).delivered_beside_terminal(&session);
            }
            let _ = acknowledgement.receipt.send(if accepted {
                crate::agent_input::Receipt::Confirmed
            } else {
                crate::agent_input::Receipt::NotConfirmed
            });
        }
    });
    Ok(UnconfirmedSend::NotConfirmed)
}

/// Whether the pane's connected pi is running a prompt.
pub(crate) fn is_running(entry: &PaneEntry) -> bool {
    bridge::of(entry).is_some_and(|bridge| bridge.state().busy)
}

/// The session the pane's pi writes, as the pane record or its bridge knows it.
pub(crate) fn session_of(entry: &PaneEntry) -> Option<String> {
    lock(&entry.record)
        .resumable
        .as_ref()
        .and_then(|agent| agent.session_id.clone())
        .or_else(|| bridge::of(entry)?.state().session?.session_id)
}

/// The pane and its pi, while its bridge is connected. Only a pi the daemon launched loads the
/// bridge; callers hold the pane's input gate, so this does not take it.
fn connected(
    core: &Core,
    pane: PaneId,
) -> Option<(std::sync::Arc<PaneEntry>, std::sync::Arc<bridge::Bridge>)> {
    let entry = core.pane(pane)?;
    let bridge = bridge::of(&entry)?;
    Some((entry, bridge))
}

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

    fn current_capabilities(&self, core: &Core, pane: PaneId) -> AgentCapabilities {
        let connected = connected(core, pane).map_or(AgentCapabilities(0), |_| {
            AgentCapabilities::STOP
                | AgentCapabilities::STREAMING_DELTAS
                | AgentCapabilities::THINKING
        });
        self.capabilities() | connected
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
        core: &Core,
        pane: &Pane,
        session: Option<&str>,
        text: &str,
        acknowledgement: Option<super::SendAcknowledgement>,
    ) -> Result<UnconfirmedSend, WsError> {
        if connected(core, pane.id).is_none() {
            super::terminal::send(pane, text)?;
            return Ok(UnconfirmedSend::SentNotConfirmed);
        }
        prompt(core, pane, session, text, &[], acknowledgement)
    }

    fn send_images(
        &self,
        core: &Core,
        pane: &Pane,
        session: Option<&str>,
        text: &str,
        images: &[std::path::PathBuf],
        acknowledgement: Option<super::SendAcknowledgement>,
    ) -> Result<UnconfirmedSend, WsError> {
        prompt(core, pane, session, text, images, acknowledgement)
    }

    fn stop(
        &self,
        core: &Core,
        pane: &Pane,
        _session: Option<&str>,
        _revision: u64,
        _actor: proto::Actor,
    ) -> Result<StopDelivery, WsError> {
        let (_, bridge) = connected(core, pane.id).ok_or_else(|| {
            WsError::Failed("Chat cannot interrupt this pi. Press Escape in Terminal.".into())
        })?;
        let reply = bridge.request(&bridge::Request::Abort)?;
        tokio::spawn(async move {
            let _ = reply.await;
        });
        Ok(StopDelivery::AgentRequest)
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
