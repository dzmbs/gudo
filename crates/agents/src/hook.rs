//! Helpers shared by hook parsers.

use std::path::PathBuf;

use serde::Deserialize;
use serde_json::Value;

use crate::event::{Subagent, SubagentId};
use crate::signal::SessionUpdate;

const MAX_SUMMARY_CHARS: usize = 200;
const MAX_MESSAGE_CHARS: usize = 500;
const MAX_DETAIL_STRING_CHARS: usize = 1024;
const MAX_DETAIL_DEPTH: usize = 6;
const MAX_DETAIL_ITEMS: usize = 32;

/// Fields every Claude and Codex hook payload carries.
#[derive(Debug, Deserialize)]
pub(crate) struct Common {
    pub session_id: Option<String>,
    pub transcript_path: Option<PathBuf>,
    pub cwd: Option<PathBuf>,
    /// Set inside subagents (Claude) — such hooks must not change the lead's state.
    pub agent_id: Option<String>,
    pub agent_type: Option<String>,
}

impl Common {
    pub fn session(&self) -> SessionUpdate {
        SessionUpdate {
            native_id: self.session_id.clone().map(crate::NativeSessionId::new),
            transcript: self.transcript_path.clone(),
            cwd: self.cwd.clone(),
        }
    }

    pub fn subagent(&self) -> Option<Subagent> {
        self.agent_id.as_ref().map(|id| Subagent {
            id: SubagentId::new(id.clone()),
            agent_type: self.agent_type.clone(),
        })
    }
}

/// Truncates to `max` characters, marking the cut with `…`.
pub(crate) fn truncate(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        Some((cut, _)) => format!("{}…", &text[..cut]),
        None => text.to_owned(),
    }
}

/// Truncates a message for an event.
pub(crate) fn message(text: Option<String>) -> Option<String> {
    text.map(|t| truncate(&t, MAX_MESSAGE_CHARS))
}

/// One line describing a tool call: the command, path, URL or description.
pub(crate) fn tool_summary(input: &Value) -> Option<String> {
    [
        "command",
        "file_path",
        "path",
        "url",
        "pattern",
        "description",
    ]
    .iter()
    .find_map(|key| input.get(key)?.as_str())
    .map(|s| truncate(s.lines().next().unwrap_or(""), MAX_SUMMARY_CHARS))
}

/// Bounds a tool input for the wire: long strings are cut and deep or wide values elided.
pub(crate) fn bounded_detail(value: &Value) -> Value {
    fn walk(value: &Value, depth: usize) -> Value {
        if depth > MAX_DETAIL_DEPTH {
            return Value::String("…".into());
        }
        match value {
            Value::String(s) => Value::String(truncate(s, MAX_DETAIL_STRING_CHARS)),
            Value::Array(items) => items
                .iter()
                .take(MAX_DETAIL_ITEMS)
                .map(|v| walk(v, depth + 1))
                .collect(),
            Value::Object(map) => map
                .iter()
                .take(MAX_DETAIL_ITEMS)
                .map(|(k, v)| (k.clone(), walk(v, depth + 1)))
                .collect(),
            other => other.clone(),
        }
    }
    walk(value, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncates_on_char_boundaries() {
        assert_eq!(truncate("héllo", 2), "hé…");
        assert_eq!(truncate("hi", 2), "hi");
    }

    #[test]
    fn summarizes_tool_input() {
        let input = serde_json::json!({"command": "npm test\nmore", "description": "Run"});
        assert_eq!(tool_summary(&input).as_deref(), Some("npm test"));
        assert_eq!(tool_summary(&serde_json::json!({})), None);
    }

    #[test]
    fn bounds_detail() {
        let long = "x".repeat(5000);
        let detail = bounded_detail(&serde_json::json!({ "content": long }));
        assert_eq!(
            detail["content"].as_str().unwrap().chars().count(),
            MAX_DETAIL_STRING_CHARS + 1
        );
    }
}
