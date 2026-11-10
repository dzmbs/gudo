//! Wire input events to libghostty-vt encoder events.

use ghostty_vt::{Key, KeyAction, KeyEvent, Mods, MouseAction, MouseButton, MouseEvent};

pub(crate) fn is_focus_report(bytes: &[u8]) -> bool {
    matches!(bytes, b"\x1b[I" | b"\x1b[O" | b"\x9bI" | b"\x9bO")
}

/// Most numbers in one report: primary device attributes list a few features each.
const MAX_REPORT_NUMBERS: usize = 32;
const MAX_REPORT_DIGITS: usize = 10;

/// Whether `bytes` are nothing but replies a terminal sends on its own: focus changes and
/// answers to a program's queries (cursor position, device status and attributes, mode and
/// keyboard-flag reports, colours). None of them can carry text, so a client may send them
/// without it counting as typing; anything else it calls generated is typing.
pub(crate) fn is_terminal_report(bytes: &[u8]) -> bool {
    let mut rest = bytes;
    while !rest.is_empty() {
        match report_len(rest) {
            Some(len) => rest = &rest[len..],
            None => return false,
        }
    }
    !bytes.is_empty()
}

fn report_len(bytes: &[u8]) -> Option<usize> {
    match bytes {
        [0x9b, b'I' | b'O', ..] => Some(2),
        [0x1b, b'[', body @ ..] => csi_report_len(body).map(|len| 2 + len),
        [0x1b, b']', body @ ..] => osc_colour_report_len(body).map(|len| 2 + len),
        _ => None,
    }
}

/// The length of a CSI report after `ESC [`.
fn csi_report_len(body: &[u8]) -> Option<usize> {
    let private = body
        .first()
        .filter(|byte| matches!(byte, b'?' | b'>'))
        .copied();
    let after_private = &body[usize::from(private.is_some())..];
    let params_len = after_private
        .iter()
        .take_while(|byte| byte.is_ascii_digit() || **byte == b';')
        .count();
    let params = &after_private[..params_len];
    let numbers = number_count(params);
    let final_len = match (private, numbers, &after_private[params_len..]) {
        (None, Some(0), [b'I' | b'O', ..]) => 1,
        (None | Some(b'?'), Some(2..=3), [b'R', ..]) => 1,
        (None | Some(b'?'), Some(1..=2), [b'n', ..]) => 1,
        (Some(b'?' | b'>'), Some(1..), [b'c', ..]) => 1,
        (None | Some(b'?'), Some(2), [b'$', b'y', ..]) => 2,
        (Some(b'?'), Some(1), [b'u', ..]) => 1,
        _ => return None,
    };
    Some(usize::from(private.is_some()) + params_len + final_len)
}

/// How many numbers `params` holds (`1;22;3` is three), if each is a plain bounded number.
fn number_count(params: &[u8]) -> Option<usize> {
    if params.is_empty() {
        return Some(0);
    }
    let mut count = 0;
    for number in params.split(|byte| *byte == b';') {
        if number.is_empty() || number.len() > MAX_REPORT_DIGITS {
            return None;
        }
        count += 1;
    }
    (count <= MAX_REPORT_NUMBERS).then_some(count)
}

/// The length of an OSC 4, 10, 11 or 12 colour reply after `ESC ]`:
/// `4;<index>;rgb:<r>/<g>/<b>` or `1x;rgb:<r>/<g>/<b>`, ended by BEL or `ESC \`.
fn osc_colour_report_len(body: &[u8]) -> Option<usize> {
    let after_code = if let Some(rest) = body.strip_prefix(b"4;") {
        let digits = rest.iter().take_while(|byte| byte.is_ascii_digit()).count();
        if digits == 0 || digits > 3 {
            return None;
        }
        &rest[digits..]
    } else {
        [b"10".as_slice(), b"11", b"12"]
            .into_iter()
            .find_map(|code| body.strip_prefix(code))?
    };
    let mut rest = after_code.strip_prefix(b";rgb:")?;
    for channel in 0..3 {
        let digits = rest
            .iter()
            .take_while(|byte| byte.is_ascii_hexdigit())
            .count();
        if !(1..=4).contains(&digits) {
            return None;
        }
        rest = &rest[digits..];
        if channel < 2 {
            rest = rest.strip_prefix(b"/")?;
        }
    }
    let terminator = match rest {
        [0x07, ..] => 1,
        [0x1b, b'\\', ..] => 2,
        _ => return None,
    };
    Some(body.len() - rest.len() + terminator)
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
    use super::{is_focus_report, is_sizing_input, is_terminal_report};

    #[test]
    fn only_a_terminals_own_replies_pass_as_reports() {
        for report in [
            b"\x1b[I".as_slice(),
            b"\x9bO",
            b"\x1b[12;40R",
            b"\x1b[?12;40;1R",
            b"\x1b[0n",
            b"\x1b[?997;1n",
            b"\x1b[?62;22;52c",
            b"\x1b[>1;10;0c",
            b"\x1b[?2004;1$y",
            b"\x1b[4;2$y",
            b"\x1b[?5u",
            b"\x1b]4;1;rgb:cd/31/31\x07",
            b"\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\",
            b"\x1b[I\x1b[0n\x1b]10;rgb:f/f/f\x07",
        ] {
            assert!(is_terminal_report(report), "{report:?}");
        }
        for typed in [
            b"".as_slice(),
            b"ls\r",
            b"\r",
            b"\x1b[0nrm -rf ~\r",
            b"\x1b[13u",
            b"\x1b[13;1:3u",
            b"\x1b[A",
            b"\x1b[200~text\x1b[201~",
            b"\x1b[<0;1;1M",
            b"\x1b[M !!",
            b"\x1b]52;c;bHM=\x07",
            b"\x1bP>|ghostty\x1b\\",
            b"\x1b]11;rgb:1e1e/1e1e/2e2e",
            b"\x1b]11;rgb:1e1e/1e1e/2e2e\x07x",
            b"\x1b[12;R",
            b"\x1b[12345678901;1R",
        ] {
            assert!(!is_terminal_report(typed), "{typed:?}");
        }
    }

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
