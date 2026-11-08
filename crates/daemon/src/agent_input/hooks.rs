use serde_json::Value;

use crate::HookRequest;
use crate::pane::Pane;

pub(crate) fn record(pane: &Pane, request: &HookRequest) {
    if let Some((session, prompt)) = submission(request) {
        super::submitted(pane, session, prompt, request.seq);
    } else if request.event == "SessionEnd" {
        super::agent_exited(pane);
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
