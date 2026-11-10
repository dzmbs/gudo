//! Cell-level reads: the text, width, style and shell-integration role of each cell in a row.
//!
//! [`Terminal::text`] flattens a region to plain text; this module keeps what flattening loses
//! (faint or colored cells, which part of a line the shell marked as prompt or input), which is
//! what reading a shell's input line off the screen needs.

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
    pub bg: Color,
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
    let mut style = style(grid_ref)?;
    if let Some(bg) = background_only(cell)? {
        style.bg = bg;
    }
    Ok(Cell {
        text: graphemes(grid_ref)?,
        width: match wide {
            ffi::GhosttyCellWide_GHOSTTY_CELL_WIDE_WIDE => CellWidth::Wide,
            ffi::GhosttyCellWide_GHOSTTY_CELL_WIDE_SPACER_TAIL => CellWidth::SpacerTail,
            ffi::GhosttyCellWide_GHOSTTY_CELL_WIDE_SPACER_HEAD => CellWidth::SpacerHead,
            _ => CellWidth::Narrow,
        },
        style,
        semantic: match semantic {
            ffi::GhosttyCellSemanticContent_GHOSTTY_CELL_SEMANTIC_INPUT => Semantic::Input,
            ffi::GhosttyCellSemanticContent_GHOSTTY_CELL_SEMANTIC_PROMPT => Semantic::Prompt,
            _ => Semantic::Output,
        },
    })
}

/// The color of a cell that holds no text, only a background (erased with a color set):
/// such cells keep it in their content rather than in a style.
fn background_only(cell: ffi::GhosttyCell) -> Result<Option<Color>, Error> {
    let mut tag: ffi::GhosttyCellContentTag = 0;
    // SAFETY: CONTENT_TAG writes a `GhosttyCellContentTag` (`c_int`).
    Error::check(unsafe {
        ffi::ghostty_cell_get(
            cell,
            ffi::GhosttyCellData_GHOSTTY_CELL_DATA_CONTENT_TAG,
            (&raw mut tag).cast(),
        )
    })?;
    match tag {
        ffi::GhosttyCellContentTag_GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE => {
            let mut index: ffi::GhosttyColorPaletteIndex = 0;
            // SAFETY: COLOR_PALETTE writes a `GhosttyColorPaletteIndex`, valid for this tag.
            Error::check(unsafe {
                ffi::ghostty_cell_get(
                    cell,
                    ffi::GhosttyCellData_GHOSTTY_CELL_DATA_COLOR_PALETTE,
                    (&raw mut index).cast(),
                )
            })?;
            Ok(Some(Color::Palette(index)))
        }
        ffi::GhosttyCellContentTag_GHOSTTY_CELL_CONTENT_BG_COLOR_RGB => {
            let mut rgb = ffi::GhosttyColorRgb { r: 0, g: 0, b: 0 };
            // SAFETY: COLOR_RGB writes a `GhosttyColorRgb`, valid for this tag.
            Error::check(unsafe {
                ffi::ghostty_cell_get(
                    cell,
                    ffi::GhosttyCellData_GHOSTTY_CELL_DATA_COLOR_RGB,
                    (&raw mut rgb).cast(),
                )
            })?;
            Ok(Some(Color::Rgb(rgb.r, rgb.g, rgb.b)))
        }
        _ => Ok(None),
    }
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
    let mut raw = ffi::GhosttyStyle::default();
    // SAFETY: `raw` is a valid `GhosttyStyle` out pointer.
    Error::check(unsafe { ffi::ghostty_grid_ref_style(grid_ref, &mut raw) })?;
    let has_flag = |flag: u32| u32::from(raw.flags) & flag != 0;
    Ok(CellStyle {
        fg: color(raw.fg_color),
        bg: color(raw.bg_color),
        faint: has_flag(ffi::GHOSTTY_STYLE_FLAG_FAINT),
        bold: has_flag(ffi::GHOSTTY_STYLE_FLAG_BOLD),
        italic: has_flag(ffi::GHOSTTY_STYLE_FLAG_ITALIC),
        underline: has_flag(ffi::GHOSTTY_STYLE_UNDERLINE_MASK),
        inverse: has_flag(ffi::GHOSTTY_STYLE_FLAG_INVERSE),
    })
}

fn color(raw: ffi::GhosttyStyleColor) -> Color {
    match ffi::GhosttyStyleColorTag::from(raw.tag) {
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
        assert_eq!(row.cells[5].style.bg, Color::Default);
        let next = terminal.row(1).unwrap();
        assert!(!next.wrapped);
        assert_eq!(next.cells[0].text, "z");
        assert!(terminal.row(99).is_err());
    }

    #[test]
    fn rows_report_background_colors() {
        let mut terminal = Terminal::new(6, 1).unwrap();
        terminal.write(b"a\x1b[44mb\x1b[48;2;1;2;3mc\x1b[0;7md");
        let cells = terminal.row(0).unwrap().cells;
        assert_eq!(cells[0].style.bg, Color::Default);
        assert_eq!(cells[1].style.bg, Color::Palette(4));
        assert_eq!(cells[2].style.bg, Color::Rgb(1, 2, 3));
        assert!(cells[3].style.inverse);
        assert_eq!(cells[3].style.bg, Color::Default);
        terminal.write(b"\x1b[0;45m\x1b[2K");
        let erased = terminal.row(0).unwrap().cells;
        assert!(erased[0].is_blank());
        assert_eq!(erased[0].style.bg, Color::Palette(5));
    }
}
