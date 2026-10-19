//!
//! The input starts at the `133;B` pin (or, for shells that do not send it, where the cursor
//! was once the prompt was drawn). From there the text runs to the end of the logical line the
//! cursor is on: rows between the start and the cursor are joined (soft wraps with nothing,
//! hard line breaks with `\n`), then the cursor's row and the rows it soft-wraps into. Cells
//! the shell marked as prompt text (continuation prompts) are dropped.
//!
//! Three things on that line are not input, and are cut:
//!
//! - **Autosuggestions** (zsh-autosuggestions `POSTDISPLAY`, fish): text from the cursor to the
//!   end drawn faint, in palette color 8 (bright black, the default of both), in the 256-color
//!   grey ramp (232–250), or in a dim grey RGB color, when the text before the cursor is not.
//!   It is reported as the suggestion. Text after the cursor in another single non-default
//!   style the typed text does not use is kept but flagged ([`InputDoubt::PossibleGhostText`]).
//! - **Right prompts**: the text drawn after a gap on the first row when the prompt appeared
//!   is remembered and cut while it is still there. Unremembered trailing text at the right
//!   edge after a wide gap is cut as a guess ([`InputDoubt::RightPromptGuess`]).
//! - **Rows below** the cursor's line (a completion listing, or the rest of a multi-line
//!   buffer): left out and flagged ([`InputDoubt::ContentBelow`]).

use ghostty_vt::{Cell, CellStyle, CellWidth, Color, Point, Row, Semantic, Terminal};
use proto::InputDoubt;

use super::marks::{LineView, RightPrompt};

/// Rows read below the cursor to notice listings.
const ROWS_BELOW: u32 = 24;
/// Rows read above the cursor at most (a very long command line).
const MAX_ROWS: u32 = 200;
/// Gap (blank cells) before trailing text that makes it look like a right prompt.
const RIGHT_PROMPT_GAP: usize = 3;

/// The rows around an input line, copied out of the terminal.
#[derive(Debug, Clone)]
pub(crate) struct Screen {
    /// `rows[i]` is screen row `first_y + i`.
    pub rows: Vec<Row>,
    pub first_y: u32,
    pub start: Point,
    pub cursor: Point,
}

impl Screen {
    /// Copies the rows from the input start to a little below the cursor.
    pub fn capture(term: &Terminal, view: &LineView) -> Option<Self> {
        let start = term.pin_point(view.input?)?;
        let cursor = term.cursor_point();
        let last_row = (term.total_rows() as u32).saturating_sub(1);
        let first_y = start.y.max(cursor.y.saturating_sub(MAX_ROWS));
        let end_y = last_row.min(cursor.y.max(start.y) + ROWS_BELOW);
        let rows = (first_y..=end_y)
            .map(|y| term.row(y))
            .collect::<Result<Vec<_>, _>>()
            .ok()?;
        Some(Self {
            rows,
            first_y,
            start,
            cursor,
        })
    }
}

/// What was read.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Reading {
    pub text: String,
    pub cursor: u32,
    pub doubt: Option<InputDoubt>,
    pub suggestion: Option<String>,
    pub right_prompt: bool,
}

/// One character of the input with where and how it is drawn.
#[derive(Debug, Clone)]
struct Glyph {
    text: String,
    at: Point,
    style: CellStyle,
}

/// Reads the input line.
pub(crate) fn read(screen: &Screen, view: &LineView) -> Reading {
    let mut doubt = None;
    let mut note = |d: InputDoubt| {
        doubt.get_or_insert(d);
    };
    if view.inferred {
        note(InputDoubt::NoInputMark);
    }
    if view.continuation {
        note(InputDoubt::Continuation);
    }
    let (start, cursor) = (screen.start, screen.cursor);
    if cursor < start || start.y < screen.first_y {
        note(InputDoubt::CursorOutside);
    }

    // Rows of the input: up to the cursor's row, then while rows soft-wrap.
    let mut glyphs: Vec<Glyph> = Vec::new();
    let mut right_prompt = false;
    let mut y = start.y.max(screen.first_y);
    while let Some(row) = screen.rows.get((y - screen.first_y) as usize) {
        let from = if y == start.y { start.x } else { 0 };
        let mut cells: Vec<(u16, &Cell)> = row
            .cells
            .iter()
            .enumerate()
            .skip(usize::from(from))
            .map(|(x, c)| (x as u16, c))
            .collect();
        if y == start.y {
            match cut_right_prompt(&mut cells, view.right_prompt.as_ref(), cursor, y, row) {
                Cut::Known => right_prompt = true,
                Cut::Guess => {
                    right_prompt = true;
                    note(InputDoubt::RightPromptGuess);
                }
                Cut::None => {}
            }
        }
        // A row's text ends at its last non-blank cell, or (on the cursor's row) just before
        // the cursor, which keeps typed trailing spaces.
        let keep_to = if row.wrapped {
            u16::MAX
        } else {
            let last = cells
                .iter()
                .rev()
                .find(|(_, c)| !c.is_blank())
                .map(|(x, _)| x + 1);
            let cursor_end = (cursor.y == y).then_some(cursor.x);
            last.max(cursor_end).unwrap_or(from)
        };
        for (x, cell) in cells {
            if x >= keep_to {
                break;
            }
            if matches!(cell.width, CellWidth::SpacerTail | CellWidth::SpacerHead) {
                continue;
            }
            // Continuation prompts inside the input; without a `133;B` everything the shell
            // drew counts as prompt, so the mark cannot be used.
            if cell.semantic == Semantic::Prompt && !view.inferred {
                continue;
            }
            glyphs.push(Glyph {
                text: if cell.text.is_empty() {
                    " ".into()
                } else {
                    cell.text.clone()
                },
                at: Point { y, x },
                style: cell.style,
            });
        }
        let past_cursor = y >= cursor.y;
        if past_cursor && !row.wrapped {
            break;
        }
        if !row.wrapped {
            glyphs.push(Glyph {
                text: "\n".into(),
                at: Point { y, x: u16::MAX },
                style: CellStyle::default(),
            });
        }
        y += 1;
    }
    // Rows after the input line.
    let below = screen
        .rows
        .iter()
        .skip((y + 1).saturating_sub(screen.first_y) as usize)
        .any(|r| r.cells.iter().any(|c| !c.is_blank()));
    if below {
        note(InputDoubt::ContentBelow);
    }

    let cursor_index = glyphs.iter().take_while(|g| g.at < cursor).count();
    let (glyphs, suggestion) = split_suggestion(glyphs, cursor_index, &mut note);
    let text: String = glyphs.iter().map(|g| g.text.as_str()).collect();
    let cursor_index = cursor_index.min(glyphs.len());
    Reading {
        cursor: text.chars().count().min(
            glyphs[..cursor_index]
                .iter()
                .map(|g| g.text.chars().count())
                .sum(),
        ) as u32,
        text,
        doubt,
        suggestion,
        right_prompt,
    }
}

enum Cut {
    None,
    Known,
    Guess,
}

/// Removes a right prompt from the input's first row.
fn cut_right_prompt(
    cells: &mut Vec<(u16, &Cell)>,
    known: Option<&RightPrompt>,
    cursor: Point,
    y: u32,
    row: &Row,
) -> Cut {
    if row.wrapped {
        return Cut::None;
    }
    let cursor_col = if cursor.y == y { cursor.x } else { u16::MAX };
    if let Some(rp) = known
        && rp.col > cursor_col.min(u16::MAX - 1)
    {
        let matches = rp.cells.iter().enumerate().all(|(i, text)| {
            cells
                .iter()
                .find(|(x, _)| usize::from(*x) == usize::from(rp.col) + i)
                .is_some_and(|(_, c)| &c.text == text)
        });
        let nothing_after = cells
            .iter()
            .filter(|(x, _)| usize::from(*x) >= usize::from(rp.col) + rp.cells.len())
            .all(|(_, c)| c.is_blank());
        if matches && nothing_after {
            cells.retain(|(x, _)| *x < rp.col);
            return Cut::Known;
        }
    }
    // Unknown: trailing text ending at the right edge after a wide gap, past the cursor.
    let cols = row.cells.len();
    let Some(last) = cells.iter().rposition(|(_, c)| !c.is_blank()) else {
        return Cut::None;
    };
    if usize::from(cells[last].0) + 2 < cols {
        return Cut::None;
    }
    let mut first = last;
    while first > 0 && !cells[first - 1].1.is_blank() {
        first -= 1;
    }
    let gap = cells[..first]
        .iter()
        .rev()
        .take_while(|(_, c)| c.is_blank())
        .count();
    let typed_before = cells[..first].iter().any(|(_, c)| !c.is_blank());
    if gap >= RIGHT_PROMPT_GAP && typed_before && cells[first].0 > cursor_col.min(u16::MAX - 1) {
        let col = cells[first].0;
        cells.retain(|(x, _)| *x < col);
        return Cut::Guess;
    }
    Cut::None
}

/// Splits a ghost-styled tail from the cursor on.
fn split_suggestion(
    mut glyphs: Vec<Glyph>,
    cursor: usize,
    note: &mut impl FnMut(InputDoubt),
) -> (Vec<Glyph>, Option<String>) {
    if cursor >= glyphs.len() {
        return (glyphs, None);
    }
    let visible = |g: &&Glyph| g.text != " " && g.text != "\n";
    let after: Vec<&Glyph> = glyphs[cursor..].iter().filter(visible).collect();
    let before: Vec<&Glyph> = glyphs[..cursor].iter().filter(visible).collect();
    if after.is_empty() {
        // Only blanks after the cursor: drop them (a cleared suggestion leaves none, but a
        // trailing space typed before moving left stays inside `text` anyway).
        return (glyphs, None);
    }
    let all_ghost = after.iter().all(|g| ghostlike(g.style));
    let typed_ghost = before.iter().any(|g| ghostlike(g.style));
    if all_ghost && !typed_ghost {
        let tail: String = glyphs[cursor..].iter().map(|g| g.text.as_str()).collect();
        glyphs.truncate(cursor);
        let tail = tail.trim_end().to_owned();
        return (glyphs, Some(tail).filter(|t| !t.is_empty()));
    }
    let one_style = after.iter().all(|g| g.style == after[0].style);
    let foreign =
        after[0].style != CellStyle::default() && before.iter().all(|g| g.style != after[0].style);
    if after.iter().any(|g| ghostlike(g.style)) || (one_style && foreign && !before.is_empty()) {
        note(InputDoubt::PossibleGhostText);
    }
    (glyphs, None)
}

/// Styles autosuggestion plugins draw with.
fn ghostlike(style: CellStyle) -> bool {
    if style.faint {
        return true;
    }
    match style.fg {
        Color::Palette(8) => true,
        Color::Palette(n) => (232..=250).contains(&n),
        Color::Rgb(r, g, b) => {
            let (hi, lo) = (r.max(g).max(b), r.min(g).min(b));
            hi - lo <= 24 && (60..=170).contains(&hi)
        }
        Color::Default => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CommandLog;
    use proto::{PaneId, Seq};

    struct Fixture {
        term: Terminal,
        log: CommandLog,
    }

    impl Fixture {
        fn new(cols: u16) -> Self {
            let mut term = Terminal::new(cols, 8).unwrap();
            term.record_semantic_prompts().unwrap();
            Self {
                term,
                log: CommandLog::default(),
            }
        }

        fn feed(&mut self, bytes: &str) -> &mut Self {
            self.term.write(bytes.as_bytes());
            let events = self.term.take_semantic_prompts();
            self.log.apply(&mut self.term, PaneId(1), Seq(0), events);
            self.log.after_output(&mut self.term);
            self
        }

        fn read(&self) -> Reading {
            let view = self.log.line_marks();
            let screen = Screen::capture(&self.term, &view).expect("input start");
            read(&screen, &view)
        }
    }

    const PROMPT: &str = "\x1b]133;A\x07$ \x1b]133;B\x07";

    #[test]
    fn plain_line_with_cursor_in_the_middle() {
        let mut f = Fixture::new(40);
        f.feed(PROMPT).feed("git status\x1b[4D");
        let r = f.read();
        assert_eq!(r.text, "git status");
        assert_eq!(r.cursor, 6);
        assert_eq!(r.doubt, None);
    }

    #[test]
    fn trailing_space_before_the_cursor_is_kept() {
        let mut f = Fixture::new(40);
        f.feed(PROMPT).feed("ls ");
        assert_eq!(f.read().text, "ls ");
        assert_eq!(f.read().cursor, 3);
    }

    #[test]
    fn soft_wraps_join_and_wide_characters_count_once() {
        let mut f = Fixture::new(10);
        f.feed(PROMPT).feed("echo 漢字 abcdef");
        let r = f.read();
        assert_eq!(r.text, "echo 漢字 abcdef");
        assert_eq!(r.cursor, r.text.chars().count() as u32);
        assert_eq!(r.doubt, None);
    }

    #[test]
    fn autosuggestion_is_cut_and_reported() {
        let mut f = Fixture::new(40);
        // zsh-autosuggestions: POSTDISPLAY drawn with fg=8, cursor back at the buffer end.
        f.feed(PROMPT)
            .feed("git st\x1b[38;5;8matus --short\x1b[0m\x1b[12D");
        let r = f.read();
        assert_eq!(r.text, "git st");
        assert_eq!(r.cursor, 6);
        assert_eq!(r.suggestion.as_deref(), Some("atus --short"));
        assert_eq!(r.doubt, None);
        // Faint works too.
        let mut f = Fixture::new(40);
        f.feed(PROMPT).feed("ls\x1b[2m -la\x1b[0m\x1b[4D");
        assert_eq!(f.read().text, "ls");
        assert_eq!(f.read().suggestion.as_deref(), Some(" -la"));
    }

    #[test]
    fn syntax_highlighting_is_not_ghost_text() {
        let mut f = Fixture::new(40);
        // A green command word, default args, cursor moved left into the args.
        f.feed(PROMPT).feed("\x1b[32mls\x1b[0m -la\x1b[2D");
        let r = f.read();
        assert_eq!(r.text, "ls -la");
        assert_eq!(r.cursor, 4);
        assert_eq!(r.doubt, None);
    }

    #[test]
    fn unknown_styled_tail_is_doubtful() {
        let mut f = Fixture::new(40);
        f.feed(PROMPT)
            .feed("make\x1b[38;2;200;80;80m test\x1b[0m\x1b[5D");
        let r = f.read();
        assert_eq!(r.text, "make test");
        assert_eq!(r.doubt, Some(InputDoubt::PossibleGhostText));
    }

    #[test]
    fn right_prompt_drawn_with_the_prompt_is_cut() {
        let mut f = Fixture::new(30);
        // zle: prompt, right prompt at the edge, cursor back at the input start.
        f.feed("\x1b]133;A\x07$ \x1b]133;B\x07\x1b[22G[main]\x1b[3G");
        f.feed("echo hi");
        let r = f.read();
        assert_eq!(r.text, "echo hi");
        assert!(r.right_prompt);
        assert_eq!(r.doubt, None);
        // Once the buffer grows over it, zsh removes it.
        f.feed("\x1b[K");
        let r = f.read();
        assert_eq!(r.text, "echo hi");
        assert!(!r.right_prompt);
    }

    #[test]
    fn right_prompt_stays_out_of_the_command_mark() {
        let mut f = Fixture::new(30);
        f.feed("\x1b]133;A\x07$ \x1b]133;B\x07\x1b[22G[main]\x1b[3G");
        f.feed("echo hi\r\n\x1b]133;C\x07");
        let list = f.log.list(&f.term);
        assert_eq!(list[0].mark.command.as_deref(), Some("echo hi"));
    }

    #[test]
    fn unremembered_right_prompt_is_a_guess() {
        let mut f = Fixture::new(30);
        f.feed(PROMPT).feed("echo hi\x1b[25G12:00\x1b[10G");
        let r = f.read();
        assert_eq!(r.text, "echo hi");
        assert_eq!(r.doubt, Some(InputDoubt::RightPromptGuess));
    }

    #[test]
    fn multi_line_prompt_and_listing_below() {
        let mut f = Fixture::new(40);
        f.feed("\x1b]133;A\x07~/src\r\n\x1b]133;P;k=s\x07$ \x1b]133;B\x07cd sr");
        let r = f.read();
        assert_eq!(r.text, "cd sr");
        assert_eq!(r.doubt, None);
        // A completion listing printed below; the cursor goes back to the line.
        f.feed("\x1b7\r\nsrc/  srv/\x1b8");
        let r = f.read();
        assert_eq!(r.text, "cd sr");
        assert_eq!(r.doubt, Some(InputDoubt::ContentBelow));
    }

    #[test]
    fn continuation_prompt_is_flagged() {
        let mut f = Fixture::new(40);
        f.feed(PROMPT)
            .feed("for i in 1 2\r\n\x1b]133;P;k=s\x07> \x1b]133;B\x07do");
        let r = f.read();
        assert_eq!(r.doubt, Some(InputDoubt::Continuation));
        assert_eq!(r.text, "for i in 1 2\ndo");
    }

    #[test]
    fn fish_without_input_mark_infers_the_start() {
        let mut f = Fixture::new(40);
        // The prompt in two reads, then typing a moment later.
        f.feed("\x1b]133;A\x07~");
        f.feed("> ");
        std::thread::sleep(std::time::Duration::from_millis(40));
        f.feed("ls");
        let r = f.read();
        assert_eq!(r.text, "ls");
        assert_eq!(r.doubt, Some(InputDoubt::NoInputMark));
    }

    #[test]
    fn running_and_new_prompt_change_the_id() {
        let mut f = Fixture::new(40);
        f.feed(PROMPT);
        let first = f.log.line_marks().prompt_id;
        f.feed("ls\r\n\x1b]133;C\x07");
        assert!(matches!(
            f.log.line_marks().phase,
            crate::assist::marks::Phase::Running(_)
        ));
        f.feed("a\r\n\x1b]133;D;0\x07").feed(PROMPT);
        assert_ne!(f.log.line_marks().prompt_id, first);
        // A redraw of the same prompt keeps it.
        let id = f.log.line_marks().prompt_id;
        f.feed("\r\x1b[K").feed(PROMPT);
        assert_eq!(f.log.line_marks().prompt_id, id);
    }

    #[test]
    fn leading_space_marks_a_command_private() {
        let mut f = Fixture::new(40);
        f.feed(PROMPT).feed(" export TOKEN=x\r\n\x1b]133;C\x07");
        f.feed("\x1b]133;D;0\x07")
            .feed(PROMPT)
            .feed("ls\r\n\x1b]133;C\x07");
        assert!(f.log.is_private(1));
        assert!(!f.log.is_private(2));
        let list = f.log.list(&f.term);
        assert_eq!(list[0].mark.command.as_deref(), Some("export TOKEN=x"));
    }
}
