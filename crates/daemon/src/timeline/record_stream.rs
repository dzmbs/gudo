pub(super) const RECORD_BYTES_LIMIT: usize = 8 * 1024 * 1024;
// Reserve the terminating newline inside the same bounded read used by output/history.
const BODY_BYTES_LIMIT: usize = RECORD_BYTES_LIMIT - 1;

#[derive(Debug)]
enum PendingRecord {
    Collecting(Vec<u8>),
    Skipping,
}

/// Scanning may advance through an oversized line; a published offset never does.
#[derive(Debug)]
pub(super) struct RecordStream {
    scan_offset: u64,
    complete_end: u64,
    pending: PendingRecord,
}

impl RecordStream {
    pub fn at_boundary(offset: u64) -> Self {
        Self {
            scan_offset: offset,
            complete_end: offset,
            pending: PendingRecord::Collecting(Vec::new()),
        }
    }

    pub fn inside_fragment(offset: u64) -> Self {
        // The previous boundary is unknown in a bounded tail read; zero is conservative.
        Self {
            scan_offset: offset,
            complete_end: 0,
            pending: PendingRecord::Skipping,
        }
    }

    pub fn scan_offset(&self) -> u64 {
        self.scan_offset
    }
    pub fn complete_end(&self) -> u64 {
        self.complete_end
    }

    pub fn push(&mut self, bytes: &[u8]) -> Vec<(u64, Vec<u8>)> {
        let mut records = Vec::new();
        for part in bytes.split_inclusive(|byte| *byte == b'\n') {
            let complete = part.last() == Some(&b'\n');
            let body = if complete {
                &part[..part.len() - 1]
            } else {
                part
            };
            if let PendingRecord::Collecting(pending) = &mut self.pending {
                if body.len() <= BODY_BYTES_LIMIT.saturating_sub(pending.len()) {
                    pending.extend_from_slice(body);
                } else {
                    self.pending = PendingRecord::Skipping;
                }
            }
            self.scan_offset += part.len() as u64;
            if !complete {
                continue;
            }
            let start = self.complete_end;
            self.complete_end = self.scan_offset;
            let pending =
                std::mem::replace(&mut self.pending, PendingRecord::Collecting(Vec::new()));
            if let PendingRecord::Collecting(record) = pending
                && !record.is_empty()
            {
                records.push((start, record));
            }
        }
        records
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fragments_and_utf8_are_joined_only_at_real_boundaries() {
        let mut stream = RecordStream::at_boundary(10);
        assert!(stream.push(&[0xf0, 0x9f]).is_empty());
        assert_eq!(stream.complete_end(), 10);
        assert_eq!(
            stream.push(&[0xa6, 0x80, b'\n']),
            [(10, "🦀".as_bytes().to_vec())]
        );
        assert_eq!(stream.complete_end(), 15);
        assert_eq!(stream.scan_offset(), 15);
    }

    #[test]
    fn oversized_records_are_skipped_until_newline_without_publishing_partial_offsets() {
        let mut stream = RecordStream::at_boundary(5);
        assert!(stream.push(&vec![b'x'; RECORD_BYTES_LIMIT]).is_empty());
        assert!(stream.push(b"overflow").is_empty());
        assert_eq!(stream.complete_end(), 5);
        assert!(matches!(stream.pending, PendingRecord::Skipping));
        let records = stream.push(b"\nnext\n");
        assert_eq!(
            records,
            [(5 + RECORD_BYTES_LIMIT as u64 + 9, b"next".to_vec())]
        );
        assert_eq!(stream.complete_end(), stream.scan_offset());
    }

    #[test]
    fn the_record_byte_limit_includes_its_terminating_newline() {
        let mut stream = RecordStream::at_boundary(0);
        assert!(stream.push(&vec![b'x'; BODY_BYTES_LIMIT]).is_empty());
        let records = stream.push(b"\n");
        assert_eq!(records.len(), 1);
        assert_eq!(stream.complete_end(), RECORD_BYTES_LIMIT as u64);
        assert_eq!(records[0].1.len(), BODY_BYTES_LIMIT);
        assert!(stream.push(&vec![b'x'; RECORD_BYTES_LIMIT]).is_empty());
        assert!(stream.push(b"\n").is_empty());
    }

    #[test]
    fn an_unknown_leading_fragment_is_not_a_record() {
        let mut stream = RecordStream::inside_fragment(100);
        assert!(stream.push(b"partial").is_empty());
        assert_eq!(stream.complete_end(), 0);
        assert_eq!(stream.push(b"\nnext\n"), [(108, b"next".to_vec())]);
        assert_eq!(stream.complete_end(), 113);
    }
}
