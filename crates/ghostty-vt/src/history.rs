//! Restoring a snapshot whose history arrives later, in pieces, over the network.

use std::ffi::c_void;
use std::ptr::{self, NonNull};

use ghostty_vt_sys as ffi;

use crate::terminal::CONTINUATION_MAX_BYTES;
use crate::{Error, HistoryPage, Screen, Terminal};

const RECORD_HEADER_LEN: usize = 10;
const TAG_PAGE: u16 = 3;
const TAG_FINISH: u16 = 6;

/// Bytes handed to the decoder's reader, with a read cursor.
#[derive(Default)]
struct Source {
    data: Vec<u8>,
    pos: usize,
}

/// A terminal restored from a snapshot's READY section whose scrollback is fetched later,
/// newest page first.
///
/// Unlike [`Restore`](crate::Restore), which borrows a complete snapshot, this owns its input:
/// history records are [`push`](Self::push)ed as they arrive (for example from the daemon's
/// `bulk` stream), and every complete page in them is prepended at once. The terminal can be
/// rendered, written to and resized in between.
///
/// Pushed bytes must be whole records that end after a page record or at FINISH (the daemon
/// cuts pages that way); a partial record is kept until the rest arrives.
///
/// # Examples
///
/// ```
/// # fn main() -> Result<(), ghostty_vt::Error> {
/// use ghostty_vt::{StreamingRestore, Terminal, TextRegion, history_chunks, ready_len};
///
/// let mut daemon = Terminal::new(10, 2)?;
/// for i in 0..50 {
///     daemon.write(format!("line {i}\r\n").as_bytes());
/// }
/// let snapshot = daemon.encode_snapshot()?;
/// let ready = ready_len(&snapshot).unwrap();
///
/// let mut client = StreamingRestore::new(&snapshot[..ready])?;
/// // READY carries the rows sharing a page with the active area; older pages come later.
/// for (start, end) in history_chunks(&snapshot, ready, 1) {
///     client.push(&snapshot[start..end])?;
/// }
/// assert!(client.is_finished());
/// assert_eq!(client.terminal().text(TextRegion::All)?, daemon.text(TextRegion::All)?);
/// # Ok(())
/// # }
/// ```
pub struct StreamingRestore {
    // Freed in `Drop`, before the terminal and the source it refers to.
    decoder: NonNull<ffi::GhosttySnapshotDecoderImpl>,
    terminal: Terminal,
    source: Box<Source>,
    /// Offset in `source.data` of the first record not yet scanned for pages.
    scanned: usize,
    pending_pages: u32,
    finish_seen: bool,
    finished: bool,
}

impl std::fmt::Debug for StreamingRestore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StreamingRestore")
            .field("terminal", &self.terminal)
            .field("buffered", &(self.source.data.len() - self.source.pos))
            .field("finished", &self.finished)
            .finish()
    }
}

// SAFETY: the decoder, terminal and source are owned heap state with no thread affinity, and
// the decoder only refers to the terminal and source owned alongside it. Not `Sync`, so access
// stays serialized.
unsafe impl Send for StreamingRestore {}

impl StreamingRestore {
    /// Decodes a snapshot's READY prefix (see [`ready_len`](crate::ready_len)).
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] if the bytes are not a complete READY section of this
    /// snapshot format, and [`Error::OutOfMemory`] if allocation fails.
    pub fn new(ready: &[u8]) -> Result<Self, Error> {
        let mut source = Box::new(Source {
            data: ready.to_vec(),
            pos: 0,
        });
        let reader = ffi::GhosttyReader {
            read: Some(read_source),
            userdata: ptr::from_mut(&mut *source).cast::<c_void>(),
        };
        let mut raw = ptr::null_mut();
        // SAFETY: `raw` is a valid out pointer; the reader's userdata is the boxed source,
        // which keeps its address and outlives the decoder (see field order and `Drop`).
        Error::check(unsafe { ffi::ghostty_snapshot_decoder_new(ptr::null(), &mut raw, reader) })?;
        let decoder = NonNull::new(raw).ok_or(Error::InvalidValue)?;
        let free = |e| {
            // SAFETY: created above, not shared, freed once on this error path.
            unsafe { ffi::ghostty_snapshot_decoder_free(decoder.as_ptr()) };
            e
        };
        // SAFETY: the decoder is live; each option reads the documented type before returning.
        unsafe {
            let set = |option, value: *const c_void| {
                Error::check(ffi::ghostty_snapshot_decoder_set(
                    decoder.as_ptr(),
                    option,
                    value,
                ))
            };
            set(
                ffi::GhosttySnapshotDecoderOption_GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,
                ptr::from_ref(&CONTINUATION_MAX_BYTES).cast(),
            )
            .map_err(free)?;
            let yes = true;
            for option in [
                ffi::GhosttySnapshotDecoderOption_GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION,
                ffi::GhosttySnapshotDecoderOption_GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY,
            ] {
                set(option, (&raw const yes).cast()).map_err(free)?;
            }
        }
        let mut terminal = ptr::null_mut();
        // SAFETY: the decoder is live and `terminal` a valid out pointer.
        Error::check(unsafe {
            ffi::ghostty_snapshot_decoder_ready(decoder.as_ptr(), &mut terminal)
        })
        .map_err(free)?;
        let terminal = NonNull::new(terminal)
            .ok_or(Error::InvalidValue)
            .map_err(free)?;
        let scanned = source.pos;
        Ok(Self {
            decoder,
            // SAFETY: on success the caller owns the returned live terminal; the decoder keeps
            // referring to it, which `Self` allows only through the methods below.
            terminal: unsafe { Terminal::from_raw(terminal) },
            source,
            scanned,
            pending_pages: 0,
            finish_seen: false,
            finished: false,
        })
    }

    /// The restored terminal.
    pub fn terminal(&self) -> &Terminal {
        &self.terminal
    }

    /// Feeds live PTY bytes; see [`Terminal::write`].
    pub fn write(&mut self, bytes: &[u8]) {
        self.terminal.write(bytes);
    }

    /// Resizes the terminal; see [`Terminal::resize`]. History pages that no longer fit are
    /// skipped (their [`HistoryPage::rows`] is 0).
    ///
    /// # Errors
    ///
    /// As for [`Terminal::resize`].
    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), Error> {
        self.terminal.resize(cols, rows)
    }

    /// Caps the terminal's scrollback; see [`Terminal::set_scrollback_max_bytes`]. A restored
    /// terminal starts with libghostty-vt's small default, so raise it before pushing more
    /// history than that, or older pages are dropped as they arrive.
    ///
    /// # Errors
    ///
    /// As for [`Terminal::set_scrollback_max_bytes`].
    pub fn set_scrollback_max_bytes(&mut self, limit: Option<usize>) -> Result<(), Error> {
        self.terminal.set_scrollback_max_bytes(limit)
    }

    /// Total scrollback rows the snapshot declares for `screen`.
    pub fn history_rows(&self, screen: Screen) -> Option<u64> {
        let data = match screen {
            Screen::Primary => {
                ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY
            }
            Screen::Alternate => {
                ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_ALTERNATE
            }
        };
        let mut out = 0u64;
        // SAFETY: both HISTORY_ROWS fields write a `uint64_t`.
        let result = unsafe {
            ffi::ghostty_snapshot_decoder_get(self.decoder.as_ptr(), data, (&raw mut out).cast())
        };
        (result == ffi::GhosttyResult_GHOSTTY_SUCCESS).then_some(out)
    }

    /// Whether the snapshot's FINISH record has been decoded: all history is restored.
    pub fn is_finished(&self) -> bool {
        self.finished
    }

    /// Adds history records and prepends every page they complete, newest first.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] if the records are corrupt or out of order. The
    /// terminal stays usable with the history restored so far, but no more can be added.
    pub fn push(&mut self, records: &[u8]) -> Result<Vec<HistoryPage>, Error> {
        if self.finished {
            return Ok(Vec::new());
        }
        // Drop what the decoder has consumed, so the buffer only holds pending records.
        let consumed = self.source.pos;
        self.source.data.drain(..consumed);
        self.source.pos = 0;
        self.scanned -= consumed;
        self.source.data.extend_from_slice(records);

        while let Some(header) = self
            .source
            .data
            .get(self.scanned..self.scanned + RECORD_HEADER_LEN)
        {
            let tag = u16::from_le_bytes([header[0], header[1]]);
            let len = u32::from_le_bytes([header[2], header[3], header[4], header[5]]) as usize;
            let end = self.scanned + RECORD_HEADER_LEN + len;
            if end > self.source.data.len() {
                break;
            }
            self.scanned = end;
            match tag {
                TAG_PAGE => self.pending_pages += 1,
                TAG_FINISH => self.finish_seen = true,
                _ => {}
            }
        }

        let mut pages = Vec::new();
        while self.pending_pages > 0 {
            self.pending_pages -= 1;
            match self.next()? {
                Some(page) => pages.push(page),
                None => return Err(Error::InvalidValue),
            }
        }
        if self.finish_seen {
            if self.next()?.is_some() {
                return Err(Error::InvalidValue);
            }
            self.finished = true;
        }
        Ok(pages)
    }

    fn next(&mut self) -> Result<Option<HistoryPage>, Error> {
        let decoder = self.decoder.as_ptr();
        // SAFETY: the decoder is live; the terminal and source it refers to live in `self`.
        match unsafe { ffi::ghostty_snapshot_decoder_next(decoder) } {
            ffi::GhosttyResult_GHOSTTY_NO_VALUE => Ok(None),
            code => {
                Error::check(code)?;
                let get = |data, out: *mut c_void| {
                    // SAFETY: each PROGRESS field is available after a successful `next` and
                    // `out` points at its documented type.
                    Error::check(unsafe { ffi::ghostty_snapshot_decoder_get(decoder, data, out) })
                };
                let mut screen: ffi::GhosttyTerminalScreen = 0;
                let mut rows = 0usize;
                let mut remaining = 0u32;
                get(
                    ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_SCREEN,
                    (&raw mut screen).cast(),
                )?;
                get(
                    ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS,
                    (&raw mut rows).cast(),
                )?;
                get(
                    ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_REMAINING,
                    (&raw mut remaining).cast(),
                )?;
                Ok(Some(HistoryPage {
                    screen: Screen::from_raw(screen),
                    rows,
                    remaining,
                }))
            }
        }
    }

    /// Stops restoring and returns the terminal with the history restored so far.
    pub fn into_terminal(self) -> Terminal {
        let this = std::mem::ManuallyDrop::new(self);
        // SAFETY: the decoder is live and freed once here; `Drop` does not run for `this`.
        // Afterwards nothing refers to the terminal, which is moved out exactly once, and the
        // source is dropped explicitly.
        unsafe {
            ffi::ghostty_snapshot_decoder_free(this.decoder.as_ptr());
            drop(ptr::read(&this.source));
            ptr::read(&this.terminal)
        }
    }
}

impl Drop for StreamingRestore {
    fn drop(&mut self) {
        // SAFETY: the decoder is owned by `self` and freed once; the terminal and source it
        // refers to are dropped after this, in field order.
        unsafe { ffi::ghostty_snapshot_decoder_free(self.decoder.as_ptr()) }
    }
}

unsafe extern "C" fn read_source(
    userdata: *mut c_void,
    buffer: *mut u8,
    capacity: usize,
    out_read: *mut usize,
) -> bool {
    // SAFETY: userdata is the boxed `Source` owned by the `StreamingRestore` whose decoder
    // calls this, only from inside its `&mut self` methods; `buffer` is valid for `capacity`
    // bytes and `out_read` is non-null.
    unsafe {
        let source = &mut *userdata.cast::<Source>();
        let available = &source.data[source.pos..];
        let n = available.len().min(capacity);
        ptr::copy_nonoverlapping(available.as_ptr(), buffer, n);
        source.pos += n;
        *out_read = n;
    }
    true
}

/// Splits the history after `start` (the READY length or a previous chunk's end) into chunks
/// of whole records of about `max_bytes`, each ending after a page record or at FINISH, as
/// [`StreamingRestore::push`] needs. Returns `(start, end)` byte ranges and stops at FINISH or
/// at the first malformed header.
///
/// # Examples
///
/// ```
/// # fn main() -> Result<(), ghostty_vt::Error> {
/// use ghostty_vt::{Terminal, history_chunks, ready_len};
///
/// let mut terminal = Terminal::new(10, 2)?;
/// terminal.write(b"1\r\n2\r\n3\r\n4");
/// let snapshot = terminal.encode_snapshot()?;
/// let ready = ready_len(&snapshot).unwrap();
/// let chunks = history_chunks(&snapshot, ready, usize::MAX);
/// assert_eq!(chunks, [(ready, snapshot.len())]);
/// # Ok(())
/// # }
/// ```
pub fn history_chunks(snapshot: &[u8], start: usize, max_bytes: usize) -> Vec<(usize, usize)> {
    let mut chunks = Vec::new();
    let mut chunk_start = start;
    let mut pos = start;
    // Where the current chunk may end: after its last page record.
    let mut cut = None;
    while let Some(header) = snapshot.get(pos..pos + RECORD_HEADER_LEN) {
        let tag = u16::from_le_bytes([header[0], header[1]]);
        let len = u32::from_le_bytes([header[2], header[3], header[4], header[5]]) as usize;
        let Some(end) = pos
            .checked_add(RECORD_HEADER_LEN + len)
            .filter(|&e| e <= snapshot.len())
        else {
            break;
        };
        if tag == TAG_FINISH {
            chunks.push((chunk_start, end));
            return chunks;
        }
        if tag == TAG_PAGE {
            if let Some(c) = cut
                && end - chunk_start > max_bytes
            {
                chunks.push((chunk_start, c));
                chunk_start = c;
            }
            cut = Some(end);
        }
        pos = end;
    }
    if let Some(c) = cut.filter(|&c| c > chunk_start) {
        chunks.push((chunk_start, c));
    }
    chunks
}

/// The end of the first chunk [`history_chunks`] would return from `start`, and whether it
/// reaches FINISH. Cheaper when only one page is served at a time.
pub fn history_chunk(snapshot: &[u8], start: usize, max_bytes: usize) -> Option<(usize, bool)> {
    let mut pos = start;
    let mut cut = None;
    while let Some(header) = snapshot.get(pos..pos + RECORD_HEADER_LEN) {
        let tag = u16::from_le_bytes([header[0], header[1]]);
        let len = u32::from_le_bytes([header[2], header[3], header[4], header[5]]) as usize;
        let end = pos
            .checked_add(RECORD_HEADER_LEN + len)
            .filter(|&e| e <= snapshot.len())?;
        match tag {
            TAG_FINISH => return Some((end, true)),
            TAG_PAGE => {
                if cut.is_some() && end - start > max_bytes {
                    return cut.map(|c| (c, false));
                }
                cut = Some(end);
            }
            _ => {}
        }
        pos = end;
    }
    cut.map(|c| (c, false))
}

/// Counts the page records in `records` (whole records only).
pub fn count_pages(records: &[u8]) -> u32 {
    let mut pos = 0;
    let mut pages = 0;
    while let Some(header) = records.get(pos..pos + RECORD_HEADER_LEN) {
        let tag = u16::from_le_bytes([header[0], header[1]]);
        let len = u32::from_le_bytes([header[2], header[3], header[4], header[5]]) as usize;
        pos += RECORD_HEADER_LEN + len;
        if pos > records.len() {
            break;
        }
        pages += u32::from(tag == TAG_PAGE);
    }
    pages
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{TextRegion, ready_len};

    fn busy_terminal(lines: usize) -> Result<Terminal, Error> {
        let mut t = Terminal::new(40, 5)?;
        t.set_scrollback_max_bytes(Some(64 << 20))?;
        for i in 0..lines {
            t.write(format!("\x1b[3{}mline {i} of history\x1b[0m\r\n", i % 8).as_bytes());
        }
        Ok(t)
    }

    #[test]
    fn small_chunks_restore_everything_with_live_output_between() -> Result<(), Error> {
        let mut daemon = busy_terminal(5000)?;
        let snapshot = daemon.encode_snapshot()?;
        let ready = ready_len(&snapshot).unwrap();
        let mut client = StreamingRestore::new(&snapshot[..ready])?;
        let chunks = history_chunks(&snapshot, ready, 4096);
        assert!(chunks.len() > 2, "{} chunks", chunks.len());
        let mut rows = 0;
        for (i, (start, end)) in chunks.iter().copied().enumerate() {
            let pages = client.push(&snapshot[start..end])?;
            assert_eq!(pages.len() as u32, count_pages(&snapshot[start..end]));
            rows += pages.iter().map(|p| p.rows).sum::<usize>();
            if i == 1 {
                // Live output keeps flowing while history is restored.
                daemon.write(b"live output\r\n");
                client.write(b"live output\r\n");
            }
        }
        assert!(client.is_finished());
        assert!(rows > 4000, "{rows}");
        assert_eq!(
            client.terminal().text(TextRegion::All)?,
            daemon.text(TextRegion::All)?
        );
        Ok(())
    }

    #[test]
    fn single_page_iteration_matches_chunks() -> Result<(), Error> {
        let daemon = busy_terminal(3000)?;
        let snapshot = daemon.encode_snapshot()?;
        let ready = ready_len(&snapshot).unwrap();
        let mut pos = ready;
        let mut client = StreamingRestore::new(&snapshot[..ready])?;
        loop {
            let (end, done) = history_chunk(&snapshot, pos, 1).unwrap();
            client.push(&snapshot[pos..end])?;
            pos = end;
            if done {
                break;
            }
        }
        assert!(client.is_finished());
        let terminal = client.into_terminal();
        assert_eq!(
            terminal.text(TextRegion::All)?,
            daemon.text(TextRegion::All)?
        );
        Ok(())
    }
}
