//! Wire input events to libghostty-vt encoder events.

use ghostty_vt::{Key, KeyAction, KeyEvent, Mods, MouseAction, MouseButton, MouseEvent};

pub(crate) fn is_focus_report(bytes: &[u8]) -> bool {
    matches!(bytes, b"\x1b[I" | b"\x1b[O" | b"\x9bI" | b"\x9bO")
}

fn action(key_action: proto::KeyAction) -> KeyAction {
    match key_action {
        proto::KeyAction::Press => KeyAction::Press,
        proto::KeyAction::Repeat => KeyAction::Repeat,
        proto::KeyAction::Release => KeyAction::Release,
    }
}

/// A [`proto::KeyEvent`]: the base key is derived from the text when it is one unshifted
/// character, which is right for most layouts; [`proto::FullKeyEvent`] says it exactly.
pub(crate) fn key(event: proto::KeyEvent) -> KeyEvent {
    let unshifted = event
        .text
        .as_deref()
        .and_then(|text| {
            let mut chars = text.chars();
            chars.next().filter(|_| chars.next().is_none())
        })
        .map(|c| c.to_lowercase().next().unwrap_or(c));
    KeyEvent {
        key: Some(Key(event.key)),
        mods: Mods(event.mods),
        consumed_mods: Mods::NONE,
        action: action(event.action),
        text: event.text,
        unshifted,
        composing: false,
    }
}

pub(crate) fn full_key(event: proto::FullKeyEvent) -> KeyEvent {
    KeyEvent {
        key: Some(Key(event.key)),
        mods: Mods(event.mods),
        consumed_mods: Mods(event.consumed_mods),
        action: action(event.action),
        text: event.text,
        unshifted: event.unshifted_codepoint.and_then(char::from_u32),
        composing: event.composing,
    }
}

pub(crate) fn mouse(event: proto::MouseEvent) -> MouseEvent {
    MouseEvent {
        action: match event.action {
            proto::MouseAction::Press => MouseAction::Press,
            proto::MouseAction::Release => MouseAction::Release,
            proto::MouseAction::Motion => MouseAction::Motion,
        },
        button: match event.button {
            proto::MouseButton::None => None,
            proto::MouseButton::Left => Some(MouseButton::Left),
            proto::MouseButton::Middle => Some(MouseButton::Middle),
            proto::MouseButton::Right => Some(MouseButton::Right),
            proto::MouseButton::WheelUp => Some(MouseButton::WheelUp),
            proto::MouseButton::WheelDown => Some(MouseButton::WheelDown),
            proto::MouseButton::WheelLeft => Some(MouseButton::WheelLeft),
            proto::MouseButton::WheelRight => Some(MouseButton::WheelRight),
        },
        col: event.col,
        row: event.row,
        mods: Mods(event.mods),
    }
}

#[cfg(test)]
mod tests {
    use super::is_focus_report;

    #[test]
    fn only_a_complete_lone_focus_report_is_protocol_only() {
        for report in [b"\x1b[I".as_slice(), b"\x1b[O", b"\x9bI", b"\x9bO"] {
            assert!(is_focus_report(report));
        }
        for input in [
            b"".as_slice(),
            b"I",
            b"\x1b[",
            b"\x1b[Itext",
            b"text\x1b[O",
            b"\x1b[I\x1b[O",
        ] {
            assert!(!is_focus_report(input));
        }
    }
}
