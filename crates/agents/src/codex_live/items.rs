use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer};
use serde_json::Value;

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
    FileChange {
        id: String,
        changes: Vec<CodexFileChange>,
        status: String,
    },
    #[serde(rename_all = "camelCase")]
    McpToolCall {
        id: String,
        server: String,
        tool: String,
        status: String,
        #[serde(default)]
        arguments: Value,
        result: Option<CodexToolResult>,
        error: Option<CodexToolError>,
        duration_ms: Option<u64>,
    },
    #[serde(rename_all = "camelCase")]
    DynamicToolCall {
        id: String,
        tool: String,
        status: String,
        #[serde(default)]
        arguments: Value,
        content_items: Option<Vec<Value>>,
        duration_ms: Option<u64>,
    },
    #[serde(rename_all = "camelCase")]
    CollabAgentToolCall {
        id: String,
        tool: String,
        status: String,
        #[serde(default)]
        receiver_thread_ids: Vec<String>,
        prompt: Option<String>,
        model: Option<String>,
        #[serde(default)]
        agents_states: BTreeMap<String, CodexAgentState>,
    },
    WebSearch {
        id: String,
        #[serde(default)]
        query: String,
        action: Option<CodexWebSearchAction>,
    },
    ImageView {
        id: String,
        path: String,
    },
    /// A plan proposed in plan mode, as Markdown.
    Plan {
        id: String,
        text: String,
    },
    ContextCompaction {
        id: String,
    },
    EnteredReviewMode {
        id: String,
        review: String,
    },
    ExitedReviewMode {
        id: String,
        review: String,
    },
    #[serde(other)]
    Unsupported,
}

impl CodexItem {
    /// The app-server's id for the item; `None` for kinds the adapter does not read.
    pub fn id(&self) -> Option<&str> {
        match self {
            Self::UserMessage { id, .. }
            | Self::AgentMessage { id, .. }
            | Self::CommandExecution { id, .. }
            | Self::Reasoning { id, .. }
            | Self::FileChange { id, .. }
            | Self::McpToolCall { id, .. }
            | Self::DynamicToolCall { id, .. }
            | Self::CollabAgentToolCall { id, .. }
            | Self::WebSearch { id, .. }
            | Self::ImageView { id, .. }
            | Self::Plan { id, .. }
            | Self::ContextCompaction { id }
            | Self::EnteredReviewMode { id, .. }
            | Self::ExitedReviewMode { id, .. } => Some(id),
            Self::Unsupported => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum CodexInput {
    Text {
        text: String,
    },
    #[serde(alias = "local_image")]
    LocalImage {
        path: String,
    },
    Image {
        url: String,
    },
    #[serde(other)]
    Unsupported,
}

/// One file of a change: a unified diff for an update, the whole file for an add or delete.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct CodexFileChange {
    pub path: String,
    pub kind: CodexFileChangeKind,
    #[serde(default)]
    pub diff: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum CodexFileChangeKind {
    Add,
    Delete,
    Update {
        #[serde(default)]
        move_path: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct CodexToolResult {
    #[serde(default)]
    pub content: Vec<Value>,
}

impl CodexToolResult {
    /// The text blocks of the result, joined by line breaks.
    pub fn text(&self) -> String {
        content_text(&self.content)
    }
}

/// The text blocks of MCP-style content, joined by line breaks.
pub fn content_text(content: &[Value]) -> String {
    content
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct CodexToolError {
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct CodexAgentState {
    pub status: String,
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum CodexWebSearchAction {
    Search {
        query: Option<String>,
        queries: Option<Vec<String>>,
    },
    #[serde(alias = "open_page")]
    OpenPage { url: Option<String> },
    #[serde(alias = "find_in_page")]
    FindInPage {
        url: Option<String>,
        pattern: Option<String>,
    },
    #[serde(other)]
    Other,
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
