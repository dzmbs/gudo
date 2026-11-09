use serde::{Deserialize, Deserializer};

/// The command output kept for Chat; the full output stays in Terminal.
pub const CODEX_OUTPUT_TAIL: usize = 64 * 1024;

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
        #[serde(default, deserialize_with = "output_tail")]
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

fn output_tail<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<String>, D::Error> {
    Ok(Option::<String>::deserialize(deserializer)?.map(|output| tail(output, CODEX_OUTPUT_TAIL)))
}

fn tail(mut text: String, limit: usize) -> String {
    if text.len() <= limit {
        return text;
    }
    let mut start = text.len() - limit;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text.drain(..start);
    text
}
