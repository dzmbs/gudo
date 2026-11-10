//! Fenced, turn-bound interrupt admission; never a stopped acknowledgement.

use std::sync::Arc;
use std::time::Instant;

use crate::agent_driver::{AgentCapabilities, AgentDriver, driver};
use proto::{ChatSendStatus, WorkspaceRequest, WsError};

use super::draft::Admission;
use super::{AgentInputPhase, lock};
use crate::core::{Core, PaneEntry};
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
    let (driver, session) = stop_target(core, &entry)?;
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
        conn.actor,
    )
}

/// The agent guard is released before the driver reads capabilities, which take the Codex
/// source: bootstrap holds that source and then the agent.
fn stop_target(
    core: &Core,
    entry: &PaneEntry,
) -> Result<(&'static dyn AgentDriver, Option<String>), WsError> {
    let (kind, session, working) = {
        let runtime = lock(&entry.agent);
        let runtime = runtime.as_ref().ok_or_else(unavailable)?;
        (
            runtime.kind(),
            runtime
                .session()
                .native_id
                .as_ref()
                .map(|id| id.as_str().to_owned()),
            runtime.state() == agents::AgentState::Working,
        )
    };
    let driver = driver(kind);
    let stoppable = driver
        .current_capabilities(core, entry.pane.id)
        .contains(AgentCapabilities::STOP);
    if !working || !stoppable {
        return Err(unavailable());
    }
    Ok((driver, session))
}

fn admit(
    driver: &dyn AgentDriver,
    core: &Core,
    pane: &crate::pane::Pane,
    gate: &mut super::AgentInputGate,
    session: Option<&str>,
    request: WorkspaceRequest,
    actor: proto::Actor,
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
                && driver
                    .stop(core, pane, session, gate.revision, actor)
                    .is_ok()
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_input::chat_tests::raw_fixture;

    #[tokio::test(flavor = "multi_thread")]
    async fn stop_admission_never_waits_for_the_codex_source_while_holding_the_agent() {
        let raw = raw_fixture().await;
        *lock(&raw.entry.agent) = Some(crate::agent::AgentRuntime::structured(
            proto::AgentKind::Codex,
            raw.entry.pane.id,
            crate::agent::adapter(proto::AgentKind::Codex),
        ));
        *lock(&raw.entry.codex) = Some(crate::agent_driver::codex::tests::source());
        let codex = lock(&raw.entry.codex);
        let core = Arc::clone(&raw.daemon.core);
        let entry = Arc::clone(&raw.entry);
        let admission = std::thread::spawn(move || stop_target(&core, &entry).is_ok());
        let deadline = Instant::now() + std::time::Duration::from_secs(2);
        let mut agent_free = false;
        while Instant::now() < deadline && !agent_free {
            std::thread::sleep(std::time::Duration::from_millis(50));
            agent_free = raw.entry.agent.try_lock().is_ok();
        }
        drop(codex);
        assert!(!admission.join().unwrap());
        assert!(
            agent_free,
            "stop admission held the agent while waiting for Codex"
        );
        raw.daemon.shutdown().await;
    }
}
