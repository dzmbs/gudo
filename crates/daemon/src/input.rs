//! Wire input events to libghostty-vt encoder events.

use ghostty_vt::{Key, KeyAction, KeyEvent, Mods, MouseAction, MouseButton, MouseEvent};

fn action(a: proto::KeyAction) -> KeyAction {
    match a {
        proto::KeyAction::Press => KeyAction::Press,
        proto::KeyAction::Repeat => KeyAction::Repeat,
        proto::KeyAction::Release => KeyAction::Release,
    }
}

/// A [`proto::KeyEvent`]: the base key is derived from the text when it is one unshifted
/// character, which is right for most layouts; [`proto::FullKeyEvent`] says it exactly.
pub(crate) fn key(k: proto::KeyEvent) -> KeyEvent {
    let unshifted = k
        .text
        .as_deref()
        .and_then(|t| {
            let mut chars = t.chars();
            chars.next().filter(|_| chars.next().is_none())
        })
        .map(|c| c.to_lowercase().next().unwrap_or(c));
    KeyEvent {
        key: Some(Key(k.key)),
        mods: Mods(k.mods),
        consumed_mods: Mods::NONE,
        action: action(k.action),
        text: k.text,
        unshifted,
        composing: false,
    }
}

pub(crate) fn full_key(k: proto::FullKeyEvent) -> KeyEvent {
    KeyEvent {
        key: Some(Key(k.key)),
        mods: Mods(k.mods),
        consumed_mods: Mods(k.consumed_mods),
        action: action(k.action),
        text: k.text,
        unshifted: k.unshifted_codepoint.and_then(char::from_u32),
        composing: k.composing,
    }
}

pub(crate) fn mouse(m: proto::MouseEvent) -> MouseEvent {
    MouseEvent {
        action: match m.action {
            proto::MouseAction::Press => MouseAction::Press,
            proto::MouseAction::Release => MouseAction::Release,
            proto::MouseAction::Motion => MouseAction::Motion,
        },
        button: match m.button {
            proto::MouseButton::None => None,
            proto::MouseButton::Left => Some(MouseButton::Left),
            proto::MouseButton::Middle => Some(MouseButton::Middle),
            proto::MouseButton::Right => Some(MouseButton::Right),
            proto::MouseButton::WheelUp => Some(MouseButton::WheelUp),
            proto::MouseButton::WheelDown => Some(MouseButton::WheelDown),
            proto::MouseButton::WheelLeft => Some(MouseButton::WheelLeft),
            proto::MouseButton::WheelRight => Some(MouseButton::WheelRight),
        },
        col: m.col,
        row: m.row,
        mods: Mods(m.mods),
    }
}
