use std::sync::Arc;
use std::time::Instant;

use proto::{AgentKind, ChatSendStatus, WorkspaceRequest, WsError};

use super::draft::{Admission, Receipt};
use super::{AgentInputPhase, lock};
use crate::core::Core;
use crate::ws::ConnCtx;

pub(crate) async fn request(
    core: &Arc<Core>,
    conn: &ConnCtx,
    request: WorkspaceRequest,
) -> Result<ChatSendStatus, WsError> {
    if !conn.owner {
        return Err(WsError::Denied("Only the owner can send from Chat.".into()));
    }
    let pane = match &request {
        WorkspaceRequest::ChatPrepare { pane_id } | WorkspaceRequest::ChatSend { pane_id, .. } => {
            *pane_id
        }
        _ => return Err(unavailable()),
    };
    let entry = core.pane(pane).ok_or_else(unavailable)?;
    let (kind, session) = {
        let agent = lock(&entry.agent);
        let agent = agent.as_ref().ok_or_else(unavailable)?;
        (
            agent.kind(),
            agent
                .session()
                .native_id
                .as_ref()
                .map(|id| id.as_str().to_owned()),
        )
    };
    let bracketed = entry.pane.line_snapshot().bracketed;
    let (mut receipt, audit) = {
        let mut gate = lock(&entry.pane.agent_input_gate);
        if !matches!(&gate.phase, AgentInputPhase::Open(_))
            || !core.agent_has_terminal(pane)
            || !bracketed
            || gate.pending_unproven_writes != 0
        {
            return Err(unavailable());
        }
        match request {
            WorkspaceRequest::ChatPrepare { .. } => {
                let offer = gate
                    .draft
                    .prepare(session.as_deref(), Instant::now())
                    .ok_or_else(unavailable)?;
                return Ok(ChatSendStatus::Prepared {
                    ticket: offer.ticket,
                    revision: offer.revision,
                    needs_confirmation: offer.needs_confirmation,
                });
            }
            WorkspaceRequest::ChatSend {
                ticket,
                text,
                confirmed_revision,
                ..
            } => {
                crate::mp::prompt::check(&text)
                    .map_err(|error| WsError::Failed(error.to_string()))?;
                let receipt = match gate.draft.admit(
                    ticket,
                    session.as_deref(),
                    &text,
                    confirmed_revision,
                    Instant::now(),
                ) {
                    Admission::Confirm(offer) => {
                        return Ok(ChatSendStatus::ConfirmationRequired {
                            revision: offer.revision,
                        });
                    }
                    Admission::Refused => return Ok(ChatSendStatus::NotConfirmed),
                    Admission::Ready(receipt) => receipt,
                };
                // The fence and ticket remain locked through the single atomic queue admission.
                // No delayed Return, prompt clearing, retry or write into a replacement process.
                let bytes = format!("\x1b[200~{text}\x1b[201~\r").into_bytes();
                gate.last_user_input_seq = crate::hook_seq();
                gate.advance_revision();
                let queued = matches!(&gate.phase, AgentInputPhase::Open(_))
                    && entry.pane.pty().try_write(bytes).is_ok();
                if !queued {
                    gate.draft.finish(Receipt::NotConfirmed);
                }
                let audit = queued.then(|| prompt_audit(conn.actor, pane, &text));
                (receipt, audit)
            }
            _ => return Err(unavailable()),
        }
    };
    // Disk I/O must not hold the input/exit mutex or delay a hook from publishing its receipt.
    if let Some(audit) = audit {
        core.mp.audit.append(proto::AuditKind::Prompt, audit);
    }
    let _ = tokio::time::timeout(
        super::draft::CONFIRMATION_WAIT,
        receipt.wait_for(|value| *value != Receipt::Waiting),
    )
    .await;
    lock(&entry.pane.agent_input_gate)
        .draft
        .expire(Instant::now());
    let status = match *receipt.borrow() {
        Receipt::Confirmed => ChatSendStatus::Confirmed,
        Receipt::Expired if kind == AgentKind::Codex => ChatSendStatus::SentNotConfirmed,
        Receipt::Waiting | Receipt::Expired | Receipt::NotConfirmed => ChatSendStatus::NotConfirmed,
    };
    Ok(status)
}

fn prompt_audit(actor: proto::Actor, pane: proto::PaneId, text: &str) -> crate::mp::AuditEntry {
    let digest = grants::sha256(&[text.as_bytes()]);
    crate::mp::AuditEntry {
        actor: Some(actor),
        pane_id: Some(pane),
        detail: format!(
            "chat prompt of {} chars, sha256 {}",
            text.chars().count(),
            crate::fsutil::hex(&digest[..8])
        ),
        ..crate::mp::AuditEntry::default()
    }
}

fn unavailable() -> WsError {
    WsError::Failed("Chat cannot send to this agent right now. Check the terminal.".into())
}
