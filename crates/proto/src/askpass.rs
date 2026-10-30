//! Native password prompts: secrets asked for by programs in a pane, answered on a device.
//!
//! Two sources:
//!
//! 1. **Askpass.** Panes get `SUDO_ASKPASS`, `SSH_ASKPASS` (with `SSH_ASKPASS_REQUIRE=prefer`)
//!    and `GIT_ASKPASS` pointing at the daemon's helper. When `sudo -A`, `ssh` or `git` run it,
//!    the daemon pushes [`AskpassPush::Prompt`] to the clients that may answer, and the first
//!    [`AskpassRequest::Answer`] goes to the helper's stdout. Everyone else's prompt closes
//!    with [`AskpassPush::Closed`].
//! 2. **Detected prompts.** A program that reads a password from the terminal itself turns
//!    echo off (`-echo icanon`) and prints a prompt. The daemon pushes
//!    [`AskpassPush::Detected`] while that holds and the cursor line looks like a password
//!    prompt; [`AskpassRequest::TypeSecret`] types a secret and Return into the pane, but only
//!    while echo is still off.
//!
//! Requests travel as [`ClientCtl::Askpass`](crate::ClientCtl::Askpass) and are answered by
//! [`ServerCtl::AskpassResult`](crate::ServerCtl::AskpassResult); pushes are
//! [`ServerCtl::Askpass`](crate::ServerCtl::Askpass). Both go only to connections that
//! announced [`Caps::ASKPASS`](crate::Caps::ASKPASS) and hold Driver (or Owner) on the pane:
//! guests who can only watch never see the prompt text.
//!
//! Secrets travel as [`Secret`], whose `Debug` output is redacted and whose bytes are zeroed
//! when it is dropped. The daemon never logs or stores them.
//!
//! Same compatibility rules as the rest of the crate: append only. A client without
//! [`Caps::ASKPASS`](crate::Caps::ASKPASS) is never sent these messages, and the helper
//! falls back to asking on the terminal.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::ids::{PaneId, PrincipalId, Seq, UnixMillis};

/// One askpass prompt on one daemon. Unique for the daemon's lifetime.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize,
)]
pub struct AskpassId(pub u64);

impl fmt::Display for AskpassId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.0, f)
    }
}

/// A password, passphrase or answer, as bytes.
///
/// `Debug` never prints it, and the bytes are overwritten with zeros when it is dropped.
/// Copies made on the way (frame buffers, the kernel's socket buffers) are outside its
/// control; nothing in the daemon writes it anywhere but the asking program.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Secret(#[serde(with = "crate::serde_bytes")] Vec<u8>);

impl Secret {
    /// Wraps `bytes`, which are zeroed when the secret is dropped.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::Secret;
    ///
    /// let s = Secret::new(b"hunter2".to_vec());
    /// assert_eq!(s.expose(), b"hunter2");
    /// assert_eq!(format!("{s:?}"), "Secret(7 bytes)");
    /// ```
    pub fn new(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }

    /// The secret's bytes. Copy them only into the place they are meant for.
    pub fn expose(&self) -> &[u8] {
        &self.0
    }

    /// The length in bytes.
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// Whether the secret is empty.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Secret({} bytes)", self.0.len())
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        zeroize::Zeroize::zeroize(&mut self.0);
    }
}

/// The kind of program asking, from the helper's parent process.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SecretSource {
    /// `sudo -A` (`SUDO_ASKPASS`).
    Sudo,
    /// `ssh`, `scp`, `sftp`, `ssh-add` (`SSH_ASKPASS`).
    Ssh,
    /// `git` and its remote helpers (`GIT_ASKPASS`).
    Git,
    /// `gpg` / `gpg-agent`.
    Gpg,
    /// Anything else that runs an askpass program.
    Other,
}

/// A program in a pane asks for a secret through the askpass helper.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SecretPrompt {
    /// Answer with this id.
    pub id: AskpassId,
    /// The pane the program runs in.
    pub pane_id: PaneId,
    /// What kind of program asks.
    pub source: SecretSource,
    /// The program's prompt (`[sudo] password for ana:`), control and bidi characters
    /// removed, at most 512 characters.
    pub prompt: String,
    /// The asking program's command line (`sudo apt upgrade`), cleaned the same way; empty
    /// when unknown. Reported by the host, not verified.
    pub program: String,
    /// The answer is not secret and may be shown while typed: a yes/no question such as
    /// ssh's host key confirmation.
    pub echo: bool,
    /// The same pane asked the same question moments after an answer: the last answer was
    /// probably wrong.
    pub retry: bool,
    /// When the daemon gives up waiting and the program gets no answer.
    pub expires_at: UnixMillis,
}

/// Why an askpass prompt closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CloseReason {
    /// Someone answered it.
    Answered {
        /// Who.
        by: PrincipalId,
    },
    /// Someone cancelled it (`None`: the daemon, e.g. it is shutting down).
    Cancelled {
        /// Who.
        by: Option<PrincipalId>,
    },
    /// Nobody answered in time.
    TimedOut,
    /// The asking program went away (interrupted, or it timed out itself).
    Abandoned,
    /// No connection that may answer is left; the helper asks on the terminal instead.
    MovedToTerminal,
}

/// A password prompt the program printed itself, with echo off.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DetectedPrompt {
    /// The pane.
    pub pane_id: PaneId,
    /// The prompt line (`Password:`), cleaned like [`SecretPrompt::prompt`].
    pub prompt: String,
    /// Output offset at which it was seen.
    pub at_seq: Seq,
}

/// Askpass state pushed to connections that may answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AskpassPush {
    /// A new prompt (also sent for open prompts when a connection subscribes to the pane).
    Prompt(SecretPrompt),
    /// The prompt is over; close its sheet.
    Closed {
        /// The prompt.
        id: AskpassId,
        /// Its pane.
        pane_id: PaneId,
        /// Why.
        reason: CloseReason,
    },
    /// The pane shows a password prompt with echo off.
    Detected(DetectedPrompt),
    /// The detected prompt is gone (echo is back, or the line changed).
    DetectedGone {
        /// The pane.
        pane_id: PaneId,
    },
}

/// An askpass request (see the module docs). Each is answered by
/// [`ServerCtl::AskpassResult`](crate::ServerCtl::AskpassResult).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AskpassRequest {
    /// Answers a prompt. The first answer wins; later ones get [`AskpassError::Gone`].
    Answer {
        /// The prompt.
        id: AskpassId,
        /// The answer, without a trailing newline.
        secret: Secret,
    },
    /// Declines a prompt: the program gets no answer (its askpass fails).
    Cancel {
        /// The prompt.
        id: AskpassId,
    },
    /// Types `secret` and Return into a pane at a detected prompt. Refused with
    /// [`AskpassError::NotHidden`] (nothing written) unless the pane's echo is still off, so
    /// the secret is never echoed or run as a command.
    TypeSecret {
        /// The pane.
        pane_id: PaneId,
        /// What to type, without the Return.
        secret: Secret,
    },
}

/// Why an askpass request failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AskpassError {
    /// The prompt is closed: answered by someone else, cancelled, timed out or abandoned.
    Gone,
    /// The connection's roles or scope do not allow it; the text names the role needed.
    Denied(String),
    /// The pane does not exist or is outside the grant's scope.
    UnknownPane,
    /// The pane's terminal echoes input now; nothing was typed.
    NotHidden,
    /// Anything else; the text says why.
    Failed(String),
    /// The connection dropped before the answer arrived (client side only).
    Disconnected,
}

impl fmt::Display for AskpassError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Gone => f.write_str("the prompt is no longer open"),
            Self::Denied(why) => write!(f, "not allowed: {why}"),
            Self::UnknownPane => f.write_str("no such pane"),
            Self::NotHidden => f.write_str("the pane is not at a hidden-input prompt"),
            Self::Failed(why) => f.write_str(why),
            Self::Disconnected => f.write_str("disconnected before the daemon answered"),
        }
    }
}

impl std::error::Error for AskpassError {}

/// Whether a terminal line looks like a password prompt: it ends with `:` (optionally
/// followed by spaces) and names a password, passphrase, PIN or passcode.
///
/// # Examples
///
/// ```
/// use proto::looks_like_password_prompt;
///
/// assert!(looks_like_password_prompt("[sudo] password for ana: "));
/// assert!(looks_like_password_prompt("Enter passphrase for key '/home/a/.ssh/id_ed25519':"));
/// assert!(looks_like_password_prompt("ana@host's password:"));
/// assert!(!looks_like_password_prompt("$ echo password"));
/// assert!(!looks_like_password_prompt("Username:"));
/// ```
pub fn looks_like_password_prompt(line: &str) -> bool {
    let line = line.trim_end();
    let Some(body) = line.strip_suffix(':').or_else(|| line.strip_suffix('：')) else {
        return false;
    };
    let lower = body.to_lowercase();
    [
        "password",
        "passphrase",
        "passcode",
        "pass phrase",
        "pin",
        "kennwort",
        "mot de passe",
    ]
    .iter()
    .any(|word| {
        lower.match_indices(word).any(|(at, _)| {
            // `pin` must be a word of its own ("PIN:", "Enter PIN for"), not "spinning".
            let before = lower[..at].chars().next_back();
            let after = lower[at + word.len()..].chars().next();
            *word != "pin"
                || (!before.is_some_and(char::is_alphanumeric)
                    && !after.is_some_and(char::is_alphanumeric))
        })
    })
}

/// Cleans text a host reports for display: control and bidi/format characters removed,
/// whitespace runs collapsed, at most `max` characters (an ellipsis marks a cut).
///
/// # Examples
///
/// ```
/// use proto::clean_prompt_text;
///
/// assert_eq!(clean_prompt_text("Pass\u{202e}word:\r\n", 512), "Password:");
/// assert_eq!(clean_prompt_text("a\tb   c", 512), "a b c");
/// assert_eq!(clean_prompt_text("abcdef", 3), "abc…");
/// ```
pub fn clean_prompt_text(text: &str, max: usize) -> String {
    let mut out = String::with_capacity(text.len().min(max * 4));
    let mut space = false;
    let mut count = 0;
    for c in text.chars() {
        if is_invisible_format(c) {
            continue;
        }
        if c.is_whitespace() || c.is_control() {
            space = !out.is_empty();
            continue;
        }
        if space {
            if count == max {
                out.push('…');
                return out;
            }
            out.push(' ');
            count += 1;
            space = false;
        }
        if count == max {
            out.push('…');
            return out;
        }
        out.push(c);
        count += 1;
    }
    out
}

/// Whether `c` is a Unicode format character that can disguise text: bidi controls,
/// zero-width characters, the BOM, the soft hyphen, and tag characters (invisible to people,
/// read by language models as ASCII).
///
/// # Examples
///
/// ```
/// assert!(proto::is_invisible_format('\u{202e}'));
/// assert!(proto::is_invisible_format('\u{e0041}'));
/// assert!(!proto::is_invisible_format('a'));
/// ```
pub fn is_invisible_format(c: char) -> bool {
    matches!(
        c,
        '\u{00AD}'
            | '\u{061C}'
            | '\u{180E}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2069}'
            | '\u{FEFF}'
            | '\u{E0000}'..='\u{E007F}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_password_prompts() {
        for yes in [
            "Password:",
            "Password: ",
            "[sudo] password for ana: ",
            "Password for 'https://ana@github.com': ",
            "Enter PIN for 'PIV Card Holder pin (PIV_II)': ",
            "Enter passphrase: ",
            "Verification passcode:",
        ] {
            assert!(looks_like_password_prompt(yes), "{yes:?}");
        }
        for no in [
            "",
            "Password",
            "Username for 'https://github.com': ",
            "spinning:",
            "$ ",
            "password: ok then",
        ] {
            assert!(!looks_like_password_prompt(no), "{no:?}");
        }
    }

    #[test]
    fn secret_debug_is_redacted() {
        let s = Secret::new(b"hunter2".to_vec());
        assert!(!format!("{s:?}").contains("hunter2"));
        let req = AskpassRequest::Answer {
            id: AskpassId(1),
            secret: s,
        };
        assert!(!format!("{req:?}").contains("hunter2"));
    }

    #[test]
    fn cleans_prompt_text() {
        assert_eq!(clean_prompt_text("  a\u{200b}b  ", 10), "ab");
        assert_eq!(clean_prompt_text("x\u{1b}[31my", 10), "x [31my");
        assert_eq!(clean_prompt_text("a b", 1), "a…");
    }
}
