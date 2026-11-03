//! A streaming OSC extractor for the facts the daemon tracks outside libghostty-vt: titles,
//! working directory, agent reports and clipboard writes (OSC 52). Shell-integration marks (OSC 133) come from
//! libghostty-vt itself, with cursor positions (see `commands`).
//!
//! It only recognises `ESC ] … (BEL | ESC \)`; everything else passes through untouched (the
//! VT parser sees every byte regardless). Bodies longer than [`MAX_BODY`] are dropped.

const MAX_BODY: usize = 8 * 1024;
/// Longest OSC 52 body kept: `52;<targets>;` and the base64 of the largest clipboard write.
const MAX_CLIPBOARD_BODY: usize = 64 + proto::MAX_CLIPBOARD_BYTES.div_ceil(3) * 4;
const MAX_TITLE_CHARS: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Osc {
    Title(String),
    /// OSC 7, as a path (see [`file_url_path`]).
    Cwd(String),
    /// OSC 9 body after `9;` (Codex notifications, progress reports).
    Notify(String),
    /// OSC 7501 body after `7501;` (program status).
    ProgramStatus(String),
    /// OSC 52 write; reads (`?`) are never recognised.
    Clipboard(String),
}

#[derive(Debug, Default)]
enum State {
    #[default]
    Ground,
    Esc,
    Body,
    BodyEsc,
}

/// Incremental scanner; sequences may be split across feeds.
#[derive(Debug, Default)]
pub(crate) struct OscScanner {
    state: State,
    body: Vec<u8>,
    overflow: bool,
}

impl OscScanner {
    pub fn feed(&mut self, data: &[u8], mut emit: impl FnMut(Osc)) {
        let mut rest = data;
        while !rest.is_empty() {
            if matches!(self.state, State::Ground) {
                match memchr::memchr(0x1b, rest) {
                    Some(at) => rest = &rest[at..],
                    None => return,
                }
            }
            let byte = rest[0];
            rest = &rest[1..];
            self.state = match (&self.state, byte) {
                (State::Ground, 0x1b) => State::Esc,
                (State::Ground, _) => State::Ground,
                (State::Esc, b']') => {
                    self.body.clear();
                    self.overflow = false;
                    State::Body
                }
                (State::Esc, 0x1b) => State::Esc,
                (State::Esc, _) => State::Ground,
                (State::Body, 0x07) => {
                    self.finish(&mut emit);
                    State::Ground
                }
                (State::Body, 0x1b) => State::BodyEsc,
                (State::Body, 0x18 | 0x1a) => State::Ground,
                (State::Body, _) => {
                    self.push(byte);
                    State::Body
                }
                (State::BodyEsc, b'\\') => {
                    self.finish(&mut emit);
                    State::Ground
                }
                // ESC inside an OSC that is not ST aborts it and starts a new escape.
                (State::BodyEsc, b']') => {
                    self.body.clear();
                    self.overflow = false;
                    State::Body
                }
                (State::BodyEsc, _) => State::Ground,
            };
        }
    }

    fn push(&mut self, byte: u8) {
        let max = if self.body.starts_with(b"52;") {
            MAX_CLIPBOARD_BODY
        } else {
            MAX_BODY
        };
        if self.body.len() < max {
            self.body.push(byte);
        } else {
            self.overflow = true;
        }
    }

    fn finish(&mut self, emit: &mut impl FnMut(Osc)) {
        if self.overflow {
            return;
        }
        let Ok(body) = std::str::from_utf8(&self.body) else {
            return;
        };
        let (code, rest) = body.split_once(';').unwrap_or((body, ""));
        let osc = match code {
            "0" | "2" => Osc::Title(proto::clean_prompt_text(rest, MAX_TITLE_CHARS)),
            "7" => match cwd_path(rest) {
                Some(path) => Osc::Cwd(path),
                None => return,
            },
            "9" => Osc::Notify(rest.to_owned()),
            "7501" => Osc::ProgramStatus(rest.to_owned()),
            "52" => match clipboard_text(rest) {
                Some(text) => Osc::Clipboard(text),
                None => return,
            },
            _ => return,
        };
        emit(osc);
    }
}

/// A ConEmu progress report, `OSC 9 ; 4 ; <state> [; <percent>]`, as Ghostty reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Progress {
    /// State 0: no progress any more.
    Remove,
    /// State 1: this far along.
    Set(u8),
    /// State 2: the operation failed, at this point if given.
    Error(Option<u8>),
    /// State 3: working, extent unknown.
    Indeterminate,
    /// State 4: paused, at this point if given.
    Paused(Option<u8>),
}

impl Progress {
    /// Parses the body after `9;`. Percentages above 100 are 100; a missing one is 0 for
    /// state 1, as in Ghostty.
    pub fn parse(body: &str) -> Option<Self> {
        let mut fields = body.strip_prefix("4;")?.split(';');
        let state = fields.next()?;
        let percent = match fields.next() {
            None | Some("") => None,
            Some(value) => Some(value.parse::<u32>().ok()?.min(100) as u8),
        };
        Some(match state {
            "0" => Self::Remove,
            "1" => Self::Set(percent.unwrap_or(0)),
            "2" => Self::Error(percent),
            "3" => Self::Indeterminate,
            "4" => Self::Paused(percent),
            _ => return None,
        })
    }

    pub fn percent(self) -> Option<u8> {
        match self {
            Self::Set(percent) => Some(percent),
            Self::Error(percent) | Self::Paused(percent) => percent,
            Self::Remove | Self::Indeterminate => None,
        }
    }
}

/// The text of an OSC 52 write, `<targets>;<base64>`: UTF-8 of at most
/// [`proto::MAX_CLIPBOARD_BYTES`]. A query (`?`) asks to read the clipboard and is never
/// answered; an empty, oversized or undecodable payload changes nothing.
fn clipboard_text(rest: &str) -> Option<String> {
    let (targets, data) = rest.split_once(';')?;
    if !targets.bytes().all(|b| b"cpqs01234567".contains(&b)) || data == "?" {
        return None;
    }
    // Some programs wrap long base64 lines; padding is optional.
    let data: Vec<u8> = data.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    let bytes = data_encoding::BASE64
        .decode(&data)
        .or_else(|_| data_encoding::BASE64_NOPAD.decode(&data))
        .ok()?;
    if bytes.len() > proto::MAX_CLIPBOARD_BYTES {
        return None;
    }
    String::from_utf8(bytes)
        .ok()
        .filter(|text| !text.is_empty())
}

/// The directory an OSC 7 URL names, if it is an absolute path that prints as it is: any
/// program can set it, and it is shown to people and agents.
pub(crate) fn cwd_path(url: &str) -> Option<String> {
    let path = file_url_path(url);
    let plain = path
        .chars()
        .all(|c| !c.is_control() && !proto::is_invisible_format(c));
    (path.starts_with('/') && plain).then_some(path)
}

/// The path of an OSC 7 working-directory URL: `file://host/path` (percent-decoded) or the
/// `kitty-shell-cwd://host/path` form Ghostty's shell integration sends (taken verbatim);
/// anything else unchanged.
pub(crate) fn file_url_path(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("kitty-shell-cwd://") {
        return rest.find('/').map_or("/", |i| &rest[i..]).to_owned();
    }
    let Some(rest) = url.strip_prefix("file://") else {
        return url.to_owned();
    };
    let path = rest.find('/').map_or("/", |i| &rest[i..]);
    let mut decoded = Vec::with_capacity(path.len());
    let bytes = path.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(byte) = bytes
                .get(i + 1..i + 3)
                .and_then(|hex| std::str::from_utf8(hex).ok())
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
        {
            decoded.push(byte);
            i += 3;
            continue;
        }
        decoded.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan(chunks: &[&[u8]]) -> Vec<Osc> {
        let mut scanner = OscScanner::default();
        let mut found = Vec::new();
        for chunk in chunks {
            scanner.feed(chunk, |osc| found.push(osc));
        }
        found
    }

    #[test]
    fn recognises_split_sequences() {
        let got = scan(&[
            b"hi\x1b]0;ti",
            b"tle\x07\x1b]7;file://mac/home/a%20b\x1b",
            b"\\\x1b]133;B\x07\x1b]9;4;1;50\x07\x1b]7501;working\x1b\\\x1b]52;c;xx\x07",
            b"\x1b]7;kitty-shell-cwd://mac/home/a%20b\x07",
        ]);
        assert_eq!(
            got,
            [
                Osc::Title("title".into()),
                Osc::Cwd("/home/a b".into()),
                Osc::Notify("4;1;50".into()),
                Osc::ProgramStatus("working".into()),
                Osc::Cwd("/home/a%20b".into()),
            ]
        );
    }

    #[test]
    fn titles_and_directories_print_as_they_are() {
        let got = scan(&[
            "\x1b]2;Build\u{202e}gnissap\u{202c} ok\x07".as_bytes(),
            b"\x1b]7;file://h/tmp/a%0Ab\x07\x1b]7;rm -rf ~\x07\x1b]7;file://h/ok\x07",
        ]);
        assert_eq!(
            got,
            [Osc::Title("Buildgnissap ok".into()), Osc::Cwd("/ok".into())]
        );
    }

    #[test]
    fn clipboard_writes_are_recognised_and_reads_never() {
        let b64 = |text: &str| data_encoding::BASE64.encode(text.as_bytes());
        let write = format!("\x1b]52;c;{}\x07", b64("yanked line"));
        assert_eq!(
            scan(&[write.as_bytes()]),
            [Osc::Clipboard("yanked line".into())]
        );
        // tmux sends no target; long payloads may be wrapped and unpadded.
        let wrapped = format!("\x1b]52;;{}\x1b\\", "eWFu\na2Vk");
        assert_eq!(
            scan(&[wrapped.as_bytes()]),
            [Osc::Clipboard("yanked".into())]
        );
        // A read, an empty write, junk and a write past the limit do nothing.
        for body in [
            "52;c;?".to_owned(),
            "52;c;".to_owned(),
            "52;c;!!!".to_owned(),
            "52;x;aGk=".to_owned(),
            format!("52;c;{}", b64(&"x".repeat(proto::MAX_CLIPBOARD_BYTES + 1))),
        ] {
            let seq = format!("\x1b]{body}\x07");
            assert!(
                scan(&[seq.as_bytes()]).is_empty(),
                "{}",
                &body[..body.len().min(20)]
            );
        }
        // The largest allowed write gets through.
        let big = "y".repeat(proto::MAX_CLIPBOARD_BYTES);
        let seq = format!("\x1b]52;c;{}\x07", b64(&big));
        assert_eq!(scan(&[seq.as_bytes()]), [Osc::Clipboard(big)]);
    }

    #[test]
    fn progress_reports_parse_as_ghostty_reads_them() {
        assert_eq!(Progress::parse("4;1;50"), Some(Progress::Set(50)));
        assert_eq!(Progress::parse("4;1;250"), Some(Progress::Set(100)));
        assert_eq!(Progress::parse("4;1"), Some(Progress::Set(0)));
        assert_eq!(Progress::parse("4;0"), Some(Progress::Remove));
        assert_eq!(Progress::parse("4;0;0"), Some(Progress::Remove));
        assert_eq!(Progress::parse("4;2"), Some(Progress::Error(None)));
        assert_eq!(Progress::parse("4;3;"), Some(Progress::Indeterminate));
        assert_eq!(Progress::parse("4;4;20"), Some(Progress::Paused(Some(20))));
        for body in ["4;5;1", "4;1;x", "4", "Approval requested: ls", "44;1;2"] {
            assert_eq!(Progress::parse(body), None, "{body}");
        }
    }

    #[test]
    fn oversized_bodies_are_dropped() {
        let mut big = b"\x1b]0;".to_vec();
        big.extend(std::iter::repeat_n(b'x', MAX_BODY + 10));
        big.push(0x07);
        assert!(scan(&[&big]).is_empty());
    }
}
