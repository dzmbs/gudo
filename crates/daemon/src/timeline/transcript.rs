use std::collections::{HashMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use super::claude::{ClaudeTimeline, result_text};
use super::claude_record::{BlockKind, Record, RecordKind};
use proto::{
    TimelineBody, TimelineCursor, TimelineItem, TimelineNoticeKind, TimelineOp, TimelineOrigin,
    TimelineSession, TimelineSnapshot, TimelineToolOutput, UnixMillis, WsError,
};

use super::record_stream::{RECORD_BYTES_LIMIT as READ_LIMIT, RecordStream};
const SNAPSHOT_BYTES: usize = 1024 * 1024;
const CACHE_ITEMS: usize = 512;
const CACHE_VALUE_BYTES: usize = 16 * 1024 * 1024;
const INDEXED_VALUE_FACTOR: usize = 4;
const OUTPUT_PAGE_BYTES: usize = 256 * 1024;

pub(super) struct Transcript {
    pub path: PathBuf,
    pub native_session: String,
    file: File,
    identity: (u64, u64),
    stream: RecordStream,
    observed_length: u64,
    modified: Option<std::time::SystemTime>,
    anchor: Vec<u8>,
    scan_anchor: Vec<u8>,
    parser: ClaudeTimeline,
    cursor: TimelineCursor,
    order: VecDeque<String>,
    items: HashMap<String, StoredItem>,
    retained_bytes: usize,
}

struct StoredItem {
    item: TimelineItem,
    offset: u64,
    encoded_bound: usize,
}

impl StoredItem {
    fn new(item: TimelineItem, offset: u64) -> Self {
        Self {
            encoded_bound: super::value_weight::item(&item),
            item,
            offset,
        }
    }

    fn retained_weight(&self) -> usize {
        // Reserve for owned fields plus duplicated index keys and container metadata.
        // The wire bound is cached; this value allowance is not an allocator/RSS reading.
        self.encoded_bound * INDEXED_VALUE_FACTOR
    }

    fn replace(&mut self, item: TimelineItem) {
        self.encoded_bound = super::value_weight::item(&item);
        self.item = item;
    }
}

struct Window {
    records: Vec<(u64, Record)>,
    stream: RecordStream,
}

impl Transcript {
    pub fn open(path: PathBuf, native_session: String, epoch: u64) -> Result<Self, WsError> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)
            .map_err(failed)?;
        let metadata = file.metadata().map_err(failed)?;
        if !metadata.is_file() {
            return Err(WsError::Denied(
                "the transcript is not a regular file".into(),
            ));
        }
        let mut transcript = Self {
            path,
            file,
            identity: (metadata.dev(), metadata.ino()),
            native_session: native_session.clone(),
            stream: RecordStream::at_boundary(0),
            observed_length: metadata.len(),
            modified: metadata.modified().ok(),
            anchor: Vec::new(),
            scan_anchor: Vec::new(),
            parser: ClaudeTimeline::new(native_session),
            cursor: TimelineCursor { epoch, sequence: 0 },
            order: VecDeque::new(),
            items: HashMap::new(),
            retained_bytes: 0,
        };
        let window = read_window(&mut transcript.file, metadata.len(), 60)?;
        transcript.stream = window.stream;
        for (offset, record) in window.records {
            let items = transcript.parser.parse_record(&record, offset);
            for item in bounded_record(items, offset) {
                transcript.store(item, offset);
            }
        }
        transcript.update_anchors()?;
        Ok(transcript)
    }

    pub fn set_commands(&mut self, commands: Vec<proto::TimelineCommand>) -> Option<TimelineOp> {
        if self.parser.session.commands == commands {
            return None;
        }
        self.parser.session.commands = commands;
        self.cursor.sequence = self.cursor.sequence.wrapping_add(1);
        Some(TimelineOp::Session {
            cursor: self.cursor,
            session: self.parser.session.clone(),
        })
    }

    pub fn cursor(&self) -> TimelineCursor {
        self.cursor
    }

    /// Returns whether the last bounded read left known bytes to consume without another file event.
    pub fn has_backlog(&self) -> bool {
        self.stream.scan_offset() < self.observed_length
    }

    pub fn snapshot(&self, limit: usize, since: Option<UnixMillis>) -> TimelineSnapshot {
        self.select_records(
            self.order.iter().filter_map(|id| self.items.get(id)),
            limit,
            since,
        )
    }

    fn select_records<'a>(
        &self,
        values: impl DoubleEndedIterator<Item = &'a StoredItem>,
        limit: usize,
        since: Option<UnixMillis>,
    ) -> TimelineSnapshot {
        // A byte cursor names a whole JSONL record, never an individual visible child.
        // Original offsets stay ordered even when a later result revises an earlier tool.
        let mut values = values
            .rev()
            .filter(|value| since.is_none_or(|since| value.item.at >= since))
            .peekable();
        let mut page = Self::empty_page(self.parser.session.clone(), self.cursor);
        let mut bytes = 0;
        while page.items.len() < limit {
            let Some(first) = values.next() else {
                break;
            };
            let offset = first.offset;
            let mut record = vec![first];
            while let Some(value) = values.next_if(|value| value.offset == offset) {
                record.push(value);
            }
            let weight = record
                .iter()
                .map(|value| value.encoded_bound)
                .sum::<usize>();
            if bytes + weight > SNAPSHOT_BYTES {
                if page.items.is_empty() {
                    page.items.push(record_notice(offset, first.item.at));
                    page.before = (offset > 0).then_some(offset);
                }
                break;
            }
            bytes += weight;
            page.before = (offset > 0).then_some(offset);
            page.items.extend(
                record
                    .into_iter()
                    .map(|value| with_output_epoch(value.item.clone(), self.cursor.epoch)),
            );
        }
        page.items.reverse();
        page
    }

    pub fn refresh(&mut self) -> Result<Vec<TimelineOp>, WsError> {
        let metadata = std::fs::metadata(&self.path).map_err(failed)?;
        if self.was_rewritten(&metadata)? {
            return self.rebuild();
        }
        if metadata.len() == self.observed_length
            && metadata.modified().ok() == self.modified
            && self.stream.scan_offset() == metadata.len()
        {
            return Ok(Vec::new());
        }
        let previous_session = self.parser.session.clone();
        let records = self.read_pending_records(metadata.len())?;
        let mut operations = self.publish_records(records);
        self.observed_length = metadata.len();
        self.modified = metadata.modified().ok();
        self.update_anchors()?;
        if self.parser.session != previous_session {
            self.cursor.sequence = self.cursor.sequence.wrapping_add(1);
            operations.push(TimelineOp::Session {
                cursor: self.cursor,
                session: self.parser.session.clone(),
            });
        }
        Ok(operations)
    }

    fn was_rewritten(&mut self, metadata: &std::fs::Metadata) -> Result<bool, WsError> {
        if (metadata.dev(), metadata.ino()) != self.identity
            || metadata.len() < self.stream.scan_offset()
        {
            return Ok(true);
        }
        if read_anchor(&mut self.file, self.stream.complete_end())? != self.anchor {
            return Ok(true);
        }
        Ok(self.stream.scan_offset() != self.stream.complete_end()
            && read_anchor(&mut self.file, self.stream.scan_offset())? != self.scan_anchor)
    }

    fn update_anchors(&mut self) -> Result<(), WsError> {
        self.anchor = read_anchor(&mut self.file, self.stream.complete_end())?;
        self.scan_anchor = if self.stream.scan_offset() != self.stream.complete_end() {
            read_anchor(&mut self.file, self.stream.scan_offset())?
        } else {
            Vec::new()
        };
        Ok(())
    }

    fn read_pending_records(&mut self, length: u64) -> Result<Vec<(u64, Vec<u8>)>, WsError> {
        let offset = self.stream.scan_offset();
        let length = length.saturating_sub(offset).min(READ_LIMIT as u64);
        self.file.seek(SeekFrom::Start(offset)).map_err(failed)?;
        let mut bytes = Vec::with_capacity(length as usize);
        (&mut self.file)
            .take(length)
            .read_to_end(&mut bytes)
            .map_err(failed)?;
        Ok(self.stream.push(&bytes))
    }

    fn publish_records(&mut self, records: Vec<(u64, Vec<u8>)>) -> Vec<TimelineOp> {
        let mut operations = Vec::new();
        for (offset, bytes) in records {
            let items = self.parser.parse_line(&bytes, offset).unwrap_or_default();
            for item in bounded_record(items, offset) {
                if let Some(item) = self.store(item, offset) {
                    self.cursor.sequence = self.cursor.sequence.wrapping_add(1);
                    operations.push(TimelineOp::Upsert {
                        cursor: self.cursor,
                        item: Box::new(with_output_epoch(item, self.cursor.epoch)),
                    });
                }
            }
        }
        operations
    }

    fn rebuild(&mut self) -> Result<Vec<TimelineOp>, WsError> {
        let epoch = self.cursor.epoch.wrapping_add(1);
        let session = self.parser.session.clone();
        let mut rebuilt = Self::open(self.path.clone(), self.native_session.clone(), epoch)?;
        rebuilt.parser.session.commands = session.commands;
        rebuilt.parser.session.title = rebuilt.parser.session.title.or(session.title);
        rebuilt.parser.session.model = rebuilt.parser.session.model.or(session.model);
        rebuilt.parser.session.permission_mode = rebuilt
            .parser
            .session
            .permission_mode
            .or(session.permission_mode);
        *self = rebuilt;
        Ok(vec![TimelineOp::Snapshot(self.snapshot(60, None))])
    }

    pub fn page(
        &mut self,
        before: u64,
        limit: usize,
        since: Option<UnixMillis>,
    ) -> Result<TimelineSnapshot, WsError> {
        let length = self.file.metadata().map_err(failed)?.len();
        if before == 0 || before > length || !record_boundary(&mut self.file, before)? {
            return Err(WsError::Invalid(
                "the history cursor is no longer valid".into(),
            ));
        }
        let window = read_window(&mut self.file, before, limit.clamp(1, 100))?;
        let mut order = Vec::new();
        let mut items: HashMap<String, StoredItem> = HashMap::new();
        let mut parser = ClaudeTimeline::new(self.native_session.clone());
        for (offset, record) in window.records {
            let parsed = parser.parse_record(&record, offset);
            for item in bounded_record(parsed, offset) {
                if since.is_some_and(|since| item.at < since) {
                    continue;
                }
                if let Some(stored) = items.get_mut(&item.id) {
                    // Results revise the original tool's record; moving its cursor skips siblings.
                    stored.replace(item);
                } else {
                    order.push(item.id.clone());
                    items.insert(item.id.clone(), StoredItem::new(item, offset));
                }
            }
        }
        Ok(self.select_records(
            order.iter().filter_map(|id| items.get(id)),
            limit.clamp(1, 100),
            since,
        ))
    }

    pub fn output(
        &mut self,
        handle: &str,
        offset: u64,
        length: u32,
        since: Option<UnixMillis>,
    ) -> Result<TimelineToolOutput, WsError> {
        if length < 4 {
            return Err(WsError::Invalid(
                "output pages must hold at least four bytes".into(),
            ));
        }
        let handle = handle
            .parse::<proto::OutputHandle>()
            .map_err(|error| WsError::Invalid(error.to_string()))?;
        let record = self.output_record(&handle)?;
        self.validate_output_scope(&record, since)?;
        let block = record
            .message
            .content
            .blocks()
            .iter()
            .find(|block| {
                block.kind == BlockKind::ToolResult
                    && block.tool_use_id.as_deref() == Some(handle.id())
            })
            .ok_or_else(|| WsError::NotFound("tool output".into()))?;
        output_page(&result_text(&record, block), offset, length)
    }

    pub fn tool_diff(
        &mut self,
        handle: &str,
        since: Option<UnixMillis>,
    ) -> Result<Vec<proto::FileDiff>, WsError> {
        let handle = handle
            .parse::<proto::OutputHandle>()
            .map_err(|error| WsError::Invalid(error.to_string()))?;
        let record = self.output_record(&handle)?;
        self.validate_output_scope(&record, since)?;
        let mut results = record
            .message
            .content
            .blocks()
            .iter()
            .filter(|block| block.kind == BlockKind::ToolResult);
        let matches = results
            .next()
            .is_some_and(|block| block.tool_use_id.as_deref() == Some(handle.id()));
        if !matches || results.next().is_some() {
            return Err(WsError::Unavailable(
                "The recorded change is not correlated with this tool. Open Terminal.".into(),
            ));
        }
        let result = record
            .tool_use_result
            .rich()
            .ok_or_else(|| WsError::NotFound("recorded changes".into()))?;
        super::complete_diff::recorded_diff(result)
    }

    fn output_record(&mut self, handle: &proto::OutputHandle) -> Result<Record, WsError> {
        let metadata = std::fs::metadata(&self.path).map_err(failed)?;
        if self.was_rewritten(&metadata)? || handle.epoch() != self.cursor.epoch {
            return Err(WsError::Conflict(
                "the transcript changed; reopen the tool".into(),
            ));
        }
        if !record_boundary(&mut self.file, handle.offset())? {
            return Err(WsError::Invalid("the output handle is invalid".into()));
        }
        self.file
            .seek(SeekFrom::Start(handle.offset()))
            .map_err(failed)?;
        let mut bytes = Vec::new();
        let mut reader = std::io::BufReader::new((&mut self.file).take(READ_LIMIT as u64));
        std::io::BufRead::read_until(&mut reader, b'\n', &mut bytes).map_err(failed)?;
        if bytes.last() != Some(&b'\n') {
            return Err(WsError::Unavailable(
                "the tool output is too large; open Terminal".into(),
            ));
        }
        serde_json::from_slice(&bytes).map_err(failed)
    }

    fn validate_output_scope(
        &self,
        record: &Record,
        since: Option<UnixMillis>,
    ) -> Result<(), WsError> {
        if record.kind != RecordKind::User || record.is_sidechain {
            return Err(WsError::Denied(
                "this output is not part of the main conversation".into(),
            ));
        }
        let at = UnixMillis(
            record
                .timestamp
                .as_deref()
                .and_then(crate::usage::rfc3339_millis)
                .unwrap_or(0),
        );
        if since.is_some_and(|since| at < since) {
            return Err(WsError::Denied(
                "this output predates joining the session".into(),
            ));
        }
        if record
            .session_id
            .as_deref()
            .is_some_and(|session| session != self.native_session)
        {
            return Err(WsError::Denied(
                "this output belongs to another session".into(),
            ));
        }
        Ok(())
    }

    fn store(&mut self, mut item: TimelineItem, offset: u64) -> Option<TimelineItem> {
        let original_offset = self
            .items
            .get(&item.id)
            .map_or(offset, |stored| stored.offset);
        if let Some(stored) = self.items.get_mut(&item.id) {
            if item.body == stored.item.body
                && item.turn == stored.item.turn
                && item.parent == stored.item.parent
            {
                return None;
            }
            self.retained_bytes -= stored.retained_weight();
            item.revision = stored.item.revision.saturating_add(1);
            stored.replace(item.clone());
            self.retained_bytes += stored.retained_weight();
        } else {
            let stored = StoredItem::new(item.clone(), offset);
            self.retained_bytes += stored.retained_weight();
            self.order.push_back(item.id.clone());
            self.items.insert(item.id.clone(), stored);
        }
        Some(self.enforce_cache_limit(item, original_offset))
    }

    fn enforce_cache_limit(&mut self, mut item: TimelineItem, offset: u64) -> TimelineItem {
        let mut replaced = false;
        while self.order.len() > CACHE_ITEMS || self.retained_bytes > CACHE_VALUE_BYTES {
            if self.evict_oldest_record() == Some(offset) && !replaced {
                // Revisions can grow one old record beyond the entire allowance. Do not
                // silently empty the timeline or emit a value we immediately discarded.
                item = record_notice(offset, item.at);
                let stored = StoredItem::new(item.clone(), offset);
                self.retained_bytes += stored.retained_weight();
                self.order.push_front(item.id.clone());
                self.items.insert(item.id.clone(), stored);
                replaced = true;
            }
        }
        item
    }

    fn evict_oldest_record(&mut self) -> Option<u64> {
        // Partial retention would make the next snapshot's record cursor silently lossy.
        let offset = self
            .order
            .front()
            .and_then(|id| self.items.get(id))
            .map(|value| value.offset);
        while let Some(id) = self.order.front() {
            if self
                .items
                .get(id)
                .is_some_and(|value| Some(value.offset) != offset)
            {
                break;
            }
            if let Some(id) = self.order.pop_front()
                && let Some(stored) = self.items.remove(&id)
            {
                self.retained_bytes -= stored.retained_weight();
            }
        }
        offset
    }

    fn empty_page(session: TimelineSession, cursor: TimelineCursor) -> TimelineSnapshot {
        TimelineSnapshot {
            cursor,
            session,
            items: Vec::new(),
            before: None,
        }
    }
}

fn bounded_record(items: Vec<TimelineItem>, offset: u64) -> Vec<TimelineItem> {
    if items.len() <= CACHE_ITEMS
        && items.iter().map(super::value_weight::item).sum::<usize>() <= SNAPSHOT_BYTES
    {
        return items;
    }
    vec![record_notice(
        offset,
        items.first().map_or(UnixMillis(0), |item| item.at),
    )]
}

fn record_notice(offset: u64, at: UnixMillis) -> TimelineItem {
    TimelineItem {
        id: format!("record:{offset}:unavailable"),
        revision: 1,
        turn: None,
        parent: None,
        at,
        origin: TimelineOrigin::Agent,
        body: TimelineBody::Notice {
            kind: TimelineNoticeKind::Error,
            text: "This record is too large for Chat. Open Terminal to read it.".into(),
        },
    }
}

fn output_page(text: &str, offset: u64, length: u32) -> Result<TimelineToolOutput, WsError> {
    let start = usize::try_from(offset)
        .ok()
        .filter(|offset| *offset <= text.len() && text.is_char_boundary(*offset))
        .ok_or_else(|| WsError::Invalid("the output offset is invalid".into()))?;
    let mut end = start
        .saturating_add((length as usize).clamp(1, OUTPUT_PAGE_BYTES))
        .min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    Ok(TimelineToolOutput {
        text: text[start..end].to_owned(),
        next_offset: (end < text.len()).then_some(end as u64),
        total_bytes: text.len() as u64,
    })
}

fn with_output_epoch(mut item: TimelineItem, epoch: u64) -> TimelineItem {
    if let proto::TimelineBody::Tool(tool) = &mut item.body
        && let Some(output) = &mut tool.output
    {
        output.handle.set_epoch(epoch);
    }
    item
}

fn read_window(file: &mut File, end: u64, limit: usize) -> Result<Window, WsError> {
    let start = end.saturating_sub(READ_LIMIT as u64);
    let mut stream = if record_boundary(file, start)? {
        RecordStream::at_boundary(start)
    } else {
        RecordStream::inside_fragment(start)
    };
    file.seek(SeekFrom::Start(start)).map_err(failed)?;
    let mut bytes = Vec::with_capacity((end - start) as usize);
    (&mut *file)
        .take(end - start)
        .read_to_end(&mut bytes)
        .map_err(failed)?;
    let mut records = Vec::new();
    let mut candidates = 0;
    for (offset, bytes) in stream.push(&bytes).into_iter().rev() {
        let Ok(record) = serde_json::from_slice::<Record>(&bytes) else {
            continue;
        };
        if record.kind != RecordKind::Other {
            if matches!(record.kind, RecordKind::User | RecordKind::Assistant) {
                candidates += 1;
            }
            records.push((offset, record));
        }
        if candidates >= limit.saturating_mul(2) {
            break;
        }
    }
    records.reverse();
    Ok(Window { records, stream })
}

fn read_anchor(file: &mut File, end: u64) -> Result<Vec<u8>, WsError> {
    let start = end.saturating_sub(128);
    file.seek(SeekFrom::Start(start)).map_err(failed)?;
    let mut anchor = Vec::with_capacity((end - start) as usize);
    (&mut *file)
        .take(end - start)
        .read_to_end(&mut anchor)
        .map_err(failed)?;
    Ok(anchor)
}

fn record_boundary(file: &mut File, position: u64) -> Result<bool, WsError> {
    if position == 0 {
        return Ok(true);
    }
    file.seek(SeekFrom::Start(position - 1)).map_err(failed)?;
    let mut byte = [0];
    Ok(file.read(&mut byte).map_err(failed)? == 1 && byte[0] == b'\n')
}

pub(super) fn validate_path(root: &Path, path: &Path, session: &str) -> Result<PathBuf, WsError> {
    let root = root.canonicalize().map_err(failed)?;
    let path = path.canonicalize().map_err(failed)?;
    if !path.starts_with(&root)
        || path.extension().and_then(|extension| extension.to_str()) != Some("jsonl")
        || path.file_stem().and_then(|stem| stem.to_str()) != Some(session)
    {
        return Err(WsError::Denied(
            "the transcript is outside the agent's session directory".into(),
        ));
    }
    Ok(path)
}

fn failed(error: impl std::fmt::Display) -> WsError {
    WsError::Failed(error.to_string())
}

#[cfg(test)]
#[path = "transcript_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "complete_diff_read_tests.rs"]
mod complete_diff_read_tests;
