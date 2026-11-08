use super::AgentInputGate;
use crate::HookRequest;
use crate::agent_driver::InputEvent;

// Called only after token, pane, agent-kind and tracked-session admission in handle_hook.
pub(crate) fn record(gate: &mut AgentInputGate, request: &HookRequest) {
    match event(request) {
        InputEvent::TurnStarted { session, prompt } => {
            // An older hook cannot renew eligibility after admitted input.
            let turn = (request.seq > gate.last_user_input_seq).then_some(session);
            gate.draft.record_turn(turn, request.seq);
            super::submitted_locked(gate, session, prompt, request.seq);
        }
        InputEvent::Submitted { session, prompt } => {
            super::submitted_locked(gate, session, prompt, request.seq)
        }
        InputEvent::TurnEnded => gate.draft.record_turn(None, request.seq),
        InputEvent::SessionEnded => gate.draft.close(),
        InputEvent::Ignored => {}
    }
}

fn event(request: &HookRequest) -> InputEvent<'_> {
    crate::agent::agent_kind(&request.agent).map_or(InputEvent::Ignored, |kind| {
        crate::agent_driver::driver(kind).input_event(request)
    })
}

#[cfg(test)]
fn submission(request: &HookRequest) -> Option<(&str, &str)> {
    match event(request) {
        InputEvent::Submitted { session, prompt } | InputEvent::TurnStarted { session, prompt } => {
            Some((session, prompt))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

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
