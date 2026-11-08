#[cfg(test)]
pub(super) mod fixtures;

use proto::{PaneId, WsError};
use tokio::sync::mpsc;

use super::{AgentCapabilities, AgentDriver, AgentSession, ApprovalDecision, UnconfirmedSend};
use crate::core::Core;
use crate::pane::Pane;

pub(super) struct ClaudeDriver;

impl AgentDriver for ClaudeDriver {
    fn pending_approval(&self, core: &Core, pane: PaneId) -> Option<super::PendingApproval> {
        pending_hook(core, pane)
    }
    fn approval_is_pending(&self, core: &Core, pane: PaneId, request: &agents::RequestId) -> bool {
        core.hooks.is_pending(pane, request)
    }
    fn input_event<'a>(&self, request: &'a crate::HookRequest) -> super::InputEvent<'a> {
        use super::InputEvent;
        if let Some((session, prompt)) = prompt_hook(request) {
            return InputEvent::TurnStarted { session, prompt };
        }
        if request.agent == "claude"
            && matches!(request.event.as_str(), "Stop" | "StopFailure")
            && request
                .payload
                .get("hook_event_name")
                .and_then(serde_json::Value::as_str)
                == Some(request.event.as_str())
        {
            return InputEvent::TurnEnded;
        }
        if request.event == "SessionEnd" {
            InputEvent::SessionEnded
        } else {
            InputEvent::Ignored
        }
    }

    fn capabilities(&self) -> AgentCapabilities {
        AgentCapabilities::READ
            | AgentCapabilities::SEND
            | AgentCapabilities::ACKNOWLEDGED_SEND
            | AgentCapabilities::STOP
            | AgentCapabilities::APPROVALS
            | AgentCapabilities::DIFFS
            | AgentCapabilities::THINKING
            | AgentCapabilities::PLANS
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
        Ok(Box::new(
            crate::timeline::claude_source::ClaudeSession::open(core, pane, epoch, wake)?,
        ))
    }

    fn send(
        &self,
        _: &Core,
        pane: &Pane,
        _: Option<&str>,
        text: &str,
    ) -> Result<UnconfirmedSend, WsError> {
        super::terminal::send(pane, text)?;
        Ok(UnconfirmedSend::NotConfirmed)
    }

    fn stop(&self, _: &Core, pane: &Pane, _: Option<&str>) -> Result<(), WsError> {
        pane.pty()
            .try_write(vec![0x1b])
            .map_err(|error| WsError::Failed(error.to_string()))
    }

    fn approve(
        &self,
        core: &Core,
        pane: PaneId,
        request: &agents::RequestId,
        decision: ApprovalDecision<'_>,
    ) -> bool {
        core.hooks
            .resolve_with(pane, request, |suggestions, input| {
                approval_response(suggestions, input, decision)
            })
    }
}

pub(super) fn pending_hook(core: &Core, pane: PaneId) -> Option<super::PendingApproval> {
    let held = core.hooks.held(pane)?;
    let command = held.command().map(str::to_owned);
    let editable = (held.agent == Some(proto::AgentKind::Claude) && held.tool == "Bash")
        .then(|| command.clone())
        .flatten();
    Some(super::PendingApproval {
        request: held.request,
        tool: held.tool,
        command,
        editable,
    })
}

pub(super) fn prompt_hook(request: &crate::HookRequest) -> Option<(&str, &str)> {
    if !matches!(request.agent.as_str(), "claude" | "codex")
        || request.event != "UserPromptSubmit"
        || request.payload.get("hook_event_name")?.as_str()? != "UserPromptSubmit"
    {
        return None;
    }
    Some((
        request.payload.get("session_id")?.as_str()?,
        request.payload.get("prompt")?.as_str()?,
    ))
}

pub(super) fn approval_response(
    suggestions: &[serde_json::Value],
    input: &serde_json::Value,
    decision: ApprovalDecision<'_>,
) -> String {
    match decision {
        ApprovalDecision::Choice(choice) => {
            agents::ClaudeCode::permission_response(choice, suggestions).to_string()
        }
        ApprovalDecision::Edited(command) => {
            let mut input = input.clone();
            if let Some(fields) = input.as_object_mut() {
                fields.insert("command".into(), command.into());
            }
            serde_json::json!({
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": { "behavior": "allow", "updatedInput": input },
                }
            })
            .to_string()
        }
    }
}
