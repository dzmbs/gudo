use std::collections::{HashMap, VecDeque};

use proto::{
    AgentKind, TimelineAttachment, TimelineBody, TimelineItem, TimelineNoticeKind, TimelineOrigin,
    TimelineOutputRef, TimelinePlanEntry, TimelinePlanStatus, TimelineSession, TimelineTool,
    TimelineToolKind, TimelineToolStatus, UnixMillis,
};

use super::claude_diff::result_diff;
use super::claude_record::{
    Block, BlockKind, Content, Decision, Record, RecordKind, SystemKind, TodoStatus,
};
use super::text::{output_preview, plain_text};

const TOOL_CACHE_LIMIT: usize = 128;
const TEXT_LIMIT: usize = 256 * 1024;
const METADATA_CHARS_LIMIT: usize = 2048;
const PLAN_ENTRIES_LIMIT: usize = 200;
const OVERSIZED_MESSAGE: &str = "This message is too large for Chat. Open Terminal to read it.";

#[derive(Debug, thiserror::Error)]
pub(super) enum ParseError {
    #[error("the transcript contains an invalid record")]
    Json(#[from] serde_json::Error),
}

pub(super) struct ClaudeTimeline {
    pub session: TimelineSession,
    turn: Option<String>,
    tools: HashMap<String, TimelineItem>,
    tool_order: VecDeque<String>,
    seen_usage: VecDeque<String>,
    input_tokens: u64,
    output_tokens: u64,
}

impl ClaudeTimeline {
    pub fn new(native_session: String) -> Self {
        Self {
            session: TimelineSession {
                agent: AgentKind::Claude,
                native_session,
                title: None,
                model: None,
                permission_mode: None,
                commands: Vec::new(),
            },
            turn: None,
            tools: HashMap::new(),
            tool_order: VecDeque::new(),
            seen_usage: VecDeque::new(),
            input_tokens: 0,
            output_tokens: 0,
        }
    }

    pub fn parse_line(
        &mut self,
        bytes: &[u8],
        offset: u64,
    ) -> Result<Vec<TimelineItem>, ParseError> {
        let record: Record = serde_json::from_slice(bytes)?;
        Ok(self.parse_record(&record, offset))
    }

    pub(super) fn parse_record(&mut self, record: &Record, offset: u64) -> Vec<TimelineItem> {
        if record
            .session_id
            .as_ref()
            .is_some_and(|session| session != &self.session.native_session)
            || record.is_sidechain
        {
            return Vec::new();
        }
        self.session_metadata(record);
        match record.kind {
            RecordKind::User if record.is_compact_summary => vec![self.item(
                record,
                record_id(record, offset),
                TimelineBody::Notice {
                    kind: TimelineNoticeKind::Compacted,
                    text: "Context compacted".into(),
                },
            )],
            RecordKind::User if record.is_meta => Vec::new(),
            RecordKind::User => self.user(record, offset),
            RecordKind::Assistant => self.assistant(record, offset),
            RecordKind::System => self.system(record, offset),
            _ => Vec::new(),
        }
    }

    fn session_metadata(&mut self, record: &Record) {
        if let Some(mode) = record.permission_mode {
            self.session.permission_mode = Some(mode);
        }
        match record.kind {
            RecordKind::AiTitle | RecordKind::CustomTitle => {
                if let Some(title) = record.custom_title.as_ref().or(record.ai_title.as_ref()) {
                    self.session.title = Some(metadata_text(title));
                }
            }
            RecordKind::PermissionMode => {
                if let Some(mode) = record.mode.or(record.permission_mode) {
                    self.session.permission_mode = Some(mode);
                }
            }
            _ => {}
        }
    }

    fn user(&mut self, record: &Record, offset: u64) -> Vec<TimelineItem> {
        let content = &record.message.content;
        let mut items = Vec::new();
        for block in content.blocks() {
            if block.kind == BlockKind::ToolResult
                && let Some(id) = &block.tool_use_id
            {
                items.push(self.tool_result(record, block, id, offset));
            }
        }
        let text = user_text(content);
        let attachments = attachments(content);
        if text.as_ref().is_some_and(String::is_empty) && attachments.is_empty() {
            return items;
        }
        let id = record_id(record, offset);
        self.turn = Some(id.clone());
        self.input_tokens = 0;
        self.output_tokens = 0;
        let body = match text {
            Some(text) => TimelineBody::User {
                text,
                attachments,
                queued: false,
            },
            None => oversized_message(),
        };
        let mut item = self.item(record, id, body);
        item.origin = TimelineOrigin::Terminal;
        items.push(item);
        items
    }

    fn assistant(&mut self, record: &Record, offset: u64) -> Vec<TimelineItem> {
        self.note_message(record);
        let record_id = record_id(record, offset);
        let mut items = Vec::new();
        for (index, block) in record.message.content.blocks().iter().enumerate() {
            items.extend(self.assistant_block(record, block, &record_id, index));
        }
        items
    }

    fn note_message(&mut self, record: &Record) {
        let message = &record.message;
        if let Some(model) = message
            .model
            .as_deref()
            .filter(|model| *model != "<synthetic>")
        {
            self.session.model = Some(metadata_text(model));
        }
        let Some(id) = &message.id else { return };
        if self.seen_usage.iter().any(|seen| seen == id) {
            return;
        }
        self.seen_usage.push_back(id.clone());
        if self.seen_usage.len() > TOOL_CACHE_LIMIT {
            self.seen_usage.pop_front();
        }
        let usage = &message.usage;
        self.input_tokens = [
            usage.input_tokens,
            usage.cache_read_input_tokens,
            usage.cache_creation_input_tokens,
        ]
        .into_iter()
        .fold(self.input_tokens, u64::saturating_add);
        self.output_tokens = self.output_tokens.saturating_add(usage.output_tokens);
    }

    fn assistant_block(
        &mut self,
        record: &Record,
        block: &Block,
        record_id: &str,
        index: usize,
    ) -> Vec<TimelineItem> {
        let body = match block.kind {
            BlockKind::Text => bounded_body(block.text.as_deref().unwrap_or_default(), |text| {
                TimelineBody::Assistant {
                    text,
                    streaming: false,
                }
            }),
            BlockKind::Thinking => match block.thinking.as_deref() {
                Some(text) => bounded_body(text, |text| TimelineBody::Thinking {
                    text: Some(text),
                    duration_ms: block.duration_ms,
                }),
                None => TimelineBody::Thinking {
                    text: None,
                    duration_ms: block.duration_ms,
                },
            },
            BlockKind::RedactedThinking => TimelineBody::Thinking {
                text: None,
                duration_ms: None,
            },
            BlockKind::ToolUse => return self.tool_call(record, block, record_id),
            BlockKind::Other => TimelineBody::Unsupported,
            _ => return Vec::new(),
        };
        vec![self.item(record, format!("{record_id}:{index}"), body)]
    }

    fn tool_call(&mut self, record: &Record, block: &Block, record_id: &str) -> Vec<TimelineItem> {
        let Some(id) = &block.id else {
            return Vec::new();
        };
        let name = block.name.as_deref().unwrap_or("Tool");
        let mut items = Vec::new();
        if name == "TodoWrite" {
            let plan_id = format!("plan:{}", self.turn.as_deref().unwrap_or(record_id));
            let entries = plan_entries(block);
            items.push(self.item(record, plan_id, TimelineBody::Plan { entries }));
        }
        let tool = TimelineTool {
            kind: tool_kind(name),
            name: name.to_owned(),
            title: block.input.title.clone().unwrap_or_else(|| name.to_owned()),
            input: block.input.json.clone(),
            status: TimelineToolStatus::Running,
            output: None,
            diff: Vec::new(),
            exit: None,
            duration_ms: None,
            command_mark: None,
        };
        let item = self.item(record, id.clone(), TimelineBody::Tool(tool));
        self.remember_tool(item.clone());
        items.push(item);
        items
    }

    fn tool_result(
        &mut self,
        record: &Record,
        block: &Block,
        id: &str,
        offset: u64,
    ) -> TimelineItem {
        let rich = record.tool_use_result.rich();
        let mut item = self.tools.get(id).cloned().unwrap_or_else(|| {
            self.item(record, id.to_owned(), TimelineBody::Tool(unknown_tool()))
        });
        item.revision = item.revision.saturating_add(1);
        let TimelineBody::Tool(tool) = &mut item.body else {
            return item;
        };
        tool.status = tool_status(record, block);
        let output = result_text(record, block);
        tool.output =
            proto::OutputHandle::new(0, offset, id)
                .ok()
                .map(|handle| TimelineOutputRef {
                    handle,
                    bytes: output.len() as u64,
                    preview: output_preview(&output),
                });
        tool.exit = rich
            .and_then(|rich| rich.exit_code)
            .and_then(|exit| i32::try_from(exit).ok());
        tool.duration_ms = rich.and_then(|rich| rich.duration_ms.or(rich.total_duration_ms));
        tool.diff = rich.map(result_diff).unwrap_or_default();
        self.remember_tool(item.clone());
        item
    }

    fn system(&self, record: &Record, offset: u64) -> Vec<TimelineItem> {
        let body = match record.subtype {
            SystemKind::TurnDuration => TimelineBody::TurnEnd {
                duration_ms: record.duration_ms.unwrap_or(0),
                input_tokens: Some(self.input_tokens),
                output_tokens: Some(self.output_tokens),
            },
            SystemKind::CompactBoundary => TimelineBody::Notice {
                kind: TimelineNoticeKind::Compacted,
                text: "Context compacted".into(),
            },
            SystemKind::ApiError => TimelineBody::Notice {
                kind: TimelineNoticeKind::Error,
                text: "The agent could not reach its service. Open Terminal for details.".into(),
            },
            SystemKind::LocalCommand
                if record
                    .content
                    .as_ref()
                    .is_some_and(|text| text.contains("/clear")) =>
            {
                TimelineBody::Notice {
                    kind: TimelineNoticeKind::Cleared,
                    text: "Conversation cleared".into(),
                }
            }
            _ => return Vec::new(),
        };
        vec![self.item(record, record_id(record, offset), body)]
    }

    fn item(&self, record: &Record, id: String, body: TimelineBody) -> TimelineItem {
        let mut item = TimelineItem {
            id,
            revision: 1,
            turn: self.turn.clone(),
            parent: record.parent_tool_use_id.clone(),
            at: UnixMillis(
                record
                    .timestamp
                    .as_deref()
                    .and_then(crate::usage::rfc3339_millis)
                    .unwrap_or(0),
            ),
            origin: TimelineOrigin::Agent,
            body,
        };
        proto::TimelineVersion::CURRENT.item(&mut item);
        item
    }

    fn remember_tool(&mut self, item: TimelineItem) {
        if !self.tools.contains_key(&item.id) {
            self.tool_order.push_back(item.id.clone());
        }
        self.tools.insert(item.id.clone(), item);
        while self.tool_order.len() > TOOL_CACHE_LIMIT {
            if let Some(id) = self.tool_order.pop_front() {
                self.tools.remove(&id);
            }
        }
    }
}

fn unknown_tool() -> TimelineTool {
    TimelineTool {
        kind: TimelineToolKind::Other,
        name: "Tool".into(),
        title: "Tool output".into(),
        input: "{}".into(),
        status: TimelineToolStatus::Running,
        output: None,
        diff: Vec::new(),
        exit: None,
        duration_ms: None,
        command_mark: None,
    }
}

fn tool_status(record: &Record, block: &Block) -> TimelineToolStatus {
    if record
        .tool_use_result
        .rich()
        .is_some_and(|rich| rich.interrupted)
    {
        TimelineToolStatus::Interrupted
    } else if matches!(record.permission_decision.decision, Decision::Deny) {
        TimelineToolStatus::Denied
    } else if block.is_error {
        TimelineToolStatus::Failed
    } else {
        TimelineToolStatus::Done
    }
}

fn plan_entries(block: &Block) -> Vec<TimelinePlanEntry> {
    block
        .input
        .todos
        .iter()
        .take(PLAN_ENTRIES_LIMIT)
        .filter_map(|todo| {
            Some(TimelinePlanEntry {
                text: todo
                    .content
                    .as_ref()?
                    .chars()
                    .take(METADATA_CHARS_LIMIT)
                    .collect(),
                status: match todo.status {
                    TodoStatus::Completed => TimelinePlanStatus::Completed,
                    TodoStatus::InProgress => TimelinePlanStatus::InProgress,
                    TodoStatus::Pending => TimelinePlanStatus::Pending,
                },
            })
        })
        .collect()
}

fn record_id(record: &Record, offset: u64) -> String {
    record
        .uuid
        .clone()
        .unwrap_or_else(|| format!("record:{offset}"))
}

fn metadata_text(text: &str) -> String {
    text.chars().take(METADATA_CHARS_LIMIT).collect()
}

fn oversized_message() -> TimelineBody {
    TimelineBody::Notice {
        kind: TimelineNoticeKind::Error,
        text: OVERSIZED_MESSAGE.into(),
    }
}

fn bounded_body(text: &str, body: impl FnOnce(String) -> TimelineBody) -> TimelineBody {
    if text.len() > TEXT_LIMIT {
        oversized_message()
    } else {
        body(text.to_owned())
    }
}

fn user_text(content: &Content) -> Option<String> {
    if let Some(text) = content.text() {
        return (text.len() <= TEXT_LIMIT).then(|| text.to_owned());
    }
    let mut text = String::new();
    for block in content
        .blocks()
        .iter()
        .filter(|block| block.kind == BlockKind::Text)
    {
        if let Some(part) = &block.text {
            if part
                .len()
                .saturating_add(text.len())
                .saturating_add(usize::from(!text.is_empty()))
                > TEXT_LIMIT
            {
                return None;
            }
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(part);
        }
    }
    Some(text)
}

fn attachments(content: &Content) -> Vec<TimelineAttachment> {
    content
        .blocks()
        .iter()
        .filter(|block| matches!(block.kind, BlockKind::Image | BlockKind::Document))
        .filter_map(|block| {
            Some(TimelineAttachment {
                path: block
                    .source
                    .as_ref()
                    .and_then(|source| source.path.as_ref())
                    .or(block.path.as_ref())?
                    .clone(),
                media_type: block
                    .source
                    .as_ref()
                    .and_then(|source| source.media_type.clone()),
            })
        })
        .collect()
}

fn tool_kind(name: &str) -> TimelineToolKind {
    match name {
        "Bash" => TimelineToolKind::Shell,
        "Read" | "LS" => TimelineToolKind::Read,
        "Grep" | "Glob" | "ToolSearch" => TimelineToolKind::Search,
        "Edit" | "MultiEdit" | "NotebookEdit" => TimelineToolKind::Edit,
        "Write" => TimelineToolKind::Write,
        "WebFetch" => TimelineToolKind::Fetch,
        "WebSearch" => TimelineToolKind::WebSearch,
        "Task" | "Agent" => TimelineToolKind::Task,
        name if name.starts_with("mcp__") => TimelineToolKind::Mcp,
        _ => TimelineToolKind::Other,
    }
}

pub(super) fn result_text(record: &Record, block: &Block) -> String {
    if let Some(rich) = record.tool_use_result.rich() {
        if rich.stdout.is_some() || rich.stderr.is_some() {
            let stdout = rich.stdout.as_deref().unwrap_or_default();
            let stderr = rich.stderr.as_deref().unwrap_or_default();
            return plain_text(&if stdout.is_empty() || stderr.is_empty() {
                format!("{stdout}{stderr}")
            } else {
                format!("{stdout}\n{stderr}")
            });
        }
        if let Some(content) = rich.file.as_ref().and_then(|file| file.content.as_ref()) {
            return plain_text(content);
        }
    }
    plain_text(&block.content.joined_text())
}

#[cfg(test)]
#[path = "claude_tests.rs"]
mod tests;
