use super::{CodexBindingError, CodexItem, CodexTurnOutcome, parse, validate_id};
use serde::Deserialize;
use std::collections::HashSet;

/// History from a correlated thread reply; this payload alone proves no pane ownership.
#[derive(Debug, Deserialize)]
pub struct CodexThreadHistory {
    pub id: String,
    /// The app-server's thread context, not the daemon's launch-directory guess.
    pub cwd: Option<std::path::PathBuf>,
    /// Absent history is different from a complete empty history.
    pub turns: Option<Vec<CodexHistoryTurn>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHistoryTurn {
    pub id: String,
    pub status: CodexHistoryStatus,
    pub items: Vec<CodexItem>,
    items_view: Option<String>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CodexHistoryStatus {
    InProgress,
    Completed,
    Interrupted,
    Failed,
    #[serde(other)]
    Unknown,
}

impl CodexHistoryStatus {
    pub fn outcome(&self) -> Option<CodexTurnOutcome> {
        match self {
            Self::InProgress => None,
            Self::Completed => Some(CodexTurnOutcome::Completed),
            Self::Interrupted => Some(CodexTurnOutcome::Interrupted),
            Self::Failed => Some(CodexTurnOutcome::Failed),
            Self::Unknown => Some(CodexTurnOutcome::Unknown),
        }
    }
}

impl CodexThreadHistory {
    /// Parses bounded history without treating an unsolicited reply as a binding.
    /// # Errors
    /// Rejects malformed frames, duplicate identities and more than one active turn.
    pub fn parse(frame: &str) -> Result<Self, CodexBindingError> {
        #[derive(Deserialize)]
        struct Reply {
            result: ResultData,
        }
        #[derive(Deserialize)]
        struct ResultData {
            thread: CodexThreadHistory,
        }
        let reply: Reply = parse(frame)?;
        let history = reply.result.thread;
        validate_id(&history.id)?;
        if let Some(cwd) = &history.cwd {
            let bytes = cwd.as_os_str().as_encoded_bytes();
            if !cwd.is_absolute() || bytes.len() > 4096 || bytes.contains(&0) {
                return Err(CodexBindingError::InvalidFrame);
            }
        }
        let mut turns = HashSet::new();
        let mut active = 0;
        for turn in history.turns.iter().flatten() {
            validate_id(&turn.id)?;
            if turn
                .items_view
                .as_deref()
                .is_some_and(|view| view != "full")
            {
                return Err(CodexBindingError::InvalidFrame);
            }
            if !turns.insert(&turn.id) {
                return Err(CodexBindingError::InvalidFrame);
            }
            active += usize::from(turn.status == CodexHistoryStatus::InProgress);
            let mut items = HashSet::new();
            for item in &turn.items {
                let id = match item {
                    CodexItem::UserMessage { id, .. }
                    | CodexItem::AgentMessage { id, .. }
                    | CodexItem::CommandExecution { id, .. }
                    | CodexItem::Reasoning { id, .. } => id,
                    CodexItem::Unsupported => continue,
                };
                validate_id(id)?;
                if !items.insert(id) {
                    return Err(CodexBindingError::InvalidFrame);
                }
            }
        }
        if active > 1 {
            return Err(CodexBindingError::InvalidFrame);
        }
        Ok(history)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn history_preserves_turn_status_and_rejects_ambiguous_identity() {
        let mut frame = json!({"result":{"thread":{"id":"thread","turns":[{"id":"turn","status":"completed","items":[{"type":"agentMessage","id":"message","text":"remembered"}]}]}}});
        let history = CodexThreadHistory::parse(&frame.to_string()).unwrap();
        assert_eq!(
            history.turns.unwrap()[0].status.outcome(),
            Some(CodexTurnOutcome::Completed)
        );
        let turn = frame["result"]["thread"]["turns"][0].clone();
        frame["result"]["thread"]["turns"]
            .as_array_mut()
            .unwrap()
            .push(turn);
        assert!(CodexThreadHistory::parse(&frame.to_string()).is_err());
        frame["result"]["thread"]["turns"][1]["id"] = json!("other");
        frame["result"]["thread"]["turns"][0]["status"] = json!("inProgress");
        frame["result"]["thread"]["turns"][1]["status"] = json!("inProgress");
        assert!(CodexThreadHistory::parse(&frame.to_string()).is_err());
    }

    #[test]
    fn history_larger_than_one_websocket_read_still_parses() {
        let text = "remembered ".repeat(32 * 1024);
        let frame = json!({"result":{"thread":{"id":"thread","turns":[{"id":"turn","status":"completed","items":[{"type":"agentMessage","id":"message","text":text}]}]}}});
        let history = CodexThreadHistory::parse(&frame.to_string()).unwrap();
        assert_eq!(history.turns.unwrap().len(), 1);
    }

    #[test]
    fn thread_context_requires_an_absolute_non_nul_directory() {
        for cwd in ["relative", "/invalid\0directory"] {
            let frame = json!({"result":{"thread":{"id":"thread","cwd":cwd,"turns":[]}}});
            assert!(CodexThreadHistory::parse(&frame.to_string()).is_err());
        }
    }

    #[test]
    fn duplicate_items_and_missing_history_are_not_silently_empty_conversations() {
        let frame = json!({"result":{"thread":{"id":"thread"}}});
        assert!(
            CodexThreadHistory::parse(&frame.to_string())
                .unwrap()
                .turns
                .is_none()
        );
        let frame = json!({"result":{"thread":{"id":"thread","turns":[{"id":"turn","status":"completed","items":[{"type":"agentMessage","id":"same","text":"first"},{"type":"agentMessage","id":"same","text":"second"}]}]}}});
        assert!(CodexThreadHistory::parse(&frame.to_string()).is_err());
    }
}
