//! Wire input events to libghostty-vt encoder events.

use ghostty_vt::{Key, KeyAction, KeyEvent, Mods, MouseAction, MouseButton, MouseEvent};

pub(crate) fn is_focus_report(bytes: &[u8]) -> bool {
    matches!(bytes, b"\x1b[I" | b"\x1b[O" | b"\x9bI" | b"\x9bO")
}

pub(crate) fn is_sizing_input(payload: &proto::InputPayload) -> bool {
    match payload {
        proto::InputPayload::Bytes(bytes) => !bytes.is_empty() && !is_focus_report(bytes),
        proto::InputPayload::Paste(text) => !text.is_empty(),
        proto::InputPayload::Key(key) => key.action != proto::KeyAction::Release,
        proto::InputPayload::KeyFull(key) => {
            !key.composing && key.action != proto::KeyAction::Release
        }
        proto::InputPayload::Mouse(_) | proto::InputPayload::GeneratedBytes(_) => false,
    }
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
    use super::{is_focus_report, is_sizing_input};

    #[test]
    fn reports_and_key_releases_are_not_sizing_input() {
        use proto::{
            FullKeyEvent, InputPayload, KeyAction, KeyEvent, MouseAction, MouseButton, MouseEvent,
        };
        for bytes in [b"".as_slice(), b"\x1b[I", b"\x9bO"] {
            assert!(!is_sizing_input(&InputPayload::Bytes(bytes.to_vec())));
        }
        assert!(!is_sizing_input(&InputPayload::GeneratedBytes(
            b"text".to_vec()
        )));
        assert!(!is_sizing_input(&InputPayload::Mouse(MouseEvent {
            action: MouseAction::Press,
            button: MouseButton::Left,
            col: 0,
            row: 0,
            mods: 0
        })));
        assert!(is_sizing_input(&InputPayload::Bytes(b"text".to_vec())));
        assert!(is_sizing_input(&InputPayload::Paste("\x1b[I".into())));
        let mut key = FullKeyEvent {
            key: 0,
            mods: 0,
            consumed_mods: 0,
            action: KeyAction::Press,
            text: None,
            unshifted_codepoint: None,
            composing: false,
        };
        for action in [KeyAction::Press, KeyAction::Repeat, KeyAction::Release] {
            key.action = action;
            assert_eq!(
                is_sizing_input(&InputPayload::KeyFull(key.clone())),
                action != KeyAction::Release
            );
            assert_eq!(
                is_sizing_input(&InputPayload::Key(KeyEvent {
                    key: 0,
                    mods: 0,
                    action,
                    text: None
                })),
                action != KeyAction::Release
            );
        }
        key.action = KeyAction::Press;
        key.composing = true;
        assert!(!is_sizing_input(&InputPayload::KeyFull(key)));
    }

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
