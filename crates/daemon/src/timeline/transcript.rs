use std::collections::{HashMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use super::claude::{ClaudeTimeline, result_text};
use super::claude_record::{BlockKind, Record, RecordKind};
use proto::{
    TimelineCursor, TimelineItem, TimelineOp, TimelineSession, TimelineSnapshot,
    TimelineToolOutput, UnixMillis, WsError,
};

use super::record_stream::{RECORD_BYTES_LIMIT as READ_LIMIT, RecordStream};
const SNAPSHOT_BYTES: usize = 1024 * 1024;
const CACHE_ITEMS: usize = 512;
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
}

struct StoredItem {
    item: TimelineItem,
    offset: u64,
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
        };
        let window = read_window(&mut transcript.file, metadata.len(), 60)?;
        transcript.stream = window.stream;
        for (offset, record) in window.records {
            let items = transcript.parser.parse_record(&record, offset);
            for item in items {
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

    pub fn snapshot(&self, limit: usize, since: Option<UnixMillis>) -> TimelineSnapshot {
        let mut items = Vec::new();
        let mut encoded_bytes = 0;
        let mut before = None;
        for id in self.order.iter().rev() {
            let Some(stored) = self.items.get(id) else {
                continue;
            };
            if since.is_some_and(|since| stored.item.at < since) {
                continue;
            }
            let item_bytes =
                postcard::to_allocvec(&stored.item).map_or(SNAPSHOT_BYTES, |bytes| bytes.len());
            if items.len() >= limit || encoded_bytes + item_bytes > SNAPSHOT_BYTES {
                break;
            }
            encoded_bytes += item_bytes;
            before = (stored.offset > 0).then_some(stored.offset);
            items.push(with_output_epoch(stored.item.clone(), self.cursor.epoch));
        }
        items.reverse();
        TimelineSnapshot {
            cursor: self.cursor,
            session: self.parser.session.clone(),
            items,
            before,
        }
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
            for item in self.parser.parse_line(&bytes, offset).unwrap_or_default() {
                if let Some(item) = self.store(item, offset) {
                    self.cursor.sequence = self.cursor.sequence.wrapping_add(1);
                    operations.push(TimelineOp::Upsert {
                        cursor: self.cursor,
                        item: with_output_epoch(item, self.cursor.epoch),
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
        let mut page = Self::empty_page(self.parser.session.clone(), self.cursor);
        let mut order = Vec::new();
        let mut items = HashMap::new();
        let mut parser = ClaudeTimeline::new(self.native_session.clone());
        for (offset, record) in window.records {
            for item in parser.parse_record(&record, offset) {
                if since.is_some_and(|since| item.at < since) {
                    continue;
                }
                if !items.contains_key(&item.id) {
                    order.push(item.id.clone());
                }
                items.insert(item.id.clone(), StoredItem { item, offset });
            }
        }
        let mut retained = Vec::new();
        let mut encoded_bytes = 0;
        for id in order.into_iter().rev() {
            let Some(stored) = items.remove(&id) else {
                continue;
            };
            let item_bytes = postcard::to_allocvec(&stored.item).map_err(failed)?.len();
            if retained.len() >= limit.clamp(1, 100) || encoded_bytes + item_bytes > SNAPSHOT_BYTES
            {
                break;
            }
            encoded_bytes += item_bytes;
            page.before = (stored.offset > 0).then_some(stored.offset);
            retained.push(with_output_epoch(stored.item, self.cursor.epoch));
        }
        retained.reverse();
        page.items = retained;
        Ok(page)
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
        if let Some(stored) = self.items.get_mut(&item.id) {
            if item.body == stored.item.body
                && item.turn == stored.item.turn
                && item.parent == stored.item.parent
            {
                return None;
            }
            item.revision = stored.item.revision.saturating_add(1);
            stored.item = item.clone();
        } else {
            self.order.push_back(item.id.clone());
            self.items.insert(
                item.id.clone(),
                StoredItem {
                    item: item.clone(),
                    offset,
                },
            );
        }
        while self.order.len() > CACHE_ITEMS {
            if let Some(id) = self.order.pop_front() {
                self.items.remove(&id);
            }
        }
        Some(item)
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
