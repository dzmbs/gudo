use std::collections::HashMap;
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
    /// Callback state, owned here and freed in `Drop`. libghostty-vt holds it as the
    /// terminal's userdata, so it must stay at a stable address: hence a raw heap pointer.
    /// Null until a callback is installed.
    callbacks: *mut Callbacks,
    /// Tracked grid references handed out as [`PinId`]s.
    pins: HashMap<PinId, NonNull<ffi::GhosttyTrackedGridRefImpl>>,
    next_pin: u64,
}

/// Receives bytes the terminal wants to send back to the program (query replies).
pub type ReplySink = Box<dyn FnMut(&[u8]) + Send>;

/// State the C callbacks reach through the terminal's userdata pointer.
#[derive(Default)]
struct Callbacks {
    reply: Option<ReplySink>,
    /// Shell-integration events seen during the current `write`, with the cursor tracked at
    /// the moment each arrived.
    prompts: Vec<RawPrompt>,
}

struct RawPrompt {
    kind: SemanticPromptKind,
    pin: Option<NonNull<ffi::GhosttyTrackedGridRefImpl>>,
}

impl std::fmt::Debug for Terminal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Terminal")
            .field("raw", &self.raw)
            .field("callbacks", &!self.callbacks.is_null())
            .field("pins", &self.pins.len())
            .finish()
    }
}

// SAFETY: the callback state is `Send` (the reply sink is `Send`, tracked references are owned
// heap handles) and only reached through this terminal, so moving it along with the handle is
// sound. A terminal handle owns all of its state and libghostty-vt keeps no thread-local or
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

/// A cell in screen coordinates: row 0 is the oldest row still in scrollback.
///
/// Screen rows shift down by the number of pruned rows whenever scrollback is trimmed, so a
/// point is only meaningful together with the terminal state it was read from. Use a
/// [`PinId`] to follow a cell over time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Point {
    /// Row, from the top of scrollback.
    pub y: u32,
    /// Column.
    pub x: u16,
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
    /// The cells from `start` to `end`, both inclusive, in reading order.
    Range {
        /// First cell.
        start: Point,
        /// Last cell.
        end: Point,
    },
}

/// Whether extracted text keeps soft wraps as line breaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Wrap {
    /// One line per row.
    #[default]
    Rows,
    /// Rows that soft-wrapped are joined into one logical line.
    Join,
}

/// A terminal mode, as libghostty-vt packs it (`include/ghostty/vt/modes.h`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Mode(u16);

impl Mode {
    /// DECCKM: cursor keys send application sequences.
    pub const CURSOR_KEYS: Self = Self::dec(1);
    /// X10 mouse reporting.
    pub const X10_MOUSE: Self = Self::dec(9);
    /// DECTCEM: the cursor is visible.
    pub const CURSOR_VISIBLE: Self = Self::dec(25);
    /// Application keypad.
    pub const KEYPAD_KEYS: Self = Self::dec(66);
    /// Normal mouse tracking (button presses and releases).
    pub const NORMAL_MOUSE: Self = Self::dec(1000);
    /// Button-event mouse tracking.
    pub const BUTTON_MOUSE: Self = Self::dec(1002);
    /// Any-event mouse tracking.
    pub const ANY_MOUSE: Self = Self::dec(1003);
    /// Focus in/out reports.
    pub const FOCUS_EVENT: Self = Self::dec(1004);
    /// SGR mouse format.
    pub const SGR_MOUSE: Self = Self::dec(1006);
    /// Bracketed paste.
    pub const BRACKETED_PASTE: Self = Self::dec(2004);

    /// A DEC private mode (`CSI ? n h`).
    pub const fn dec(value: u16) -> Self {
        Self(value & 0x7fff)
    }

    /// An ANSI mode (`CSI n h`).
    pub const fn ansi(value: u16) -> Self {
        Self((value & 0x7fff) | 0x8000)
    }
}

/// A tracked cell reference: it follows its cell through scrolling, reflow and pruning.
///
/// Created by [`Terminal::pin_cursor`] and shell-integration events; read with
/// [`Terminal::pin_point`] and released with [`Terminal::unpin`]. Ids are only meaningful for
/// the terminal that issued them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PinId(u64);

/// Which prompt a [`SemanticPromptKind::PromptStart`] starts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PromptKind {
    /// The main prompt before each command.
    Primary,
    /// A prompt at the right edge (zsh `RPROMPT`).
    Right,
    /// The start of an extra line of a multi-line command.
    Continuation,
    /// Another prompt for extra input (bash `PS2`).
    Secondary,
}

/// One shell-integration (OSC 133) step.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SemanticPromptKind {
    /// The shell started drawing a prompt (`133;A`, `133;P`).
    PromptStart(PromptKind),
    /// The prompt is drawn; the user types the command from here (`133;B`).
    InputStart,
    /// The command was submitted and runs; output follows (`133;C`).
    OutputStart {
        /// The command line, if the shell sent it.
        command: Option<String>,
    },
    /// The command finished (`133;D`).
    CommandEnd {
        /// Its exit status, if the shell sent it.
        exit: Option<i32>,
    },
}

/// A shell-integration event with where the cursor was when it arrived.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SemanticPrompt {
    /// What happened.
    pub kind: SemanticPromptKind,
    /// The cursor cell at that moment, tracked; `None` if it could not be tracked.
    pub pin: Option<PinId>,
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
        // SAFETY: freshly created and owned by nothing else.
        let mut terminal = unsafe { Self::from_raw(raw) };
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
            callbacks: ptr::null_mut(),
            pins: HashMap::new(),
            next_pin: 0,
        }
    }

    pub(crate) fn as_raw(&self) -> ffi::GhosttyTerminal {
        self.raw.as_ptr()
    }

    /// Feeds raw PTY output to the parser.
    ///
    /// Malformed input never fails; libghostty-vt logs and skips it. Writes may split escape
    /// sequences and UTF-8 codepoints anywhere. Queries that need a reply (device status
    /// reports and the like) go to the [reply sink](Self::set_reply_sink), if any.
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

    /// Rows on the active screen, scrollback included: one past the last screen row.
    pub fn total_rows(&self) -> usize {
        // SAFETY: TOTAL_ROWS writes a `size_t`.
        unsafe { self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_TOTAL_ROWS) }
    }

    /// The cursor position in screen coordinates.
    pub fn cursor_point(&self) -> Point {
        let cursor = self.cursor();
        Point {
            y: (self.total_rows() - usize::from(self.rows()) + usize::from(cursor.y)) as u32,
            x: cursor.x,
        }
    }

    /// Whether `mode` is set.
    pub fn mode(&self, mode: Mode) -> bool {
        let mut config = ffi::GhosttyTerminalModeConfig {
            mode: mode.0,
            value: false,
        };
        // SAFETY: MODE reads and writes a `GhosttyTerminalModeConfig`, which `config` is.
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.as_raw(),
                ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_MODE,
                (&raw mut config).cast(),
            )
        };
        result == ffi::GhosttyResult_GHOSTTY_SUCCESS && config.value
    }

    /// The kitty keyboard protocol flags the program enabled (0 when it uses legacy keys).
    pub fn kitty_keyboard_flags(&self) -> u8 {
        // SAFETY: KITTY_KEYBOARD_FLAGS writes a `GhosttyKittyKeyFlags` (`u8`).
        unsafe { self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS) }
    }

    /// Whether any mouse tracking mode is on.
    pub fn mouse_tracking(&self) -> bool {
        // SAFETY: MOUSE_TRACKING writes a `bool`.
        unsafe { self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING) }
    }

    /// Whether the cursor is in a shell prompt or its input area (OSC 133), on the primary
    /// screen.
    pub fn cursor_at_prompt(&self) -> bool {
        // SAFETY: CURSOR_AT_PROMPT writes a `bool`.
        unsafe { self.get(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT) }
    }

    /// The working directory the program reported (OSC 7), as sent: usually a `file://` or
    /// `kitty-shell-cwd://` URL.
    pub fn pwd(&self) -> Option<String> {
        let mut out = ffi::GhosttyString {
            ptr: ptr::null(),
            len: 0,
        };
        // SAFETY: PWD writes a `GhosttyString` borrowed until the next mutation; it is copied
        // before `self` can be mutated.
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.as_raw(),
                ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_PWD,
                (&raw mut out).cast(),
            )
        };
        if result != ffi::GhosttyResult_GHOSTTY_SUCCESS || out.len == 0 || out.ptr.is_null() {
            return None;
        }
        // SAFETY: libghostty-vt returned `len` valid bytes at `ptr`.
        let bytes = unsafe { slice::from_raw_parts(out.ptr, out.len) };
        Some(String::from_utf8_lossy(bytes).into_owned())
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
        self.callbacks()?.reply = Some(sink);
        let callback: ffi::GhosttyTerminalWritePtyFn = Some(write_pty_trampoline);
        // SAFETY: the handle is live; WRITE_PTY takes a `GhosttyTerminalWritePtyFn`.
        Error::check(unsafe {
            ffi::ghostty_terminal_set(
                self.as_raw(),
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                callback.map_or(ptr::null(), |f| f as *const c_void),
            )
        })
    }

    /// Starts recording shell-integration (OSC 133) events for
    /// [`take_semantic_prompts`](Self::take_semantic_prompts).
    ///
    /// Each event carries a [`PinId`] on the cursor cell at the moment it arrived, even when
    /// several arrive within one [`write`](Self::write), so prompts, command output and
    /// command ends can be located later, after scrolling, reflow or pruning.
    ///
    /// # Errors
    ///
    /// Returns an error if libghostty-vt rejects the callback options.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), ghostty_vt::Error> {
    /// use ghostty_vt::{SemanticPromptKind, Terminal};
    ///
    /// let mut terminal = Terminal::new(20, 5)?;
    /// terminal.record_semantic_prompts()?;
    /// terminal.write(b"\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07a b\r\n\x1b]133;D;0\x07");
    /// let events = terminal.take_semantic_prompts();
    /// assert_eq!(events.len(), 4);
    /// assert_eq!(events[3].kind, SemanticPromptKind::CommandEnd { exit: Some(0) });
    /// let output = terminal.pin_point(events[2].pin.unwrap()).unwrap();
    /// assert_eq!((output.y, output.x), (1, 0));
    /// # Ok(())
    /// # }
    /// ```
    pub fn record_semantic_prompts(&mut self) -> Result<(), Error> {
        self.callbacks()?;
        let callback: ffi::GhosttyTerminalSemanticPromptFn = Some(semantic_prompt_trampoline);
        // SAFETY: the handle is live; SEMANTIC_PROMPT takes a `GhosttyTerminalSemanticPromptFn`.
        Error::check(unsafe {
            ffi::ghostty_terminal_set(
                self.as_raw(),
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
                callback.map_or(ptr::null(), |f| f as *const c_void),
            )
        })
    }

    /// Returns the shell-integration events recorded since the last call, oldest first.
    ///
    /// Their pins belong to this terminal until [`unpin`](Self::unpin)ned.
    pub fn take_semantic_prompts(&mut self) -> Vec<SemanticPrompt> {
        if self.callbacks.is_null() {
            return Vec::new();
        }
        // SAFETY: `callbacks` is live and only touched by `write`'s callbacks, which cannot be
        // running while we hold `&mut self`.
        let raw = mem::take(unsafe { &mut (*self.callbacks).prompts });
        raw.into_iter()
            .map(|p| SemanticPrompt {
                kind: p.kind,
                pin: p.pin.map(|r| self.adopt_pin(r)),
            })
            .collect()
    }

    /// Tracks the cell under the cursor.
    ///
    /// # Errors
    ///
    /// Returns [`Error::OutOfMemory`] if allocation fails.
    pub fn pin_cursor(&mut self) -> Result<PinId, Error> {
        let cursor = self.cursor();
        let raw = track(self.as_raw(), cursor.x, u32::from(cursor.y))?;
        Ok(self.adopt_pin(raw))
    }

    /// Tracks the cell at `at` in screen coordinates (row 0 = the oldest retained row) of the
    /// screen active now. The pin stays on that screen's page list (an alternate-screen pin
    /// does not move to the primary screen).
    ///
    /// # Errors
    ///
    /// [`Error::InvalidValue`] for a point outside the screen, [`Error::OutOfMemory`] if
    /// allocation fails.
    pub fn pin_at(&mut self, at: Point) -> Result<PinId, Error> {
        let raw = track_tagged(
            self.as_raw(),
            ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_SCREEN,
            at.x,
            at.y,
        )?;
        Ok(self.adopt_pin(raw))
    }

    /// Where a pin is now, in screen coordinates; `None` once its row left scrollback, or
    /// for an unknown id.
    pub fn pin_point(&self, pin: PinId) -> Option<Point> {
        let raw = self.pins.get(&pin)?;
        let mut out = ffi::GhosttyPointCoordinate::default();
        // SAFETY: the tracked reference is live (owned by `self.pins`) and `out` is valid.
        let result = unsafe {
            ffi::ghostty_tracked_grid_ref_point(
                raw.as_ptr(),
                ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_SCREEN,
                &mut out,
            )
        };
        (result == ffi::GhosttyResult_GHOSTTY_SUCCESS).then_some(Point { y: out.y, x: out.x })
    }

    /// Stops tracking a pin. Unknown ids are ignored.
    pub fn unpin(&mut self, pin: PinId) {
        if let Some(raw) = self.pins.remove(&pin) {
            // SAFETY: owned by `self.pins` until now; access is serialized by `&mut self`.
            unsafe { ffi::ghostty_tracked_grid_ref_free(raw.as_ptr()) }
        }
    }

    fn adopt_pin(&mut self, raw: NonNull<ffi::GhosttyTrackedGridRefImpl>) -> PinId {
        let id = PinId(self.next_pin);
        self.next_pin += 1;
        self.pins.insert(id, raw);
        id
    }

    /// The callback state, allocating and installing it on first use.
    fn callbacks(&mut self) -> Result<&mut Callbacks, Error> {
        if self.callbacks.is_null() {
            let new = Box::into_raw(Box::<Callbacks>::default());
            // SAFETY: the handle is live; USERDATA takes the pointer value itself, which stays
            // valid until `Drop`.
            let result = Error::check(unsafe {
                ffi::ghostty_terminal_set(
                    self.as_raw(),
                    ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_USERDATA,
                    new.cast::<c_void>().cast_const(),
                )
            });
            if let Err(err) = result {
                // SAFETY: `new` came from `Box::into_raw` above and was never handed out.
                drop(unsafe { Box::<Callbacks>::from_raw(new) });
                return Err(err);
            }
            self.callbacks = new;
        }
        // SAFETY: non-null, owned by `self`, and no callback runs while we hold `&mut self`.
        Ok(unsafe { &mut *self.callbacks })
    }

    /// Extracts the plain text of `region`, one line per row.
    ///
    /// Trailing blanks are trimmed and soft-wrapped rows stay separate lines. Styles,
    /// hyperlinks and the cursor are not included.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] for a range outside the screen and
    /// [`Error::OutOfMemory`] if allocation fails.
    pub fn text(&self, region: TextRegion) -> Result<String, Error> {
        self.format(region, Format::Plain, Wrap::Rows)
    }

    /// Extracts the plain text of `region` with soft wraps kept or joined.
    ///
    /// # Errors
    ///
    /// As for [`text`](Self::text).
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), ghostty_vt::Error> {
    /// use ghostty_vt::{Terminal, TextRegion, Wrap};
    ///
    /// let mut terminal = Terminal::new(4, 3)?;
    /// terminal.write(b"abcdef");
    /// assert_eq!(terminal.text_wrapped(TextRegion::Active, Wrap::Rows)?, "abcd\nef");
    /// assert_eq!(terminal.text_wrapped(TextRegion::Active, Wrap::Join)?, "abcdef");
    /// # Ok(())
    /// # }
    /// ```
    pub fn text_wrapped(&self, region: TextRegion, wrap: Wrap) -> Result<String, Error> {
        self.format(region, Format::Plain, wrap)
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
    /// As for [`text`](Self::text).
    pub fn vt(&self, region: TextRegion) -> Result<String, Error> {
        self.format(region, Format::Vt, Wrap::Rows)
    }

    fn format(&self, region: TextRegion, format: Format, wrap: Wrap) -> Result<String, Error> {
        let range = |start: ffi::GhosttyGridRef, end: ffi::GhosttyGridRef| ffi::GhosttySelection {
            size: mem::size_of::<ffi::GhosttySelection>(),
            start,
            end,
            rectangle: false,
        };
        let selection = match region {
            TextRegion::All => None,
            TextRegion::Active => Some(range(
                self.grid_ref(ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_ACTIVE, 0, 0)?,
                self.grid_ref(
                    ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_ACTIVE,
                    self.cols() - 1,
                    u32::from(self.rows()) - 1,
                )?,
            )),
            TextRegion::Range { start, end } => Some(range(
                self.grid_ref(
                    ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_SCREEN,
                    start.x,
                    start.y,
                )?,
                self.grid_ref(ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_SCREEN, end.x, end.y)?,
            )),
        };
        let vt = format == Format::Vt;
        let options = ffi::GhosttyFormatterTerminalOptions {
            size: mem::size_of::<ffi::GhosttyFormatterTerminalOptions>(),
            emit: match format {
                Format::Plain => ffi::GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_PLAIN,
                Format::Vt => ffi::GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_VT,
            },
            unwrap: wrap == Wrap::Join,
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

    fn grid_ref(
        &self,
        tag: ffi::GhosttyPointTag,
        x: u16,
        y: u32,
    ) -> Result<ffi::GhosttyGridRef, Error> {
        let mut grid_ref = ffi::GhosttyGridRef {
            size: mem::size_of::<ffi::GhosttyGridRef>(),
            ..Default::default()
        };
        // SAFETY: the handle is live and `grid_ref` is a valid, sized out struct.
        Error::check(unsafe {
            ffi::ghostty_terminal_grid_ref(self.as_raw(), point(tag, x, y), &mut grid_ref)
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
        for (_, raw) in self.pins.drain() {
            // SAFETY: each tracked reference is owned by `self` and freed once.
            unsafe { ffi::ghostty_tracked_grid_ref_free(raw.as_ptr()) }
        }
        // SAFETY: the handle is live and owned by `self`; nothing uses it afterwards.
        unsafe { ffi::ghostty_terminal_free(self.as_raw()) }
        if !self.callbacks.is_null() {
            // SAFETY: allocated by `callbacks`; the terminal that called into it is gone.
            let callbacks = unsafe { Box::from_raw(self.callbacks) };
            for prompt in callbacks.prompts {
                if let Some(raw) = prompt.pin {
                    // SAFETY: never adopted, so still owned here; freeing after the terminal is
                    // allowed by the tracked-reference API.
                    unsafe { ffi::ghostty_tracked_grid_ref_free(raw.as_ptr()) }
                }
            }
        }
    }
}

fn point(tag: ffi::GhosttyPointTag, x: u16, y: u32) -> ffi::GhosttyPoint {
    ffi::GhosttyPoint {
        tag,
        value: ffi::GhosttyPointValue {
            coordinate: ffi::GhosttyPointCoordinate { x, y },
        },
    }
}

/// Tracks the active-area cell `(x, y)` of `terminal`.
fn track(
    terminal: ffi::GhosttyTerminal,
    x: u16,
    y: u32,
) -> Result<NonNull<ffi::GhosttyTrackedGridRefImpl>, Error> {
    track_tagged(
        terminal,
        ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_ACTIVE,
        x,
        y,
    )
}

/// Tracks cell `(x, y)` of `terminal` in the coordinate space `tag`.
fn track_tagged(
    terminal: ffi::GhosttyTerminal,
    tag: ffi::GhosttyPointTag,
    x: u16,
    y: u32,
) -> Result<NonNull<ffi::GhosttyTrackedGridRefImpl>, Error> {
    let mut raw = ptr::null_mut();
    // SAFETY: the caller passes a live terminal with access serialized; `raw` is a valid out
    // pointer.
    Error::check(unsafe {
        ffi::ghostty_terminal_grid_ref_track(terminal, point(tag, x, y), &mut raw)
    })?;
    NonNull::new(raw).ok_or(Error::InvalidValue)
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
    // SAFETY: userdata is the `Callbacks` installed by `Terminal::callbacks`, alive for the
    // terminal's lifetime and only used from inside `write`, which holds `&mut Terminal`.
    // `data` is valid for `len` bytes for the duration of the call.
    unsafe {
        let callbacks = &mut *userdata.cast::<Callbacks>();
        if let Some(sink) = callbacks.reply.as_mut() {
            sink(slice::from_raw_parts(data, len));
        }
    }
}

unsafe extern "C" fn semantic_prompt_trampoline(
    terminal: ffi::GhosttyTerminal,
    userdata: *mut c_void,
    event: *const ffi::GhosttyTerminalSemanticPrompt,
) {
    if userdata.is_null() || event.is_null() {
        return;
    }
    // SAFETY: as for `write_pty_trampoline`; `event` and its strings are valid for the call.
    unsafe {
        let callbacks = &mut *userdata.cast::<Callbacks>();
        let event = &*event;
        let string = |s: &ffi::GhosttyString| {
            (!s.ptr.is_null() && s.len > 0)
                .then(|| String::from_utf8_lossy(slice::from_raw_parts(s.ptr, s.len)).into_owned())
        };
        let kind = match event.kind {
            ffi::GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_PROMPT_START => {
                SemanticPromptKind::PromptStart(match event.prompt_kind {
                    ffi::GhosttySemanticPromptPromptKind_GHOSTTY_SEMANTIC_PROMPT_PROMPT_RIGHT => {
                        PromptKind::Right
                    }
                    ffi::GhosttySemanticPromptPromptKind_GHOSTTY_SEMANTIC_PROMPT_PROMPT_CONTINUATION => {
                        PromptKind::Continuation
                    }
                    ffi::GhosttySemanticPromptPromptKind_GHOSTTY_SEMANTIC_PROMPT_PROMPT_SECONDARY => {
                        PromptKind::Secondary
                    }
                    _ => PromptKind::Primary,
                })
            }
            ffi::GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_INPUT_START => {
                SemanticPromptKind::InputStart
            }
            ffi::GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START => {
                SemanticPromptKind::OutputStart {
                    command: string(&event.command),
                }
            }
            ffi::GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_COMMAND_END => {
                SemanticPromptKind::CommandEnd {
                    exit: event.has_exit_code.then_some(event.exit_code),
                }
            }
            // Kinds added by a newer libghostty-vt are not ours to interpret.
            _ => return,
        };
        let mut x = 0u16;
        let mut y = 0u16;
        let have_cursor = ffi::ghostty_terminal_get(
            terminal,
            ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_X,
            (&raw mut x).cast(),
        ) == ffi::GhosttyResult_GHOSTTY_SUCCESS
            && ffi::ghostty_terminal_get(
                terminal,
                ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y,
                (&raw mut y).cast(),
            ) == ffi::GhosttyResult_GHOSTTY_SUCCESS;
        let pin = have_cursor
            .then(|| track(terminal, x, u32::from(y)).ok())
            .flatten();
        callbacks.prompts.push(RawPrompt { kind, pin });
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
        assert_eq!(terminal.total_rows(), 3);
        assert_eq!(terminal.text(TextRegion::All)?, "one\ntwo\nthree");
        assert_eq!(terminal.cursor_point(), Point { y: 2, x: 5 });
        Ok(())
    }

    #[test]
    fn ranges_and_modes() -> Result<(), Error> {
        let mut terminal = Terminal::new(10, 3)?;
        terminal.write(b"one\r\ntwo\r\nthree\r\nfour");
        let range = TextRegion::Range {
            start: Point { y: 1, x: 1 },
            end: Point { y: 2, x: 2 },
        };
        assert_eq!(terminal.text(range)?, "wo\nthr");
        assert!(!terminal.mode(Mode::BRACKETED_PASTE));
        terminal.write(b"\x1b[?2004h\x1b[?1000h\x1b[>5u");
        assert!(terminal.mode(Mode::BRACKETED_PASTE));
        assert!(terminal.mouse_tracking());
        assert_eq!(terminal.kitty_keyboard_flags(), 5);
        Ok(())
    }

    #[test]
    fn pins_follow_scrolling_and_reflow() -> Result<(), Error> {
        let mut terminal = Terminal::new(10, 3)?;
        terminal.write(b"a\r\nbb");
        let pin = terminal.pin_cursor()?;
        assert_eq!(terminal.pin_point(pin), Some(Point { y: 1, x: 2 }));
        terminal.write(b"\r\nc\r\nd\r\ne");
        assert_eq!(terminal.pin_point(pin), Some(Point { y: 1, x: 2 }));
        terminal.write(b"\x1b]7;file://h/tmp/x\x07");
        assert_eq!(terminal.pwd().as_deref(), Some("file://h/tmp/x"));
        terminal.unpin(pin);
        assert_eq!(terminal.pin_point(pin), None);
        Ok(())
    }

    #[test]
    fn semantic_prompts_carry_positions_and_exit() -> Result<(), Error> {
        let mut terminal = Terminal::new(20, 4)?;
        terminal.record_semantic_prompts()?;
        terminal.write(b"\x1b]133;A\x07$ \x1b]133;B\x07");
        terminal.write(b"echo hi\r\n\x1b]133;C\x07hi\r\n\x1b]133;D;3\x07");
        let events = terminal.take_semantic_prompts();
        let kinds: Vec<_> = events.iter().map(|e| e.kind.clone()).collect();
        assert_eq!(
            kinds,
            [
                SemanticPromptKind::PromptStart(PromptKind::Primary),
                SemanticPromptKind::InputStart,
                SemanticPromptKind::OutputStart { command: None },
                SemanticPromptKind::CommandEnd { exit: Some(3) },
            ]
        );
        let at = |i: usize| terminal.pin_point(events[i].pin.unwrap()).unwrap();
        assert_eq!(at(1), Point { y: 0, x: 2 });
        assert_eq!(at(2), Point { y: 1, x: 0 });
        assert_eq!(at(3), Point { y: 2, x: 0 });
        assert!(terminal.take_semantic_prompts().is_empty());
        Ok(())
    }
}
