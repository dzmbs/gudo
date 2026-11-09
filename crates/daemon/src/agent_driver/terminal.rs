#[cfg(test)]
pub(super) mod fixtures;

use proto::{PaneId, WsError};
use tokio::sync::mpsc;

use super::{AgentCapabilities, AgentDriver, AgentSession, ApprovalDecision, UnconfirmedSend};
use crate::core::Core;
use crate::pane::Pane;

pub(super) struct TerminalDriver;

impl AgentDriver for TerminalDriver {
    fn pending_approval(&self, core: &Core, pane: PaneId) -> Option<super::PendingApproval> {
        if let Some(source) = source(core, pane) {
            return source.pending_approval();
        }
        super::claude::pending_hook(core, pane)
    }
    fn approval_is_pending(&self, core: &Core, pane: PaneId, request: &agents::RequestId) -> bool {
        source(core, pane).map_or_else(
            || core.hooks.is_pending(pane, request),
            |source| source.approval_pending(request),
        )
    }
    fn input_event<'a>(&self, request: &'a crate::HookRequest) -> super::InputEvent<'a> {
        use super::InputEvent;
        let submission = super::claude::prompt_hook(request).or_else(|| notify_submission(request));
        if let Some((session, prompt)) = submission {
            return InputEvent::Submitted { session, prompt };
        }
        if request.event == "SessionEnd" {
            InputEvent::SessionEnded
        } else {
            InputEvent::Ignored
        }
    }

    fn capabilities(&self) -> AgentCapabilities {
        AgentCapabilities::SEND | AgentCapabilities::ACKNOWLEDGED_SEND
    }

    fn current_capabilities(&self, core: &Core, pane: PaneId) -> AgentCapabilities {
        if let Some(source) = source(core, pane) {
            source.capabilities()
        } else {
            self.capabilities()
        }
    }

    fn check_prompt(&self, text: &str) -> Result<(), WsError> {
        check_prompt(text)
    }

    fn open(
        &self,
        core: &Core,
        pane: PaneId,
        _: u64,
        wake: mpsc::Sender<()>,
    ) -> Result<Box<dyn AgentSession>, WsError> {
        if live(core, pane) {
            return super::codex::open(core, pane, wake);
        }
        Err(WsError::Unavailable(
            "Chat is not available for this agent".into(),
        ))
    }

    fn send(
        &self,
        core: &Core,
        pane: &Pane,
        session: Option<&str>,
        text: &str,
        acknowledgement: Option<super::SendAcknowledgement>,
    ) -> Result<UnconfirmedSend, WsError> {
        if let Some(source) = source(core, pane.id) {
            return source.send_prompt(
                session,
                text,
                acknowledgement.ok_or_else(|| {
                    WsError::Unavailable("Codex send requires an admission receipt.".into())
                })?,
            );
        }
        send(pane, text)?;
        Ok(UnconfirmedSend::SentNotConfirmed)
    }

    fn stop(
        &self,
        core: &Core,
        pane: &Pane,
        session: Option<&str>,
        revision: u64,
        actor: proto::Actor,
    ) -> Result<(), WsError> {
        if let Some(source) = source(core, pane.id) {
            return source.interrupt(session, revision, actor);
        }
        Err(WsError::Failed(
            "Chat cannot interrupt this agent right now. Check the terminal.".into(),
        ))
    }

    fn approve(
        &self,
        core: &Core,
        pane: PaneId,
        request: &agents::RequestId,
        decision: ApprovalDecision<'_>,
        authority: super::ApprovalAuthority,
    ) -> bool {
        if let Some(source) = source(core, pane) {
            let delivered = source.approve(request, decision, authority);
            if !delivered {
                source.control_failed();
            }
            return delivered;
        }
        // The terminal hook lane retains its held PermissionRequest reply format, not RPC approvals.
        core.hooks
            .resolve_with(pane, request, |suggestions, input| {
                super::claude::approval_response(suggestions, input, decision)
            })
    }
}

fn source(core: &Core, pane: PaneId) -> Option<std::sync::Arc<super::codex::Live>> {
    core.pane(pane)
        .and_then(|entry| crate::core::lock(&entry.codex).clone())
}

fn live(core: &Core, pane: PaneId) -> bool {
    core.pane(pane)
        .is_some_and(|entry| crate::core::lock(&entry.codex).is_some())
}

fn notify_submission(request: &crate::HookRequest) -> Option<(&str, &str)> {
    if request.agent != "codex"
        || request.event != crate::CODEX_NOTIFY_EVENT
        || request.payload.get("type")?.as_str()? != "agent-turn-complete"
    {
        return None;
    }
    let [serde_json::Value::String(prompt)] = request
        .payload
        .get("input-messages")?
        .as_array()?
        .as_slice()
    else {
        return None;
    };
    Some((request.payload.get("thread-id")?.as_str()?, prompt))
}

pub(super) fn check_prompt(text: &str) -> Result<(), WsError> {
    crate::mp::prompt::check(text).map_err(|error| WsError::Failed(error.to_string()))
}

pub(super) fn send(pane: &Pane, text: &str) -> Result<(), WsError> {
    let bytes = format!("\x1b[200~{text}\x1b[201~\r").into_bytes();
    pane.pty()
        .try_write(bytes)
        .map_err(|error| WsError::Failed(error.to_string()))
}
