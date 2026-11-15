//! Prompts on resize, as Ghostty's own terminal treats them: the shell redraws its prompt at
//! the new size (Ghostty's zsh integration relies on the terminal clearing the old one), and
//! a screen cleared at a prompt stays clear when the pane narrows.

use ghostty_vt::{Error, SnapshotDecoder, Terminal, TextRegion};

const RIGHT_PROMPT: &str = "ok 19:42 🕒";
const RIGHT_PROMPT_WIDTH: usize = 11;

/// A prompt with a right prompt, drawn the way zsh draws it at `cols` columns.
fn prompt(cols: usize) -> Vec<u8> {
    let gap = cols - 3 - RIGHT_PROMPT_WIDTH - 1;
    let back = gap + RIGHT_PROMPT_WIDTH;
    format!(
        "\r\x1b[J\x1b]133;A;cl=line\x07P> \x1b]133;B\x07\x1b[K\x1b[{gap}C{RIGHT_PROMPT}\x1b[{back}D"
    )
    .into_bytes()
}

fn prompt_row(cols: usize) -> String {
    format!(
        "P>{}{RIGHT_PROMPT}",
        " ".repeat(cols - 2 - RIGHT_PROMPT_WIDTH - 1)
    )
}

/// The active area's non-blank rows.
fn rows(terminal: &Terminal) -> Result<Vec<String>, Error> {
    Ok(terminal
        .text(TextRegion::Active)?
        .lines()
        .map(str::trim_end)
        .filter(|row| !row.is_empty())
        .map(str::to_owned)
        .collect())
}

#[test]
fn resize_clears_the_prompt_for_the_shell_to_redraw() -> Result<(), Error> {
    let mut terminal = Terminal::new(100, 30)?;
    terminal.write(&prompt(100));
    terminal.resize(50, 30, (8, 16))?;
    assert_eq!(rows(&terminal)?, Vec::<String>::new());

    terminal.write(&prompt(50));
    assert_eq!(rows(&terminal)?, [prompt_row(50)]);
    Ok(())
}

#[test]
fn screen_cleared_at_a_prompt_stays_clear_when_the_pane_narrows() -> Result<(), Error> {
    let mut terminal = Terminal::new(100, 30)?;
    terminal.set_scrollback_max_bytes(None)?;
    terminal.write(&prompt(100));
    terminal.write(b"echo one\r\n\x1b]133;C\x07one\r\n\x1b]133;D;0\x07");
    terminal.write(&prompt(100));
    terminal.write(b"clear\r\n\x1b]133;C\x07\x1b[3J\x1b[H\x1b[2J\x1b]133;D;0\x07");
    terminal.write(&prompt(100));
    assert_eq!(rows(&terminal)?, [prompt_row(100)]);

    terminal.resize(50, 30, (8, 16))?;
    terminal.write(&prompt(50));
    assert_eq!(rows(&terminal)?, [prompt_row(50)]);
    assert_eq!(terminal.cursor().y, 0);
    Ok(())
}

#[test]
fn restored_terminal_keeps_the_shells_redraw_setting() -> Result<(), Error> {
    let mut daemon = Terminal::new(40, 4)?;
    daemon.write(b"\x1b]133;A;redraw=0\x07P> \x1b]133;B\x07");
    let mut client = SnapshotDecoder::new(&daemon.encode_snapshot()?)?.decode()?;
    client.resize(30, 4, (8, 16))?;
    assert_eq!(rows(&client)?, ["P>"]);
    Ok(())
}

#[test]
fn resize_clears_every_row_of_a_two_line_prompt() -> Result<(), Error> {
    let mut terminal = Terminal::new(100, 30)?;
    let first_line = "=".repeat(60);
    terminal.write(
        format!("\x1b]133;A;cl=line\x07{first_line}\r\n\x1b]133;P;k=s\x07> \x1b]133;B\x07")
            .as_bytes(),
    );
    terminal.resize(50, 30, (8, 16))?;
    assert_eq!(rows(&terminal)?, Vec::<String>::new());
    Ok(())
}
