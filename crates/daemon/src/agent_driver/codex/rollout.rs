//! Codex's rollout file, read as the durable store of a Chat conversation: older items page
//! from it, and long text and command output read back from it in full.

use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use agents::{CodexInput, CodexItem, CodexTurnOutcome};
use proto::{OutputHandle, TimelineBody, TimelineItem, TimelineToolOutput, UnixMillis, WsError};
use serde::Deserialize;
use serde::de::IgnoredAny;

use super::projection::{self, Location};
use crate::timeline::complete_diff::{RecordedFile, recorded_files};
use crate::timeline::record_stream::{RECORD_BYTES_LIMIT, RecordStream};

#[cfg(test)]
pub(crate) mod tests;

const PAGE_ITEMS: usize = 100;
const PAGE_BYTES: usize = 1024 * 1024;
/// How far back a page, or the search for one item, reads before answering.
const SCAN_BYTES: u64 = 64 * 1024 * 1024;

pub(super) struct Rollout {
    path: PathBuf,
    file: File,
    identity: (u64, u64),
    thread: String,
}

#[derive(Debug)]
pub(super) struct RolloutPage {
    pub items: Vec<TimelineItem>,
    pub before: Option<u64>,
}

/// What Codex recorded since the last read.
#[derive(Debug)]
pub(super) struct Appended {
    pub items: Vec<TimelineItem>,
    /// A rollback dropped turns already shown.
    pub rolled_back: bool,
    /// More was recorded than one read takes.
    pub more: bool,
}

enum Record {
    Items(Vec<TimelineItem>),
    RolledBack,
    Other,
}

/// The complete records of one bounded read, and the record boundary to continue from.
struct Window {
    records: Vec<(u64, Vec<u8>)>,
    start: u64,
}

#[derive(Deserialize)]
struct Envelope<'a> {
    #[serde(rename = "type", borrow)]
    kind: Cow<'a, str>,
}

#[derive(Deserialize)]
struct SessionLine {
    payload: SessionMeta,
}

#[derive(Deserialize)]
struct SessionMeta {
    id: String,
    #[serde(default)]
    history_mode: agents::CodexHistoryMode,
    /// A fork keeps its inherited turns in the rollout it was forked from.
    history_base: Option<IgnoredAny>,
}

#[derive(Deserialize)]
struct EventLine {
    payload: Event,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
    ItemCompleted {
        thread_id: Option<String>,
        turn_id: String,
        item: Box<RecordedItem>,
        started_at_ms: Option<i64>,
        completed_at_ms: Option<i64>,
    },
    #[serde(rename = "task_complete", alias = "turn_complete")]
    TurnComplete {
        turn_id: String,
        error: Option<RecordedError>,
        duration_ms: Option<u64>,
        completed_at: Option<i64>,
    },
    TurnAborted {
        turn_id: Option<String>,
    },
    ThreadRolledBack {},
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct RecordedError {
    #[serde(default)]
    message: String,
}

/// A model request the rollout keeps beside its items; only plan updates are read from them.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ResponseItem {
    FunctionCall {
        name: String,
        arguments: String,
        call_id: String,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct ResponseLine {
    timestamp: Option<String>,
    payload: ResponseItem,
}

#[derive(Deserialize)]
struct PlanArguments {
    plan: Vec<agents::CodexPlanStep>,
}

/// An item as Codex persists it, before the app-server reshapes it for its stream.
#[derive(Deserialize)]
#[serde(tag = "type")]
enum RecordedItem {
    UserMessage {
        id: String,
        content: Vec<CodexInput>,
    },
    AgentMessage {
        id: String,
        content: Vec<AgentContent>,
    },
    Plan {
        id: String,
        text: String,
    },
    Reasoning {
        id: String,
        #[serde(default)]
        summary_text: Vec<String>,
        #[serde(default)]
        raw_content: Vec<String>,
    },
    CommandExecution {
        id: String,
        command: Vec<String>,
        status: String,
        aggregated_output: Option<String>,
        exit_code: Option<i32>,
        duration: Option<RecordedDuration>,
    },
    McpToolCall {
        id: String,
        server: String,
        tool: String,
        #[serde(default)]
        arguments: serde_json::Value,
        status: String,
        result: Option<agents::CodexToolResult>,
        error: Option<serde_json::Value>,
        duration: Option<RecordedDuration>,
    },
    DynamicToolCall {
        id: String,
        tool: String,
        #[serde(default)]
        arguments: serde_json::Value,
        status: String,
        content_items: Option<Vec<serde_json::Value>>,
        error: Option<String>,
    },
    CollabAgentToolCall {
        id: String,
        tool: String,
        status: String,
        #[serde(default)]
        receiver_thread_ids: Vec<String>,
        prompt: Option<String>,
        model: Option<String>,
        #[serde(default)]
        agents_states: BTreeMap<String, serde_json::Value>,
    },
    FileChange {
        id: String,
        changes: BTreeMap<String, RecordedChange>,
        status: String,
    },
    ImageView {
        id: String,
        path: String,
    },
    WebSearch {
        id: String,
        #[serde(default)]
        query: String,
        action: Option<agents::CodexWebSearchAction>,
    },
    /// Web search records its query; other extensions stay Terminal-only.
    Extension {
        id: String,
        query: Option<String>,
    },
    ContextCompaction {
        id: String,
    },
    EnteredReviewMode {
        id: String,
        #[serde(default)]
        user_facing_hint: String,
    },
    ExitedReviewMode {
        id: String,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RecordedChange {
    Add {
        content: String,
    },
    Delete {
        content: String,
    },
    Update {
        unified_diff: String,
        move_path: Option<String>,
    },
}

#[derive(Deserialize)]
#[serde(tag = "type")]
enum AgentContent {
    Text {
        text: String,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct RecordedDuration {
    secs: u64,
    nanos: u32,
}

impl RecordedItem {
    fn id(&self) -> Option<&str> {
        match self {
            Self::UserMessage { id, .. }
            | Self::AgentMessage { id, .. }
            | Self::Plan { id, .. }
            | Self::Reasoning { id, .. }
            | Self::CommandExecution { id, .. }
            | Self::McpToolCall { id, .. }
            | Self::DynamicToolCall { id, .. }
            | Self::CollabAgentToolCall { id, .. }
            | Self::FileChange { id, .. }
            | Self::ImageView { id, .. }
            | Self::WebSearch { id, .. }
            | Self::Extension { id, .. }
            | Self::ContextCompaction { id }
            | Self::EnteredReviewMode { id, .. }
            | Self::ExitedReviewMode { id } => Some(id),
            Self::Other => None,
        }
    }

    /// The item as the app-server streams it, so both sources shape it the same way.
    fn into_live(self) -> CodexItem {
        match self {
            Self::UserMessage { id, content } => CodexItem::UserMessage { id, content },
            Self::AgentMessage { id, content } => CodexItem::AgentMessage {
                id,
                text: content
                    .into_iter()
                    .filter_map(|part| match part {
                        AgentContent::Text { text } => Some(text),
                        AgentContent::Other => None,
                    })
                    .collect(),
            },
            Self::Plan { id, text } => CodexItem::Plan { id, text },
            Self::Reasoning {
                id,
                summary_text,
                raw_content,
            } => CodexItem::Reasoning {
                id,
                summary: summary_text,
                content: raw_content,
            },
            Self::CommandExecution {
                id,
                command,
                status,
                aggregated_output,
                exit_code,
                duration,
            } => CodexItem::CommandExecution {
                id,
                command: shell_words(&command),
                status: match status.as_str() {
                    "in_progress" => "inProgress".into(),
                    _ => status,
                },
                aggregated_output,
                exit_code,
                duration_ms: duration.as_ref().map(RecordedDuration::millis),
            },
            Self::McpToolCall {
                id,
                server,
                tool,
                arguments,
                status,
                result,
                error,
                duration,
            } => CodexItem::McpToolCall {
                id,
                server,
                tool,
                status,
                arguments,
                result,
                error: error.map(|error| agents::CodexToolError {
                    message: match error {
                        serde_json::Value::String(message) => message,
                        error => error
                            .get("message")
                            .and_then(serde_json::Value::as_str)
                            .map_or_else(|| error.to_string(), str::to_owned),
                    },
                }),
                duration_ms: duration.as_ref().map(RecordedDuration::millis),
            },
            Self::DynamicToolCall {
                id,
                tool,
                arguments,
                status,
                content_items,
                error,
            } => CodexItem::DynamicToolCall {
                id,
                tool,
                status: if error.is_some() {
                    "failed".into()
                } else {
                    status
                },
                arguments,
                content_items,
                duration_ms: None,
            },
            Self::CollabAgentToolCall {
                id,
                tool,
                status,
                receiver_thread_ids,
                prompt,
                model,
                agents_states,
            } => CodexItem::CollabAgentToolCall {
                id,
                tool,
                status,
                receiver_thread_ids,
                prompt,
                model,
                agents_states: agents_states
                    .into_iter()
                    .map(|(thread, state)| (thread, agent_state(state)))
                    .collect(),
            },
            Self::FileChange {
                id,
                changes,
                status,
            } => CodexItem::FileChange {
                id,
                changes: changes
                    .into_iter()
                    .map(|(path, change)| match change {
                        RecordedChange::Add { content } => agents::CodexFileChange {
                            path,
                            kind: agents::CodexFileChangeKind::Add,
                            diff: content,
                        },
                        RecordedChange::Delete { content } => agents::CodexFileChange {
                            path,
                            kind: agents::CodexFileChangeKind::Delete,
                            diff: content,
                        },
                        RecordedChange::Update {
                            unified_diff,
                            move_path,
                        } => agents::CodexFileChange {
                            path,
                            kind: agents::CodexFileChangeKind::Update { move_path },
                            diff: unified_diff,
                        },
                    })
                    .collect(),
                status,
            },
            Self::ImageView { id, path } => CodexItem::ImageView { id, path },
            Self::WebSearch { id, query, action } => CodexItem::WebSearch { id, query, action },
            Self::Extension {
                id,
                query: Some(query),
            } => CodexItem::WebSearch {
                id,
                query,
                action: None,
            },
            Self::ContextCompaction { id } => CodexItem::ContextCompaction { id },
            Self::EnteredReviewMode {
                id,
                user_facing_hint,
            } => CodexItem::EnteredReviewMode {
                id,
                review: user_facing_hint,
            },
            Self::ExitedReviewMode { id } => CodexItem::ExitedReviewMode {
                id,
                review: String::new(),
            },
            Self::Extension { query: None, .. } | Self::Other => CodexItem::Unsupported,
        }
    }
}

/// An agent's recorded status, `"running"` or `{"completed": "its last message"}`.
fn agent_state(state: serde_json::Value) -> agents::CodexAgentState {
    match state {
        serde_json::Value::String(status) => agents::CodexAgentState {
            status,
            message: None,
        },
        serde_json::Value::Object(fields) => {
            let (status, message) = fields.into_iter().next().unwrap_or_default();
            agents::CodexAgentState {
                status,
                message: message.as_str().map(str::to_owned),
            }
        }
        _ => agents::CodexAgentState {
            status: String::new(),
            message: None,
        },
    }
}

impl RecordedDuration {
    fn millis(&self) -> u64 {
        self.secs
            .saturating_mul(1000)
            .saturating_add(u64::from(self.nanos / 1_000_000))
    }
}

impl Rollout {
    /// Opens the rollout Codex reported for `thread`, refusing anything outside
    /// `<codex_home>/sessions`, a final symbolic link, another thread's file or a rollout
    /// whose items lack the ids the app-server streams.
    pub fn open(codex_home: &Path, path: &Path, thread: &str) -> Result<Self, WsError> {
        let sessions = codex_home.join("sessions").canonicalize().map_err(failed)?;
        let canonical = path.canonicalize().map_err(failed)?;
        let named = canonical
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| {
                name.starts_with("rollout-") && name.ends_with(&format!("-{thread}.jsonl"))
            });
        if !canonical.starts_with(&sessions) || !named {
            return Err(WsError::Denied(
                "the rollout is outside the Codex sessions directory".into(),
            ));
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(failed)?;
        let metadata = file.metadata().map_err(failed)?;
        let checked = std::fs::metadata(&canonical).map_err(failed)?;
        if !metadata.is_file() || (metadata.dev(), metadata.ino()) != (checked.dev(), checked.ino())
        {
            return Err(WsError::Denied("the rollout is not a regular file".into()));
        }
        let mut first = Vec::new();
        BufReader::new((&file).take(RECORD_BYTES_LIMIT as u64))
            .read_until(b'\n', &mut first)
            .map_err(failed)?;
        let meta = serde_json::from_slice::<Envelope<'_>>(&first)
            .ok()
            .filter(|envelope| envelope.kind == "session_meta")
            .and_then(|_| serde_json::from_slice::<SessionLine>(&first).ok())
            .map(|line| line.payload)
            .ok_or_else(|| WsError::Unavailable("the rollout has no session record".into()))?;
        if meta.id != thread {
            return Err(WsError::Denied(
                "the rollout belongs to another thread".into(),
            ));
        }
        if meta.history_mode != agents::CodexHistoryMode::Paginated {
            return Err(WsError::Unavailable(
                "This Codex saves its history in an older format. Update Codex to see it in Chat."
                    .into(),
            ));
        }
        if meta.history_base.is_some() {
            return Err(WsError::Unavailable(
                "This Codex conversation continues a forked one, which Chat cannot show yet. Use Terminal.".into(),
            ));
        }
        Ok(Self {
            path: path.to_owned(),
            file,
            identity: (metadata.dev(), metadata.ino()),
            thread: thread.to_owned(),
        })
    }

    /// The end of the last complete record: the cursor of a page of the newest items.
    pub fn end(&self) -> Result<u64, WsError> {
        let length = self.length()?;
        let start = length.saturating_sub(RECORD_BYTES_LIMIT as u64);
        let mut stream = self.stream_at(start)?;
        stream.push(&self.read(start, length)?);
        Ok(stream.complete_end())
    }

    /// The items Codex recorded past where `stream` stopped, at most one bounded read of them.
    pub fn appended(&self, stream: &mut RecordStream, epoch: u64) -> Result<Appended, WsError> {
        let length = self.length()?;
        let start = stream.scan_offset();
        if start > length {
            return Err(WsError::Conflict(
                "the Codex rollout changed; reopen Chat".into(),
            ));
        }
        let end = length.min(start.saturating_add(RECORD_BYTES_LIMIT as u64));
        let mut appended = Appended {
            items: Vec::new(),
            rolled_back: false,
            more: end < length,
        };
        for (offset, record) in stream.push(&self.read(start, end)?) {
            match self.parse(offset, &record, epoch) {
                Record::Items(items) => appended.items.extend(items),
                Record::RolledBack => appended.rolled_back = true,
                Record::Other => {}
            }
        }
        Ok(appended)
    }

    /// Up to `limit` items recorded before the record at `before`, oldest first.
    pub fn page(&self, before: u64, limit: usize, epoch: u64) -> Result<RolloutPage, WsError> {
        let length = self.length()?;
        if before == 0 || before > length || !self.is_boundary(before)? {
            return Err(WsError::Invalid(
                "the history cursor is no longer valid".into(),
            ));
        }
        let limit = limit.clamp(1, PAGE_ITEMS);
        let mut items: Vec<(u64, TimelineItem)> = Vec::new();
        let mut bytes = 0;
        let mut end = before;
        let mut scanned = 0;
        while end > 0 {
            if scanned >= SCAN_BYTES {
                return Ok(page(items, Some(end)));
            }
            let Window { records, start } = self.window(end)?;
            scanned += end - start;
            for (offset, record) in records.into_iter().rev() {
                let recorded = match self.parse(offset, &record, epoch) {
                    Record::Items(recorded) => recorded,
                    Record::RolledBack => return Ok(page(items, None)),
                    Record::Other => continue,
                };
                let weight: usize = recorded
                    .iter()
                    .map(crate::timeline::value_weight::item)
                    .sum();
                if items.len() >= limit || (bytes + weight > PAGE_BYTES && !items.is_empty()) {
                    let oldest = items.last().map(|(offset, _)| *offset);
                    return Ok(page(items, oldest));
                }
                bytes += weight;
                for item in recorded.into_iter().rev() {
                    // A turn's notice for details Chat does not show stands at its first such item.
                    items.retain(|(_, newer)| newer.id != item.id);
                    items.push((offset, item));
                }
            }
            end = start;
        }
        Ok(page(items, None))
    }

    /// The cursor for older history under a snapshot whose items are `ids`, oldest first:
    /// the record of the oldest item saved in the rollout. Items not saved yet are newer.
    pub fn before_items(&self, ids: &[String], epoch: u64) -> Result<Option<u64>, WsError> {
        let end = self.end()?;
        if ids.is_empty() {
            return Ok(Some(end).filter(|end| *end > 0));
        }
        let wanted: HashSet<&str> = ids.iter().map(String::as_str).collect();
        let mut found: HashMap<String, u64> = HashMap::new();
        let mut cursor = end;
        while cursor > 0 && end - cursor < SCAN_BYTES && !found.contains_key(&ids[0]) {
            let Window { records, start } = self.window(cursor)?;
            for (offset, record) in records.into_iter().rev() {
                let Record::Items(items) = self.parse(offset, &record, epoch) else {
                    continue;
                };
                for item in items {
                    if wanted.contains(item.id.as_str()) {
                        found.insert(item.id, offset);
                    }
                }
            }
            cursor = start;
        }
        Ok(ids.iter().find_map(|id| found.get(id).copied()))
    }

    /// A page of the whole text behind `handle`: a long message, thinking or command output.
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
        let (turn, item) = projection::split_item_id(handle.id())
            .ok_or_else(|| WsError::Invalid("the output handle is invalid".into()))?;
        let recorded = match self.recorded_at(handle.offset(), turn, item)? {
            Some(recorded) => recorded,
            None => self.find(turn, item)?.ok_or_else(|| {
                WsError::Unavailable(
                    "Codex has not saved this yet. Try again when the turn ends.".into(),
                )
            })?,
        };
        let text = projection::paged_text(&recorded.into_live())
            .ok_or_else(|| WsError::NotFound("text".into()))?;
        crate::timeline::output_page(&text, offset, length)
    }

    /// The complete changes of the file change behind `handle`.
    pub fn diff(&self, handle: &OutputHandle) -> Result<Vec<proto::FileDiff>, WsError> {
        let (turn, item) = projection::split_item_id(handle.id())
            .ok_or_else(|| WsError::Invalid("the change handle is invalid".into()))?;
        let recorded = match self.recorded_at(handle.offset(), turn, item)? {
            Some(recorded) => recorded,
            None => self.find(turn, item)?.ok_or_else(|| {
                WsError::Unavailable(
                    "Codex has not saved this change yet. Try again when the turn ends.".into(),
                )
            })?,
        };
        let CodexItem::FileChange { changes, .. } = recorded.into_live() else {
            return Err(WsError::NotFound("recorded changes".into()));
        };
        let files: Vec<RecordedFile<'_>> = changes
            .iter()
            .map(|change| match &change.kind {
                agents::CodexFileChangeKind::Add => RecordedFile::Added {
                    path: &change.path,
                    content: &change.diff,
                },
                agents::CodexFileChangeKind::Delete => RecordedFile::Deleted {
                    path: &change.path,
                    content: &change.diff,
                },
                agents::CodexFileChangeKind::Update { move_path } => RecordedFile::Updated {
                    path: move_path.as_deref().unwrap_or(&change.path),
                    old_path: move_path.as_ref().map(|_| change.path.as_str()),
                    unified: &change.diff,
                },
            })
            .collect();
        recorded_files(&files)
    }

    fn recorded_at(
        &self,
        offset: u64,
        turn: &str,
        item: &str,
    ) -> Result<Option<RecordedItem>, WsError> {
        let length = self.length()?;
        if offset == 0 || offset >= length || !self.is_boundary(offset)? {
            return Ok(None);
        }
        let mut record = Vec::new();
        BufReader::new(self.reader(offset)?.take(RECORD_BYTES_LIMIT as u64))
            .read_until(b'\n', &mut record)
            .map_err(failed)?;
        if record.last() != Some(&b'\n') {
            return Ok(None);
        }
        Ok(self.recorded_item(&record, turn, item))
    }

    fn find(&self, turn: &str, item: &str) -> Result<Option<RecordedItem>, WsError> {
        let end = self.end()?;
        let mut cursor = end;
        while cursor > 0 && end - cursor < SCAN_BYTES {
            let Window { records, start } = self.window(cursor)?;
            for (_, record) in records.into_iter().rev() {
                if memchr::memmem::find(&record, item.as_bytes()).is_some()
                    && let Some(recorded) = self.recorded_item(&record, turn, item)
                {
                    return Ok(Some(recorded));
                }
            }
            cursor = start;
        }
        Ok(None)
    }

    fn recorded_item(&self, record: &[u8], turn: &str, item: &str) -> Option<RecordedItem> {
        match event(record)? {
            Event::ItemCompleted {
                thread_id,
                turn_id,
                item: recorded,
                ..
            } if turn_id == turn
                && recorded.id() == Some(item)
                && thread_id
                    .as_deref()
                    .is_none_or(|thread| thread == self.thread) =>
            {
                Some(*recorded)
            }
            _ => None,
        }
    }

    fn parse(&self, offset: u64, record: &[u8], epoch: u64) -> Record {
        if let Some(plan) = plan(record) {
            return Record::Items(vec![plan]);
        }
        let Some(event) = event(record) else {
            return Record::Other;
        };
        let item = |id, turn: String, body: TimelineBody, at: i64| TimelineItem {
            id,
            revision: 1,
            turn: Some(turn),
            parent: None,
            at: UnixMillis(u64::try_from(at).unwrap_or(0)),
            origin: projection::origin(&body),
            body,
        };
        let items = match event {
            Event::ItemCompleted {
                thread_id,
                turn_id,
                item: recorded,
                started_at_ms,
                completed_at_ms,
            } => {
                if thread_id.is_some_and(|thread| thread != self.thread) {
                    return Record::Other;
                }
                let location = Location::recorded(epoch, offset);
                let Some((id, body)) =
                    projection::body((*recorded).into_live(), true, &turn_id, location)
                else {
                    return Record::Other;
                };
                let at = completed_at_ms.or(started_at_ms).unwrap_or(0);
                vec![item(id, turn_id, body, at)]
            }
            Event::TurnComplete {
                turn_id,
                error,
                duration_ms,
                completed_at,
            } => {
                let at = completed_at.unwrap_or(0).saturating_mul(1000);
                let failure = error.and_then(|error| {
                    projection::turn_failure(CodexTurnOutcome::Failed, Some(&error.message))
                });
                let end = duration_ms.map(|duration_ms| TimelineBody::TurnEnd {
                    duration_ms,
                    input_tokens: None,
                    output_tokens: None,
                });
                let mut items = Vec::new();
                if let Some(body) = failure {
                    items.push(item(
                        projection::turn_notice_id(&turn_id),
                        turn_id.clone(),
                        body,
                        at,
                    ));
                }
                if let Some(body) = end {
                    items.push(item(projection::turn_end_id(&turn_id), turn_id, body, at));
                }
                items
            }
            Event::TurnAborted {
                turn_id: Some(turn_id),
            } => match projection::turn_failure(CodexTurnOutcome::Interrupted, None) {
                Some(body) => vec![item(projection::turn_notice_id(&turn_id), turn_id, body, 0)],
                None => return Record::Other,
            },
            Event::ThreadRolledBack {} => return Record::RolledBack,
            Event::TurnAborted { .. } | Event::Other => return Record::Other,
        };
        if items.is_empty() {
            Record::Other
        } else {
            Record::Items(items)
        }
    }

    /// The complete records in the bounded read that ends at the record boundary `end`.
    /// A record too large to read is passed over.
    fn window(&self, end: u64) -> Result<Window, WsError> {
        let start = end.saturating_sub(RECORD_BYTES_LIMIT as u64);
        let mut stream = self.stream_at(start)?;
        let records = stream.push(&self.read(start, end)?);
        let next = match records.first() {
            Some((offset, _)) => *offset,
            None if start == 0 => 0,
            None => self.line_start(start)?,
        };
        Ok(Window {
            records,
            start: next,
        })
    }

    fn stream_at(&self, start: u64) -> Result<RecordStream, WsError> {
        Ok(if self.is_boundary(start)? {
            RecordStream::at_boundary(start)
        } else {
            RecordStream::inside_fragment(start)
        })
    }

    /// The start of the line holding `position`.
    fn line_start(&self, position: u64) -> Result<u64, WsError> {
        const CHUNK: u64 = 1024 * 1024;
        let mut end = position;
        while end > 0 {
            let start = end.saturating_sub(CHUNK);
            let bytes = self.read(start, end)?;
            if let Some(newline) = memchr::memrchr(b'\n', &bytes) {
                return Ok(start + newline as u64 + 1);
            }
            end = start;
        }
        Ok(0)
    }

    fn length(&self) -> Result<u64, WsError> {
        let current = std::fs::symlink_metadata(&self.path).map_err(failed)?;
        let length = self.file.metadata().map_err(failed)?.len();
        if (current.dev(), current.ino()) != self.identity {
            return Err(WsError::Conflict(
                "the Codex rollout changed; reopen Chat".into(),
            ));
        }
        Ok(length)
    }

    fn is_boundary(&self, position: u64) -> Result<bool, WsError> {
        if position == 0 {
            return Ok(true);
        }
        let byte = self.read(position - 1, position)?;
        Ok(byte == b"\n")
    }

    fn reader(&self, offset: u64) -> Result<&File, WsError> {
        let mut file = &self.file;
        file.seek(SeekFrom::Start(offset)).map_err(failed)?;
        Ok(file)
    }

    fn read(&self, start: u64, end: u64) -> Result<Vec<u8>, WsError> {
        let mut bytes = Vec::with_capacity(usize::try_from(end - start).unwrap_or(0));
        self.reader(start)?
            .take(end - start)
            .read_to_end(&mut bytes)
            .map_err(failed)?;
        Ok(bytes)
    }
}

fn page(mut items: Vec<(u64, TimelineItem)>, before: Option<u64>) -> RolloutPage {
    items.reverse();
    RolloutPage {
        items: items.into_iter().map(|(_, item)| item).collect(),
        before,
    }
}

/// A plan the agent set with its plan tool, recorded as the model request itself.
fn plan(record: &[u8]) -> Option<TimelineItem> {
    memchr::memmem::find(record, b"\"update_plan\"")?;
    let envelope = serde_json::from_slice::<Envelope<'_>>(record).ok()?;
    if envelope.kind != "response_item" {
        return None;
    }
    let line = serde_json::from_slice::<ResponseLine>(record).ok()?;
    let ResponseItem::FunctionCall {
        name,
        arguments,
        call_id,
    } = line.payload
    else {
        return None;
    };
    if name != "update_plan" {
        return None;
    }
    let arguments: PlanArguments = serde_json::from_str(&arguments).ok()?;
    let body = projection::plan_body(arguments.plan);
    let at = line
        .timestamp
        .as_deref()
        .and_then(crate::usage::rfc3339_millis)
        .unwrap_or(0);
    Some(TimelineItem {
        id: format!("plan:{call_id}"),
        revision: 1,
        turn: None,
        parent: None,
        at: UnixMillis(at),
        origin: projection::origin(&body),
        body,
    })
}

fn event(record: &[u8]) -> Option<Event> {
    memchr::memmem::find(record, b"\"event_msg\"")?;
    let envelope = serde_json::from_slice::<Envelope<'_>>(record).ok()?;
    if envelope.kind != "event_msg" {
        return None;
    }
    serde_json::from_slice::<EventLine>(record)
        .ok()
        .map(|line| line.payload)
}

/// Words joined as a POSIX shell reads them back.
fn shell_words(words: &[String]) -> String {
    words
        .iter()
        .map(|word| {
            let plain = !word.is_empty()
                && word
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_./=:,+@%".contains(&byte));
            if plain {
                Cow::Borrowed(word.as_str())
            } else {
                Cow::Owned(format!("'{}'", word.replace('\'', "'\\''")))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn failed(error: impl std::fmt::Display) -> WsError {
    WsError::Failed(error.to_string())
}
