use std::marker::PhantomData;
use std::ptr::{self, NonNull};

use ghostty_vt_sys as ffi;

use crate::terminal::CONTINUATION_MAX_BYTES;
use crate::{Error, Screen, Terminal};

/// Restores a [`Terminal`] from bytes produced by [`Terminal::encode_snapshot`].
///
/// A snapshot decodes in two phases. [`ready`](Self::ready) stops at the READY marker, once
/// the visible screens and unfinished parser input are restored, so a client can render and
/// accept live bytes before scrollback arrives; [`Restore::next_page`] then prepends history.
/// [`decode`](Self::decode) does both in one call.
///
/// Restored terminals keep continuation tracking on, so they can be snapshotted again.
///
/// # Examples
///
/// Paint the visible screen first, then fill in scrollback:
///
/// ```
/// # fn main() -> Result<(), ghostty_vt::Error> {
/// use ghostty_vt::{SnapshotDecoder, Terminal};
///
/// let mut daemon = Terminal::new(80, 2)?;
/// daemon.write(b"1\r\n2\r\n3\r\n4");
/// let snapshot = daemon.encode_snapshot()?;
///
/// let mut restore = SnapshotDecoder::new(&snapshot)?.ready()?;
/// let ready_len = restore.source_offset().expect("offset is known after READY");
/// assert!(ready_len <= snapshot.len());
/// while let Some(_page) = restore.next_page()? {}
/// let client = restore.into_terminal();
/// assert_eq!(client.scrollback_rows(), daemon.scrollback_rows());
/// # Ok(())
/// # }
/// ```
#[derive(Debug)]
pub struct SnapshotDecoder<'a> {
    raw: NonNull<ffi::GhosttySnapshotDecoderImpl>,
    // The decoder reads the borrowed snapshot bytes until FINISH or until it is freed.
    _source: PhantomData<&'a [u8]>,
}

// SAFETY: the decoder owns its state and only borrows immutable bytes (`&[u8]` is `Send`), and
// libghostty-vt keeps no thread-affine data. It is not `Sync`, so access stays serialized.
unsafe impl Send for SnapshotDecoder<'_> {}

impl<'a> SnapshotDecoder<'a> {
    /// Creates a decoder over `snapshot`.
    ///
    /// Nothing is read until [`ready`](Self::ready) or [`decode`](Self::decode). Bytes after
    /// the snapshot's FINISH marker are left unread; see [`source_offset`](Self::source_offset).
    ///
    /// # Errors
    ///
    /// Returns [`Error::OutOfMemory`] if allocation fails.
    pub fn new(snapshot: &'a [u8]) -> Result<Self, Error> {
        let mut raw = ptr::null_mut();
        // SAFETY: `raw` is a valid out pointer; the bytes stay borrowed and immutable for 'a,
        // which outlives the decoder.
        Error::check(unsafe {
            ffi::ghostty_snapshot_decoder_new_buf(
                ptr::null(),
                &mut raw,
                snapshot.as_ptr(),
                snapshot.len(),
            )
        })?;
        let mut decoder = Self {
            raw: NonNull::new(raw).ok_or(Error::InvalidValue)?,
            _source: PhantomData,
        };
        // SAFETY: MAX_CONTINUATION_BYTES reads a `size_t`, RETAIN_CONTINUATION a `bool`.
        unsafe {
            decoder.set(
                ffi::GhosttySnapshotDecoderOption_GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,
                &CONTINUATION_MAX_BYTES,
            )?;
            decoder.set(
                ffi::GhosttySnapshotDecoderOption_GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION,
                &true,
            )?;
        }
        Ok(decoder)
    }

    /// Decodes the whole snapshot, scrollback included, in one call.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] if the bytes are truncated, corrupt, from another
    /// snapshot format version, or if this decoder was already used; [`Error::OutOfMemory`]
    /// if allocation fails. After an error the decoder is spent.
    pub fn decode(&mut self) -> Result<Terminal, Error> {
        let mut raw = ptr::null_mut();
        // SAFETY: the decoder is live and `raw` is a valid out pointer. After FINISH the
        // decoder no longer refers to the terminal, so handing out ownership is sound.
        Error::check(unsafe { ffi::ghostty_snapshot_decoder_decode(self.raw.as_ptr(), &mut raw) })?;
        let raw = NonNull::new(raw).ok_or(Error::InvalidValue)?;
        // SAFETY: on success the caller owns the returned live terminal.
        Ok(unsafe { Terminal::from_raw(raw) })
    }

    /// Decodes up to the READY marker and returns a renderable terminal with history pending.
    ///
    /// Only the bytes up to READY need to be present: a client can decode a prefix of the
    /// snapshot of [`Restore::source_offset`] bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] if the bytes before READY are truncated, corrupt, from
    /// another snapshot format version, or if this decoder was already used;
    /// [`Error::OutOfMemory`] if allocation fails.
    pub fn ready(self) -> Result<Restore<'a>, Error> {
        let mut raw = ptr::null_mut();
        // SAFETY: the decoder is live and `raw` is a valid out pointer.
        Error::check(unsafe { ffi::ghostty_snapshot_decoder_ready(self.raw.as_ptr(), &mut raw) })?;
        let raw = NonNull::new(raw).ok_or(Error::InvalidValue)?;
        Ok(Restore {
            decoder: self,
            // SAFETY: on success the caller owns the returned live terminal. `Restore` keeps it
            // alive, and never lets it be moved out, while the decoder still refers to it.
            terminal: unsafe { Terminal::from_raw(raw) },
        })
    }

    /// Number of snapshot bytes consumed so far.
    ///
    /// After [`decode`](Self::decode) this is the snapshot's length, so trailing transport
    /// bytes start here. `None` before decoding starts reading and after a decoding error.
    pub fn source_offset(&self) -> Option<usize> {
        // SAFETY: SOURCE_OFFSET writes a `size_t`.
        unsafe {
            self.get(ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET)
        }
        .filter(|&offset| offset > 0)
    }

    /// # Safety
    ///
    /// `T` must be the input type libghostty-vt documents for `option`.
    unsafe fn set<T>(
        &mut self,
        option: ffi::GhosttySnapshotDecoderOption,
        value: &T,
    ) -> Result<(), Error> {
        // SAFETY: the decoder is live and the caller guarantees `T` matches `option`.
        Error::check(unsafe {
            ffi::ghostty_snapshot_decoder_set(
                self.raw.as_ptr(),
                option,
                ptr::from_ref(value).cast(),
            )
        })
    }

    /// Reads a data field, mapping "not available in this phase" to `None`.
    ///
    /// # Safety
    ///
    /// `T` must be the output type libghostty-vt documents for `data`.
    unsafe fn get<T: Default>(&self, data: ffi::GhosttySnapshotDecoderData) -> Option<T> {
        let mut out = T::default();
        // SAFETY: the decoder is live and the caller guarantees `T` matches `data`.
        let result = unsafe {
            ffi::ghostty_snapshot_decoder_get(self.raw.as_ptr(), data, (&raw mut out).cast())
        };
        (result == ffi::GhosttyResult_GHOSTTY_SUCCESS).then_some(out)
    }
}

impl Drop for SnapshotDecoder<'_> {
    fn drop(&mut self) {
        // SAFETY: the decoder is live and owned by `self`; freeing it never frees a terminal.
        unsafe { ffi::ghostty_snapshot_decoder_free(self.raw.as_ptr()) }
    }
}

/// A terminal restored up to READY whose scrollback is still being decoded.
///
/// The terminal can be rendered and fed live bytes between [`next_page`](Self::next_page)
/// calls. The decoder keeps a pointer to it until FINISH, so `Restore` only lends it out
/// immutably and forwards the mutations that are safe mid-restore.
#[derive(Debug)]
pub struct Restore<'a> {
    // Declared before `terminal` so the decoder is freed first on drop.
    decoder: SnapshotDecoder<'a>,
    terminal: Terminal,
}

/// Progress after one decoded scrollback page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct HistoryPage {
    /// The screen the page belongs to.
    pub screen: Screen,
    /// Rows prepended to that screen's scrollback. Zero when the page no longer fit the live
    /// terminal (for example after a resize) and was skipped.
    pub rows: usize,
    /// Pages still to come for the same screen.
    pub remaining: u32,
}

impl Restore<'_> {
    /// The restored terminal, for rendering and reads.
    pub fn terminal(&self) -> &Terminal {
        &self.terminal
    }

    /// Feeds live PTY bytes to the restored terminal; see [`Terminal::write`].
    pub fn write(&mut self, bytes: &[u8]) {
        self.terminal.write(bytes);
    }

    /// Resizes the restored terminal; see [`Terminal::resize`].
    ///
    /// # Errors
    ///
    /// As for [`Terminal::resize`].
    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), Error> {
        self.terminal.resize(cols, rows)
    }

    /// Total scrollback rows the snapshot declares for `screen`, for sizing a scrollbar early.
    ///
    /// `None` if the snapshot has no such screen.
    pub fn history_rows(&self, screen: Screen) -> Option<u64> {
        let data = match screen {
            Screen::Primary => {
                ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY
            }
            Screen::Alternate => {
                ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_ALTERNATE
            }
        };
        // SAFETY: both HISTORY_ROWS fields write a `uint64_t`.
        unsafe { self.decoder.get(data) }
    }

    /// Snapshot bytes consumed so far; right after [`SnapshotDecoder::ready`] this is the
    /// length of the READY prefix.
    pub fn source_offset(&self) -> Option<usize> {
        self.decoder.source_offset()
    }

    /// Decodes and prepends one scrollback page, or returns `None` once FINISH is reached.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] if the history bytes are truncated or corrupt and
    /// [`Error::OutOfMemory`] if allocation fails. The terminal stays usable with the history
    /// restored so far (see [`into_terminal`](Self::into_terminal)), but the decoder is spent.
    pub fn next_page(&mut self) -> Result<Option<HistoryPage>, Error> {
        // SAFETY: the decoder is live and the terminal it restores into is alive in `self`.
        match unsafe { ffi::ghostty_snapshot_decoder_next(self.decoder.raw.as_ptr()) } {
            ffi::GhosttyResult_GHOSTTY_NO_VALUE => Ok(None),
            code => {
                Error::check(code)?;
                let decoder = &self.decoder;
                // SAFETY: after a successful `next`, PROGRESS_SCREEN writes a
                // `GhosttyTerminalScreen`, PROGRESS_ROWS a `size_t` and PROGRESS_REMAINING a
                // `uint32_t`.
                let page = unsafe {
                    HistoryPage {
                        screen: Screen::from_raw(
                            decoder
                                .get(ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_SCREEN)
                                .ok_or(Error::NoValue)?,
                        ),
                        rows: decoder
                            .get(ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS)
                            .ok_or(Error::NoValue)?,
                        remaining: decoder
                            .get(ffi::GhosttySnapshotDecoderData_GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_REMAINING)
                            .ok_or(Error::NoValue)?,
                    }
                };
                Ok(Some(page))
            }
        }
    }

    /// Decodes all remaining scrollback and returns the terminal.
    ///
    /// # Errors
    ///
    /// As for [`next_page`](Self::next_page). The terminal is dropped on error; call
    /// `next_page` directly to keep it.
    pub fn finish(mut self) -> Result<Terminal, Error> {
        while self.next_page()?.is_some() {}
        Ok(self.into_terminal())
    }

    /// Stops restoring and returns the terminal with whatever scrollback has arrived.
    pub fn into_terminal(self) -> Terminal {
        let Self { decoder, terminal } = self;
        // Free the decoder first so nothing refers to the terminal once it is handed out.
        drop(decoder);
        terminal
    }
}

/// Size of the snapshot envelope: the `GHOSTSNP` magic and a `u16` format version.
const ENVELOPE_LEN: usize = 10;
/// Size of a record header: `tag u16, len u32, crc32c u32`, little-endian.
const RECORD_HEADER_LEN: usize = 10;
/// Record tag of the READY marker.
const READY_TAG: u16 = 5;

/// Returns the length of the snapshot's prefix up to and including the READY record.
///
/// scrollback records after it can follow lazily. Walks the record headers without decoding
/// or checksumming them, so it costs nothing next to encoding. Returns `None` if the bytes are
/// not a snapshot or contain no READY record.
///
/// # Examples
///
/// ```
/// # fn main() -> Result<(), ghostty_vt::Error> {
/// use ghostty_vt::{SnapshotDecoder, Terminal, ready_len};
///
/// let mut daemon = Terminal::new(80, 2)?;
/// daemon.write(b"1\r\n2\r\n3\r\n4");
/// let snapshot = daemon.encode_snapshot()?;
/// let len = ready_len(&snapshot).expect("snapshots always have READY");
/// let restore = SnapshotDecoder::new(&snapshot[..len])?.ready()?;
/// assert_eq!(restore.source_offset(), Some(len));
/// # Ok(())
/// # }
/// ```
pub fn ready_len(snapshot: &[u8]) -> Option<usize> {
    if snapshot.get(..8)? != b"GHOSTSNP" {
        return None;
    }
    let mut pos = ENVELOPE_LEN;
    while let Some(header) = snapshot.get(pos..pos + RECORD_HEADER_LEN) {
        let tag = u16::from_le_bytes([header[0], header[1]]);
        let len = u32::from_le_bytes([header[2], header[3], header[4], header[5]]) as usize;
        pos = pos.checked_add(RECORD_HEADER_LEN + len)?;
        if pos > snapshot.len() {
            return None;
        }
        if tag == READY_TAG {
            return Some(pos);
        }
    }
    None
}

/// Returns the snapshot format version this build of libghostty-vt writes.
///
/// Client and daemon must agree on it; the `Hello` handshake compares it (ARCHITECTURE §4).
pub fn snapshot_format() -> u16 {
    static FORMAT: std::sync::OnceLock<u16> = std::sync::OnceLock::new();
    *FORMAT.get_or_init(|| {
        Terminal::new(1, 1)
            .and_then(|t| t.encode_snapshot())
            .ok()
            .and_then(|s| Some(u16::from_le_bytes([*s.get(8)?, *s.get(9)?])))
            .unwrap_or(0)
    })
}
