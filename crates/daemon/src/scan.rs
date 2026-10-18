//! Text-level features over a pane's screen: scrollback search and link/path detection.
//!
//! Both work on plain text the pane's VT extracts, with soft-wrapped rows joined into logical
//! lines. Positions are mapped back to cells by laying each line out again with
//! libghostty-vt's character widths, wrapping wide characters that do not fit exactly as the
//! terminal does.

use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

use ghostty_vt::char_width;
use proto::{CaseMode, Link, LinkKind, LinkSource, SearchMatch, SearchMode, SearchQuery};
use regex::{Regex, RegexBuilder};

/// Most matches a search collects; a larger total is reported as this.
pub(crate) const MAX_MATCHES: usize = 100_000;

/// A screen's text as logical lines, each knowing its first row.
#[derive(Debug)]
pub(crate) struct ScreenText {
    cols: u16,
    pub total_rows: u64,
    lines: Vec<Line>,
}

#[derive(Debug)]
struct Line {
    row: u64,
    text: String,
}

/// A cell position relative to a line's first row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Cell {
    row: u64,
    col: u16,
}

/// Walks `text` as the terminal lays it out in `cols` columns, calling `f(byte, cell, width)`
/// for every character that takes cells. Returns the number of rows used (at least one).
fn layout(text: &str, cols: u16, mut f: impl FnMut(usize, Cell, u16)) -> u64 {
    let cols = cols.max(1);
    let (mut row, mut col) = (0u64, 0u16);
    for (i, c) in text.char_indices() {
        let w = u16::from(char_width(c));
        if w == 0 {
            continue;
        }
        if col + w > cols {
            row += 1;
            col = 0;
        }
        f(i, Cell { row, col }, w);
        col += w;
    }
    row + 1
}

impl ScreenText {
    /// `joined` is the screen's plain text with soft wraps joined, from the top of
    /// scrollback; `total_rows` the terminal's row count.
    pub fn new(joined: &str, cols: u16, total_rows: u64) -> Self {
        let mut row = 0;
        let lines = joined
            .split('\n')
            .map(|text| {
                let line = Line {
                    row,
                    text: text.to_owned(),
                };
                row += layout(text, cols, |_, _, _| {});
                line
            })
            .collect();
        Self {
            cols,
            total_rows,
            lines,
        }
    }

    /// Every match of `re`, newest (bottom right) first, at most [`MAX_MATCHES`].
    pub fn search(&self, re: &Regex) -> Vec<SearchMatch> {
        let mut out = Vec::new();
        for line in self.lines.iter().rev() {
            let spans: Vec<(usize, usize)> = re
                .find_iter(&line.text)
                .filter(|m| !m.is_empty())
                .map(|m| (m.start(), m.end()))
                .collect();
            if spans.is_empty() {
                continue;
            }
            let cells = self.cells(&line.text);
            for (start, end) in spans.into_iter().rev() {
                let first = cells.iter().find(|(b, _, _)| *b >= start);
                let last = cells.iter().rev().find(|(b, _, _)| *b < end);
                let (Some(&(_, first, _)), Some(&(_, last, w))) = (first, last) else {
                    continue;
                };
                out.push(SearchMatch {
                    row: line.row + first.row,
                    col: first.col,
                    end_row: line.row + last.row,
                    end_col: last.col + w - 1,
                    line: line.text.clone(),
                });
                if out.len() >= MAX_MATCHES {
                    return out;
                }
            }
        }
        out
    }

    fn cells(&self, text: &str) -> Vec<(usize, Cell, u16)> {
        let mut cells = Vec::with_capacity(text.len());
        layout(text, self.cols, |b, cell, w| cells.push((b, cell, w)));
        cells
    }
}

/// Compiles a search query.
///
/// # Errors
///
/// Returns the reason for an empty pattern or an invalid regex.
pub(crate) fn compile(query: &SearchQuery) -> Result<Regex, String> {
    if query.pattern.is_empty() {
        return Err("empty pattern".into());
    }
    let pattern = match query.mode {
        SearchMode::Plain => regex::escape(&query.pattern),
        SearchMode::Regex => query.pattern.clone(),
    };
    let insensitive = match query.case {
        CaseMode::Sensitive => false,
        CaseMode::Insensitive => true,
        CaseMode::Smart => !query.pattern.chars().any(char::is_uppercase),
    };
    RegexBuilder::new(&pattern)
        .case_insensitive(insensitive)
        .size_limit(1 << 22)
        .build()
        .map_err(|e| e.to_string())
}

/// Collects links, deduplicated across calls through `seen`.
pub(crate) struct LinkCollector<'a> {
    pub cwd: Option<&'a Path>,
    pub home: Option<&'a Path>,
    pub links: Vec<Link>,
    seen: HashSet<(String, Option<u32>, Option<u32>)>,
}

impl<'a> LinkCollector<'a> {
    pub fn new(cwd: Option<&'a Path>, home: Option<&'a Path>) -> Self {
        Self {
            cwd,
            home,
            links: Vec::new(),
            seen: HashSet::new(),
        }
    }

    fn push(&mut self, link: Link) {
        if self
            .seen
            .insert((link.target.clone(), link.line, link.column))
        {
            self.links.push(link);
        }
    }

    /// Adds the OSC 8 hyperlinks in `vt` (a VT-formatted region), then URLs and paths in
    /// `plain` (the same region as plain text), bottom up.
    pub fn scan(&mut self, vt: &str, plain: &str, source: LinkSource) {
        let mut hyperlinks = hyperlinks(vt);
        hyperlinks.reverse();
        for (uri, text) in hyperlinks {
            self.push(Link {
                kind: LinkKind::Hyperlink,
                text,
                target: uri,
                line: None,
                column: None,
                exists: None,
                source,
            });
        }
        for line in plain.lines().rev() {
            let urls: Vec<(usize, usize)> = url_re()
                .find_iter(line)
                .map(|m| (m.start(), m.start() + trim_url(m.as_str()).len()))
                .collect();
            let mut found = Vec::new();
            for &(start, end) in &urls {
                let url = &line[start..end];
                found.push((
                    start,
                    Link {
                        kind: LinkKind::Url,
                        text: url.to_owned(),
                        target: url.to_owned(),
                        line: None,
                        column: None,
                        exists: None,
                        source,
                    },
                ));
            }
            for caps in path_re().captures_iter(line) {
                let whole = caps.get(0).expect("group 0 always matches");
                let overlaps_url = urls
                    .iter()
                    .any(|&(s, e)| whole.start() < e && s < whole.end());
                let glued = line[..whole.start()]
                    .chars()
                    .next_back()
                    .is_some_and(|c| c.is_alphanumeric() || "/._-~:".contains(c));
                if overlaps_url || glued {
                    continue;
                }
                let raw = &caps["path"];
                let Some(target) = self.resolve(raw) else {
                    continue;
                };
                let exists = target.exists();
                let explicit = raw.starts_with('/')
                    || raw.starts_with("~/")
                    || raw.starts_with("./")
                    || raw.starts_with("../");
                if !exists && !(explicit && raw.matches('/').count() >= 2) {
                    continue;
                }
                let number = |name| caps.name(name).and_then(|m| m.as_str().parse().ok());
                found.push((
                    whole.start(),
                    Link {
                        kind: LinkKind::Path,
                        text: whole.as_str().to_owned(),
                        target: target.to_string_lossy().into_owned(),
                        line: number("line"),
                        column: number("col"),
                        exists: Some(exists),
                        source,
                    },
                ));
            }
            // Right to left within the line, matching the bottom-up order.
            found.sort_by_key(|(start, _)| std::cmp::Reverse(*start));
            for (_, link) in found {
                self.push(link);
            }
        }
    }

    fn resolve(&self, raw: &str) -> Option<PathBuf> {
        let path = if raw == "~" {
            self.home?.to_owned()
        } else if let Some(rest) = raw.strip_prefix("~/") {
            self.home?.join(rest)
        } else if raw.starts_with('/') {
            PathBuf::from(raw)
        } else {
            self.cwd?.join(raw)
        };
        Some(normalize(&path))
    }
}

/// Removes `.` and resolves `..` lexically (symlinks are kept as written).
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

fn url_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)\b(?:https?|wss?|ftp|file|ssh|git|vscode)://[^\s<>\x22'`\x00-\x1f]+")
            .expect("valid URL regex")
    })
}

fn path_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        let seg = r"[\w.@%+=~-]+";
        let name = r"[\w@%+=~-][\w.@%+=~-]*";
        Regex::new(&format!(
            r"(?P<path>(?:~|\.{{1,2}})?(?:/{seg})+/?|{name}(?:/{seg})+/?|{name}\.[A-Za-z]\w{{0,9}}|~)(?::(?P<line>\d+)(?::(?P<col>\d+))?)?"
        ))
        .expect("valid path regex")
    })
}

/// Drops trailing punctuation that is almost never part of a URL, and an unbalanced `)`.
fn trim_url(url: &str) -> &str {
    let mut s = url;
    loop {
        let Some(last) = s.chars().next_back() else {
            return s;
        };
        let unbalanced = |open, close| s.matches(open).count() < s.matches(close).count();
        let trim = match last {
            '.' | ',' | ';' | ':' | '!' | '?' => true,
            ')' => unbalanced('(', ')'),
            ']' => unbalanced('[', ']'),
            '}' => unbalanced('{', '}'),
            _ => false,
        };
        if !trim {
            return s;
        }
        s = &s[..s.len() - last.len_utf8()];
    }
}

/// `(uri, text)` of every OSC 8 hyperlink in VT-formatted text, in order.
fn hyperlinks(vt: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut rest = vt;
    while let Some(start) = rest.find("\x1b]8;") {
        let after = &rest[start + 4..];
        let Some((uri, body)) = osc_body(after).and_then(|(osc, body)| {
            let (_, uri) = osc.split_once(';')?;
            Some((uri, body))
        }) else {
            rest = after;
            continue;
        };
        if uri.is_empty() {
            rest = body;
            continue;
        }
        let end = body.find("\x1b]8;").unwrap_or(body.len());
        let text = strip_escapes(&body[..end]).trim().to_owned();
        out.push((uri.to_owned(), text));
        rest = &body[end..];
    }
    out
}

/// Splits `s` at the end of an OSC (BEL or ST), returning the body and what follows.
fn osc_body(s: &str) -> Option<(&str, &str)> {
    let bel = s.find('\x07');
    let st = s.find("\x1b\\");
    match (bel, st) {
        (Some(b), Some(t)) if b < t => Some((&s[..b], &s[b + 1..])),
        (_, Some(t)) => Some((&s[..t], &s[t + 2..])),
        (Some(b), None) => Some((&s[..b], &s[b + 1..])),
        (None, None) => None,
    }
}

/// Plain text of VT output: CSI, OSC and two-byte escapes removed.
fn strip_escapes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            if !c.is_control() || c == '\n' {
                out.push(c);
            }
            continue;
        }
        match chars.next() {
            Some('[') => {
                for c in chars.by_ref() {
                    if ('\x40'..='\x7e').contains(&c) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(c) = chars.next() {
                    if c == '\x07' || (c == '\x1b' && chars.next_if_eq(&'\\').is_some()) {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query(pattern: &str, mode: SearchMode, case: CaseMode) -> Regex {
        compile(&SearchQuery {
            pattern: pattern.into(),
            mode,
            case,
        })
        .unwrap()
    }

    #[test]
    fn search_maps_wrapped_and_wide_text_to_cells() {
        // 10 columns: "0123456789abc" wraps after 9; "漢字" never splits a wide char.
        let text = ScreenText::new("first\n0123456789abc\nxxxxxxxxx漢字 end", 10, 6);
        let found = text.search(&query("9ab", SearchMode::Plain, CaseMode::Sensitive));
        assert_eq!(found.len(), 1);
        let m = &found[0];
        assert_eq!((m.row, m.col, m.end_row, m.end_col), (1, 9, 2, 1));
        let found = text.search(&query("字 E", SearchMode::Plain, CaseMode::Insensitive));
        let m = &found[0];
        // "xxxxxxxxx" fills 9 cells; 漢 (2 wide) wraps to row 4, 字 follows at col 2.
        assert_eq!((m.row, m.col, m.end_row, m.end_col), (4, 2, 4, 5));
    }

    #[test]
    fn search_is_newest_first_with_case_rules() {
        let text = ScreenText::new("Error one\nok\nerror two error", 80, 3);
        let smart = text.search(&query("error", SearchMode::Plain, CaseMode::Smart));
        let at: Vec<_> = smart.iter().map(|m| (m.row, m.col)).collect();
        assert_eq!(at, [(2, 10), (2, 0), (0, 0)]);
        let upper = text.search(&query("Error", SearchMode::Plain, CaseMode::Smart));
        assert_eq!(upper.len(), 1);
        let re = text.search(&query(r"e\w+r t", SearchMode::Regex, CaseMode::Sensitive));
        assert_eq!(re.len(), 1);
        assert!(
            compile(&SearchQuery {
                pattern: "(".into(),
                mode: SearchMode::Regex,
                case: CaseMode::Smart
            })
            .is_err()
        );
    }

    #[test]
    fn links_paths_and_hyperlinks() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("src")).unwrap();
        std::fs::write(dir.path().join("src/main.rs"), "").unwrap();
        std::fs::write(dir.path().join("Cargo.toml"), "").unwrap();
        let plain = "see https://example.com/a_(b). and src/main.rs:12:5\n\
                     error in Cargo.toml, not in nope.toml or 1/2\n\
                     /definitely/missing/file.txt ./src/main.rs";
        let vt = "x \x1b]8;id=1;https://docs.rs/\x1b\\\x1b[1mdocs\x1b[0m\x1b]8;;\x1b\\ y";
        let mut c = LinkCollector::new(Some(dir.path()), None);
        c.scan(vt, plain, LinkSource::Screen);
        let got: Vec<_> = c
            .links
            .iter()
            .map(|l| (l.kind, l.text.as_str(), l.exists, l.line, l.column))
            .collect();
        assert_eq!(
            got,
            [
                (LinkKind::Hyperlink, "docs", None, None, None),
                (LinkKind::Path, "./src/main.rs", Some(true), None, None),
                (
                    LinkKind::Path,
                    "/definitely/missing/file.txt",
                    Some(false),
                    None,
                    None
                ),
                (LinkKind::Path, "Cargo.toml", Some(true), None, None),
                (
                    LinkKind::Path,
                    "src/main.rs:12:5",
                    Some(true),
                    Some(12),
                    Some(5)
                ),
                (LinkKind::Url, "https://example.com/a_(b)", None, None, None),
            ]
        );
        assert_eq!(
            c.links[4].target,
            dir.path().join("src/main.rs").to_string_lossy()
        );
        // A second scan of the same targets adds nothing.
        c.scan(vt, plain, LinkSource::Command { command_id: 1 });
        assert_eq!(c.links.len(), 6);
    }
}
