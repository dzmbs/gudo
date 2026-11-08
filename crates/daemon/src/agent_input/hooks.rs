use serde_json::Value;

use super::AgentInputGate;
use crate::HookRequest;

pub(crate) fn record(gate: &mut AgentInputGate, request: &HookRequest) {
    if let Some((session, prompt)) = submission(request) {
        if request.agent == "claude" {
            // An older, delayed hook cannot renew eligibility after an admitted Escape/input.
            // Retire the previous identity too: the current turn is no longer unambiguous.
            let turn = (request.seq > gate.last_user_input_seq).then_some(session);
            gate.draft.record_turn(turn, request.seq);
        }
        super::submitted_locked(gate, session, prompt, request.seq);
    } else if request.agent == "claude"
        && matches!(request.event.as_str(), "Stop" | "StopFailure")
        && request
            .payload
            .get("hook_event_name")
            .and_then(Value::as_str)
            == Some(request.event.as_str())
    {
        gate.draft.record_turn(None, request.seq);
    } else if request.event == "SessionEnd" {
        gate.draft.close();
    }
}

// Called only after token, pane, agent-kind and tracked-session admission in handle_hook.
fn submission(request: &HookRequest) -> Option<(&str, &str)> {
    let payload = &request.payload;
    if matches!(request.agent.as_str(), "claude" | "codex")
        && request.event == "UserPromptSubmit"
        && payload.get("hook_event_name")?.as_str()? == "UserPromptSubmit"
    {
        return Some((
            payload.get("session_id")?.as_str()?,
            payload.get("prompt")?.as_str()?,
        ));
    }
    if request.agent != "codex"
        || request.event != crate::CODEX_NOTIFY_EVENT
        || payload.get("type")?.as_str()? != "agent-turn-complete"
    {
        return None;
    }
    let [Value::String(prompt)] = payload.get("input-messages")?.as_array()?.as_slice() else {
        return None;
    };
    Some((payload.get("thread-id")?.as_str()?, prompt))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_a_claude_prompt_hook_supplies_interrupt_turn_identity_and_stop_retires_it() {
        let mut gate = AgentInputGate::default();
        let mut request = HookRequest {
            v: 1,
            token: "fixture".into(),
            pane: "7".into(),
            agent: "claude".into(),
            event: "UserPromptSubmit".into(),
            seq: 10,
            payload: json!({"hook_event_name":"UserPromptSubmit", "session_id":"session", "prompt":"hello"}),
        };
        record(&mut gate, &request);
        assert!(
            gate.draft
                .prepare_interrupt(Some("session"), std::time::Instant::now())
                .is_some()
        );
        request.event = "Stop".into();
        request.payload["hook_event_name"] = json!("Stop");
        request.seq = 9;
        record(&mut gate, &request);
        assert!(
            gate.draft
                .prepare_interrupt(Some("session"), std::time::Instant::now())
                .is_some()
        );
        request.seq = 11;
        record(&mut gate, &request);
        assert!(
            gate.draft
                .prepare_interrupt(Some("session"), std::time::Instant::now())
                .is_none()
        );
        assert!(matches!(
            gate.phase,
            super::super::AgentInputPhase::Disabled
        ));
        request.agent = "codex".into();
        request.event = crate::CODEX_NOTIFY_EVENT.into();
        request.seq = 12;
        request.payload = json!({"type":"agent-turn-complete", "thread-id":"session", "input-messages":["hello"]});
        record(&mut gate, &request);
        assert!(
            gate.draft
                .prepare_interrupt(Some("session"), std::time::Instant::now())
                .is_none()
        );
    }

    #[test]
    fn a_prompt_hook_older_than_last_input_cannot_renew_interrupt_identity() {
        let mut gate = AgentInputGate::default();
        let mut request = HookRequest {
            v: 1,
            token: "fixture".into(),
            pane: "7".into(),
            agent: "claude".into(),
            event: "UserPromptSubmit".into(),
            seq: 10,
            payload: json!({"hook_event_name":"UserPromptSubmit", "session_id":"session", "prompt":"hello"}),
        };
        record(&mut gate, &request);
        gate.last_user_input_seq = 20;
        request.seq = 19;
        record(&mut gate, &request);
        assert!(
            gate.draft
                .prepare_interrupt(Some("session"), std::time::Instant::now())
                .is_none()
        );
        request.seq = 21;
        record(&mut gate, &request);
        assert!(
            gate.draft
                .prepare_interrupt(Some("session"), std::time::Instant::now())
                .is_some()
        );
    }

    #[test]
    fn codex_notify_requires_one_exact_input_message_and_thread_identity() {
        let mut request = HookRequest {
            v: 1,
            token: "fixture".into(),
            pane: "7".into(),
            agent: "codex".into(),
            event: crate::CODEX_NOTIFY_EVENT.into(),
            seq: 1,
            payload: json!({"type":"agent-turn-complete", "thread-id":"thread", "input-messages":["hello"]}),
        };
        assert_eq!(submission(&request), Some(("thread", "hello")));
        for messages in [
            json!([]),
            json!(["hello", "other"]),
            json!([1]),
            Value::Null,
        ] {
            request.payload["input-messages"] = messages;
            assert_eq!(submission(&request), None);
        }
        request.payload["input-messages"] = json!(["hello"]);
        request.payload["thread-id"] = Value::Null;
        assert_eq!(submission(&request), None);
    }
}
