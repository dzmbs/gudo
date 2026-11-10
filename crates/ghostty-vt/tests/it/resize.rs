//! Resizes that change rows and columns at once, as a window drag or a rotation does.

use ghostty_vt::{Error, Terminal, TextRegion};

#[test]
fn growing_rows_while_shrinking_cols_pulls_scrollback_down() -> Result<(), Error> {
    let mut terminal = Terminal::new(5, 2)?;
    terminal.set_scrollback_max_bytes(None)?;
    terminal.write(b"1A\r\n2B\r\n3C\r\n");
    assert_eq!(terminal.text(TextRegion::Active)?, "3C");
    assert_eq!(terminal.cursor().y, 1);

    terminal.resize(4, 4, (8, 16))?;

    assert_eq!(terminal.text(TextRegion::Active)?, "1A\n2B\n3C");
    assert_eq!(terminal.cursor().y, 3);
    assert_eq!(terminal.scrollback_rows(), 0);
    Ok(())
}

#[test]
fn growing_rows_while_shrinking_cols_matches_two_separate_resizes() -> Result<(), Error> {
    let fill = |terminal: &mut Terminal| -> Result<(), Error> {
        terminal.set_scrollback_max_bytes(None)?;
        for line in 0..40 {
            terminal.write(format!("line {line} with some words\r\n").as_bytes());
        }
        terminal.write(b"$ ");
        Ok(())
    };
    let mut at_once = Terminal::new(30, 6)?;
    fill(&mut at_once)?;
    at_once.resize(12, 20, (8, 16))?;

    let mut in_steps = Terminal::new(30, 6)?;
    fill(&mut in_steps)?;
    in_steps.resize(30, 20, (8, 16))?;
    in_steps.resize(12, 20, (8, 16))?;

    assert_eq!(
        at_once.text(TextRegion::Active)?,
        in_steps.text(TextRegion::Active)?
    );
    assert_eq!(at_once.cursor(), in_steps.cursor());
    assert_eq!(at_once.scrollback_rows(), in_steps.scrollback_rows());
    Ok(())
}
