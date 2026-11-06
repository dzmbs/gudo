//! Captured real-TUI layouts: a blank rendered row is not a draft-state authority.

use ghostty_vt::{Cursor, Screen, Terminal, TextRegion};
use serde::Deserialize;

const BURST: &str = include_str!("fixtures/agent-input/claude-2.1.318-burst.json");
const MULTILINE: &str = include_str!("fixtures/agent-input/claude-2.1.319-multiline.json");
const SPACES: &str = include_str!("fixtures/agent-input/claude-2.1.319-spaces.json");

#[derive(Deserialize)]
struct Fixture {
    version: String,
    cols: u16,
    rows: u16,
    frames: Vec<Frame>,
    #[serde(default)]
    observed_user_messages: Vec<String>,
}

#[derive(Deserialize)]
struct Frame {
    label: String,
    input_hex: Option<String>,
    output: String,
}

fn fixture(json: &str) -> Fixture {
    serde_json::from_str(json).unwrap()
}

fn replay(fixture: &Fixture, frames: usize) -> Terminal {
    assert!(frames <= fixture.frames.len());
    let mut terminal = Terminal::new(fixture.cols, fixture.rows).unwrap();
    for frame in fixture.frames.iter().take(frames) {
        terminal.write(frame.output.as_bytes());
    }
    terminal
}

#[test]
fn both_captured_versions_have_the_expected_initial_input_layout() {
    for json in [BURST, MULTILINE, SPACES] {
        let fixture = fixture(json);
        assert!(matches!(fixture.version.as_str(), "2.1.318" | "2.1.319"));
        assert_eq!(fixture.frames[0].label, "ready");
        let terminal = replay(&fixture, 1);
        assert_eq!(terminal.active_screen(), Screen::Alternate);
        assert_eq!(
            terminal.cursor(),
            Cursor {
                x: 2,
                y: 37,
                pending_wrap: false
            }
        );
        let row = terminal.row(37).unwrap();
        assert_eq!(row.cells[0].text, "❯");
        assert_eq!(row.cells[1].text, "\u{a0}");
        assert_eq!(row.cells[2].text, " ");
        assert!(row.cells[2].style.inverse);
        assert!(row.cells[3..].iter().all(|cell| cell.text.is_empty()));
    }
}

#[test]
fn control_u_after_a_multiline_paste_leaves_an_earlier_line_intact() {
    let fixture = fixture(MULTILINE);
    assert_eq!(fixture.frames[2].input_hex.as_deref(), Some("15"));
    let terminal = replay(&fixture, fixture.frames.len());
    assert_eq!(terminal.cursor().x, 2);
    assert!(
        terminal
            .text(TextRegion::Active)
            .unwrap()
            .contains("❯\u{a0}first")
    );
    let cursor_row = terminal.row(u32::from(terminal.cursor().y)).unwrap();
    assert!(
        cursor_row.cells[3..]
            .iter()
            .all(|cell| cell.text.is_empty())
    );
    assert_eq!(terminal.row(36).unwrap().cells[2].text, "f");
}

#[test]
fn a_spaces_only_draft_at_home_has_the_same_input_cells_and_cursor_as_empty() {
    let fixture = fixture(SPACES);
    assert_eq!(fixture.frames[1].input_hex.as_deref(), Some("202020"));
    assert_eq!(fixture.frames[2].input_hex.as_deref(), Some("01"));
    let empty = replay(&fixture, 1);
    let spaces = replay(&fixture, fixture.frames.len());
    assert_eq!(spaces.cursor(), empty.cursor());
    for row in 36..=38 {
        assert_eq!(spaces.row(row).unwrap(), empty.row(row).unwrap());
    }
}

#[test]
fn the_captured_single_write_paste_and_return_reached_the_loopback_api_once() {
    let fixture = fixture(BURST);
    assert_eq!(
        fixture.frames[1].input_hex.as_deref(),
        Some("1b5b3230307e48656c6c6f206d6972726f722e1b5b3230317e0d")
    );
    assert_eq!(fixture.observed_user_messages, ["Hello mirror."]);
}
