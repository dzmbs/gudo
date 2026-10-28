//! Output as an agent reads it: bytes rendered by a scratch terminal (so carriage returns,
//! erases and colors come out as a person sees them), capped with the head and tail kept.

use ghostty_vt::{Terminal, TextRegion};
use serde::Serialize;

use proto::Seq;

/// Rows of the scratch terminal; older lines scroll into its history, which `text` includes.
const SCRATCH_ROWS: u16 = 24;

/// What a read returns.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Output {
    /// Rendered text, soft wraps joined, trailing blank lines dropped.
    pub text: String,
    /// Lines in `text`.
    pub lines: usize,
    /// The middle was left out to fit (head and tail kept).
    pub truncated: bool,
    /// Lines left out.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub omitted_lines: Option<usize>,
    /// Pass as `since` to read only what comes after.
    pub cursor: String,
}

impl Output {
    pub fn new(text: String, max_bytes: usize, at: Seq) -> Self {
        let (text, omitted) = cap(text, max_bytes);
        Self {
            lines: text.lines().count(),
            truncated: omitted.is_some(),
            omitted_lines: omitted,
            text,
            cursor: cursor(at),
        }
    }
}

pub fn cursor(at: Seq) -> String {
    format!("c{}", at.0)
}

pub fn parse_cursor(cursor: &str) -> Option<Seq> {
    cursor.strip_prefix('c')?.parse().ok().map(Seq)
}

/// Renders PTY output on a terminal `cols` wide.
pub fn render(bytes: &[u8], cols: u16) -> String {
    let Ok(mut term) = Terminal::new(cols.max(20), SCRATCH_ROWS) else {
        return String::from_utf8_lossy(bytes).into_owned();
    };
    let _ = term.set_scrollback_max_bytes(Some(64 << 20));
    term.write(bytes);
    let text = term.text(TextRegion::All).unwrap_or_default();
    let trimmed = text.trim_end_matches(['\n', ' ']).len();
    let mut text = text;
    text.truncate(trimmed);
    text
}

/// Keeps the first third and the last two thirds of `max_bytes`, by whole lines, with a marker
/// line between. Returns the lines left out.
fn cap(text: String, max_bytes: usize) -> (String, Option<usize>) {
    if text.len() <= max_bytes {
        return (text, None);
    }
    let lines: Vec<&str> = text.lines().collect();
    let (mut head, mut head_bytes) = (0, 0);
    while head < lines.len() && head_bytes + lines[head].len() < max_bytes / 3 {
        head_bytes += lines[head].len() + 1;
        head += 1;
    }
    let (mut tail, mut tail_bytes) = (lines.len(), 0);
    while tail > head && tail_bytes + lines[tail - 1].len() < max_bytes - max_bytes / 3 {
        tail -= 1;
        tail_bytes += lines[tail].len() + 1;
    }
    let omitted = tail - head;
    let mut out = lines[..head].join("\n");
    out.push_str(&format!(
        "\n… {omitted} lines left out (read on with `since`, or narrow with `grep`) …\n"
    ));
    out.push_str(&lines[tail..].join("\n"));
    (out, Some(omitted))
}

/// The lines matching `pattern`, each with `context` lines around it.
pub fn grep(text: &str, pattern: &regex::Regex, context: usize) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let mut keep = vec![false; lines.len()];
    for (i, line) in lines.iter().enumerate() {
        if pattern.is_match(line) {
            let from = i.saturating_sub(context);
            let to = (i + context + 1).min(lines.len());
            keep[from..to].iter_mut().for_each(|k| *k = true);
        }
    }
    let mut out = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        if keep[i] {
            if i > 0 && !keep[i - 1] && !out.is_empty() {
                out.push("--");
            }
            out.push(line);
        }
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn carriage_returns_and_erases_render_as_seen() {
        let text = render(
            b"progress 10%\rprogress 100%\r\nok \x1b[31mred\x1b[0m\r\n",
            80,
        );
        assert_eq!(text, "progress 100%\nok red");
    }

    #[test]
    fn long_output_keeps_head_and_tail() {
        let text: String = (0..1000).map(|i| format!("line {i}\n")).collect();
        let out = Output::new(text, 2000, Seq(7));
        assert!(out.truncated);
        assert!(out.text.starts_with("line 0\n"));
        assert!(out.text.ends_with("line 999"));
        assert!(out.text.len() < 2200);
        assert_eq!(out.cursor, "c7");
    }

    #[test]
    fn grep_keeps_context() {
        let re = regex::Regex::new("error").unwrap();
        let text = "a\nb\nerror one\nc\nd\ne\nerror two\nf";
        assert_eq!(grep(text, &re, 1), "b\nerror one\nc\n--\ne\nerror two\nf");
    }
}
