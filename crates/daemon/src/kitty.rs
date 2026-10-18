//! Finds PNG images programs display with the kitty graphics protocol (`ESC _ G … ESC \`),
//! image state, and the daemon's VT runs with graphics storage off.
//!
//! Handled: direct transmission (`t=d`, the default) of PNG data (`f=100`) displayed at once
//! (`a=T`), in one APC or chunked with `m=1`; `c`/`r` give the size in cells. Not handled
//! (documented gap): images transmitted first and placed later (`a=t` then `a=p`), raw
//! RGB(A) data, file / shared-memory transmission, animation, deletion.

use std::collections::HashMap;

/// Longest base64 payload collected for one image.
const MAX_PAYLOAD: usize = 48 << 20;

/// A completed image: where in the chunk its last APC ended, the PNG, and its size in cells
/// (0 = unspecified).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct KittyImage {
    pub end: usize,
    pub png: Vec<u8>,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Default)]
enum State {
    #[default]
    Ground,
    Esc,
    /// Inside an APC; `graphics` once its first byte was `G`.
    Apc {
        graphics: bool,
        esc: bool,
    },
}

#[derive(Debug, Default)]
pub(crate) struct KittyScanner {
    state: State,
    body: Vec<u8>,
    /// Params of the first chunk and the payload so far of a chunked transmission.
    pending: Option<(HashMap<String, String>, Vec<u8>)>,
}

fn params(s: &str) -> HashMap<String, String> {
    s.split(',')
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
}

impl KittyScanner {
    /// Feeds output; returns the images completed in it.
    pub fn feed(&mut self, data: &[u8]) -> Vec<KittyImage> {
        let mut out = Vec::new();
        for (i, &b) in data.iter().enumerate() {
            self.state = match std::mem::take(&mut self.state) {
                State::Ground if b == 0x1b => State::Esc,
                State::Ground => State::Ground,
                State::Esc if b == b'_' => {
                    self.body.clear();
                    State::Apc {
                        graphics: false,
                        esc: false,
                    }
                }
                State::Esc if b == 0x1b => State::Esc,
                State::Esc => State::Ground,
                State::Apc { graphics, esc } => {
                    if esc && b == b'\\' {
                        if graphics && let Some(img) = self.finish(i + 1) {
                            out.push(img);
                        }
                        State::Ground
                    } else if b == 0x1b {
                        State::Apc {
                            graphics,
                            esc: true,
                        }
                    } else if b == 0x18 || b == 0x1a {
                        // CAN / SUB abort the sequence.
                        State::Ground
                    } else {
                        let graphics = if self.body.is_empty() && !graphics {
                            b == b'G'
                        } else {
                            graphics
                        };
                        if graphics && self.body.len() < MAX_PAYLOAD {
                            self.body.push(b);
                        }
                        State::Apc {
                            graphics,
                            esc: false,
                        }
                    }
                }
            };
        }
        out
    }

    fn finish(&mut self, end: usize) -> Option<KittyImage> {
        let body = std::mem::take(&mut self.body);
        let body = body.strip_prefix(b"G")?;
        let (head, payload) = match body.iter().position(|&b| b == b';') {
            Some(p) => (&body[..p], &body[p + 1..]),
            None => (body, &[][..]),
        };
        let p = params(std::str::from_utf8(head).ok()?);
        let more = p.get("m").is_some_and(|m| m == "1");
        let (first, mut data) = match self.pending.take() {
            Some((first, mut data)) => {
                data.extend_from_slice(payload);
                (first, data)
            }
            None => (p, payload.to_vec()),
        };
        if data.len() > MAX_PAYLOAD {
            return None;
        }
        if more {
            self.pending = Some((first, data));
            return None;
        }
        let get = |k: &str, d: &str| first.get(k).cloned().unwrap_or_else(|| d.to_owned());
        if get("a", "t") != "T" || get("f", "32") != "100" || get("t", "d") != "d" {
            return None;
        }
        data.retain(|b| !b.is_ascii_whitespace());
        let png = data_encoding::BASE64
            .decode(&data)
            .or_else(|_| data_encoding::BASE64_NOPAD.decode(&data))
            .ok()?;
        Some(KittyImage {
            end,
            png,
            cols: get("c", "0").parse().unwrap_or(0),
            rows: get("r", "0").parse().unwrap_or(0),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_and_chunked_png_transmissions() {
        let mut s = KittyScanner::default();
        let one = b"hi\x1b_Ga=T,f=100,c=4,r=2;aGVsbG8=\x1b\\after";
        let got = s.feed(one);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].png, b"hello");
        assert_eq!((got[0].cols, got[0].rows), (4, 2));
        assert_eq!(&one[got[0].end..], b"after");

        // Chunked, and split across feeds anywhere.
        let wire = b"\x1b_Ga=T,f=100,m=1;aGVs\x1b\\\x1b_Gm=1;bG8g\x1b\\\x1b_Gm=0;d29ybGQ=\x1b\\";
        let mut s = KittyScanner::default();
        let mut got = Vec::new();
        for chunk in wire.chunks(3) {
            got.extend(s.feed(chunk));
        }
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].png, b"hello world");

        // Not PNG, not displayed, other APCs: ignored.
        let mut s = KittyScanner::default();
        assert!(s.feed(b"\x1b_Ga=T;AAAA\x1b\\").is_empty());
        assert!(s.feed(b"\x1b_Ga=t,f=100;AAAA\x1b\\").is_empty());
        assert!(s.feed(b"\x1b_Xother\x1b\\").is_empty());
    }
}
