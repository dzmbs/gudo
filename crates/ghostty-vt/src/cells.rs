//! Cell-level reads: the text, width, style and shell-integration role of each cell in a row.
//!
//! [`Terminal::text`] flattens a region to plain text; this module keeps what flattening loses
//! (faint or colored cells, which part of a line the shell marked as prompt or input), which is
//! what reading a shell's input line off the screen needs.

use std::mem;

use ghostty_vt_sys as ffi;

use crate::{Error, Terminal};

/// A color as a cell's style names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Color {
    /// No color set: the terminal's default.
    #[default]
    Default,
    /// An index into the 256-color palette (0–15 are the ANSI colors).
    Palette(u8),
    /// A direct RGB color.
    Rgb(u8, u8, u8),
}

/// The parts of a cell's style that matter for reading text back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct CellStyle {
    pub fg: Color,
    /// SGR 2: faint (dim).
    pub faint: bool,
    pub bold: bool,
    pub italic: bool,
    /// Any underline style.
    pub underline: bool,
    pub inverse: bool,
}

/// How much horizontal space a cell's character takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CellWidth {
    /// One column.
    Narrow,
    /// The first of a two-column character.
    Wide,
    /// The second column of a wide character; it has no text of its own.
    SpacerTail,
    /// Padding at the end of a row before a wide character that wrapped to the next row.
    SpacerHead,
}

/// What shell integration (OSC 133) marked a cell as.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Semantic {
    /// Program output, or anything written outside shell integration.
    Output,
    /// Text the user typed into the shell's line editor (after `133;B`).
    Input,
    /// Prompt text (after `133;A` or `133;P`).
    Prompt,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    /// The grapheme cluster shown, empty for a blank cell or a spacer.
    pub text: String,
    pub width: CellWidth,
    pub style: CellStyle,
    pub semantic: Semantic,
}

impl Cell {
    /// Whether the cell shows nothing (blank, or the tail of a wide character).
    pub fn is_blank(&self) -> bool {
        self.text.is_empty() || self.text == " "
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// The row soft-wraps: its text continues on the next row.
    pub wrapped: bool,
    /// Every column of the row, left to right.
    pub cells: Vec<Cell>,
}

impl Terminal {
    /// Reads row `y` in screen coordinates (row 0 is the oldest scrollback row; see
    /// [`Point`](crate::Point)) of the active screen, one [`Cell`] per column.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidValue`] for a row outside the screen.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), ghostty_vt::Error> {
    /// use ghostty_vt::{Color, Terminal};
    ///
    /// let mut terminal = Terminal::new(10, 2)?;
    /// terminal.write(b"ab\x1b[2;38;5;8mcd");
    /// let row = terminal.row(0)?;
    /// assert_eq!(row.cells[0].text, "a");
    /// assert!(!row.cells[1].style.faint);
    /// assert!(row.cells[2].style.faint);
    /// assert_eq!(row.cells[3].style.fg, Color::Palette(8));
    /// # Ok(())
    /// # }
    /// ```
    pub fn row(&self, y: u32) -> Result<Row, Error> {
        let cols = self.cols();
        let mut cells = Vec::with_capacity(usize::from(cols));
        let mut wrapped = false;
        for x in 0..cols {
            let grid_ref = self.grid_ref(ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_SCREEN, x, y)?;
            if x == 0 {
                wrapped = row_wrapped(&grid_ref)?;
            }
            cells.push(read_cell(&grid_ref)?);
        }
        Ok(Row { wrapped, cells })
    }
}

fn row_wrapped(grid_ref: &ffi::GhosttyGridRef) -> Result<bool, Error> {
    let mut row: ffi::GhosttyRow = 0;
    // SAFETY: `grid_ref` came from the live terminal borrowed by the caller, which cannot be
    // mutated while the borrow lasts; `row` is a valid out pointer.
    Error::check(unsafe { ffi::ghostty_grid_ref_row(grid_ref, &mut row) })?;
    let mut wrapped = false;
    // SAFETY: ROW_DATA_WRAP writes a `bool`.
    Error::check(unsafe {
        ffi::ghostty_row_get(
            row,
            ffi::GhosttyRowData_GHOSTTY_ROW_DATA_WRAP,
            (&raw mut wrapped).cast(),
        )
    })?;
    Ok(wrapped)
}

fn read_cell(grid_ref: &ffi::GhosttyGridRef) -> Result<Cell, Error> {
    let mut cell: ffi::GhosttyCell = 0;
    // SAFETY: as in `row_wrapped`; `cell` is a valid out pointer.
    Error::check(unsafe { ffi::ghostty_grid_ref_cell(grid_ref, &mut cell) })?;
    let mut wide: ffi::GhosttyCellWide = 0;
    let mut semantic: ffi::GhosttyCellSemanticContent = 0;
    // SAFETY: WIDE writes a `GhosttyCellWide` and SEMANTIC_CONTENT a
    // `GhosttyCellSemanticContent`, both `c_int`.
    unsafe {
        Error::check(ffi::ghostty_cell_get(
            cell,
            ffi::GhosttyCellData_GHOSTTY_CELL_DATA_WIDE,
            (&raw mut wide).cast(),
        ))?;
        Error::check(ffi::ghostty_cell_get(
            cell,
            ffi::GhosttyCellData_GHOSTTY_CELL_DATA_SEMANTIC_CONTENT,
            (&raw mut semantic).cast(),
        ))?;
    }
    Ok(Cell {
        text: graphemes(grid_ref)?,
        width: match wide {
            ffi::GhosttyCellWide_GHOSTTY_CELL_WIDE_WIDE => CellWidth::Wide,
            ffi::GhosttyCellWide_GHOSTTY_CELL_WIDE_SPACER_TAIL => CellWidth::SpacerTail,
            ffi::GhosttyCellWide_GHOSTTY_CELL_WIDE_SPACER_HEAD => CellWidth::SpacerHead,
            _ => CellWidth::Narrow,
        },
        style: style(grid_ref)?,
        semantic: match semantic {
            ffi::GhosttyCellSemanticContent_GHOSTTY_CELL_SEMANTIC_INPUT => Semantic::Input,
            ffi::GhosttyCellSemanticContent_GHOSTTY_CELL_SEMANTIC_PROMPT => Semantic::Prompt,
            _ => Semantic::Output,
        },
    })
}

fn graphemes(grid_ref: &ffi::GhosttyGridRef) -> Result<String, Error> {
    let mut inline = [0u32; 8];
    let mut len = 0usize;
    // SAFETY: `inline` holds `inline.len()` codepoints; `len` is a valid out pointer.
    let code = unsafe {
        ffi::ghostty_grid_ref_graphemes(grid_ref, inline.as_mut_ptr(), inline.len(), &mut len)
    };
    let codepoints = if code == ffi::GhosttyResult_GHOSTTY_OUT_OF_SPACE {
        let mut heap = vec![0u32; len];
        // SAFETY: `heap` holds the `len` codepoints libghostty-vt asked for.
        Error::check(unsafe {
            ffi::ghostty_grid_ref_graphemes(grid_ref, heap.as_mut_ptr(), heap.len(), &mut len)
        })?;
        heap.truncate(len);
        heap
    } else {
        Error::check(code)?;
        inline[..len.min(inline.len())].to_vec()
    };
    Ok(codepoints.into_iter().filter_map(char::from_u32).collect())
}

fn style(grid_ref: &ffi::GhosttyGridRef) -> Result<CellStyle, Error> {
    let mut raw = ffi::GhosttyStyle {
        size: mem::size_of::<ffi::GhosttyStyle>(),
        fg_color: ffi::GhosttyStyleColor::default(),
        bg_color: ffi::GhosttyStyleColor::default(),
        underline_color: ffi::GhosttyStyleColor::default(),
        bold: false,
        italic: false,
        faint: false,
        blink: false,
        inverse: false,
        invisible: false,
        strikethrough: false,
        overline: false,
        underline: 0,
    };
    // SAFETY: `raw` is a sized `GhosttyStyle` out struct.
    Error::check(unsafe { ffi::ghostty_grid_ref_style(grid_ref, &mut raw) })?;
    Ok(CellStyle {
        fg: color(raw.fg_color),
        faint: raw.faint,
        bold: raw.bold,
        italic: raw.italic,
        underline: raw.underline != 0,
        inverse: raw.inverse,
    })
}

fn color(raw: ffi::GhosttyStyleColor) -> Color {
    match raw.tag {
        // SAFETY: the tag says which union arm is initialized.
        ffi::GhosttyStyleColorTag_GHOSTTY_STYLE_COLOR_PALETTE => {
            Color::Palette(unsafe { raw.value.palette })
        }
        ffi::GhosttyStyleColorTag_GHOSTTY_STYLE_COLOR_RGB => {
            // SAFETY: as above.
            let rgb = unsafe { raw.value.rgb };
            Color::Rgb(rgb.r, rgb.g, rgb.b)
        }
        _ => Color::Default,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rows_report_styles_widths_wraps_and_semantics() {
        let mut terminal = Terminal::new(6, 3).unwrap();
        terminal.write("\x1b]133;A\x07$ \x1b]133;B\x07漢x\x1b[38;2;10;20;30myz".as_bytes());
        let row = terminal.row(0).unwrap();
        assert!(row.wrapped);
        assert_eq!(row.cells[0].semantic, Semantic::Prompt);
        assert_eq!(row.cells[2].text, "漢");
        assert_eq!(row.cells[2].width, CellWidth::Wide);
        assert_eq!(row.cells[2].semantic, Semantic::Input);
        assert_eq!(row.cells[3].width, CellWidth::SpacerTail);
        assert!(row.cells[3].text.is_empty());
        assert_eq!(row.cells[5].style.fg, Color::Rgb(10, 20, 30));
        let next = terminal.row(1).unwrap();
        assert!(!next.wrapped);
        assert_eq!(next.cells[0].text, "z");
        assert!(terminal.row(99).is_err());
    }
}
