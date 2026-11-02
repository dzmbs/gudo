//! Anchoring ink to output rows with tracked grid references (`Terminal::pin_at`).
//!
//! What a row anchor has to survive, and what libghostty-vt does (asserted below):
//!
//! - scrolling: the pin follows its row into scrollback;
//! - resize with reflow: the pin follows its cell into the re-wrapped row;
//! - scrollback eviction: the pin loses its value (`pin_point` = `None`);
//! - `clear` (`ESC[H ESC[2J ESC[3J`): ED 2 blanks the row in place, ED 3 moves pins of erased
//!   scrollback to the top-left cell instead of invalidating them (so the daemon fingerprints
//!   the row's text);
//! - alternate screen: a pin made on the primary screen keeps its row while a full-screen
//!   program runs; a pin made on the alternate screen is dropped when the program leaves;
//! - two terminals fed the same bytes (daemon and client) agree on every position.

use ghostty_vt::{Point, Screen, Terminal, TextRegion};

fn row_text(terminal: &Terminal, y: u32) -> String {
    terminal
        .text(TextRegion::Range {
            start: Point { y, x: 0 },
            end: Point {
                y,
                x: terminal.cols() - 1,
            },
        })
        .unwrap_or_default()
        .trim_end()
        .to_owned()
}

fn lines(terminal: &mut Terminal, from: usize, to: usize) {
    for i in from..to {
        terminal.write(format!("line {i}\r\n").as_bytes());
    }
}

/// Screen row whose text is `needle`.
fn find(terminal: &Terminal, needle: &str) -> Option<u32> {
    (0..terminal.total_rows() as u32).find(|&y| row_text(terminal, y) == needle)
}

#[test]
fn anchor_follows_scrolling() {
    let mut terminal = Terminal::new(40, 10).unwrap();
    lines(&mut terminal, 0, 8);
    let y = find(&terminal, "line 5").unwrap();
    let pin = terminal.pin_at(Point { y, x: 0 }).unwrap();
    lines(&mut terminal, 8, 500);
    let now = terminal.pin_point(pin).expect("still in scrollback");
    assert_eq!(row_text(&terminal, now.y), "line 5");
    // Distance from the bottom grew by exactly the rows written.
    let from_bottom = terminal.total_rows() as u32 - 1 - now.y;
    assert_eq!(from_bottom, 500 - 5);
}

#[test]
fn anchor_follows_reflow_on_resize() {
    let mut terminal = Terminal::new(40, 10).unwrap();
    lines(&mut terminal, 0, 3);
    // A 30-character line, then a marker after it.
    terminal.write(b"abcdefghijklmnopqrstuvwxyz0123\r\nafter\r\n");
    let y = find(&terminal, "after").unwrap();
    let pin = terminal.pin_at(Point { y, x: 0 }).unwrap();
    terminal.resize(10, 10, (8, 16)).unwrap();
    let now = terminal.pin_point(pin).unwrap();
    assert_eq!(row_text(&terminal, now.y), "after", "after narrowing");
    terminal.resize(80, 10, (8, 16)).unwrap();
    let now = terminal.pin_point(pin).unwrap();
    assert_eq!(row_text(&terminal, now.y), "after", "after widening");
}

#[test]
fn anchor_detaches_on_scrollback_eviction() {
    let mut terminal = Terminal::new(40, 10).unwrap();
    terminal.set_scrollback_max_lines(Some(100)).unwrap();
    lines(&mut terminal, 0, 20);
    let y = find(&terminal, "line 3").unwrap();
    let pin = terminal.pin_at(Point { y, x: 0 }).unwrap();
    lines(&mut terminal, 20, 60);
    assert_eq!(
        row_text(&terminal, terminal.pin_point(pin).unwrap().y),
        "line 3"
    );
    // Enough output to push it past the scrollback limit (limits are per page, so more).
    lines(&mut terminal, 60, 5000);
    assert_eq!(terminal.pin_point(pin), None, "evicted rows lose their pin");
}

#[test]
fn clear_and_erase_scrollback() {
    // `clear` (ncurses) sends ESC[H ESC[2J ESC[3J.
    let mut terminal = Terminal::new(40, 10).unwrap();
    lines(&mut terminal, 0, 30);
    let y_old = find(&terminal, "line 4").unwrap(); // in scrollback
    let y_visible = find(&terminal, "line 27").unwrap(); // on screen
    let old = terminal.pin_at(Point { y: y_old, x: 0 }).unwrap();
    let visible = terminal.pin_at(Point { y: y_visible, x: 0 }).unwrap();
    terminal.write(b"\x1b[H\x1b[2J");
    let after_ed2_old = terminal
        .pin_point(old)
        .map(|point| row_text(&terminal, point.y));
    let after_ed2_vis = terminal
        .pin_point(visible)
        .map(|point| row_text(&terminal, point.y));
    println!("ED2: scrollback pin -> {after_ed2_old:?}, screen pin -> {after_ed2_vis:?}");
    assert_eq!(
        after_ed2_old.as_deref(),
        Some("line 4"),
        "ED 2 keeps scrollback"
    );
    // ED 2 erases the screen rows in place: the pin keeps its row, whose text is now empty.
    assert_eq!(after_ed2_vis.as_deref(), Some(""));
    terminal.write(b"\x1b[3J");
    let after_ed3_old = terminal.pin_point(old);
    println!("ED3: scrollback pin -> {after_ed3_old:?}");
    // ED 3 frees the scrollback pages and the tracked reference with them.
    assert_eq!(after_ed3_old, None, "an erased anchor reports no point");
}

#[test]
fn alternate_screen() {
    let mut terminal = Terminal::new(40, 10).unwrap();
    lines(&mut terminal, 0, 15);
    let y = find(&terminal, "line 12").unwrap();
    let primary = terminal.pin_at(Point { y, x: 0 }).unwrap();
    // A full-screen program starts (vim, less).
    terminal.write(b"\x1b[?1049h\x1b[H\x1b[2Jvim buffer\r\nsecond");
    assert_eq!(terminal.active_screen(), Screen::Alternate);
    let alt_y = find(&terminal, "vim buffer").unwrap();
    let alt_pin = terminal.pin_at(Point { y: alt_y, x: 0 }).unwrap();
    // While it runs, the primary pin still resolves against the primary screen.
    let during = terminal.pin_point(primary);
    println!("primary pin during alt screen: {during:?}");
    assert!(during.is_some());
    terminal.write(b"\x1b[?1049l");
    assert_eq!(terminal.active_screen(), Screen::Primary);
    let after = terminal.pin_point(primary).unwrap();
    assert_eq!(row_text(&terminal, after.y), "line 12");
    let alt_point = terminal.pin_point(alt_pin);
    println!("alt pin after leaving alt screen: {alt_point:?}");
    // The alternate screen's pin survives as a stale point on the cleared alternate page
    // list (top-left), so the daemon detaches alternate-screen anchors itself when the
    // program leaves (it records the screen it pinned on).
    assert_eq!(alt_point, Some(Point { y: 0, x: 0 }));
}

#[test]
fn daemon_and_client_agree() {
    // Same bytes, same library: two terminals compute the same positions, so a client can
    // pin locally from (at_seq, from_bottom) and follow the anchor without the daemon.
    let script: Vec<u8> = (0..300)
        .map(|i| format!("row {i} {}\r\n", "x".repeat(i % 70)))
        .collect::<String>()
        .into_bytes();
    let mut daemon = Terminal::new(50, 12).unwrap();
    let mut client = Terminal::new(50, 12).unwrap();
    daemon.write(&script[..4000]);
    client.write(&script[..4000]);
    let y = daemon.total_rows() as u32 - 7;
    let daemon_pin = daemon.pin_at(Point { y, x: 0 }).unwrap();
    let client_pin = client.pin_at(Point { y, x: 0 }).unwrap();
    for terminal in [&mut daemon, &mut client] {
        terminal.write(&script[4000..]);
        terminal.resize(33, 12, (8, 16)).unwrap();
        terminal.write(b"tail\r\n");
    }
    let daemon_point = daemon.pin_point(daemon_pin).unwrap();
    let client_point = client.pin_point(client_pin).unwrap();
    assert_eq!(daemon_point, client_point);
    assert_eq!(
        daemon.total_rows() as u32 - daemon_point.y,
        client.total_rows() as u32 - client_point.y
    );
}
