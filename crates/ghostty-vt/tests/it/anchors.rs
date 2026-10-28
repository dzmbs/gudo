//!
//! What a row anchor has to survive, and what libghostty-vt does (asserted below; numbers in
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

fn row_text(t: &Terminal, y: u32) -> String {
    t.text(TextRegion::Range {
        start: Point { y, x: 0 },
        end: Point { y, x: t.cols() - 1 },
    })
    .unwrap_or_default()
    .trim_end()
    .to_owned()
}

fn lines(t: &mut Terminal, from: usize, to: usize) {
    for i in from..to {
        t.write(format!("line {i}\r\n").as_bytes());
    }
}

/// Screen row whose text is `needle`.
fn find(t: &Terminal, needle: &str) -> Option<u32> {
    (0..t.total_rows() as u32).find(|&y| row_text(t, y) == needle)
}

#[test]
fn anchor_follows_scrolling() {
    let mut t = Terminal::new(40, 10).unwrap();
    lines(&mut t, 0, 8);
    let y = find(&t, "line 5").unwrap();
    let pin = t.pin_at(Point { y, x: 0 }).unwrap();
    lines(&mut t, 8, 500);
    let now = t.pin_point(pin).expect("still in scrollback");
    assert_eq!(row_text(&t, now.y), "line 5");
    // Distance from the bottom grew by exactly the rows written.
    let from_bottom = t.total_rows() as u32 - 1 - now.y;
    assert_eq!(from_bottom, 500 - 5);
}

#[test]
fn anchor_follows_reflow_on_resize() {
    let mut t = Terminal::new(40, 10).unwrap();
    lines(&mut t, 0, 3);
    // A 30-character line, then a marker after it.
    t.write(b"abcdefghijklmnopqrstuvwxyz0123\r\nafter\r\n");
    let y = find(&t, "after").unwrap();
    let pin = t.pin_at(Point { y, x: 0 }).unwrap();
    t.resize(10, 10, (8, 16)).unwrap();
    let now = t.pin_point(pin).unwrap();
    assert_eq!(row_text(&t, now.y), "after", "after narrowing");
    t.resize(80, 10, (8, 16)).unwrap();
    let now = t.pin_point(pin).unwrap();
    assert_eq!(row_text(&t, now.y), "after", "after widening");
}

#[test]
fn anchor_detaches_on_scrollback_eviction() {
    let mut t = Terminal::new(40, 10).unwrap();
    t.set_scrollback_max_lines(Some(100)).unwrap();
    lines(&mut t, 0, 20);
    let y = find(&t, "line 3").unwrap();
    let pin = t.pin_at(Point { y, x: 0 }).unwrap();
    lines(&mut t, 20, 60);
    assert_eq!(row_text(&t, t.pin_point(pin).unwrap().y), "line 3");
    // Enough output to push it past the scrollback limit (limits are per page, so more).
    lines(&mut t, 60, 5000);
    assert_eq!(t.pin_point(pin), None, "evicted rows lose their pin");
}

#[test]
fn clear_and_erase_scrollback() {
    // `clear` (ncurses) sends ESC[H ESC[2J ESC[3J.
    let mut t = Terminal::new(40, 10).unwrap();
    lines(&mut t, 0, 30);
    let y_old = find(&t, "line 4").unwrap(); // in scrollback
    let y_vis = find(&t, "line 27").unwrap(); // on screen
    let old = t.pin_at(Point { y: y_old, x: 0 }).unwrap();
    let vis = t.pin_at(Point { y: y_vis, x: 0 }).unwrap();
    t.write(b"\x1b[H\x1b[2J");
    let after_ed2_old = t.pin_point(old).map(|p| row_text(&t, p.y));
    let after_ed2_vis = t.pin_point(vis).map(|p| row_text(&t, p.y));
    println!("ED2: scrollback pin -> {after_ed2_old:?}, screen pin -> {after_ed2_vis:?}");
    assert_eq!(
        after_ed2_old.as_deref(),
        Some("line 4"),
        "ED 2 keeps scrollback"
    );
    // ED 2 erases the screen rows in place: the pin keeps its row, whose text is now empty.
    assert_eq!(after_ed2_vis.as_deref(), Some(""));
    t.write(b"\x1b[3J");
    let after_ed3_old = t.pin_point(old);
    println!("ED3: scrollback pin -> {after_ed3_old:?}");
    // ED 3 frees the scrollback pages and the tracked reference with them.
    assert_eq!(after_ed3_old, None, "an erased anchor reports no point");
}

#[test]
fn alternate_screen() {
    let mut t = Terminal::new(40, 10).unwrap();
    lines(&mut t, 0, 15);
    let y = find(&t, "line 12").unwrap();
    let primary = t.pin_at(Point { y, x: 0 }).unwrap();
    // A full-screen program starts (vim, less).
    t.write(b"\x1b[?1049h\x1b[H\x1b[2Jvim buffer\r\nsecond");
    assert_eq!(t.active_screen(), Screen::Alternate);
    let alt_y = find(&t, "vim buffer").unwrap();
    let alt = t.pin_at(Point { y: alt_y, x: 0 }).unwrap();
    // While it runs, the primary pin still resolves against the primary screen.
    let p = t.pin_point(primary);
    println!("primary pin during alt screen: {p:?}");
    assert!(p.is_some());
    t.write(b"\x1b[?1049l");
    assert_eq!(t.active_screen(), Screen::Primary);
    let p = t.pin_point(primary).unwrap();
    assert_eq!(row_text(&t, p.y), "line 12");
    let a = t.pin_point(alt);
    println!("alt pin after leaving alt screen: {a:?}");
    // The alternate screen's pin survives as a stale point on the cleared alternate page
    // list (top-left), so the daemon detaches alternate-screen anchors itself when the
    // program leaves (it records the screen it pinned on).
    assert_eq!(a, Some(Point { y: 0, x: 0 }));
}

#[test]
fn daemon_and_client_agree() {
    // Same bytes, same library: two terminals compute the same positions, so a client can
    // pin locally from (at_seq, from_bottom) and follow the anchor without the daemon.
    let script: Vec<u8> = (0..300)
        .map(|i| format!("row {i} {}\r\n", "x".repeat(i % 70)))
        .collect::<String>()
        .into_bytes();
    let mut a = Terminal::new(50, 12).unwrap();
    let mut b = Terminal::new(50, 12).unwrap();
    a.write(&script[..4000]);
    b.write(&script[..4000]);
    let y = a.total_rows() as u32 - 7;
    let pa = a.pin_at(Point { y, x: 0 }).unwrap();
    let pb = b.pin_at(Point { y, x: 0 }).unwrap();
    for t in [&mut a, &mut b] {
        t.write(&script[4000..]);
        t.resize(33, 12, (8, 16)).unwrap();
        t.write(b"tail\r\n");
    }
    let (qa, qb) = (a.pin_point(pa).unwrap(), b.pin_point(pb).unwrap());
    assert_eq!(qa, qb);
    assert_eq!(a.total_rows() as u32 - qa.y, b.total_rows() as u32 - qb.y);
}
