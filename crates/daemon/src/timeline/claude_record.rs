//! Decode native transcript fields once; arbitrary tool input remains opaque JSON.

use serde::{Deserialize, Deserializer};
use serde_json::Value;

pub(super) const INPUT_BYTES_LIMIT: usize = 16 * 1024;
const INPUT_FALLBACK: &str = "{\"message\":\"Input is too large. Open Terminal to read it.\"}";

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub(super) struct Record {
    #[serde(rename = "type")]
    pub kind: RecordKind,
    pub session_id: Option<String>,
    pub uuid: Option<String>,
    pub timestamp: Option<String>,
    pub is_sidechain: bool,
    pub is_meta: bool,
    pub is_compact_summary: bool,
    pub parent_tool_use_id: Option<String>,
    pub permission_mode: Option<String>,
    pub mode: Option<String>,
    pub custom_title: Option<String>,
    pub ai_title: Option<String>,
    pub subtype: SystemKind,
    pub content: Option<String>,
    pub duration_ms: Option<u64>,
    pub message: Message,
    pub tool_use_result: ResultData,
    pub permission_decision: PermissionDecision,
}

#[derive(Debug, Default, Deserialize, PartialEq, Eq)]
pub(super) enum RecordKind {
    #[serde(rename = "user")]
    User,
    #[serde(rename = "assistant")]
    Assistant,
    #[serde(rename = "system")]
    System,
    #[serde(rename = "ai-title")]
    AiTitle,
    #[serde(rename = "custom-title")]
    CustomTitle,
    #[serde(rename = "permission-mode")]
    PermissionMode,
    #[default]
    #[serde(other)]
    Other,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum SystemKind {
    TurnDuration,
    CompactBoundary,
    ApiError,
    LocalCommand,
    #[default]
    #[serde(other)]
    Other,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub(super) struct Message {
    pub id: Option<String>,
    pub model: Option<String>,
    pub content: Content,
    pub usage: Usage,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub(super) struct Usage {
    pub input_tokens: u64,
    pub cache_read_input_tokens: u64,
    pub cache_creation_input_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(super) enum Content {
    Text(String),
    Blocks(Vec<Block>),
    Other(serde::de::IgnoredAny),
}

impl Default for Content {
    fn default() -> Self {
        Self::Other(serde::de::IgnoredAny)
    }
}

impl Content {
    pub fn blocks(&self) -> &[Block] {
        match self {
            Self::Blocks(blocks) => blocks,
            _ => &[],
        }
    }

    pub fn text(&self) -> Option<&str> {
        match self {
            Self::Text(text) => Some(text),
            _ => None,
        }
    }

    pub fn joined_text(&self) -> String {
        match self {
            Self::Text(text) => text.clone(),
            Self::Blocks(blocks) => blocks
                .iter()
                .filter_map(|block| block.text.as_deref().or(block.content.text()))
                .collect::<Vec<_>>()
                .join("\n"),
            Self::Other(_) => String::new(),
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub(super) struct Block {
    #[serde(rename = "type")]
    pub kind: BlockKind,
    pub text: Option<String>,
    pub thinking: Option<String>,
    #[serde(rename = "durationMs")]
    pub duration_ms: Option<u64>,
    pub id: Option<String>,
    pub name: Option<String>,
    pub input: ToolInput,
    pub tool_use_id: Option<String>,
    pub is_error: bool,
    pub content: Content,
    pub source: Option<AttachmentSource>,
    pub path: Option<String>,
}

#[derive(Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(super) enum BlockKind {
    Text,
    Thinking,
    RedactedThinking,
    ToolUse,
    ToolResult,
    Image,
    Document,
    #[default]
    #[serde(other)]
    Other,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub(super) struct AttachmentSource {
    pub path: Option<String>,
    pub media_type: Option<String>,
}

#[derive(Debug)]
pub(super) struct ToolInput {
    pub json: String,
    pub title: Option<String>,
    pub todos: Vec<Todo>,
}

impl Default for ToolInput {
    fn default() -> Self {
        Self {
            json: "null".into(),
            title: None,
            todos: Vec::new(),
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct InputHints {
    description: Option<String>,
    file_path: Option<String>,
    path: Option<String>,
    pattern: Option<String>,
    query: Option<String>,
    url: Option<String>,
    command: Option<String>,
    todos: Vec<Todo>,
}

impl<'de> Deserialize<'de> for ToolInput {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(deserializer)?;
        let hints = InputHints::deserialize(&value).unwrap_or_default();
        let title = [
            hints.description,
            hints.file_path,
            hints.path,
            hints.pattern,
            hints.query,
            hints.url,
            hints.command,
        ]
        .into_iter()
        .flatten()
        .find(|title| !title.is_empty())
        .map(|title| title.chars().take(512).collect());
        let mut buffer = InputBuffer(Vec::new());
        let json = if serde_json::to_writer(&mut buffer, &value).is_ok() {
            String::from_utf8(buffer.0).map_err(serde::de::Error::custom)?
        } else {
            INPUT_FALLBACK.to_owned()
        };
        Ok(Self {
            json,
            title,
            todos: hints.todos,
        })
    }
}

struct InputBuffer(Vec<u8>);

impl std::io::Write for InputBuffer {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > INPUT_BYTES_LIMIT.saturating_sub(self.0.len()) {
            return Err(std::io::ErrorKind::WriteZero.into());
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct Todo {
    pub content: Option<String>,
    #[serde(default)]
    pub status: TodoStatus,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum TodoStatus {
    Completed,
    InProgress,
    #[default]
    #[serde(other)]
    Pending,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(super) enum ResultData {
    Rich(RichResult),
    Other(serde::de::IgnoredAny),
}

impl Default for ResultData {
    fn default() -> Self {
        Self::Other(serde::de::IgnoredAny)
    }
}

impl ResultData {
    pub fn rich(&self) -> Option<&RichResult> {
        match self {
            Self::Rich(result) => Some(result),
            Self::Other(_) => None,
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub(super) struct RichResult {
    pub stdout: Option<String>,
    pub stderr: Option<String>,
    pub file: Option<FileContent>,
    pub interrupted: bool,
    pub exit_code: Option<i64>,
    pub duration_ms: Option<u64>,
    pub total_duration_ms: Option<u64>,
    pub file_path: Option<String>,
    #[serde(rename = "type")]
    pub kind: ResultKind,
    pub content: Option<String>,
    pub structured_patch: Option<Vec<Patch>>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum ResultKind {
    Create,
    #[default]
    #[serde(other)]
    Other,
}

#[derive(Debug, Deserialize)]
pub(super) struct FileContent {
    pub content: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub(super) struct Patch {
    pub lines: Vec<String>,
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub(super) struct PermissionDecision {
    pub decision: Decision,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Decision {
    Deny,
    #[default]
    #[serde(other)]
    Other,
}
