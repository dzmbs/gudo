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
        _: Option<super::SendAcknowledgement>,
    ) -> Result<UnconfirmedSend, WsError> {
        super::terminal::send(pane, text)?;
        Ok(UnconfirmedSend::NotConfirmed)
    }

    fn stop(
        &self,
        _: &Core,
        pane: &Pane,
        _: Option<&str>,
        _: u64,
        _: proto::Actor,
    ) -> Result<super::StopDelivery, WsError> {
        pane.pty()
            .try_write(vec![0x1b])
            .map_err(|error| WsError::Failed(error.to_string()))?;
        Ok(super::StopDelivery::TerminalEscape)
    }

    fn approve(
        &self,
        core: &Core,
        pane: PaneId,
        request: &agents::RequestId,
        decision: ApprovalDecision<'_>,
        _: super::ApprovalAuthority,
    ) -> bool {
        core.hooks.resolve_with(pane, request, |held, suggestions| {
            approval_response(held, suggestions, decision)
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

/// The hook's answer for `decision`, or `None` when it does not fit the held request (a
/// question allowed without its answers, answers to a permission request).
pub(super) fn approval_response(
    held: &crate::agent::HeldRequest,
    suggestions: &[serde_json::Value],
    decision: ApprovalDecision<'_>,
) -> Option<String> {
    use agents::{ApprovalChoice, ClaudeCode, ClaudePlanAnswer};
    let response = match held.event {
        crate::agent::HeldEvent::Permission => match decision {
            ApprovalDecision::Choice(choice) => {
                ClaudeCode::permission_response(choice, suggestions)
            }
            ApprovalDecision::Edited(command) => {
                let mut input = held.input.clone();
                if let Some(fields) = input.as_object_mut() {
                    fields.insert("command".into(), command.into());
                }
                serde_json::json!({
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": { "behavior": "allow", "updatedInput": input },
                    }
                })
            }
            ApprovalDecision::Refusal(message) => serde_json::json!({
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": { "behavior": "deny", "message": message },
                }
            }),
            ApprovalDecision::Answers(_) => return None,
        },
        crate::agent::HeldEvent::PreToolUse if held.tool == agents::CLAUDE_QUESTION_TOOL => {
            match decision {
                ApprovalDecision::Answers(answers) => {
                    ClaudeCode::question_response(&held.input, answers)
                }
                ApprovalDecision::Choice(ApprovalChoice::Deny) => {
                    ClaudeCode::refusal_response("The user chose not to answer.")
                }
                ApprovalDecision::Refusal(message) => ClaudeCode::refusal_response(message),
                ApprovalDecision::Choice(_) | ApprovalDecision::Edited(_) => return None,
            }
        }
        crate::agent::HeldEvent::PreToolUse => {
            let answer = match decision {
                ApprovalDecision::Choice(ApprovalChoice::AllowOnce) => ClaudePlanAnswer::Approve,
                ApprovalDecision::Choice(ApprovalChoice::Deny) => {
                    ClaudePlanAnswer::KeepPlanning(String::new())
                }
                ApprovalDecision::Refusal(message) => {
                    ClaudePlanAnswer::KeepPlanning(message.to_owned())
                }
                ApprovalDecision::Choice(ApprovalChoice::AllowSession)
                | ApprovalDecision::Edited(_)
                | ApprovalDecision::Answers(_) => return None,
            };
            ClaudeCode::plan_response(&held.input, &answer)
        }
    };
    Some(response.to_string())
}
