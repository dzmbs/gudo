//! The bytes of an atomic submit.
//!
//! One write: `^E` (end of line) and `^U` (kill to the start of the line: `unix-line-discard`
//! in readline, `kill-whole-line` in zsh's emacs keymap, `backward-kill-line` in fish), which
//! together empty a single-line buffer in all three; the text as a paste (bracketed when the
//! shell enabled mode 2004, which keeps a newline from running the line early); and `\r` when
//! the line should run.

const CLEAR_LINE: &[u8] = b"\x05\x15";

/// Why a text cannot be submitted.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum TextError {
    #[error("control character U+{0:04X} in the text")]
    Control(u32),
    #[error("multi-line text needs bracketed paste, which the shell has not enabled")]
    Multiline,
    #[error("the text is longer than {0} bytes")]
    TooLong(usize),
}

pub(crate) const MAX_TEXT: usize = 64 << 10;

pub(crate) fn check(text: &str, bracketed: bool) -> Result<(), TextError> {
    if text.len() > MAX_TEXT {
        return Err(TextError::TooLong(MAX_TEXT));
    }
    if let Some(character) = text
        .chars()
        .find(|&character| character.is_control() && character != '\n' && character != '\t')
    {
        return Err(TextError::Control(character as u32));
    }
    if text.contains('\n') && !bracketed {
        return Err(TextError::Multiline);
    }
    Ok(())
}

/// The whole write: clear, paste (already encoded for the pane's modes), Return.
pub(crate) fn bytes(paste: &[u8], run: bool) -> Vec<u8> {
    let mut write = Vec::with_capacity(CLEAR_LINE.len() + paste.len() + 1);
    write.extend_from_slice(CLEAR_LINE);
    write.extend_from_slice(paste);
    if run {
        write.push(b'\r');
    }
    write
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checks_and_bytes() {
        assert!(check("ls -la\techo", false).is_ok());
        assert_eq!(check("a\x1b[201~", true), Err(TextError::Control(0x1b)));
        assert_eq!(check("a\nb", false), Err(TextError::Multiline));
        assert!(check("a\nb", true).is_ok());
        assert_eq!(
            bytes(b"\x1b[200~ls\x1b[201~", true),
            b"\x05\x15\x1b[200~ls\x1b[201~\r"
        );
        assert_eq!(bytes(b"ls", false), b"\x05\x15ls");
    }
}
