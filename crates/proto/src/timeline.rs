use serde::{Deserialize, Serialize};

use crate::{Actor, AgentKind, FileDiff, PaneId, UnixMillis};

mod metadata;
mod output_handle;
mod version;
pub use metadata::{TimelineCommandSource, TimelinePermissionMode};
pub use output_handle::{InvalidOutputHandle, OutputHandle};
pub use version::{TimelineVersion, UnsupportedTimelineVersion};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineCursor {
    pub epoch: u64,
    pub sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimelineOrigin {
    Terminal,
    App(Actor),
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineItem {
    pub id: String,
    pub revision: u32,
    pub turn: Option<String>,
    pub parent: Option<String>,
    pub at: UnixMillis,
    pub origin: TimelineOrigin,
    pub body: TimelineBody,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimelineBody {
    User {
        text: String,
        attachments: Vec<TimelineAttachment>,
        queued: bool,
    },
    Assistant {
        text: String,
        streaming: bool,
    },
    Thinking {
        text: Option<String>,
        duration_ms: Option<u64>,
    },
    Tool(TimelineTool),
    Plan {
        entries: Vec<TimelinePlanEntry>,
    },
    Notice {
        kind: TimelineNoticeKind,
        text: String,
    },
    TurnEnd {
        duration_ms: u64,
        input_tokens: Option<u64>,
        output_tokens: Option<u64>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineAttachment {
    pub path: String,
    pub media_type: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelinePlanEntry {
    pub text: String,
    pub status: TimelinePlanStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimelinePlanStatus {
    Pending,
    InProgress,
    Completed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimelineToolKind {
    Shell,
    Read,
    Search,
    Edit,
    Write,
    Fetch,
    WebSearch,
    Mcp,
    Task,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimelineToolStatus {
    Running,
    Done,
    Failed,
    Denied,
    Interrupted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineTool {
    pub kind: TimelineToolKind,
    pub name: String,
    pub title: String,
    pub input: String,
    pub status: TimelineToolStatus,
    pub output: Option<TimelineOutputRef>,
    pub diff: Vec<FileDiff>,
    pub exit: Option<i32>,
    pub duration_ms: Option<u64>,
    pub command_mark: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineOutputRef {
    pub handle: OutputHandle,
    pub preview: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimelineNoticeKind {
    Compacted,
    Cleared,
    ModelChanged,
    ModeChanged,
    Error,
    Retry,
    Interrupted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineCommand {
    pub name: String,
    pub description: String,
    pub source: TimelineCommandSource,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineSession {
    pub agent: AgentKind,
    pub native_session: String,
    pub title: Option<String>,
    pub model: Option<String>,
    pub permission_mode: Option<TimelinePermissionMode>,
    pub commands: Vec<TimelineCommand>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineSnapshot {
    pub cursor: TimelineCursor,
    pub session: TimelineSession,
    pub items: Vec<TimelineItem>,
    pub before: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimelineField {
    Text,
    Output,
    Thinking,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimelineOp {
    Snapshot(TimelineSnapshot),
    Upsert {
        cursor: TimelineCursor,
        item: Box<TimelineItem>,
    },
    Append {
        cursor: TimelineCursor,
        id: String,
        field: TimelineField,
        text: String,
    },
    Remove {
        cursor: TimelineCursor,
        id: String,
    },
    Session {
        cursor: TimelineCursor,
        session: TimelineSession,
    },
    Unavailable {
        message: String,
    },
    Checkpoint {
        cursor: TimelineCursor,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineUpdate {
    pub pane_id: PaneId,
    pub operations: Vec<TimelineOp>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelineToolOutput {
    pub text: String,
    pub next_offset: Option<u64>,
    pub total_bytes: u64,
}
