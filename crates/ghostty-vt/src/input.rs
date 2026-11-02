//! Encoding user input for the program in a terminal: keys, mouse and paste.
//!
//! The encoders read the terminal's current modes (cursor-key and keypad application modes,
//! modifyOtherKeys, kitty keyboard flags, mouse tracking and format, bracketed paste), so the
//! same event produces whatever the running program asked for.

use std::ffi::c_char;
use std::ptr::{self, NonNull};

use ghostty_vt_sys as ffi;

use crate::{Error, Mode, Terminal};

macro_rules! keys {
    ($($name:ident = $raw:ident),* $(,)?) => {
        impl Key {
            $(
                #[doc = concat!("`", stringify!($raw), "`.")]
                pub const $name: Self = Self(ffi::$raw as u32);
            )*
        }
    };
}

/// A physical key, as libghostty-vt's `GhosttyKey` numbers it (W3C `code` names, US layout
/// positions). Any `GhosttyKey` value works; the constants name the common ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Key(pub u32);

keys!(
    A = GhosttyKey_GHOSTTY_KEY_A,
    B = GhosttyKey_GHOSTTY_KEY_B,
    C = GhosttyKey_GHOSTTY_KEY_C,
    D = GhosttyKey_GHOSTTY_KEY_D,
    E = GhosttyKey_GHOSTTY_KEY_E,
    F = GhosttyKey_GHOSTTY_KEY_F,
    G = GhosttyKey_GHOSTTY_KEY_G,
    H = GhosttyKey_GHOSTTY_KEY_H,
    I = GhosttyKey_GHOSTTY_KEY_I,
    J = GhosttyKey_GHOSTTY_KEY_J,
    K = GhosttyKey_GHOSTTY_KEY_K,
    L = GhosttyKey_GHOSTTY_KEY_L,
    M = GhosttyKey_GHOSTTY_KEY_M,
    N = GhosttyKey_GHOSTTY_KEY_N,
    O = GhosttyKey_GHOSTTY_KEY_O,
    P = GhosttyKey_GHOSTTY_KEY_P,
    Q = GhosttyKey_GHOSTTY_KEY_Q,
    R = GhosttyKey_GHOSTTY_KEY_R,
    S = GhosttyKey_GHOSTTY_KEY_S,
    T = GhosttyKey_GHOSTTY_KEY_T,
    U = GhosttyKey_GHOSTTY_KEY_U,
    V = GhosttyKey_GHOSTTY_KEY_V,
    W = GhosttyKey_GHOSTTY_KEY_W,
    X = GhosttyKey_GHOSTTY_KEY_X,
    Y = GhosttyKey_GHOSTTY_KEY_Y,
    Z = GhosttyKey_GHOSTTY_KEY_Z,
    DIGIT_0 = GhosttyKey_GHOSTTY_KEY_DIGIT_0,
    DIGIT_1 = GhosttyKey_GHOSTTY_KEY_DIGIT_1,
    DIGIT_2 = GhosttyKey_GHOSTTY_KEY_DIGIT_2,
    DIGIT_3 = GhosttyKey_GHOSTTY_KEY_DIGIT_3,
    DIGIT_4 = GhosttyKey_GHOSTTY_KEY_DIGIT_4,
    DIGIT_5 = GhosttyKey_GHOSTTY_KEY_DIGIT_5,
    DIGIT_6 = GhosttyKey_GHOSTTY_KEY_DIGIT_6,
    DIGIT_7 = GhosttyKey_GHOSTTY_KEY_DIGIT_7,
    DIGIT_8 = GhosttyKey_GHOSTTY_KEY_DIGIT_8,
    DIGIT_9 = GhosttyKey_GHOSTTY_KEY_DIGIT_9,
    BACKQUOTE = GhosttyKey_GHOSTTY_KEY_BACKQUOTE,
    BACKSLASH = GhosttyKey_GHOSTTY_KEY_BACKSLASH,
    BRACKET_LEFT = GhosttyKey_GHOSTTY_KEY_BRACKET_LEFT,
    BRACKET_RIGHT = GhosttyKey_GHOSTTY_KEY_BRACKET_RIGHT,
    COMMA = GhosttyKey_GHOSTTY_KEY_COMMA,
    EQUAL = GhosttyKey_GHOSTTY_KEY_EQUAL,
    MINUS = GhosttyKey_GHOSTTY_KEY_MINUS,
    PERIOD = GhosttyKey_GHOSTTY_KEY_PERIOD,
    QUOTE = GhosttyKey_GHOSTTY_KEY_QUOTE,
    SEMICOLON = GhosttyKey_GHOSTTY_KEY_SEMICOLON,
    SLASH = GhosttyKey_GHOSTTY_KEY_SLASH,
    SPACE = GhosttyKey_GHOSTTY_KEY_SPACE,
    ENTER = GhosttyKey_GHOSTTY_KEY_ENTER,
    TAB = GhosttyKey_GHOSTTY_KEY_TAB,
    BACKSPACE = GhosttyKey_GHOSTTY_KEY_BACKSPACE,
    ESCAPE = GhosttyKey_GHOSTTY_KEY_ESCAPE,
    DELETE = GhosttyKey_GHOSTTY_KEY_DELETE,
    INSERT = GhosttyKey_GHOSTTY_KEY_INSERT,
    HOME = GhosttyKey_GHOSTTY_KEY_HOME,
    END = GhosttyKey_GHOSTTY_KEY_END,
    PAGE_UP = GhosttyKey_GHOSTTY_KEY_PAGE_UP,
    PAGE_DOWN = GhosttyKey_GHOSTTY_KEY_PAGE_DOWN,
    ARROW_UP = GhosttyKey_GHOSTTY_KEY_ARROW_UP,
    ARROW_DOWN = GhosttyKey_GHOSTTY_KEY_ARROW_DOWN,
    ARROW_LEFT = GhosttyKey_GHOSTTY_KEY_ARROW_LEFT,
    ARROW_RIGHT = GhosttyKey_GHOSTTY_KEY_ARROW_RIGHT,
    F1 = GhosttyKey_GHOSTTY_KEY_F1,
    F2 = GhosttyKey_GHOSTTY_KEY_F2,
    F3 = GhosttyKey_GHOSTTY_KEY_F3,
    F4 = GhosttyKey_GHOSTTY_KEY_F4,
    F5 = GhosttyKey_GHOSTTY_KEY_F5,
    F6 = GhosttyKey_GHOSTTY_KEY_F6,
    F7 = GhosttyKey_GHOSTTY_KEY_F7,
    F8 = GhosttyKey_GHOSTTY_KEY_F8,
    F9 = GhosttyKey_GHOSTTY_KEY_F9,
    F10 = GhosttyKey_GHOSTTY_KEY_F10,
    F11 = GhosttyKey_GHOSTTY_KEY_F11,
    F12 = GhosttyKey_GHOSTTY_KEY_F12,
    SHIFT_LEFT = GhosttyKey_GHOSTTY_KEY_SHIFT_LEFT,
    SHIFT_RIGHT = GhosttyKey_GHOSTTY_KEY_SHIFT_RIGHT,
    CONTROL_LEFT = GhosttyKey_GHOSTTY_KEY_CONTROL_LEFT,
    CONTROL_RIGHT = GhosttyKey_GHOSTTY_KEY_CONTROL_RIGHT,
    ALT_LEFT = GhosttyKey_GHOSTTY_KEY_ALT_LEFT,
    ALT_RIGHT = GhosttyKey_GHOSTTY_KEY_ALT_RIGHT,
    META_LEFT = GhosttyKey_GHOSTTY_KEY_META_LEFT,
    META_RIGHT = GhosttyKey_GHOSTTY_KEY_META_RIGHT,
    NUMPAD_0 = GhosttyKey_GHOSTTY_KEY_NUMPAD_0,
    NUMPAD_1 = GhosttyKey_GHOSTTY_KEY_NUMPAD_1,
    NUMPAD_ENTER = GhosttyKey_GHOSTTY_KEY_NUMPAD_ENTER,
);

/// Modifier keys, in libghostty-vt's `GhosttyMods` bit layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Mods(pub u16);

impl Mods {
    pub const NONE: Self = Self(0);
    pub const SHIFT: Self = Self(1 << 0);
    pub const CTRL: Self = Self(1 << 1);
    /// Alt / Option.
    pub const ALT: Self = Self(1 << 2);
    /// Super / Command.
    pub const SUPER: Self = Self(1 << 3);
    /// Caps Lock is on.
    pub const CAPS_LOCK: Self = Self(1 << 4);
    /// Num Lock is on.
    pub const NUM_LOCK: Self = Self(1 << 5);
}

impl std::ops::BitOr for Mods {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

/// Whether a key went down, repeats or went up.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum KeyAction {
    /// Key pressed.
    #[default]
    Press,
    /// Auto-repeat.
    Repeat,
    /// Key released (only reported when the kitty protocol asks for release events).
    Release,
}

/// A key event to encode.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct KeyEvent {
    /// The physical key.
    pub key: Option<Key>,
    /// Modifiers held.
    pub mods: Mods,
    /// Modifiers the keyboard layout used up to produce `text`.
    pub consumed_mods: Mods,
    /// Press, repeat or release.
    pub action: KeyAction,
    /// Text the key produced under the current layout.
    pub text: Option<String>,
    /// The codepoint of the key with no modifiers (kitty's base key).
    pub unshifted: Option<char>,
    /// An input method is composing; such events encode to nothing.
    pub composing: bool,
}

/// Encodes key events for a terminal's current keyboard modes.
///
/// # Examples
///
/// ```
/// # fn main() -> Result<(), ghostty_vt::Error> {
/// use ghostty_vt::{Key, KeyEncoder, KeyEvent, Terminal};
///
/// let mut terminal = Terminal::new(80, 24)?;
/// let mut encoder = KeyEncoder::new()?;
/// let up = KeyEvent { key: Some(Key::ARROW_UP), ..KeyEvent::default() };
/// assert_eq!(encoder.encode(&terminal, &up)?, b"\x1b[A");
/// terminal.write(b"\x1b[?1h"); // application cursor keys, as vim and less ask for
/// assert_eq!(encoder.encode(&terminal, &up)?, b"\x1bOA");
/// # Ok(())
/// # }
/// ```
#[derive(Debug)]
pub struct KeyEncoder {
    encoder: NonNull<ffi::GhosttyKeyEncoderImpl>,
    event: NonNull<ffi::GhosttyKeyEventImpl>,
}

// SAFETY: both handles own plain heap state with no thread affinity; `KeyEncoder` is not
// `Sync`, so calls on it stay serialized.
unsafe impl Send for KeyEncoder {}

impl KeyEncoder {
    /// Creates an encoder.
    ///
    /// # Errors
    ///
    /// Returns [`Error::OutOfMemory`] if allocation fails.
    pub fn new() -> Result<Self, Error> {
        let mut encoder = ptr::null_mut();
        // SAFETY: valid out pointer; null selects the default allocator.
        Error::check(unsafe { ffi::ghostty_key_encoder_new(ptr::null(), &mut encoder) })?;
        let encoder = NonNull::new(encoder).ok_or(Error::InvalidValue)?;
        let mut event = ptr::null_mut();
        // SAFETY: as above.
        let result = Error::check(unsafe { ffi::ghostty_key_event_new(ptr::null(), &mut event) });
        let Some(event) = result.ok().and_then(|()| NonNull::new(event)) else {
            // SAFETY: created above and not shared.
            unsafe { ffi::ghostty_key_encoder_free(encoder.as_ptr()) };
            return Err(result.err().unwrap_or(Error::InvalidValue));
        };
        Ok(Self { encoder, event })
    }

    /// Encodes `event` for `terminal`'s current modes. An empty result means the event sends
    /// nothing (a bare modifier, a release outside the kitty protocol, IME composition).
    ///
    /// # Errors
    ///
    /// Returns an error if libghostty-vt fails to encode.
    pub fn encode(&mut self, terminal: &Terminal, event: &KeyEvent) -> Result<Vec<u8>, Error> {
        let raw = self.event.as_ptr();
        // libghostty-vt wants the layout's printable text only; control characters must come
        // from the key and modifiers instead.
        let text = event
            .text
            .as_deref()
            .filter(|text| !text.chars().any(char::is_control))
            .unwrap_or("");
        // SAFETY: the handles are live; the terminal is only read, and `&Terminal` keeps it
        // from being mutated meanwhile. The event borrows the UTF-8 text without copying it;
        // `text` outlives the encode below and the borrow is cleared right after.
        unsafe {
            ffi::ghostty_key_encoder_setopt_from_terminal(self.encoder.as_ptr(), terminal.as_raw());
            ffi::ghostty_key_event_set_key(
                raw,
                event.key.map_or(0, |key| key.0 as ffi::GhosttyKey),
            );
            ffi::ghostty_key_event_set_mods(raw, event.mods.0);
            ffi::ghostty_key_event_set_consumed_mods(raw, event.consumed_mods.0);
            ffi::ghostty_key_event_set_action(
                raw,
                match event.action {
                    KeyAction::Press => ffi::GhosttyKeyAction_GHOSTTY_KEY_ACTION_PRESS,
                    KeyAction::Repeat => ffi::GhosttyKeyAction_GHOSTTY_KEY_ACTION_REPEAT,
                    KeyAction::Release => ffi::GhosttyKeyAction_GHOSTTY_KEY_ACTION_RELEASE,
                },
            );
            ffi::ghostty_key_event_set_composing(raw, event.composing);
            ffi::ghostty_key_event_set_unshifted_codepoint(
                raw,
                event.unshifted.map_or(0, u32::from),
            );
            ffi::ghostty_key_event_set_utf8(raw, text.as_ptr().cast::<c_char>(), text.len());
        }
        let result = encode_into(|buffer, capacity, written| {
            // SAFETY: live handles; `buffer` is valid for `capacity` bytes (or null with 0).
            unsafe {
                ffi::ghostty_key_encoder_encode(
                    self.encoder.as_ptr(),
                    raw,
                    buffer,
                    capacity,
                    written,
                )
            }
        });
        // Do not keep a pointer to `text` past this call.
        // SAFETY: the event is live; an empty slice clears the borrowed text.
        unsafe { ffi::ghostty_key_event_set_utf8(raw, ptr::null(), 0) };
        result
    }
}

impl Drop for KeyEncoder {
    fn drop(&mut self) {
        // SAFETY: both handles are owned by `self` and freed once.
        unsafe {
            ffi::ghostty_key_event_free(self.event.as_ptr());
            ffi::ghostty_key_encoder_free(self.encoder.as_ptr());
        }
    }
}

/// Runs a libghostty-vt "encode into a buffer" call, growing the buffer on `OUT_OF_SPACE`.
fn encode_into(
    mut call: impl FnMut(*mut c_char, usize, *mut usize) -> ffi::GhosttyResult,
) -> Result<Vec<u8>, Error> {
    let mut buffer = vec![0u8; 64];
    loop {
        let mut len = 0usize;
        let result = call(buffer.as_mut_ptr().cast(), buffer.len(), &mut len);
        if result == ffi::GhosttyResult_GHOSTTY_OUT_OF_SPACE && len > buffer.len() {
            buffer.resize(len, 0);
            continue;
        }
        Error::check(result)?;
        buffer.truncate(len);
        return Ok(buffer);
    }
}

/// What a mouse event does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MouseAction {
    /// A button went down.
    Press,
    /// A button went up.
    Release,
    /// The pointer moved.
    Motion,
}

/// A mouse button; wheels are buttons 4–7 as in X11.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MouseButton {
    /// Primary.
    Left,
    /// Middle.
    Middle,
    /// Secondary.
    Right,
    /// Wheel up (button 4).
    WheelUp,
    /// Wheel down (button 5).
    WheelDown,
    /// Wheel left (button 6).
    WheelLeft,
    /// Wheel right (button 7).
    WheelRight,
}

impl MouseButton {
    fn raw(self) -> ffi::GhosttyMouseButton {
        match self {
            Self::Left => ffi::GhosttyMouseButton_GHOSTTY_MOUSE_BUTTON_LEFT,
            Self::Middle => ffi::GhosttyMouseButton_GHOSTTY_MOUSE_BUTTON_MIDDLE,
            Self::Right => ffi::GhosttyMouseButton_GHOSTTY_MOUSE_BUTTON_RIGHT,
            Self::WheelUp => ffi::GhosttyMouseButton_GHOSTTY_MOUSE_BUTTON_FOUR,
            Self::WheelDown => ffi::GhosttyMouseButton_GHOSTTY_MOUSE_BUTTON_FIVE,
            Self::WheelLeft => ffi::GhosttyMouseButton_GHOSTTY_MOUSE_BUTTON_SIX,
            Self::WheelRight => ffi::GhosttyMouseButton_GHOSTTY_MOUSE_BUTTON_SEVEN,
        }
    }

    fn is_wheel(self) -> bool {
        !matches!(self, Self::Left | Self::Middle | Self::Right)
    }
}

/// A mouse event in cell coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MouseEvent {
    pub action: MouseAction,
    /// The button, `None` for motion with no button held.
    pub button: Option<MouseButton>,
    /// Column, from 0.
    pub col: u16,
    /// Row within the visible area, from 0.
    pub row: u16,
    /// Modifiers held.
    pub mods: Mods,
}

/// Encodes mouse events for a terminal's current tracking mode and format.
///
/// The encoder remembers which buttons are held (button-event tracking reports motion only
/// while one is) and the last reported cell (motion within one cell is reported once), so keep
/// one per terminal.
///
/// # Examples
///
/// ```
/// # fn main() -> Result<(), ghostty_vt::Error> {
/// use ghostty_vt::{Mods, MouseAction, MouseButton, MouseEncoder, MouseEvent, Terminal};
///
/// let mut terminal = Terminal::new(80, 24)?;
/// let mut encoder = MouseEncoder::new()?;
/// let click = MouseEvent {
///     action: MouseAction::Press,
///     button: Some(MouseButton::Left),
///     col: 4,
///     row: 2,
///     mods: Mods::NONE,
/// };
/// assert!(encoder.encode(&terminal, &click, (0, 0))?.is_empty()); // no tracking yet
/// terminal.write(b"\x1b[?1000h\x1b[?1006h");
/// assert_eq!(encoder.encode(&terminal, &click, (0, 0))?, b"\x1b[<0;5;3M");
/// # Ok(())
/// # }
/// ```
#[derive(Debug)]
pub struct MouseEncoder {
    encoder: NonNull<ffi::GhosttyMouseEncoderImpl>,
    event: NonNull<ffi::GhosttyMouseEventImpl>,
    held: u8,
}

// SAFETY: as for `KeyEncoder`.
unsafe impl Send for MouseEncoder {}

impl MouseEncoder {
    /// Creates an encoder.
    ///
    /// # Errors
    ///
    /// Returns [`Error::OutOfMemory`] if allocation fails.
    pub fn new() -> Result<Self, Error> {
        let mut encoder = ptr::null_mut();
        // SAFETY: valid out pointer; null selects the default allocator.
        Error::check(unsafe { ffi::ghostty_mouse_encoder_new(ptr::null(), &mut encoder) })?;
        let encoder = NonNull::new(encoder).ok_or(Error::InvalidValue)?;
        let mut event = ptr::null_mut();
        // SAFETY: as above.
        let result = Error::check(unsafe { ffi::ghostty_mouse_event_new(ptr::null(), &mut event) });
        let Some(event) = result.ok().and_then(|()| NonNull::new(event)) else {
            // SAFETY: created above and not shared.
            unsafe { ffi::ghostty_mouse_encoder_free(encoder.as_ptr()) };
            return Err(result.err().unwrap_or(Error::InvalidValue));
        };
        let track = true;
        // SAFETY: TRACK_LAST_CELL takes a `bool`.
        unsafe {
            ffi::ghostty_mouse_encoder_setopt(
                encoder.as_ptr(),
                ffi::GhosttyMouseEncoderOption_GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL,
                (&raw const track).cast(),
            );
        }
        Ok(Self {
            encoder,
            event,
            held: 0,
        })
    }

    /// Encodes `event` for `terminal`'s current mouse modes. `cell_px` is the client's cell
    /// size in pixels, used by the SGR-pixels format; `(0, 0)` reports cell positions there.
    /// An empty result means the program did not ask for this kind of event.
    ///
    /// # Errors
    ///
    /// Returns an error if libghostty-vt fails to encode.
    pub fn encode(
        &mut self,
        terminal: &Terminal,
        event: &MouseEvent,
        cell_px: (u16, u16),
    ) -> Result<Vec<u8>, Error> {
        let (cell_width, cell_height) = (u32::from(cell_px.0.max(1)), u32::from(cell_px.1.max(1)));
        let size = ffi::GhosttyMouseEncoderSize {
            size: std::mem::size_of::<ffi::GhosttyMouseEncoderSize>(),
            screen_width: u32::from(terminal.cols()) * cell_width,
            screen_height: u32::from(terminal.rows()) * cell_height,
            cell_width,
            cell_height,
            ..Default::default()
        };
        if let Some(button) = event.button.filter(|button| !button.is_wheel()) {
            let bit = 1 << button.raw();
            match event.action {
                MouseAction::Press => self.held |= bit,
                MouseAction::Release => self.held &= !bit,
                MouseAction::Motion => {}
            }
        }
        let any_pressed = self.held != 0;
        let raw = self.event.as_ptr();
        // SAFETY: live handles; option values match their documented types and are read
        // before each call returns. The terminal is only read.
        unsafe {
            let encoder = self.encoder.as_ptr();
            ffi::ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal.as_raw());
            ffi::ghostty_mouse_encoder_setopt(
                encoder,
                ffi::GhosttyMouseEncoderOption_GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                (&raw const size).cast(),
            );
            ffi::ghostty_mouse_encoder_setopt(
                encoder,
                ffi::GhosttyMouseEncoderOption_GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                (&raw const any_pressed).cast(),
            );
            ffi::ghostty_mouse_event_set_action(
                raw,
                match event.action {
                    MouseAction::Press => ffi::GhosttyMouseAction_GHOSTTY_MOUSE_ACTION_PRESS,
                    MouseAction::Release => ffi::GhosttyMouseAction_GHOSTTY_MOUSE_ACTION_RELEASE,
                    MouseAction::Motion => ffi::GhosttyMouseAction_GHOSTTY_MOUSE_ACTION_MOTION,
                },
            );
            match event.button {
                Some(button) => ffi::ghostty_mouse_event_set_button(raw, button.raw()),
                None => ffi::ghostty_mouse_event_clear_button(raw),
            }
            ffi::ghostty_mouse_event_set_mods(raw, event.mods.0);
            // The centre of the cell, so rounding never lands on a neighbour.
            ffi::ghostty_mouse_event_set_position(
                raw,
                ffi::GhosttyMousePosition {
                    x: (f32::from(event.col) + 0.5) * cell_width as f32,
                    y: (f32::from(event.row) + 0.5) * cell_height as f32,
                },
            );
        }
        encode_into(|buffer, capacity, written| {
            // SAFETY: live handles; `buffer` is valid for `capacity` bytes.
            unsafe {
                ffi::ghostty_mouse_encoder_encode(
                    self.encoder.as_ptr(),
                    raw,
                    buffer,
                    capacity,
                    written,
                )
            }
        })
    }
}

impl Drop for MouseEncoder {
    fn drop(&mut self) {
        // SAFETY: both handles are owned by `self` and freed once.
        unsafe {
            ffi::ghostty_mouse_event_free(self.event.as_ptr());
            ffi::ghostty_mouse_encoder_free(self.encoder.as_ptr());
        }
    }
}

/// Encodes pasted text for writing to the program, following Ghostty's paste rules.
///
/// Control bytes that could escape the paste (ESC, NUL, DEL and other C0 controls besides tab
/// and line breaks) become spaces, so an embedded `ESC [201~` can no longer end a bracketed
/// paste early. With `bracketed` the text is wrapped in `ESC [200~` … `ESC [201~`; without it,
/// line feeds become carriage returns, as typed Enter keys would be.
///
/// Whether multi-line text should be pasted unbracketed at all is the caller's decision; see
/// [`paste_is_safe`].
///
/// # Examples
///
/// ```
/// use ghostty_vt::encode_paste;
///
/// assert_eq!(encode_paste("a\x1b[201~b", true), b"\x1b[200~a [201~b\x1b[201~");
/// assert_eq!(encode_paste("ls\nwc", false), b"ls\rwc");
/// ```
pub fn encode_paste(text: &str, bracketed: bool) -> Vec<u8> {
    let mut data = text.as_bytes().to_vec();
    let result = encode_into(|buffer, capacity, written| {
        // SAFETY: `data` is valid for reads and writes of its length (the encoder sanitizes in
        // place, idempotently, so a retry after OUT_OF_SPACE sees equivalent input); `buffer`
        // is valid for `capacity` bytes.
        unsafe {
            ffi::ghostty_paste_encode(
                data.as_mut_ptr().cast(),
                data.len(),
                bracketed,
                buffer,
                capacity,
                written,
            )
        }
    });
    // Encoding only fails on buffer size, which `encode_into` handles.
    result.unwrap_or_default()
}

/// Whether `text` is safe to paste anywhere: it has no line break that would run a command
/// and no bracketed-paste terminator. Clients ask for confirmation otherwise.
pub fn paste_is_safe(text: &str) -> bool {
    // SAFETY: `text` is valid for `len` bytes.
    unsafe { ffi::ghostty_paste_is_safe(text.as_ptr().cast(), text.len()) }
}

impl Terminal {
    /// Pastes `text` as the program expects it: bracketed if it enabled bracketed paste
    /// (mode 2004), sanitized either way. See [`encode_paste`].
    pub fn encode_paste(&self, text: &str) -> Vec<u8> {
        encode_paste(text, self.mode(Mode::BRACKETED_PASTE))
    }
}

/// The number of cells `character` takes, by libghostty-vt's width tables (0, 1 or 2).
pub fn char_width(character: char) -> u8 {
    // SAFETY: a pure function of its argument.
    unsafe { ffi::ghostty_unicode_codepoint_width(u32::from(character)) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(key: Key) -> KeyEvent {
        KeyEvent {
            key: Some(key),
            ..KeyEvent::default()
        }
    }

    #[test]
    fn keys_follow_kitty_flags() -> Result<(), Error> {
        let mut terminal = Terminal::new(80, 24)?;
        let mut encoder = KeyEncoder::new()?;
        let ctrl_c = KeyEvent {
            key: Some(Key::C),
            mods: Mods::CTRL,
            unshifted: Some('c'),
            ..KeyEvent::default()
        };
        assert_eq!(encoder.encode(&terminal, &ctrl_c)?, b"\x03");
        let a = KeyEvent {
            text: Some("a".into()),
            unshifted: Some('a'),
            ..key(Key::A)
        };
        assert_eq!(encoder.encode(&terminal, &a)?, b"a");
        // Disambiguate escape codes.
        terminal.write(b"\x1b[>1u");
        assert_eq!(encoder.encode(&terminal, &ctrl_c)?, b"\x1b[99;5u");
        assert_eq!(encoder.encode(&terminal, &key(Key::ESCAPE))?, b"\x1b[27u");
        assert_eq!(encoder.encode(&terminal, &a)?, b"a");
        let release = KeyEvent {
            action: KeyAction::Release,
            ..a.clone()
        };
        assert!(encoder.encode(&terminal, &release)?.is_empty());
        Ok(())
    }

    #[test]
    fn composing_keys_send_nothing() -> Result<(), Error> {
        let terminal = Terminal::new(80, 24)?;
        let mut encoder = KeyEncoder::new()?;
        let event = KeyEvent {
            text: Some("k".into()),
            composing: true,
            ..key(Key::K)
        };
        assert!(encoder.encode(&terminal, &event)?.is_empty());
        Ok(())
    }

    #[test]
    fn mouse_formats_and_button_tracking() -> Result<(), Error> {
        let mut terminal = Terminal::new(80, 24)?;
        let mut encoder = MouseEncoder::new()?;
        let event = |action, button, col| MouseEvent {
            action,
            button,
            col,
            row: 0,
            mods: Mods::NONE,
        };
        terminal.write(b"\x1b[?1002h\x1b[?1006h");
        let left = Some(MouseButton::Left);
        assert!(
            encoder
                .encode(&terminal, &event(MouseAction::Motion, None, 3), (0, 0))?
                .is_empty()
        );
        let press = encoder.encode(&terminal, &event(MouseAction::Press, left, 1), (0, 0))?;
        assert_eq!(press, b"\x1b[<0;2;1M");
        let drag = encoder.encode(&terminal, &event(MouseAction::Motion, left, 2), (0, 0))?;
        assert_eq!(drag, b"\x1b[<32;3;1M");
        let up = encoder.encode(&terminal, &event(MouseAction::Release, left, 2), (0, 0))?;
        assert_eq!(up, b"\x1b[<0;3;1m");
        let wheel = Some(MouseButton::WheelDown);
        let scroll = encoder.encode(&terminal, &event(MouseAction::Press, wheel, 2), (0, 0))?;
        assert_eq!(scroll, b"\x1b[<65;3;1M");
        Ok(())
    }

    #[test]
    fn paste_follows_mode_and_strips_escapes() -> Result<(), Error> {
        let mut terminal = Terminal::new(80, 24)?;
        assert_eq!(terminal.encode_paste("a\nb"), b"a\rb");
        terminal.write(b"\x1b[>1u");
        assert_eq!(terminal.encode_paste("x\ny"), b"x\ry");
        terminal.write(b"\x1b[?2004h");
        assert_eq!(terminal.encode_paste("a\nb"), b"\x1b[200~a\nb\x1b[201~");
        assert!(paste_is_safe("plain"));
        assert!(!paste_is_safe("two\nlines"));
        assert!(!paste_is_safe("x\x1b[201~"));
        Ok(())
    }

    /// Pasted text (MCP `pane_send`/`cmd_run`, the paste RPC, the composer) cannot end
    /// bracketed paste early or send control keys: 7-bit ESC, its UTF-8 C1 twin (U+009B CSI),
    /// ^C/^U/^W and friends never reach the PTY as themselves.
    #[test]
    fn pastes_cannot_escape_the_bracket() -> Result<(), Error> {
        let mut terminal = Terminal::new(80, 24)?;
        terminal.write(b"\x1b[?2004h");
        let hostile = "a\x1b[201~rm -rf ~\r\n\u{9b}201~\x03\x15\x17\x1a\x04\x7fb";
        let encoded = terminal.encode_paste(hostile);
        let body = encoded
            .strip_prefix(b"\x1b[200~")
            .and_then(|framed| framed.strip_suffix(b"\x1b[201~"))
            .expect("framed");
        for byte in [0x1b, 0x03, 0x15, 0x17, 0x1a, 0x04, 0x7f] {
            assert!(!body.contains(&byte), "{byte:#x} in {encoded:?}");
        }
        // U+009B stays a UTF-8 character (C2 9B), never a lone 8-bit CSI byte.
        assert!(std::str::from_utf8(body).is_ok_and(|text| text.contains('\u{9b}')));
        Ok(())
    }

    #[test]
    fn widths() {
        assert_eq!(char_width('a'), 1);
        assert_eq!(char_width('漢'), 2);
        assert_eq!(char_width('\u{301}'), 0);
    }
}
