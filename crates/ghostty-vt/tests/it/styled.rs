//! Styled text: a region's text and colours, written into another terminal, without the
//! modes, cursor or palette of the one it came from.

use ghostty_vt::{Error, Mode, Point, Terminal, TextRegion};

#[test]
fn styled_text_carries_text_and_colours_only() -> Result<(), Error> {
    let mut source = Terminal::new(20, 4)?;
    source.write(b"\x1b[?2004h\x1b[?1000h\x1b[?25l\x1b]4;1;rgb:12/34/56\x1b\\");
    source.write(b"plain \x1b[31mred\x1b[0m\r\nline two   \r\n");
    let styled = source.styled_text(TextRegion::All)?;

    let mut copy = Terminal::new(20, 4)?;
    copy.write(styled.as_bytes());
    assert_eq!(copy.text(TextRegion::All)?, "plain red\nline two");
    assert!(
        styled.contains("31m") || styled.contains("38;5;1m"),
        "{styled:?}"
    );
    assert!(!copy.mode(Mode::BRACKETED_PASTE));
    assert!(!copy.mouse_tracking());
    assert!(!styled.contains("]4;"), "{styled:?}");
    Ok(())
}

#[test]
fn soft_wrapped_lines_wrap_again_at_the_new_width() -> Result<(), Error> {
    let mut source = Terminal::new(10, 4)?;
    source.write(b"abcdefghijklmno\r\nnext");
    let styled = source.styled_text(TextRegion::All)?;

    let mut wider = Terminal::new(30, 4)?;
    wider.write(styled.as_bytes());
    assert_eq!(wider.text(TextRegion::All)?, "abcdefghijklmno\nnext");
    Ok(())
}

#[test]
fn a_range_of_rows_keeps_only_those_rows() -> Result<(), Error> {
    let mut source = Terminal::new(10, 3)?;
    source.set_scrollback_max_bytes(Some(1 << 20))?;
    for i in 0..20 {
        source.write(format!("row {i}\r\n").as_bytes());
    }
    let last = source.total_rows() as u32 - 1;
    let region = TextRegion::Range {
        start: Point { y: last - 3, x: 0 },
        end: Point { y: last, x: 9 },
    };
    let styled = source.styled_text(region)?;
    let mut copy = Terminal::new(10, 6)?;
    copy.write(styled.as_bytes());
    assert_eq!(copy.text(TextRegion::All)?, "row 17\nrow 18\nrow 19");
    Ok(())
}
