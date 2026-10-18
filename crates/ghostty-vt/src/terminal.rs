use std::ffi::c_void;
use std::mem;
use std::ptr::{self, NonNull};
use std::slice;

use ghostty_vt_sys as ffi;

use crate::Error;

/// Upper bound on unfinished VT input a terminal retains for snapshots.
///
/// Every [`Terminal`] tracks the bytes of its current unfinished escape sequence or UTF-8
/// codepoint, up to this many, so that [`Terminal::encode_snapshot`] can cut the stream
/// anywhere. Decoders accept continuations up to the same size. A longer pending sequence
/// (for example a multi-megabyte OSC 52 clipboard write) makes snapshots fail until the
/// stream returns to ground.
pub const CONTINUATION_MAX_BYTES: usize = 1 << 20;

/// A virtual terminal: VT parser plus screen, scrollback and modes.
///
/// `Terminal` is [`Send`] but not [`Sync`]: libghostty-vt does no internal locking, so a
/// terminal may move between threads but every access must be serialized. `&mut self`
/// methods mutate state; `&self` methods only read it.
///
/// Continuation tracking is always on (see [`CONTINUATION_MAX_BYTES`]), so a snapshot can be
/// taken between any two calls to [`write`](Self::write).
///
/// # Examples
///
/// ```
/// # fn main() -> Result<(), ghostty_vt::Error> {
/// use ghostty_vt::{Cursor, Terminal, TextRegion};
///
/// let mut terminal = Terminal::new(20, 3)?;
/// terminal.write("héllo\r\n\x1b[31mworld".as_bytes());
/// assert_eq!(terminal.text(TextRegion::Active)?, "héllo\nworld");
/// assert_eq!(terminal.cursor(), Cursor { x: 5, y: 1, pending_wrap: false });
/// # Ok(())
/// # }
/// ```
pub struct Terminal {
    raw: NonNull<ffi::GhosttyTerminalImpl>,
    /// Sink for query replies, owned here and freed in `Drop`. libghostty-vt holds it as the
    /// terminal's userdata, so it must stay at a stable address: hence a raw heap pointer.
    reply_sink: *mut ReplySink,
}

/// Receives bytes the terminal wants to send back to the program (query replies).
pub type ReplySink = Box<dyn FnMut(&[u8]) + Send>;

impl std::fmt::Debug for Terminal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Terminal")
            .field("raw", &self.raw)
            .field("reply_sink", &!self.reply_sink.is_null())
            .finish()
    }
}

// SAFETY: the reply sink is `Send` and only reached through this terminal, so moving it along
// with the handle is sound. A terminal handle owns all of its state and libghostty-vt keeps no thread-local or
// thread-affine data, so the handle may be used from another thread. `Terminal` is not `Sync`,
// which keeps all access to one handle serialized as the C API requires.
unsafe impl Send for Terminal {}

/// The cursor position within the active area.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Cursor {
    /// Column, from 0.
    pub x: u16,
    /// Row within the active area, from 0.
    pub y: u16,
    /// Whether the next printed character wraps to the next line first.
    pub pending_wrap: bool,
}

/// Which of the two screens a terminal shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Screen {
    /// The normal screen, which owns the scrollback.
    Primary,
    /// The alternate screen used by full-screen programs (DEC mode 1049 and friends).
    Alternate,
}

impl Screen {
    pub(crate) fn from_raw(raw: ffi::GhosttyTerminalScreen) -> Self {
        match raw {
            ffi::GhosttyTerminalScreen_GHOSTTY_TERMINAL_SCREEN_PRIMARY => Self::Primary,
            ffi::GhosttyTerminalScreen_GHOSTTY_TERMINAL_SCREEN_ALTERNATE => Self::Alternate,
            other => unreachable!("libghostty-vt reported unknown screen {other}"),
        }
    }
}

/// The part of the active screen to extract as text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TextRegion {
    /// The active area: the bottom `rows` rows that programs draw into.
    Active,
    /// The active area and all of the active screen's scrollback.
    All,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Format {
    Plain,
    Vt,
}

impl Terminal {
    /// Creates a blank terminal of `cols` × `rows` cells with continuation tracking enabled.
    ///
    /// Scrollback starts at libghostty-vt's default limit, which is small; see
    /// [`set_scrollback_max_bytes`](Self::set_scrollback_max_bytes).
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] if either dimension is zero and
    /// [`Error::OutOfMemory`] if allocation fails.
    pub fn new(cols: u16, rows: u16) -> Result<Self, Error> {
        let mut raw = ptr::null_mut();
        // SAFETY: `raw` is a valid out pointer; a null allocator selects the default one.
        Error::check(unsafe { ffi::ghostty_terminal_new(ptr::null(), &mut raw, cols, rows) })?;
        let raw = NonNull::new(raw).ok_or(Error::InvalidValue)?;
        let mut terminal = Self {
            raw,
            reply_sink: ptr::null_mut(),
        };
        terminal.set_usize(
            ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
            Some(CONTINUATION_MAX_BYTES),
        )?;
        Ok(terminal)
    }

    /// Takes ownership of a terminal handle returned by libghostty-vt.
    ///
    /// # Safety
    ///
    /// `raw` must be a live terminal handle that nothing else owns or frees.
    pub(crate) unsafe fn from_raw(raw: NonNull<ffi::GhosttyTerminalImpl>) -> Self {
        Self {
            raw,
            reply_sink: ptr::null_mut(),
        }
    }

    pub(crate) fn as_raw(&self) -> ffi::GhosttyTerminal {
        self.raw.as_ptr()
    }

    /// Feeds raw PTY output to the parser.
    ///
    /// Malformed input never fails; libghostty-vt logs and skips it. Writes may split escape
    /// sequences and UTF-8 codepoints anywhere. Queries that need a reply (device status
    /// reports and the like) are ignored.
    pub fn write(&mut self, bytes: &[u8]) {
        // SAFETY: the handle is live and `bytes` is valid for reads of `bytes.len()` bytes.
        unsafe { ffi::ghostty_terminal_vt_write(self.as_raw(), bytes.as_ptr(), bytes.len()) }
    }

    /// Resizes the grid to `cols` × `rows`, reflowing the primary screen.
    ///
    /// The cell pixel size is set to zero; pixel-based reports and images are not used yet.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] if either dimension is zero and
    /// [`Error::OutOfMemory`] if allocation fails.
    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), Error> {
        // SAFETY: the handle is live.
        Error::check(unsafe { ffi::ghostty_terminal_resize(self.as_raw(), cols, rows, 0, 0) })
    }

    /// Caps scrollback memory at `limit` bytes, or removes the byte cap with `None`.
    ///
    /// Zero disables scrollback and erases it. Pruning happens a whole page at a time.
    ///
    /// # Errors
    ///
    /// Returns [`Error::OutOfMemory`] if pruning needs to allocate and cannot.
    pub fn set_scrollback_max_bytes(&mut self, limit: Option<usize>) -> Result<(), Error> {
        self.set_usize(
            ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
            limit,
        )
    }

    /// Caps scrollback at roughly `limit` lines, or removes the line cap with `None`.
    ///
    /// The cap is approximate: whole pages are pruned, so somewhat more lines survive.
    ///
    /// # Errors
    ///
    /// Returns [`Error::OutOfMemory`] if pruning needs to allocate and cannot.
    pub fn set_scrollback_max_lines(&mut self, limit: Option<usize>) -> Result<(), Error> {
        self.set_usize(
            ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            limit,
        )
    }

    /// Width in cells.
    pub fn cols(&self) -> u16 {
        // SAFETY: COLS writes a `u16`.
        unsafe { self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS) }
    }

    /// Height in cells.
    pub fn rows(&self) -> u16 {
        // SAFETY: ROWS writes a `u16`.
        unsafe { self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS) }
    }

    /// The cursor position in the active area.
    pub fn cursor(&self) -> Cursor {
        // SAFETY: CURSOR_X and CURSOR_Y write a `u16`, CURSOR_PENDING_WRAP a `bool`.
        unsafe {
            Cursor {
                x: self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_X),
                y: self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y),
                pending_wrap: self
                    .get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP),
            }
        }
    }

    /// The screen currently shown.
    pub fn active_screen(&self) -> Screen {
        // SAFETY: ACTIVE_SCREEN writes a `GhosttyTerminalScreen`.
        Screen::from_raw(unsafe {
            self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN)
        })
    }

    /// Number of scrollback rows above the active area on the active screen.
    pub fn scrollback_rows(&self) -> usize {
        // SAFETY: SCROLLBACK_ROWS writes a `size_t`.
        unsafe { self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS) }
    }

    /// Serializes the complete terminal state, scrollback included.
    ///
    /// The snapshot holds the visible screens and the unfinished parser input first, then a
    /// READY marker, then scrollback from newest to oldest. Restore it with
    /// [`SnapshotDecoder`](crate::SnapshotDecoder) and continue writing the PTY bytes that
    /// followed the snapshot.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] if the parser is inside a sequence longer than
    /// [`CONTINUATION_MAX_BYTES`]; retry once more output has arrived. Returns
    /// [`Error::OutOfMemory`] if allocation fails.
    pub fn encode_snapshot(&self) -> Result<Vec<u8>, Error> {
        let mut out = Vec::new();
        // SAFETY: the handle is live; the writer's userdata points at `out`, which outlives
        // the call, and `extend_vec` treats it as a `Vec<u8>`.
        Error::check(unsafe { ffi::ghostty_snapshot_encode(self.as_raw(), vec_writer(&mut out)) })?;
        Ok(out)
    }

    /// Serializes only the READY section: visible screens, modes and unfinished parser input,
    ///
    /// libghostty-vt cannot stop at READY yet, so this encodes everything and truncates.
    ///
    /// # Errors
    ///
    /// As for [`encode_snapshot`](Self::encode_snapshot).
    pub fn encode_ready_snapshot(&self) -> Result<Vec<u8>, Error> {
        let mut snapshot = self.encode_snapshot()?;
        let len = crate::ready_len(&snapshot).ok_or(Error::InvalidValue)?;
        snapshot.truncate(len);
        Ok(snapshot)
    }

    /// Installs `sink` to receive the terminal's replies to queries from the program: device
    /// attributes, cursor position and status reports, mode queries and the like.
    ///
    /// A terminal without a sink ignores queries, which makes programs that wait for a reply
    /// (for example a TUI asking for the cursor position at startup) stall. The sink runs
    /// synchronously inside [`write`](Self::write); it must not block.
    ///
    /// # Errors
    ///
    /// Returns an error if libghostty-vt rejects the callback options.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), ghostty_vt::Error> {
    /// use std::sync::{Arc, Mutex};
    ///
    /// let replies = Arc::new(Mutex::new(Vec::new()));
    /// let mut terminal = ghostty_vt::Terminal::new(80, 24)?;
    /// let sink = Arc::clone(&replies);
    /// terminal.set_reply_sink(Box::new(move |b| sink.lock().unwrap().extend_from_slice(b)))?;
    /// terminal.write(b"\x1b[6n"); // where is the cursor?
    /// assert_eq!(&*replies.lock().unwrap(), b"\x1b[1;1R");
    /// # Ok(())
    /// # }
    /// ```
    pub fn set_reply_sink(&mut self, sink: ReplySink) -> Result<(), Error> {
        let new = Box::into_raw(Box::new(sink));
        // SAFETY: the handle is live. USERDATA takes the pointer value itself; WRITE_PTY takes
        // a `GhosttyTerminalWritePtyFn`. `new` stays valid until replaced or `Drop`.
        let result = unsafe {
            Error::check(ffi::ghostty_terminal_set(
                self.as_raw(),
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_USERDATA,
                new.cast::<c_void>().cast_const(),
            ))
            .and_then(|()| {
                let callback: ffi::GhosttyTerminalWritePtyFn = Some(write_pty_trampoline);
                Error::check(ffi::ghostty_terminal_set(
                    self.as_raw(),
                    ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                    callback.map_or(ptr::null(), |f| f as *const c_void),
                ))
            })
        };
        if let Err(err) = result {
            // SAFETY: `new` came from `Box::into_raw` above and was never handed out.
            drop(unsafe { Box::from_raw(new) });
            return Err(err);
        }
        let old = mem::replace(&mut self.reply_sink, new);
        if !old.is_null() {
            // SAFETY: `old` came from `Box::into_raw` and libghostty-vt now points at `new`.
            drop(unsafe { Box::from_raw(old) });
        }
        Ok(())
    }

    /// Extracts the plain text of `region`, one line per row.
    ///
    /// Trailing blanks are trimmed and soft-wrapped rows stay separate lines. Styles,
    /// hyperlinks and the cursor are not included.
    ///
    /// # Errors
    ///
    /// Returns [`Error::OutOfMemory`] if allocation fails.
    pub fn text(&self, region: TextRegion) -> Result<String, Error> {
        self.format(region, Format::Plain)
    }

    /// Serializes `region` as VT sequences that redraw it, with all terminal state the
    /// formatter knows.
    ///
    /// Besides text this carries styles, hyperlinks, the cursor and its pen, charsets,
    /// protection, modes that differ from their defaults, the palette, the scrolling region,
    /// tab stops, the working directory and keyboard modes. Two terminals with equal output
    /// render and behave the same for that region, which makes this a strict test oracle.
    ///
    /// # Errors
    ///
    /// Returns [`Error::OutOfMemory`] if allocation fails.
    pub fn vt(&self, region: TextRegion) -> Result<String, Error> {
        self.format(region, Format::Vt)
    }

    fn format(&self, region: TextRegion, format: Format) -> Result<String, Error> {
        let selection = match region {
            TextRegion::All => None,
            TextRegion::Active => Some(ffi::GhosttySelection {
                size: mem::size_of::<ffi::GhosttySelection>(),
                start: self.active_grid_ref(0, 0)?,
                end: self.active_grid_ref(self.cols() - 1, u32::from(self.rows()) - 1)?,
                rectangle: false,
            }),
        };
        let vt = format == Format::Vt;
        let options = ffi::GhosttyFormatterTerminalOptions {
            size: mem::size_of::<ffi::GhosttyFormatterTerminalOptions>(),
            emit: match format {
                Format::Plain => ffi::GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_PLAIN,
                Format::Vt => ffi::GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_VT,
            },
            unwrap: false,
            trim: !vt,
            extra: ffi::GhosttyFormatterTerminalExtra {
                size: mem::size_of::<ffi::GhosttyFormatterTerminalExtra>(),
                palette: vt,
                modes: vt,
                scrolling_region: vt,
                tabstops: vt,
                pwd: vt,
                keyboard: vt,
                screen: ffi::GhosttyFormatterScreenExtra {
                    size: mem::size_of::<ffi::GhosttyFormatterScreenExtra>(),
                    cursor: vt,
                    style: vt,
                    hyperlink: vt,
                    protection: vt,
                    kitty_keyboard: vt,
                    charsets: vt,
                },
            },
            selection: selection.as_ref().map_or(ptr::null(), ptr::from_ref),
        };

        let mut formatter = ptr::null_mut();
        // SAFETY: the handle is live and outlives the formatter, which is freed below before
        // `self` can be mutated. `options.selection` points at `selection`, alive until then.
        Error::check(unsafe {
            ffi::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.as_raw(), options)
        })?;
        let mut out = Vec::new();
        // SAFETY: `formatter` is live; the writer's userdata points at `out`, which outlives
        // the call.
        let result = unsafe { ffi::ghostty_formatter_format(formatter, vec_writer(&mut out)) };
        // SAFETY: `formatter` is live and not used again.
        unsafe { ffi::ghostty_formatter_free(formatter) };
        Error::check(result)?;
        Ok(String::from_utf8_lossy(&out).into_owned())
    }

    fn active_grid_ref(&self, x: u16, y: u32) -> Result<ffi::GhosttyGridRef, Error> {
        let point = ffi::GhosttyPoint {
            tag: ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_ACTIVE,
            value: ffi::GhosttyPointValue {
                coordinate: ffi::GhosttyPointCoordinate { x, y },
            },
        };
        let mut grid_ref = ffi::GhosttyGridRef {
            size: mem::size_of::<ffi::GhosttyGridRef>(),
            ..Default::default()
        };
        // SAFETY: the handle is live and `grid_ref` is a valid, sized out struct.
        Error::check(unsafe {
            ffi::ghostty_terminal_grid_ref(self.as_raw(), point, &mut grid_ref)
        })?;
        Ok(grid_ref)
    }

    /// Sets a `size_t *` option, passing NULL for `None`.
    fn set_usize(
        &mut self,
        option: ffi::GhosttyTerminalOption,
        value: Option<usize>,
    ) -> Result<(), Error> {
        let value_ptr = value.as_ref().map_or(ptr::null(), ptr::from_ref);
        // SAFETY: the handle is live and every caller passes an option documented as taking a
        // nullable `size_t *`, which is read before the call returns.
        Error::check(unsafe { ffi::ghostty_terminal_set(self.as_raw(), option, value_ptr.cast()) })
    }

    /// Reads a data field that cannot fail on a live handle.
    ///
    /// # Safety
    ///
    /// `T` must be the output type libghostty-vt documents for `data`.
    unsafe fn get<T: Default>(&self, data: ffi::GhosttyTerminalData) -> T {
        let mut out = T::default();
        // SAFETY: the handle is live and the caller guarantees `T` matches `data`.
        let result =
            unsafe { ffi::ghostty_terminal_get(self.as_raw(), data, (&raw mut out).cast()) };
        assert_eq!(
            result,
            ffi::GhosttyResult_GHOSTTY_SUCCESS,
            "terminal data {data} unavailable"
        );
        out
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        // SAFETY: the handle is live and owned by `self`; nothing uses it afterwards.
        unsafe { ffi::ghostty_terminal_free(self.as_raw()) }
        if !self.reply_sink.is_null() {
            // SAFETY: allocated by `set_reply_sink`; the terminal that called it is gone.
            drop(unsafe { Box::from_raw(self.reply_sink) });
        }
    }
}

unsafe extern "C" fn write_pty_trampoline(
    _terminal: ffi::GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    if userdata.is_null() || data.is_null() {
        return;
    }
    // SAFETY: userdata is the `ReplySink` installed by `set_reply_sink`, alive for the
    // terminal's lifetime and only used from inside `write`, which holds `&mut Terminal`.
    // `data` is valid for `len` bytes for the duration of the call.
    unsafe {
        let sink = &mut *userdata.cast::<ReplySink>();
        sink(slice::from_raw_parts(data, len));
    }
}

/// Builds a `GhosttyWriter` that appends to `out`.
///
/// The writer holds a raw pointer to `out`; the caller must keep `out` alive and otherwise
/// untouched until the libghostty-vt call that receives the writer returns.
pub(crate) fn vec_writer(out: &mut Vec<u8>) -> ffi::GhosttyWriter {
    ffi::GhosttyWriter {
        write: Some(extend_vec),
        userdata: ptr::from_mut(out).cast::<c_void>(),
    }
}

unsafe extern "C" fn extend_vec(userdata: *mut c_void, data: *const u8, len: usize) -> bool {
    // SAFETY: `vec_writer` set `userdata` to a live, exclusively borrowed `Vec<u8>`, and the
    // writer contract guarantees `data` is non-null and valid for `len` bytes during the call.
    unsafe {
        let out = &mut *userdata.cast::<Vec<u8>>();
        out.extend_from_slice(slice::from_raw_parts(data, len));
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_size_is_rejected() {
        assert_eq!(Terminal::new(0, 24).unwrap_err(), Error::InvalidValue);
    }

    #[test]
    fn resize_changes_dimensions() -> Result<(), Error> {
        let mut terminal = Terminal::new(80, 24)?;
        terminal.resize(100, 30)?;
        assert_eq!((terminal.cols(), terminal.rows()), (100, 30));
        assert_eq!(terminal.resize(0, 30), Err(Error::InvalidValue));
        Ok(())
    }

    #[test]
    fn alternate_screen_is_reported() -> Result<(), Error> {
        let mut terminal = Terminal::new(80, 24)?;
        terminal.write(b"\x1b[?1049h");
        assert_eq!(terminal.active_screen(), Screen::Alternate);
        terminal.write(b"\x1b[?1049l");
        assert_eq!(terminal.active_screen(), Screen::Primary);
        Ok(())
    }

    #[test]
    fn all_text_includes_scrollback() -> Result<(), Error> {
        let mut terminal = Terminal::new(10, 2)?;
        terminal.write(b"one\r\ntwo\r\nthree");
        assert_eq!(terminal.scrollback_rows(), 1);
        assert_eq!(terminal.text(TextRegion::Active)?, "two\nthree");
        assert_eq!(terminal.text(TextRegion::All)?, "one\ntwo\nthree");
        Ok(())
    }
}
