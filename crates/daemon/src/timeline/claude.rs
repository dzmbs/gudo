use std::collections::{HashMap, VecDeque};

use proto::{
    AgentKind, DiffLine, FileChange, FileDiff, Hunk, LineKind, TimelineAttachment, TimelineBody,
    TimelineItem, TimelineNoticeKind, TimelineOrigin, TimelineOutputRef, TimelinePlanEntry,
    TimelinePlanStatus, TimelineSession, TimelineTool, TimelineToolKind, TimelineToolStatus,
    UnixMillis,
};
use serde_json::Value;

use super::text::{output_preview, plain_text};

const TOOL_CACHE_LIMIT: usize = 128;
const INPUT_LIMIT: usize = 16 * 1024;
const TEXT_LIMIT: usize = 256 * 1024;

#[derive(Debug, thiserror::Error)]
pub(super) enum ParseError {
    #[error("the transcript contains an invalid record")]
    Json(#[from] serde_json::Error),
    #[error("a transcript message is too large for Chat; open Terminal to read it")]
    MessageTooLarge,
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
        let record: Value = serde_json::from_slice(bytes)?;
        self.parse_record(&record, offset)
    }

    pub(super) fn parse_record(
        &mut self,
        record: &Value,
        offset: u64,
    ) -> Result<Vec<TimelineItem>, ParseError> {
        if record["sessionId"]
            .as_str()
            .is_some_and(|session| session != self.session.native_session)
            || record["isSidechain"].as_bool() == Some(true)
        {
            return Ok(Vec::new());
        }
        if let Some(mode) = record["permissionMode"].as_str() {
            self.session.permission_mode = Some(mode.to_owned());
        }
        let kind = record["type"].as_str().unwrap_or_default();
        match kind {
            "ai-title" | "custom-title" => {
                let title = record["customTitle"]
                    .as_str()
                    .or(record["aiTitle"].as_str());
                if let Some(title) = title {
                    self.session.title = Some(checked_text(title)?);
                }
                Ok(Vec::new())
            }
            "permission-mode" => {
                if let Some(mode) = record["mode"]
                    .as_str()
                    .or(record["permissionMode"].as_str())
                {
                    self.session.permission_mode = Some(mode.to_owned());
                }
                Ok(Vec::new())
            }
            "user" if record["isCompactSummary"].as_bool() == Some(true) => Ok(vec![self.item(
                record,
                record_id(record, offset),
                TimelineBody::Notice {
                    kind: TimelineNoticeKind::Compacted,
                    text: "Context compacted".into(),
                },
            )]),
            "user" if record["isMeta"].as_bool() == Some(true) => Ok(Vec::new()),
            "user" => self.user(record, offset),
            "assistant" => self.assistant(record, offset),
            "system" => Ok(self.system(record, offset)),
            _ => Ok(Vec::new()),
        }
    }

    fn user(&mut self, record: &Value, offset: u64) -> Result<Vec<TimelineItem>, ParseError> {
        let content = &record["message"]["content"];
        let mut items = Vec::new();
        let blocks = content.as_array();
        if let Some(blocks) = blocks {
            for block in blocks {
                if block["type"].as_str() == Some("tool_result")
                    && let Some(id) = block["tool_use_id"].as_str()
                {
                    items.push(self.tool_result(record, block, id, offset));
                }
            }
        }
        let text = match content {
            Value::String(text) => checked_text(text)?,
            Value::Array(blocks) => {
                let mut text = String::new();
                for block in blocks {
                    if block["type"].as_str() == Some("text")
                        && let Some(part) = block["text"].as_str()
                    {
                        if !text.is_empty() {
                            text.push('\n');
                        }
                        text.push_str(part);
                        if text.len() > TEXT_LIMIT {
                            return Err(ParseError::MessageTooLarge);
                        }
                    }
                }
                text
            }
            _ => String::new(),
        };
        let attachments: Vec<_> = blocks
            .into_iter()
            .flatten()
            .filter(|block| matches!(block["type"].as_str(), Some("image" | "document")))
            .filter_map(|block| {
                let path = block["source"]["path"]
                    .as_str()
                    .or(block["path"].as_str())?;
                Some(TimelineAttachment {
                    path: path.to_owned(),
                    media_type: block["source"]["media_type"].as_str().map(str::to_owned),
                })
            })
            .collect();
        if !text.is_empty() || !attachments.is_empty() {
            let id = record_id(record, offset);
            self.turn = Some(id.clone());
            self.input_tokens = 0;
            self.output_tokens = 0;
            let mut item = self.item(
                record,
                id,
                TimelineBody::User {
                    text,
                    attachments,
                    queued: false,
                },
            );
            item.origin = TimelineOrigin::Terminal;
            items.push(item);
        }
        Ok(items)
    }

    fn assistant(&mut self, record: &Value, offset: u64) -> Result<Vec<TimelineItem>, ParseError> {
        let message = &record["message"];
        if let Some(model) = message["model"]
            .as_str()
            .filter(|model| *model != "<synthetic>")
        {
            self.session.model = Some(model.to_owned());
        }
        if let Some(message_id) = message["id"].as_str()
            && !self.seen_usage.iter().any(|seen| seen == message_id)
        {
            self.seen_usage.push_back(message_id.to_owned());
            if self.seen_usage.len() > TOOL_CACHE_LIMIT {
                self.seen_usage.pop_front();
            }
            let usage = &message["usage"];
            self.input_tokens = self.input_tokens.saturating_add(
                [
                    "input_tokens",
                    "cache_read_input_tokens",
                    "cache_creation_input_tokens",
                ]
                .iter()
                .filter_map(|key| usage[key].as_u64())
                .fold(0u64, u64::saturating_add),
            );
            self.output_tokens = self
                .output_tokens
                .saturating_add(usage["output_tokens"].as_u64().unwrap_or(0));
        }
        let mut items = Vec::new();
        let Some(blocks) = message["content"].as_array() else {
            return Ok(items);
        };
        let record_id = record_id(record, offset);
        for (index, block) in blocks.iter().enumerate() {
            let id = format!("{record_id}:{index}");
            let body = match block["type"].as_str() {
                Some("text") => TimelineBody::Assistant {
                    text: checked_text(block["text"].as_str().unwrap_or_default())?,
                    streaming: false,
                },
                Some("thinking") => TimelineBody::Thinking {
                    text: block["thinking"].as_str().map(checked_text).transpose()?,
                    duration_ms: block["durationMs"].as_u64(),
                },
                Some("redacted_thinking") => TimelineBody::Thinking {
                    text: None,
                    duration_ms: None,
                },
                Some("tool_use") => {
                    let Some(tool_id) = block["id"].as_str() else {
                        continue;
                    };
                    let name = block["name"].as_str().unwrap_or("Tool");
                    let input = &block["input"];
                    if name == "TodoWrite" {
                        let entries = plan_entries(&input["todos"]);
                        let plan_id =
                            format!("plan:{}", self.turn.as_deref().unwrap_or(&record_id));
                        items.push(self.item(record, plan_id, TimelineBody::Plan { entries }));
                    }
                    let serialized = input.to_string();
                    let tool = TimelineTool {
                        kind: tool_kind(name),
                        name: name.to_owned(),
                        title: tool_title(name, input),
                        input: if serialized.len() <= INPUT_LIMIT {
                            serialized
                        } else {
                            "{\"message\":\"Input is too large. Open Terminal to read it.\"}".into()
                        },
                        status: TimelineToolStatus::Running,
                        output: None,
                        diff: Vec::new(),
                        exit: None,
                        duration_ms: None,
                        command_mark: None,
                    };
                    let item = self.item(record, tool_id.to_owned(), TimelineBody::Tool(tool));
                    self.remember_tool(item.clone());
                    items.push(item);
                    continue;
                }
                _ => continue,
            };
            items.push(self.item(record, id, body));
        }
        Ok(items)
    }

    fn tool_result(
        &mut self,
        record: &Value,
        block: &Value,
        id: &str,
        offset: u64,
    ) -> TimelineItem {
        let rich = &record["toolUseResult"];
        let mut item = self.tools.get(id).cloned().unwrap_or_else(|| {
            self.item(
                record,
                id.to_owned(),
                TimelineBody::Tool(TimelineTool {
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
                }),
            )
        });
        item.revision = item.revision.saturating_add(1);
        let TimelineBody::Tool(tool) = &mut item.body else {
            return item;
        };
        let is_error = block["is_error"].as_bool().unwrap_or(false);
        tool.status = if rich["interrupted"].as_bool() == Some(true) {
            TimelineToolStatus::Interrupted
        } else if record["permissionDecision"]["decision"].as_str() == Some("deny") {
            TimelineToolStatus::Denied
        } else if is_error {
            TimelineToolStatus::Failed
        } else {
            TimelineToolStatus::Done
        };
        let output = result_text(record, block);
        tool.output =
            proto::OutputHandle::new(0, offset, id)
                .ok()
                .map(|handle| TimelineOutputRef {
                    handle,
                    bytes: output.len() as u64,
                    preview: output_preview(&output),
                });
        tool.exit = rich["exitCode"]
            .as_i64()
            .and_then(|exit| i32::try_from(exit).ok());
        tool.duration_ms = rich["durationMs"]
            .as_u64()
            .or(rich["totalDurationMs"].as_u64());
        tool.diff = result_diff(rich);
        self.remember_tool(item.clone());
        item
    }

    fn system(&self, record: &Value, offset: u64) -> Vec<TimelineItem> {
        let body = match record["subtype"].as_str() {
            Some("turn_duration") => TimelineBody::TurnEnd {
                duration_ms: record["durationMs"].as_u64().unwrap_or(0),
                input_tokens: Some(self.input_tokens),
                output_tokens: Some(self.output_tokens),
            },
            Some("compact_boundary") => TimelineBody::Notice {
                kind: TimelineNoticeKind::Compacted,
                text: "Context compacted".into(),
            },
            Some("api_error") => TimelineBody::Notice {
                kind: TimelineNoticeKind::Error,
                text: "The agent could not reach its service. Open Terminal for details.".into(),
            },
            Some("local_command")
                if record["content"]
                    .as_str()
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

    fn item(&self, record: &Value, id: String, body: TimelineBody) -> TimelineItem {
        TimelineItem {
            id,
            revision: 1,
            turn: self.turn.clone(),
            parent: record["parentToolUseId"].as_str().map(str::to_owned),
            at: UnixMillis(
                record["timestamp"]
                    .as_str()
                    .and_then(crate::usage::rfc3339_millis)
                    .unwrap_or(0),
            ),
            origin: TimelineOrigin::Agent,
            body,
        }
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

fn record_id(record: &Value, offset: u64) -> String {
    record["uuid"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| format!("record:{offset}"))
}

fn checked_text(text: &str) -> Result<String, ParseError> {
    if text.len() > TEXT_LIMIT {
        return Err(ParseError::MessageTooLarge);
    }
    Ok(text.to_owned())
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

fn tool_title(name: &str, input: &Value) -> String {
    for key in [
        "description",
        "file_path",
        "path",
        "pattern",
        "query",
        "url",
        "command",
    ] {
        if let Some(title) = input[key].as_str().filter(|text| !text.is_empty()) {
            return title.chars().take(512).collect();
        }
    }
    name.to_owned()
}

fn plan_entries(todos: &Value) -> Vec<TimelinePlanEntry> {
    todos
        .as_array()
        .into_iter()
        .flatten()
        .take(200)
        .filter_map(|todo| {
            let text = todo["content"].as_str()?;
            Some(TimelinePlanEntry {
                text: text.chars().take(2048).collect(),
                status: match todo["status"].as_str() {
                    Some("completed") => TimelinePlanStatus::Completed,
                    Some("in_progress") => TimelinePlanStatus::InProgress,
                    _ => TimelinePlanStatus::Pending,
                },
            })
        })
        .collect()
}

pub(super) fn result_text(record: &Value, block: &Value) -> String {
    let rich = &record["toolUseResult"];
    if rich["stdout"].is_string() || rich["stderr"].is_string() {
        let stdout = rich["stdout"].as_str().unwrap_or_default();
        let stderr = rich["stderr"].as_str().unwrap_or_default();
        return plain_text(&Value::String(if stdout.is_empty() || stderr.is_empty() {
            format!("{stdout}{stderr}")
        } else {
            format!("{stdout}\n{stderr}")
        }));
    }
    if let Some(content) = rich["file"]["content"].as_str() {
        return plain_text(&Value::String(content.to_owned()));
    }
    plain_text(&block["content"])
}

fn result_diff(result: &Value) -> Vec<FileDiff> {
    let Some(path) = result["filePath"].as_str() else {
        return Vec::new();
    };
    let patches = result["structuredPatch"].as_array();
    let is_created = result["type"].as_str() == Some("create");
    if patches.is_none() && !is_created {
        return Vec::new();
    }
    let mut additions = 0u32;
    let mut deletions = 0u32;
    let mut hunks = Vec::new();
    let mut retained_lines = 0usize;
    let mut omitted = false;
    for patch in patches.into_iter().flatten() {
        let mut lines = Vec::new();
        for line in patch["lines"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            let (kind, text) = match line.as_bytes().first() {
                Some(b'+') => {
                    additions = additions.saturating_add(1);
                    (LineKind::Added, &line[1..])
                }
                Some(b'-') => {
                    deletions = deletions.saturating_add(1);
                    (LineKind::Removed, &line[1..])
                }
                Some(b' ') => (LineKind::Context, &line[1..]),
                _ => (LineKind::Context, line),
            };
            if retained_lines < 6 {
                lines.push(DiffLine {
                    kind,
                    text: text.chars().take(512).collect(),
                });
                retained_lines += 1;
            } else {
                omitted = true;
            }
        }
        if !lines.is_empty() {
            hunks.push(Hunk {
                old_start: number(patch, "oldStart"),
                old_lines: number(patch, "oldLines"),
                new_start: number(patch, "newStart"),
                new_lines: number(patch, "newLines"),
                header: String::new(),
                lines,
            });
        }
    }
    if is_created && hunks.is_empty() {
        let content = result["content"].as_str().unwrap_or_default();
        additions = u32::try_from(content.lines().count()).unwrap_or(u32::MAX);
        let lines = content
            .lines()
            .take(6)
            .map(|line| DiffLine {
                kind: LineKind::Added,
                text: line.chars().take(512).collect(),
            })
            .collect();
        omitted = additions > 6;
        hunks.push(Hunk {
            old_start: 0,
            old_lines: 0,
            new_start: 1,
            new_lines: additions,
            header: String::new(),
            lines,
        });
    }
    vec![FileDiff {
        path: path.to_owned(),
        old_path: None,
        change: if is_created {
            FileChange::Added
        } else {
            FileChange::Modified
        },
        binary: false,
        additions,
        deletions,
        hunks,
        hunks_omitted: omitted,
    }]
}

fn number(record: &Value, key: &str) -> u32 {
    record[key]
        .as_u64()
        .and_then(|number| u32::try_from(number).ok())
        .unwrap_or(0)
}

#[cfg(test)]
#[path = "claude_tests.rs"]
mod tests;
