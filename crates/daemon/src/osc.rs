//! A streaming OSC extractor for the facts the daemon tracks outside libghostty-vt: titles,
//! working directory and agent reports. Shell-integration marks (OSC 133) come from
//! libghostty-vt itself, with cursor positions (see `commands`).
//!
//! It only recognises `ESC ] … (BEL | ESC \)`; everything else passes through untouched (the
//! VT parser sees every byte regardless). Bodies longer than [`MAX_BODY`] are dropped.

/// Longest OSC body kept. Agent reports and titles are far shorter; OSC 52 clipboard writes
/// are longer and are not ours to read.
const MAX_BODY: usize = 8 * 1024;
/// Longest title kept, in characters.
const MAX_TITLE_CHARS: usize = 512;

/// A recognised OSC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Osc {
    /// OSC 0 or 2.
    Title(String),
    /// OSC 7, as a path (see [`file_url_path`]).
    Cwd(String),
    /// OSC 9 body after `9;` (Codex notifications, progress reports).
    Notify(String),
    /// OSC 7501 body after `7501;` (program status).
    ProgramStatus(String),
}

#[derive(Debug, Default)]
enum State {
    #[default]
    Ground,
    Esc,
    Body,
    BodyEsc,
}

/// Incremental scanner; bytes may be split anywhere.
#[derive(Debug, Default)]
pub(crate) struct OscScanner {
    state: State,
    body: Vec<u8>,
    overflow: bool,
}

impl OscScanner {
    /// Feeds bytes, calling `emit` for every complete OSC recognised.
    pub fn feed(&mut self, data: &[u8], mut emit: impl FnMut(Osc)) {
        let mut rest = data;
        while !rest.is_empty() {
            // Almost all output is outside escapes: skip to the next ESC at once.
            if matches!(self.state, State::Ground) {
                match memchr::memchr(0x1b, rest) {
                    Some(at) => rest = &rest[at..],
                    None => return,
                }
            }
            let b = rest[0];
            rest = &rest[1..];
            self.state = match (&self.state, b) {
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
                    self.push(b);
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

    fn push(&mut self, b: u8) {
        if self.body.len() < MAX_BODY {
            self.body.push(b);
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
            "7" => {
                // Only an absolute path that prints as it is.
                let path = file_url_path(rest);
                let plain = path
                    .chars()
                    .all(|c| !c.is_control() && !proto::is_invisible_format(c));
                if !path.starts_with('/') || !plain {
                    return;
                }
                Osc::Cwd(path)
            }
            "9" => Osc::Notify(rest.to_owned()),
            "7501" => Osc::ProgramStatus(rest.to_owned()),
            _ => return,
        };
        emit(osc);
    }
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
    let mut out = Vec::with_capacity(path.len());
    let bytes = path.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(v) = bytes
                .get(i + 1..i + 3)
                .and_then(|h| std::str::from_utf8(h).ok())
                .and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(v);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan(chunks: &[&[u8]]) -> Vec<Osc> {
        let mut s = OscScanner::default();
        let mut out = Vec::new();
        for c in chunks {
            s.feed(c, |o| out.push(o));
        }
        out
    }

    #[test]
    fn recognises_split_sequences() {
        let got = scan(&[
            b"hi\x1b]0;ti",
            b"tle\x07\x1b]7;file://mac/Users/a%20b\x1b",
            b"\\\x1b]133;B\x07\x1b]9;4;1;50\x07\x1b]7501;working\x1b\\\x1b]52;c;xx\x07",
            b"\x1b]7;kitty-shell-cwd://mac/Users/a%20b\x07",
        ]);
        assert_eq!(
            got,
            [
                Osc::Title("title".into()),
                Osc::Cwd("/Users/a b".into()),
                Osc::Notify("4;1;50".into()),
                Osc::ProgramStatus("working".into()),
                Osc::Cwd("/Users/a%20b".into()),
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
    fn oversized_bodies_are_dropped() {
        let mut big = b"\x1b]0;".to_vec();
        big.extend(std::iter::repeat_n(b'x', MAX_BODY + 10));
        big.push(0x07);
        assert!(scan(&[&big]).is_empty());
    }
}
