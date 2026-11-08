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
        if live(core, pane) {
            return None;
        }
        super::claude::pending_hook(core, pane)
    }
    fn approval_is_pending(&self, core: &Core, pane: PaneId, request: &agents::RequestId) -> bool {
        !live(core, pane) && core.hooks.is_pending(pane, request)
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
        if live(core, pane) {
            AgentCapabilities::READ | AgentCapabilities::STREAMING_DELTAS
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
        _: Option<&str>,
        text: &str,
    ) -> Result<UnconfirmedSend, WsError> {
        if live(core, pane.id) {
            return Err(WsError::Unavailable(
                "Use Terminal to send to this Codex session.".into(),
            ));
        }
        send(pane, text)?;
        Ok(UnconfirmedSend::SentNotConfirmed)
    }

    fn stop(&self, _: &Core, _: &Pane, _: Option<&str>) -> Result<(), WsError> {
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
    ) -> bool {
        if live(core, pane) {
            return false;
        }
        // The terminal hook lane retains its held PermissionRequest reply format, not RPC approvals.
        core.hooks
            .resolve_with(pane, request, |suggestions, input| {
                super::claude::approval_response(suggestions, input, decision)
            })
    }
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
