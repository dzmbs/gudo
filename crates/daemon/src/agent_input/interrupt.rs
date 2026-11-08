//! Fenced, turn-bound interrupt admission; never a stopped acknowledgement.

use std::sync::Arc;
use std::time::Instant;

use crate::agent_driver::{AgentCapabilities, AgentDriver, driver};
use proto::{ChatSendStatus, WorkspaceRequest, WsError};

use super::draft::Admission;
use super::{AgentInputPhase, lock};
use crate::core::Core;
use crate::ws::ConnCtx;

pub(crate) fn request(
    core: &Arc<Core>,
    conn: &ConnCtx,
    request: WorkspaceRequest,
) -> Result<ChatSendStatus, WsError> {
    if !conn.owner {
        return Err(WsError::Denied(
            "Only the owner can interrupt from Chat.".into(),
        ));
    }
    let pane = match &request {
        WorkspaceRequest::ChatInterruptPrepare { pane_id }
        | WorkspaceRequest::ChatInterrupt { pane_id, .. } => *pane_id,
        _ => return Err(unavailable()),
    };
    let entry = core.pane(pane).ok_or_else(unavailable)?;
    // Same input -> runtime order as authenticated hook admission. A prepared interrupt cannot
    // cross an admitted new turn, even in the same process/session, or escape the exit fence.
    let mut gate = lock(&entry.pane.agent_input_gate);
    let (driver, session) = {
        let runtime = lock(&entry.agent);
        let runtime = runtime.as_ref().ok_or_else(unavailable)?;
        let driver = driver(runtime.kind());
        if !driver
            .current_capabilities(core, pane)
            .contains(AgentCapabilities::STOP)
            || runtime.state() != agents::AgentState::Working
        {
            return Err(unavailable());
        }
        (
            driver,
            runtime
                .session()
                .native_id
                .as_ref()
                .map(|id| id.as_str().to_owned()),
        )
    };
    if !matches!(&gate.phase, AgentInputPhase::Open(_))
        || !core.agent_has_terminal(pane)
        || gate.pending_unproven_writes != 0
    {
        return Err(unavailable());
    }
    admit(
        driver,
        core,
        &entry.pane,
        &mut gate,
        session.as_deref(),
        request,
    )
}

fn admit(
    driver: &dyn AgentDriver,
    core: &Core,
    pane: &crate::pane::Pane,
    gate: &mut super::AgentInputGate,
    session: Option<&str>,
    request: WorkspaceRequest,
) -> Result<ChatSendStatus, WsError> {
    match request {
        WorkspaceRequest::ChatInterruptPrepare { .. } => {
            let offer = gate
                .draft
                .prepare_interrupt(session, Instant::now())
                .ok_or_else(unavailable)?;
            Ok(ChatSendStatus::Prepared {
                ticket: offer.ticket,
                revision: offer.revision,
                needs_confirmation: offer.needs_confirmation,
            })
        }
        WorkspaceRequest::ChatInterrupt {
            ticket,
            confirmed_revision,
            ..
        } => {
            match gate
                .draft
                .admit_interrupt(ticket, session, confirmed_revision, Instant::now())
            {
                Admission::Confirm(offer) => {
                    return Ok(ChatSendStatus::ConfirmationRequired {
                        revision: offer.revision,
                    });
                }
                Admission::Refused => return Ok(ChatSendStatus::NotConfirmed),
                Admission::Ready(()) => {}
            }
            gate.last_user_input_seq = crate::hook_seq();
            gate.advance_revision();
            if matches!(&gate.phase, AgentInputPhase::Open(_))
                && driver.stop(core, pane, session).is_ok()
            {
                Ok(ChatSendStatus::InterruptRequested)
            } else {
                Ok(ChatSendStatus::NotConfirmed)
            }
        }
        _ => Err(unavailable()),
    }
}

fn unavailable() -> WsError {
    WsError::Failed("Chat cannot interrupt this agent right now. Check the terminal.".into())
}
