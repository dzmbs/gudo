//! Wire input events to libghostty-vt encoder events.

use ghostty_vt::{Key, KeyAction, KeyEvent, Mods, MouseAction, MouseButton, MouseEvent};

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
