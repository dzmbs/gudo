//! An agent's append-only JSONL session file, opened once inside its agent's folder and read in
//! bounded windows of complete records.

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use proto::WsError;

use super::record_stream::{RECORD_BYTES_LIMIT, RecordStream};

pub(crate) struct JsonlFile {
    path: PathBuf,
    file: File,
    identity: (u64, u64),
}

/// The complete records of one bounded read, and the record boundary before them.
pub(crate) struct Window {
    pub records: Vec<(u64, Vec<u8>)>,
    pub start: u64,
}

impl JsonlFile {
    /// Opens `path` only as a regular file inside `root`, without following a final symbolic
    /// link.
    pub fn open(root: &Path, path: &Path) -> Result<Self, WsError> {
        let root = root.canonicalize().map_err(failed)?;
        let canonical = path.canonicalize().map_err(failed)?;
        if !canonical.starts_with(&root) {
            return Err(WsError::Denied(
                "the session file is outside the agent's sessions folder".into(),
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
            return Err(WsError::Denied(
                "the session file is not a regular file".into(),
            ));
        }
        Ok(Self {
            path: path.to_owned(),
            file,
            identity: (metadata.dev(), metadata.ino()),
        })
    }

    /// The record that starts at `offset`, if a whole one does.
    pub fn record_at(&self, offset: u64) -> Result<Option<Vec<u8>>, WsError> {
        if offset >= self.length()? || !self.is_boundary(offset)? {
            return Ok(None);
        }
        let mut record = Vec::new();
        BufReader::new(self.reader(offset)?.take(RECORD_BYTES_LIMIT as u64))
            .read_until(b'\n', &mut record)
            .map_err(failed)?;
        if record.pop() != Some(b'\n') {
            return Ok(None);
        }
        Ok(Some(record))
    }

    /// The end of the last complete record.
    pub fn end(&self) -> Result<u64, WsError> {
        let length = self.length()?;
        let start = length.saturating_sub(RECORD_BYTES_LIMIT as u64);
        let mut stream = self.stream_at(start)?;
        stream.push(&self.read(start, length)?);
        Ok(stream.complete_end())
    }

    /// The complete records after where `stream` stopped, at most one bounded read of them, and
    /// whether more is written.
    pub fn appended(&self, stream: &mut RecordStream) -> Result<(Vec<(u64, Vec<u8>)>, bool), WsError> {
        let length = self.length()?;
        let start = stream.scan_offset();
        if start > length {
            return Err(WsError::Conflict(
                "the session file changed; reopen Chat".into(),
            ));
        }
        let end = length.min(start.saturating_add(RECORD_BYTES_LIMIT as u64));
        Ok((stream.push(&self.read(start, end)?), end < length))
    }

    /// The complete records in the bounded read that ends at the record boundary `end`. A
    /// record too large to read is passed over.
    pub fn window(&self, end: u64) -> Result<Window, WsError> {
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

    /// The complete records from the boundary `start` up to `limit` bytes past it.
    pub fn forward(&self, start: u64, limit: u64) -> Result<Vec<(u64, Vec<u8>)>, WsError> {
        let end = self.length()?.min(start.saturating_add(limit));
        Ok(RecordStream::at_boundary(start).push(&self.read(start, end)?))
    }

    pub fn length(&self) -> Result<u64, WsError> {
        let current = std::fs::symlink_metadata(&self.path).map_err(failed)?;
        let length = self.file.metadata().map_err(failed)?.len();
        if (current.dev(), current.ino()) != self.identity {
            return Err(WsError::Conflict(
                "the session file was replaced; reopen Chat".into(),
            ));
        }
        Ok(length)
    }

    pub fn is_boundary(&self, position: u64) -> Result<bool, WsError> {
        if position == 0 {
            return Ok(true);
        }
        Ok(self.read(position - 1, position)? == b"\n")
    }

    fn stream_at(&self, start: u64) -> Result<RecordStream, WsError> {
        Ok(if self.is_boundary(start)? {
            RecordStream::at_boundary(start)
        } else {
            RecordStream::inside_fragment(start)
        })
    }

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

fn failed(error: impl std::fmt::Display) -> WsError {
    WsError::Failed(error.to_string())
}
