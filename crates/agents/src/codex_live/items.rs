use serde::Deserialize;

/// Versioned app-server items retained by the Codex adapter, not the common wire protocol.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum CodexItem {
    UserMessage {
        id: String,
        content: Vec<CodexInput>,
    },
    AgentMessage {
        id: String,
        text: String,
    },
    #[serde(rename_all = "camelCase")]
    CommandExecution {
        id: String,
        command: String,
        status: String,
        aggregated_output: Option<String>,
        exit_code: Option<i32>,
        duration_ms: Option<u64>,
    },
    Reasoning {
        id: String,
        summary: Vec<String>,
        content: Vec<String>,
    },
    #[serde(other)]
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum CodexInput {
    Text {
        text: String,
    },
    #[serde(other)]
    Unsupported,
}
