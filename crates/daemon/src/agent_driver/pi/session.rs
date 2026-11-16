//! pi's session file (format 3), read only: its entries shaped into the timeline rows Claude Code
//! and Codex conversations use, older pages read back from it, and long text and tool output
//! read again in full.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use proto::{
    OutputHandle, TimelineBody, TimelineItem, TimelineNoticeKind, TimelineOrigin,
    TimelineOutputRef, TimelineTextRole, TimelineTool, TimelineToolKind, TimelineToolOutput,
    TimelineToolStatus, UnixMillis, WsError,
};
use serde::Deserialize;
use serde_json::Value;

use crate::timeline::jsonl_file::{JsonlFile, Window};
use crate::timeline::record_stream::RecordStream;

#[cfg(test)]
pub(crate) mod tests;

/// The session format this reader knows: pi migrates older files to it when it loads them.
const FORMAT_VERSION: u64 = 3;
const PAGE_ITEMS: usize = 100;
const PAGE_BYTES: usize = 1024 * 1024;
/// How far back a page reads, and how far past it a page looks for its calls' results.
const SCAN_BYTES: u64 = 64 * 1024 * 1024;
/// Text over this is pushed as its start, with the whole text paged from the file.
const LONG_TEXT_BYTES: usize = 64 * 1024;
const PREVIEW_BYTES: usize = 16 * 1024;
const TITLE_BYTES: usize = 2 * 1024;
const INPUT_BYTES: usize = 64 * 1024;

pub(super) struct PiSession {
    file: JsonlFile,
    cwd: PathBuf,
}

/// What a read of records found: rows, results of calls made in earlier records, and the
/// session's name and model as last recorded.
#[derive(Debug, Default)]
pub(super) struct Shaped {
    pub items: Vec<(u64, TimelineItem)>,
    pub results: Vec<ToolResult>,
    pub title: Option<String>,
    pub model: Option<String>,
}

#[derive(Debug, Clone)]
pub(super) struct ToolResult {
    call: String,
    offset: u64,
    failed: bool,
    text: String,
    duration_ms: Option<u64>,
    patch: Option<String>,
}

pub(super) struct Page {
    pub items: Vec<TimelineItem>,
    pub before: Option<u64>,
}

#[derive(Deserialize)]
struct Header {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    version: Option<u64>,
    id: String,
    cwd: Option<PathBuf>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Entry {
    Message {
        id: String,
        #[serde(rename = "parentId")]
        parent: Option<String>,
        message: Box<Message>,
    },
    Compaction {
        id: String,
        #[serde(rename = "tokensBefore")]
        tokens_before: Option<u64>,
    },
    BranchSummary {
        id: String,
    },
    ModelChange {
        id: String,
        #[serde(rename = "modelId")]
        model: String,
    },
    SessionInfo {
        name: Option<String>,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
#[serde(tag = "role", rename_all = "camelCase")]
enum Message {
    User {
        content: Content,
        timestamp: Option<u64>,
    },
    Assistant {
        #[serde(default)]
        content: Vec<Block>,
        model: Option<String>,
        #[serde(rename = "stopReason")]
        stop_reason: Option<String>,
        #[serde(rename = "errorMessage")]
        error_message: Option<String>,
        #[serde(rename = "durationMs")]
        duration_ms: Option<u64>,
        timestamp: Option<u64>,
    },
    ToolResult {
        #[serde(rename = "toolCallId")]
        call: String,
        #[serde(default)]
        content: Vec<Block>,
        #[serde(default, rename = "isError")]
        failed: bool,
        #[serde(rename = "durationMs")]
        duration_ms: Option<u64>,
        details: Option<Value>,
    },
    BashExecution {
        command: String,
        #[serde(default)]
        output: String,
        #[serde(rename = "exitCode")]
        exit: Option<i32>,
        #[serde(default)]
        cancelled: bool,
        timestamp: Option<u64>,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Content {
    Text(String),
    Blocks(Vec<Block>),
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum Block {
    Text {
        text: String,
    },
    Thinking {
        #[serde(default)]
        thinking: String,
    },
    Image {},
    ToolCall {
        id: String,
        name: String,
        #[serde(default)]
        arguments: Value,
    },
    #[serde(other)]
    Other,
}

impl PiSession {
    /// Opens session `id` at `path` inside `root`, refusing a file of another session or a
    /// format this reader does not know.
    pub fn open(root: &Path, path: &Path, id: &str) -> Result<Self, WsError> {
        let file = JsonlFile::open(root, path)?;
        let header = file
            .record_at(0)?
            .and_then(|record| serde_json::from_slice::<Header>(&record).ok())
            .filter(|header| header.kind == "session")
            .ok_or_else(|| {
                WsError::Unavailable(
                    "Chat can't read this pi session: it does not start with a session record. Use Terminal."
                        .into(),
                )
            })?;
        if header.id != id {
            return Err(WsError::Denied(
                "the session file belongs to another pi session".into(),
            ));
        }
        match header.version.unwrap_or(1) {
            FORMAT_VERSION => {}
            older if older < FORMAT_VERSION => {
                return Err(WsError::Unavailable(
                    "This pi session is saved in an older format. Update pi to see it in Chat."
                        .into(),
                ));
            }
            _ => {
                return Err(WsError::Unavailable(
                    "This pi saves sessions in a newer format than the helper reads. Update the helper to see it in Chat."
                        .into(),
                ));
            }
        }
        Ok(Self {
            file,
            cwd: header.cwd.unwrap_or_default(),
        })
    }

    pub fn end(&self) -> Result<u64, WsError> {
        self.file.end()
    }

    /// The newest records, shaped, from at most one bounded read before `end`.
    pub fn newest(&self, end: u64, epoch: u64) -> Result<Shaped, WsError> {
        let Window { records, .. } = self.file.window(end)?;
        Ok(self.shape(records, epoch))
    }

    /// The records pi wrote past where `stream` stopped, shaped, and whether more is written.
    pub fn appended(
        &self,
        stream: &mut RecordStream,
        epoch: u64,
    ) -> Result<(Shaped, bool), WsError> {
        let (records, more) = self.file.appended(stream)?;
        Ok((self.shape(records, epoch), more))
    }

    /// Up to `limit` items of records before the record at `before`, oldest first, with the
    /// results their calls got in later records.
    pub fn page(&self, before: u64, limit: usize, epoch: u64) -> Result<Page, WsError> {
        if before == 0 || before > self.file.length()? || !self.file.is_boundary(before)? {
            return Err(WsError::Invalid(
                "the history cursor is no longer valid".into(),
            ));
        }
        let limit = limit.clamp(1, PAGE_ITEMS);
        let mut records: Vec<(u64, Vec<u8>)> = Vec::new();
        let mut kept = 0;
        let mut bytes = 0;
        let mut end = before;
        let mut next = None;
        'windows: while end > 0 {
            if before - end >= SCAN_BYTES {
                next = Some(end);
                break;
            }
            let Window {
                records: window,
                start,
            } = self.file.window(end)?;
            for (offset, record) in window.into_iter().rev() {
                let shaped = self.shape(vec![(offset, record.clone())], epoch);
                let weight: usize = shaped
                    .items
                    .iter()
                    .map(|(_, item)| crate::timeline::value_weight::item(item))
                    .sum();
                if !shaped.items.is_empty()
                    && (kept + shaped.items.len() > limit || bytes + weight > PAGE_BYTES)
                    && kept > 0
                {
                    next = records.last().map(|(offset, _)| *offset);
                    break 'windows;
                }
                kept += shaped.items.len();
                bytes += weight;
                records.push((offset, record));
            }
            end = start;
        }
        records.reverse();
        let mut shaped = self.shape(records, epoch);
        self.resolve_after(&mut shaped, before, epoch)?;
        Ok(Page {
            items: shaped.items.into_iter().map(|(_, item)| item).collect(),
            before: next,
        })
    }

    /// The whole text behind `handle`: a long message or thinking, or a tool's output.
    pub fn text(
        &self,
        handle: &OutputHandle,
        offset: u64,
        length: u32,
    ) -> Result<TimelineToolOutput, WsError> {
        if length < 4 {
            return Err(WsError::Invalid(
                "output pages must hold at least four bytes".into(),
            ));
        }
        let missing = || WsError::NotFound("text".into());
        let record = self.file.record_at(handle.offset())?.ok_or_else(missing)?;
        let Ok(Entry::Message { id, message, .. }) = serde_json::from_slice::<Entry>(&record)
        else {
            return Err(missing());
        };
        let text = match *message {
            Message::ToolResult { call, content, .. } if handle.id() == tool_id(&call) => {
                block_text(&content)
            }
            Message::User { content, .. } if handle.id() == id => user_text(content),
            Message::Assistant { content, .. } => content
                .into_iter()
                .enumerate()
                .find_map(|(index, block)| (handle.id() == block_id(&id, index)).then_some(block))
                .and_then(|block| match block {
                    Block::Text { text } => Some(text),
                    Block::Thinking { thinking } => Some(thinking),
                    _ => None,
                })
                .ok_or_else(missing)?,
            Message::BashExecution { output, .. } if handle.id() == id => output,
            _ => return Err(missing()),
        };
        crate::timeline::output_page(&text, offset, length)
    }

    /// Fills in the results recorded after `end` for calls still running in `shaped`.
    fn resolve_after(&self, shaped: &mut Shaped, end: u64, epoch: u64) -> Result<(), WsError> {
        let mut running: HashMap<String, usize> = shaped
            .items
            .iter()
            .enumerate()
            .filter(|(_, (_, item))| {
                matches!(&item.body, TimelineBody::Tool(tool) if tool.status == TimelineToolStatus::Running)
            })
            .map(|(index, (_, item))| (item.id.clone(), index))
            .collect();
        let mut start = end;
        let length = self.file.length()?;
        while !running.is_empty() && start < length && start - end < SCAN_BYTES {
            let records = self.file.forward(start, RECORD_LIMIT)?;
            let Some((last, record)) = records.last() else {
                break;
            };
            let next = last + record.len() as u64 + 1;
            for result in self.shape(records, epoch).results {
                if let Some(index) = running.remove(&tool_id(&result.call)) {
                    let (_, item) = &mut shaped.items[index];
                    finish(item, &result, epoch);
                }
            }
            start = next;
        }
        Ok(())
    }

    fn shape(&self, records: Vec<(u64, Vec<u8>)>, epoch: u64) -> Shaped {
        let mut shaper = Shaper {
            epoch,
            cwd: &self.cwd,
            shaped: Shaped::default(),
            previous: None,
            calls: HashMap::new(),
        };
        for (offset, record) in records {
            shaper.record(offset, &record);
        }
        shaper.shaped
    }
}

const RECORD_LIMIT: u64 = crate::timeline::record_stream::RECORD_BYTES_LIMIT as u64;

/// Merges a later result into the tool row of its call.
pub(super) fn finish(item: &mut TimelineItem, result: &ToolResult, epoch: u64) {
    let TimelineBody::Tool(tool) = &mut item.body else {
        return;
    };
    tool.status = if result.failed {
        TimelineToolStatus::Failed
    } else {
        TimelineToolStatus::Done
    };
    tool.duration_ms = result.duration_ms;
    tool.output = output(epoch, result.offset, &item.id, &result.text);
    if let Some(patch) = &result.patch
        && tool.kind == TimelineToolKind::Edit
    {
        tool.diff = crate::timeline::claude_diff::unified_preview(&tool.title, patch);
    }
}

impl ToolResult {
    pub fn call(&self) -> &str {
        &self.call
    }
}

/// `newer`, keeping the name and model `older` knew when the records it read named none.
pub(super) fn merge(
    newer: proto::TimelineSession,
    older: &proto::TimelineSession,
) -> proto::TimelineSession {
    proto::TimelineSession {
        title: newer.title.or_else(|| older.title.clone()),
        model: newer.model.or_else(|| older.model.clone()),
        ..newer
    }
}

pub(super) fn tool_id(call: &str) -> String {
    format!("tool:{call}")
}

struct Shaper<'a> {
    epoch: u64,
    cwd: &'a Path,
    shaped: Shaped,
    previous: Option<String>,
    calls: HashMap<String, usize>,
}

impl Shaper<'_> {
    fn record(&mut self, offset: u64, record: &[u8]) {
        let Ok(entry) = serde_json::from_slice::<Entry>(record) else {
            return;
        };
        match entry {
            Entry::Message {
                id,
                parent,
                message,
            } => {
                if let (Some(parent), Some(previous)) = (&parent, &self.previous)
                    && parent != previous
                {
                    self.push(
                        offset,
                        format!("{id}:branch"),
                        0,
                        notice(
                            TimelineNoticeKind::Cleared,
                            "Went back to an earlier point in the conversation",
                        ),
                    );
                }
                self.previous = Some(id.clone());
                self.message(offset, id, *message);
            }
            Entry::Compaction { id, tokens_before } => {
                let text = match tokens_before {
                    Some(tokens) => format!("Context compacted from {} tokens", thousands(tokens)),
                    None => "Context compacted".to_owned(),
                };
                self.previous = Some(id.clone());
                self.push(offset, id, 0, notice(TimelineNoticeKind::Compacted, &text));
            }
            Entry::BranchSummary { id } => {
                self.previous = Some(id.clone());
                self.push(
                    offset,
                    id,
                    0,
                    notice(
                        TimelineNoticeKind::Cleared,
                        "Went back to an earlier point in the conversation",
                    ),
                );
            }
            Entry::ModelChange { id, model } => {
                self.previous = Some(id.clone());
                let text = format!("Model changed to {model}");
                self.shaped.model = Some(model);
                self.push(
                    offset,
                    id,
                    0,
                    notice(TimelineNoticeKind::ModelChanged, &text),
                );
            }
            Entry::SessionInfo { name } => {
                self.shaped.title = name.filter(|name| !name.trim().is_empty());
            }
            Entry::Other => {}
        }
    }

    fn message(&mut self, offset: u64, id: String, message: Message) {
        match message {
            Message::User { content, timestamp } => {
                let text = user_text(content);
                let body = fitted(TimelineTextRole::User, text, self.epoch, offset, &id);
                self.push(offset, id, timestamp.unwrap_or(0), body);
            }
            Message::Assistant {
                content,
                model,
                stop_reason,
                error_message,
                duration_ms,
                timestamp,
            } => {
                let at = timestamp.unwrap_or(0);
                if model.is_some() {
                    self.shaped.model = model;
                }
                for (index, block) in content.into_iter().enumerate() {
                    let block_id = block_id(&id, index);
                    let body = match block {
                        Block::Text { text } if text.trim().is_empty() => continue,
                        Block::Text { text } => fitted(
                            TimelineTextRole::Assistant,
                            text,
                            self.epoch,
                            offset,
                            &block_id,
                        ),
                        Block::Thinking { thinking } => {
                            // pi records no thinking time of its own: a response that opens
                            // with thinking counts its whole time as thought.
                            let duration_ms = duration_ms.filter(|_| index == 0);
                            if thinking.trim().is_empty() && duration_ms.is_none() {
                                continue;
                            }
                            match fitted(
                                TimelineTextRole::Thinking,
                                thinking,
                                self.epoch,
                                offset,
                                &block_id,
                            ) {
                                TimelineBody::Thinking { text, .. } => {
                                    TimelineBody::Thinking { text, duration_ms }
                                }
                                body => body,
                            }
                        }
                        Block::ToolCall {
                            id: call,
                            name,
                            arguments,
                        } => {
                            let item_id = tool_id(&call);
                            self.calls.insert(call, self.shaped.items.len());
                            self.push(
                                offset,
                                item_id,
                                at,
                                TimelineBody::Tool(tool(&name, &arguments, self.cwd)),
                            );
                            continue;
                        }
                        Block::Image {} | Block::Other => continue,
                    };
                    self.push(offset, block_id, at, body);
                }
                let stop = match stop_reason.as_deref() {
                    Some("error") => Some(notice(
                        TimelineNoticeKind::Error,
                        error_message
                            .as_deref()
                            .filter(|message| !message.trim().is_empty())
                            .unwrap_or("pi stopped with an error."),
                    )),
                    Some("aborted") => Some(notice(TimelineNoticeKind::Interrupted, "Interrupted")),
                    _ => None,
                };
                if let Some(body) = stop {
                    self.push(offset, format!("{id}:stop"), at, body);
                }
            }
            Message::ToolResult {
                call,
                content,
                failed,
                duration_ms,
                details,
            } => {
                let result = ToolResult {
                    offset,
                    failed,
                    text: block_text(&content),
                    duration_ms,
                    patch: details
                        .as_ref()
                        .and_then(|details| details.get("patch"))
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    call,
                };
                match self.calls.remove(&result.call) {
                    Some(index) => {
                        let (_, item) = &mut self.shaped.items[index];
                        finish(item, &result, self.epoch);
                    }
                    None => self.shaped.results.push(result),
                }
            }
            Message::BashExecution {
                command,
                output: text,
                exit,
                cancelled,
                timestamp,
            } => {
                let mut tool = tool("bash", &serde_json::json!({ "command": command }), self.cwd);
                tool.status = if cancelled {
                    TimelineToolStatus::Interrupted
                } else if exit.is_some_and(|code| code != 0) {
                    TimelineToolStatus::Failed
                } else {
                    TimelineToolStatus::Done
                };
                tool.exit = exit;
                tool.output = output(self.epoch, offset, &id, &text);
                self.push(offset, id, timestamp.unwrap_or(0), TimelineBody::Tool(tool));
            }
            Message::Other => {}
        }
    }

    fn push(&mut self, offset: u64, id: String, at: u64, body: TimelineBody) {
        let origin = match &body {
            TimelineBody::User { .. }
            | TimelineBody::LongText {
                role: TimelineTextRole::User,
                ..
            } => TimelineOrigin::Terminal,
            _ => TimelineOrigin::Agent,
        };
        self.shaped.items.push((
            offset,
            TimelineItem {
                id,
                revision: 1,
                turn: None,
                parent: None,
                at: UnixMillis(at),
                origin,
                body,
            },
        ));
    }
}

fn block_id(entry: &str, index: usize) -> String {
    format!("{entry}:{index}")
}

fn notice(kind: TimelineNoticeKind, text: &str) -> TimelineBody {
    TimelineBody::Notice {
        kind,
        text: text.to_owned(),
    }
}

fn thousands(value: u64) -> String {
    let digits = value.to_string();
    let mut grouped = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    grouped
}

fn user_text(content: Content) -> String {
    match content {
        Content::Text(text) => text,
        Content::Blocks(blocks) => {
            let mut text = String::new();
            for block in blocks {
                match block {
                    Block::Text { text: part } => text.push_str(&part),
                    Block::Image {} => text.push_str("\n[Image available in Terminal]\n"),
                    _ => {}
                }
            }
            text
        }
    }
}

fn block_text(blocks: &[Block]) -> String {
    blocks
        .iter()
        .filter_map(|block| match block {
            Block::Text { text } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// A tool row for one of pi's calls, still running until its result is read.
fn tool(name: &str, arguments: &Value, cwd: &Path) -> TimelineTool {
    let argument = |key: &str| arguments.get(key).and_then(Value::as_str);
    let path = argument("path").map(|path| absolute(cwd, path));
    let (kind, title) = match name {
        "bash" => (
            TimelineToolKind::Shell,
            argument("command").unwrap_or_default().to_owned(),
        ),
        "read" => (TimelineToolKind::Read, path.clone().unwrap_or_default()),
        "edit" => (TimelineToolKind::Edit, path.clone().unwrap_or_default()),
        "write" => (TimelineToolKind::Write, path.clone().unwrap_or_default()),
        "grep" | "find" => (
            TimelineToolKind::Search,
            argument("pattern").unwrap_or(name).to_owned(),
        ),
        "ls" => (
            TimelineToolKind::Search,
            path.clone().unwrap_or_else(|| cwd.display().to_string()),
        ),
        other => (TimelineToolKind::Other, other.to_owned()),
    };
    let mut input = arguments.clone();
    if let (Some(path), Some(object)) = (path, input.as_object_mut()) {
        object.insert("path".into(), Value::String(path));
    }
    let input = match input {
        Value::Null => String::new(),
        input => input.to_string(),
    };
    TimelineTool {
        kind,
        name: name.to_owned(),
        title: head(&title, TITLE_BYTES).to_owned(),
        input: head(&input, INPUT_BYTES).to_owned(),
        status: TimelineToolStatus::Running,
        output: None,
        diff: Vec::new(),
        exit: None,
        duration_ms: None,
        command_mark: None,
    }
}

fn absolute(cwd: &Path, path: &str) -> String {
    let path = Path::new(path);
    if path.is_absolute() || path.starts_with("~") || cwd.as_os_str().is_empty() {
        path.display().to_string()
    } else {
        cwd.join(path).display().to_string()
    }
}

fn output(epoch: u64, offset: u64, id: &str, text: &str) -> Option<TimelineOutputRef> {
    if text.is_empty() {
        return None;
    }
    Some(TimelineOutputRef {
        handle: OutputHandle::new(epoch, offset, id).ok()?,
        preview: crate::timeline::output_preview(text),
        bytes: text.len() as u64,
    })
}

fn fitted(role: TimelineTextRole, text: String, epoch: u64, offset: u64, id: &str) -> TimelineBody {
    if text.len() <= LONG_TEXT_BYTES {
        return match role {
            TimelineTextRole::User => TimelineBody::User {
                text,
                attachments: Vec::new(),
                queued: false,
            },
            TimelineTextRole::Assistant => TimelineBody::Assistant {
                text,
                streaming: false,
            },
            TimelineTextRole::Thinking => TimelineBody::Thinking {
                text: (!text.trim().is_empty()).then_some(text),
                duration_ms: None,
            },
        };
    }
    match OutputHandle::new(epoch, offset, id) {
        Ok(handle) => TimelineBody::LongText {
            role,
            content: TimelineOutputRef {
                handle,
                preview: head(&text, PREVIEW_BYTES).to_owned(),
                bytes: text.len() as u64,
            },
        },
        Err(_) => notice(
            TimelineNoticeKind::Error,
            "This is too large for Chat. Check Terminal.",
        ),
    }
}

/// The start of `text` within `limit` bytes, ending at a line break when one is near the end.
fn head(text: &str, limit: usize) -> &str {
    if text.len() <= limit {
        return text;
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let start = &text[..end];
    match start.rfind('\n') {
        Some(line_end) if line_end >= end / 2 => &start[..=line_end],
        _ => start,
    }
}
