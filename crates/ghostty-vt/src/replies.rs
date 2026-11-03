//! What a terminal tells programs about itself: device attributes, XTVERSION, the terminfo
//! name (XTGETTCAP `TN`), pixel sizes, its color scheme, and its default colors (OSC 4, 10,
//! 11 and 12 queries), answered as Ghostty answers them
//! (`vendor/ghostty/src/termio/stream_handler.zig`).

use std::ffi::c_void;
use std::ptr;

use ghostty_vt_sys as ffi;

use crate::{Error, Mode, Terminal};

/// Mode 2031: the program wants a report whenever the color scheme changes.
pub const COLOR_SCHEME_REPORTS: Mode = Mode::dec(2031);
/// Mode 2027: grapheme clusters take the width of the whole cluster.
pub const GRAPHEME_CLUSTERS: Mode = Mode::dec(2027);

/// A 24-bit color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    pub const fn new(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b }
    }

    fn raw(self) -> ffi::GhosttyColorRgb {
        ffi::GhosttyColorRgb {
            r: self.r,
            g: self.g,
            b: self.b,
        }
    }

    /// Relative luminance (WCAG), from 0 for black to 1 for white.
    pub fn luminance(self) -> f64 {
        let linear = |channel: u8| {
            let value = f64::from(channel) / 255.0;
            if value <= 0.03928 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * linear(self.r) + 0.7152 * linear(self.g) + 0.0722 * linear(self.b)
    }
}

/// Whether the terminal shows light text on dark or the reverse (`CSI ? 996 n`, mode 2031).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColorScheme {
    Light,
    Dark,
}

impl ColorScheme {
    /// The scheme of a theme with this background.
    pub fn of_background(background: Rgb) -> Self {
        if background.luminance() > 0.5 {
            Self::Light
        } else {
            Self::Dark
        }
    }

    fn raw(self) -> ffi::GhosttyColorScheme {
        match self {
            Self::Light => ffi::GhosttyColorScheme_GHOSTTY_COLOR_SCHEME_LIGHT,
            Self::Dark => ffi::GhosttyColorScheme_GHOSTTY_COLOR_SCHEME_DARK,
        }
    }

    /// The unsolicited report sent while mode 2031 is set: `CSI ? 997 ; 1 n` for dark,
    /// `CSI ? 997 ; 2 n` for light.
    pub fn report(self) -> Vec<u8> {
        match self {
            Self::Dark => b"\x1b[?997;1n".to_vec(),
            Self::Light => b"\x1b[?997;2n".to_vec(),
        }
    }
}

/// The colors a theme gives the terminal: what color queries are answered with and what
/// programs' color resets go back to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefaultColors {
    pub foreground: Rgb,
    pub background: Rgb,
    /// `None`: the cursor takes the foreground color.
    pub cursor: Option<Rgb>,
    /// All 256 palette colors; `None` keeps the built-in palette (Ghostty's default).
    pub palette: Option<Box<[Rgb; 256]>>,
}

impl Default for DefaultColors {
    /// Ghostty's default theme.
    fn default() -> Self {
        Self {
            foreground: Rgb::new(0xff, 0xff, 0xff),
            background: Rgb::new(0x28, 0x2c, 0x34),
            cursor: None,
            palette: None,
        }
    }
}

impl DefaultColors {
    pub fn scheme(&self) -> ColorScheme {
        ColorScheme::of_background(self.background)
    }
}

/// How the terminal names itself to programs that ask.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    /// The XTVERSION reply (`CSI > q`), such as `ghostty 1.4.0`.
    pub xtversion: String,
    /// The terminfo entry programs run under (`TERM`), reported for XTGETTCAP `TN`.
    pub terminfo: String,
}

/// Reply data the C callbacks read.
#[derive(Debug, Default)]
pub(crate) struct ReplyState {
    xtversion: Vec<u8>,
    scheme: Option<ColorScheme>,
}

impl Terminal {
    /// Answers the queries a terminal emulator answers and libghostty-vt leaves to its host,
    /// the way Ghostty does: primary and secondary device attributes (a VT220 with color and
    /// clipboard access), tertiary ones, XTVERSION, XTGETTCAP `TN`, the pixel and cell size
    /// reports (`CSI 14/16/18 t`, mode 2048), the color scheme (`CSI ? 996 n`, once
    /// [`set_default_colors`](Self::set_default_colors) gave one) and whether program status
    /// reports are understood (`OSC 7501 ; ?`; the reports themselves are left to the caller,
    /// which reads them from the byte stream). Grapheme clustering
    /// (mode 2027) becomes the default, as Ghostty's `grapheme-width-method = unicode` makes it.
    ///
    /// Replies go to the [reply sink](Self::set_reply_sink).
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] for a terminfo name longer than 128 bytes.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), ghostty_vt::Error> {
    /// use std::sync::{Arc, Mutex};
    /// use ghostty_vt::{Identity, Terminal};
    ///
    /// let replies = Arc::new(Mutex::new(Vec::new()));
    /// let sink = Arc::clone(&replies);
    /// let mut terminal = Terminal::new(80, 24)?;
    /// terminal.set_reply_sink(Box::new(move |reply| sink.lock().unwrap().extend_from_slice(reply)))?;
    /// terminal.answer_queries(&Identity { xtversion: "demo 1.0".into(), terminfo: "xterm-256color".into() })?;
    /// terminal.write(b"\x1b[c\x1b[>q");
    /// assert_eq!(&*replies.lock().unwrap(), b"\x1b[?62;22;52c\x1bP>|demo 1.0\x1b\\");
    /// # Ok(())
    /// # }
    /// ```
    pub fn answer_queries(&mut self, identity: &Identity) -> Result<(), Error> {
        let terminfo = ffi::GhosttyString {
            ptr: identity.terminfo.as_ptr(),
            len: identity.terminfo.len(),
        };
        // SAFETY: TERMINFO_NAME takes a `GhosttyString *` whose bytes are copied in the call.
        Error::check(unsafe {
            ffi::ghostty_terminal_set(
                self.as_raw(),
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_TERMINFO_NAME,
                (&raw const terminfo).cast(),
            )
        })?;
        self.callbacks()?.replies.xtversion = identity.xtversion.clone().into_bytes();
        let xtversion: ffi::GhosttyTerminalXtversionFn = Some(xtversion_trampoline);
        let attributes: ffi::GhosttyTerminalDeviceAttributesFn = Some(device_attributes_trampoline);
        let size: ffi::GhosttyTerminalSizeFn = Some(size_trampoline);
        let scheme: ffi::GhosttyTerminalColorSchemeFn = Some(color_scheme_trampoline);
        let status: ffi::GhosttyTerminalProgramStatusFn = Some(program_status_trampoline);
        for (option, callback) in [
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_XTVERSION,
                xtversion.map(|function| function as *const c_void),
            ),
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                attributes.map(|function| function as *const c_void),
            ),
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SIZE,
                size.map(|function| function as *const c_void),
            ),
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,
                scheme.map(|function| function as *const c_void),
            ),
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
                status.map(|function| function as *const c_void),
            ),
        ] {
            // SAFETY: each option takes its callback's function pointer as the value, and the
            // callbacks only reach the `Callbacks` installed above.
            Error::check(unsafe {
                ffi::ghostty_terminal_set(self.as_raw(), option, callback.unwrap_or(ptr::null()))
            })?;
        }
        self.set_mode_default(GRAPHEME_CLUSTERS, true)
    }

    /// Makes `value` what `mode` resets to (RIS) and its current value.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] for a mode that cannot have a default.
    pub fn set_mode_default(&mut self, mode: Mode, value: bool) -> Result<(), Error> {
        let config = ffi::GhosttyTerminalModeConfig {
            mode: mode.raw(),
            value,
        };
        // SAFETY: MODE_DEFAULT reads a `GhosttyTerminalModeConfig` during the call.
        Error::check(unsafe {
            ffi::ghostty_terminal_set(
                self.as_raw(),
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_MODE_DEFAULT,
                (&raw const config).cast(),
            )
        })
    }

    /// Sets the colors color queries are answered with and color resets return to. A program
    /// that asked for color scheme reports (mode 2031) gets one through the reply sink when
    /// the scheme changes.
    ///
    /// # Errors
    ///
    /// Returns an error if libghostty-vt rejects a color option.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), ghostty_vt::Error> {
    /// use std::sync::{Arc, Mutex};
    /// use ghostty_vt::{DefaultColors, Rgb, Terminal};
    ///
    /// let replies = Arc::new(Mutex::new(Vec::new()));
    /// let sink = Arc::clone(&replies);
    /// let mut terminal = Terminal::new(80, 24)?;
    /// terminal.set_reply_sink(Box::new(move |reply| sink.lock().unwrap().extend_from_slice(reply)))?;
    /// terminal.set_default_colors(&DefaultColors {
    ///     background: Rgb::new(0xfa, 0xfa, 0xfa),
    ///     ..DefaultColors::default()
    /// })?;
    /// terminal.write(b"\x1b]11;?\x1b\\");
    /// assert_eq!(&*replies.lock().unwrap(), b"\x1b]11;rgb:fafa/fafa/fafa\x1b\\");
    /// # Ok(())
    /// # }
    /// ```
    pub fn set_default_colors(&mut self, colors: &DefaultColors) -> Result<(), Error> {
        let foreground = colors.foreground.raw();
        let background = colors.background.raw();
        let cursor = colors.cursor.map(Rgb::raw);
        let palette = colors.palette.as_ref().map(|palette| palette.map(Rgb::raw));
        let options: [(ffi::GhosttyTerminalOption, *const c_void); 4] = [
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
                (&raw const foreground).cast(),
            ),
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
                (&raw const background).cast(),
            ),
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_COLOR_CURSOR,
                cursor
                    .as_ref()
                    .map_or(ptr::null(), |cursor| ptr::from_ref(cursor).cast()),
            ),
            (
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
                palette
                    .as_ref()
                    .map_or(ptr::null(), |palette| ptr::from_ref(palette).cast()),
            ),
        ];
        for (option, value) in options {
            // SAFETY: each color option reads a `GhosttyColorRgb` (the palette an array of 256)
            // during the call; NULL clears the cursor color and restores the built-in palette.
            Error::check(unsafe { ffi::ghostty_terminal_set(self.as_raw(), option, value) })?;
        }
        let scheme = colors.scheme();
        let previous = self.callbacks()?.replies.scheme.replace(scheme);
        if previous.is_some_and(|previous| previous != scheme) && self.mode(COLOR_SCHEME_REPORTS) {
            self.reply(&scheme.report())?;
        }
        Ok(())
    }

    /// The color scheme last set with [`set_default_colors`](Self::set_default_colors).
    pub fn color_scheme(&self) -> Option<ColorScheme> {
        self.replies().and_then(|replies| replies.scheme)
    }
}

/// Reads the reply state behind a callback's userdata.
///
/// # Safety
///
/// `userdata` must be null or the terminal's `Callbacks`, and the call must come from inside
/// `ghostty_terminal_vt_write` on that terminal.
unsafe fn reply_state<'a>(userdata: *mut c_void) -> Option<&'a ReplyState> {
    // SAFETY: per the contract above.
    (!userdata.is_null())
        .then(|| unsafe { &(*userdata.cast::<crate::terminal::Callbacks>()).replies })
}

unsafe extern "C" fn xtversion_trampoline(
    _terminal: ffi::GhosttyTerminal,
    userdata: *mut c_void,
) -> ffi::GhosttyString {
    // SAFETY: libghostty-vt passes the userdata installed by `Terminal::callbacks`; the
    // returned bytes live in it until the terminal is dropped, past the callback's return.
    match unsafe { reply_state(userdata) } {
        Some(state) => ffi::GhosttyString {
            ptr: state.xtversion.as_ptr(),
            len: state.xtversion.len(),
        },
        None => ffi::GhosttyString {
            ptr: ptr::null(),
            len: 0,
        },
    }
}

unsafe extern "C" fn device_attributes_trampoline(
    _terminal: ffi::GhosttyTerminal,
    _userdata: *mut c_void,
    out: *mut ffi::GhosttyDeviceAttributes,
) -> bool {
    if out.is_null() {
        return false;
    }
    let mut attributes = ffi::GhosttyDeviceAttributes::default();
    // Level 2 conformance (VT220), color text, clipboard access.
    attributes.primary.conformance_level = 62;
    attributes.primary.features[..2].copy_from_slice(&[22, 52]);
    attributes.primary.num_features = 2;
    attributes.secondary = ffi::GhosttyDeviceAttributesSecondary {
        device_type: 1,
        firmware_version: 10,
        rom_cartridge: 0,
    };
    // SAFETY: `out` is valid for one write, per the callback's contract.
    unsafe { out.write(attributes) };
    true
}

unsafe extern "C" fn size_trampoline(
    terminal: ffi::GhosttyTerminal,
    _userdata: *mut c_void,
    out: *mut ffi::GhosttySizeReportSize,
) -> bool {
    if out.is_null() || terminal.is_null() {
        return false;
    }
    let read = |data: ffi::GhosttyTerminalData, value: *mut c_void| {
        // SAFETY: the terminal is live for the callback, these getters only read, and `value`
        // has the type each one documents (`uint16_t` for cells, `uint32_t` for pixels).
        unsafe {
            ffi::ghostty_terminal_get(terminal, data, value) == ffi::GhosttyResult_GHOSTTY_SUCCESS
        }
    };
    let (mut cols, mut rows, mut width, mut height) = (0u16, 0u16, 0u32, 0u32);
    let complete = read(
        ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS,
        (&raw mut cols).cast(),
    ) && read(
        ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS,
        (&raw mut rows).cast(),
    ) && read(
        ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_WIDTH_PX,
        (&raw mut width).cast(),
    ) && read(
        ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_HEIGHT_PX,
        (&raw mut height).cast(),
    );
    if !complete || cols == 0 || rows == 0 {
        return false;
    }
    // SAFETY: `out` is valid for one write, per the callback's contract.
    unsafe {
        out.write(ffi::GhosttySizeReportSize {
            rows,
            columns: cols,
            cell_width: width / u32::from(cols),
            cell_height: height / u32::from(rows),
        });
    }
    true
}

unsafe extern "C" fn color_scheme_trampoline(
    _terminal: ffi::GhosttyTerminal,
    userdata: *mut c_void,
    out: *mut ffi::GhosttyColorScheme,
) -> bool {
    // SAFETY: as in `xtversion_trampoline`.
    let Some(scheme) = (unsafe { reply_state(userdata) }).and_then(|state| state.scheme) else {
        return false;
    };
    if out.is_null() {
        return false;
    }
    // SAFETY: `out` is valid for one write, per the callback's contract.
    unsafe { out.write(scheme.raw()) };
    true
}

unsafe extern "C" fn program_status_trampoline(
    _terminal: ffi::GhosttyTerminal,
    _userdata: *mut c_void,
    _report: *const ffi::GhosttyTerminalProgramStatus,
) {
}
