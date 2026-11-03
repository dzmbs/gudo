//! The visible screen as a full-screen program draws it: size, cursor, and the runs of cells
//! it sets apart (reverse video or a background of their own), which is how menus, pickers
//! and dialogs show the selected item.

use std::collections::HashMap;

use ghostty_vt::{CellWidth, Color, Mode, Row, Terminal};
use serde::Serialize;

use super::output::visible;

const MAX_HIGHLIGHTS: usize = 64;
const MAX_HIGHLIGHT_CHARS: usize = 240;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScreenView {
    pub cols: u16,
    pub rows: u16,
    pub cursor: ScreenCursor,
    pub highlights: Vec<Highlight>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScreenCursor {
    /// From 0 at the top of the visible screen.
    pub row: u16,
    pub col: u16,
    pub visible: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Highlight {
    pub row: u16,
    pub col: u16,
    pub text: String,
    /// Reverse video rather than a background color.
    pub inverse: bool,
}

pub(crate) fn view(term: &Terminal) -> ScreenView {
    let rows = term.rows();
    let first = term.total_rows().saturating_sub(usize::from(rows));
    let grid: Vec<Row> = (0..rows)
        .filter_map(|y| term.row((first + usize::from(y)) as u32).ok())
        .collect();
    let cursor = term.cursor();
    ScreenView {
        cols: term.cols(),
        rows,
        cursor: ScreenCursor {
            row: cursor.y,
            col: cursor.x,
            visible: term.mode(Mode::CURSOR_VISIBLE),
        },
        highlights: highlights(&grid),
    }
}

/// Runs of cells drawn apart from the screen's own background, top to bottom.
///
/// The background most cells share counts as the screen's, so a program that paints the
/// whole screen in one color does not mark every row.
pub(crate) fn highlights(rows: &[Row]) -> Vec<Highlight> {
    let mut counts: HashMap<Color, usize> = HashMap::new();
    for cell in rows.iter().flat_map(|row| &row.cells) {
        if !cell.style.inverse {
            *counts.entry(cell.style.bg).or_default() += 1;
        }
    }
    let canvas = counts
        .into_iter()
        .max_by_key(|(color, count)| (*count, *color == Color::Default))
        .map_or(Color::Default, |(color, _)| color);
    let mark = |cell: &ghostty_vt::Cell| {
        (cell.style.inverse || cell.style.bg != canvas)
            .then_some((cell.style.inverse, cell.style.bg))
    };

    let mut found = Vec::new();
    for (y, row) in rows.iter().enumerate() {
        let mut x = 0;
        while x < row.cells.len() {
            let Some(key) = mark(&row.cells[x]) else {
                x += 1;
                continue;
            };
            let start = x;
            let mut text = String::new();
            while x < row.cells.len() && mark(&row.cells[x]) == Some(key) {
                let cell = &row.cells[x];
                if cell.text.is_empty() && cell.width != CellWidth::SpacerTail {
                    text.push(' ');
                } else {
                    text.push_str(&cell.text);
                }
                x += 1;
            }
            let leading = text.len() - text.trim_start().len();
            let text: String = visible(text.trim())
                .chars()
                .take(MAX_HIGHLIGHT_CHARS)
                .collect();
            if text.is_empty() {
                continue;
            }
            found.push(Highlight {
                row: y as u16,
                col: (start + leading) as u16,
                text,
                inverse: key.0,
            });
            if found.len() == MAX_HIGHLIGHTS {
                return found;
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(cols: u16, rows: u16, bytes: &[u8]) -> ScreenView {
        let mut term = Terminal::new(cols, rows).unwrap();
        term.write(bytes);
        view(&term)
    }

    #[test]
    fn a_selected_menu_item_stands_out() {
        let view = screen(
            20,
            4,
            b"  apples\r\n\x1b[7m> pears \x1b[0m\r\n  plums\x1b[?25l",
        );
        assert_eq!(view.cols, 20);
        assert_eq!(view.rows, 4);
        assert_eq!(view.cursor.row, 2);
        assert_eq!(view.cursor.col, 7);
        assert!(!view.cursor.visible);
        assert_eq!(
            view.highlights,
            vec![Highlight {
                row: 1,
                col: 0,
                text: "> pears".into(),
                inverse: true,
            }]
        );
    }

    #[test]
    fn a_painted_screen_marks_only_what_differs() {
        let mut bytes = b"\x1b[44m\x1b[2J\x1b[H".to_vec();
        bytes.extend_from_slice(b"one\r\n\x1b[42m  two  \x1b[44m\r\nthree");
        let view = screen(10, 3, &bytes);
        assert_eq!(view.highlights.len(), 1);
        assert_eq!(view.highlights[0].row, 1);
        assert_eq!(view.highlights[0].col, 2);
        assert_eq!(view.highlights[0].text, "two");
        assert!(!view.highlights[0].inverse);
    }

    #[test]
    fn blank_runs_and_plain_text_are_not_highlights() {
        let view = screen(10, 2, b"plain\r\n\x1b[7m   \x1b[0m");
        assert!(view.highlights.is_empty());
    }
}
