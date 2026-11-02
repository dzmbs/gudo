//! Forgetting scrollback (multiplayer `since_join`): a copy of a terminal that keeps the
//! screen but none of the history, on either screen, and grows new history afterwards.

use ghostty_vt::{Error, SnapshotDecoder, Terminal, TextRegion};

fn filled(alt: bool) -> Result<Terminal, Error> {
    let mut terminal = Terminal::new(20, 4)?;
    terminal.set_scrollback_max_bytes(Some(10 << 20))?;
    for i in 0..300 {
        terminal.write(format!("old {i}\r\n").as_bytes());
    }
    if alt {
        terminal.write(b"\x1b[?1049h\x1b[Halt screen");
    }
    Ok(terminal)
}

fn copy_without_history(terminal: &Terminal) -> Result<Terminal, Error> {
    let snapshot = terminal.encode_snapshot()?;
    let mut copy = SnapshotDecoder::new(&snapshot)?.decode()?;
    copy.forget_history()?;
    copy.set_scrollback_max_bytes(Some(10 << 20))?;
    Ok(copy)
}

#[test]
fn forgetting_history_keeps_the_screen() -> Result<(), Error> {
    let terminal = filled(false)?;
    let copy = copy_without_history(&terminal)?;
    assert_eq!(copy.scrollback_rows(), 0);
    assert_eq!(
        copy.text(TextRegion::Active)?,
        terminal.text(TextRegion::Active)?,
        "the screen survives"
    );
    let all = copy.text(TextRegion::All)?;
    assert!(!all.contains("old 1\n"), "no history left: {all}");
    Ok(())
}

#[test]
fn forgetting_history_on_the_alternate_screen_clears_the_primary_too() -> Result<(), Error> {
    let terminal = filled(true)?;
    let mut copy = copy_without_history(&terminal)?;
    assert_eq!(
        copy.text(TextRegion::Active)?,
        terminal.text(TextRegion::Active)?
    );
    copy.write(b"\x1b[?1049l");
    let all = copy.text(TextRegion::All)?;
    assert!(!all.contains("old 100"), "primary history leaked: {all}");
    assert!(
        all.contains("old 299"),
        "the primary screen itself stays: {all}"
    );
    Ok(())
}

#[test]
fn history_grows_again_after_forgetting() -> Result<(), Error> {
    let terminal = filled(false)?;
    let mut copy = copy_without_history(&terminal)?;
    for i in 0..50 {
        copy.write(format!("new {i}\r\n").as_bytes());
    }
    let all = copy.text(TextRegion::All)?;
    assert!(all.contains("new 0\n") && all.contains("new 49"), "{all}");
    assert!(!all.contains("old 100"), "{all}");
    assert!(copy.scrollback_rows() > 40);
    Ok(())
}
