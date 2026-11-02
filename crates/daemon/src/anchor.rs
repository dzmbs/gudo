//! Row anchors for ink overlays.
//!
//! An anchor is a libghostty-vt tracked grid reference on the pane's terminal plus a
//! fingerprint of the anchored row's text. The reference follows its row through scrolling
//! and reflow; the fingerprint catches what the reference does not report:
//!
//! - `ED 2` blanks the row in place (the pin stays, the text is gone);
//! - `ED 3` frees erased scrollback but moves its pins to the top-left cell instead of
//!   invalidating them;
//! - leaving the alternate screen leaves alternate-screen pins on a stale point.
//!
//! So an anchor is live while its pin has a point, the screen it was made on is still the
//! one it belongs to, and the row's text still starts with (or is a prefix of, after reflow)
//! the fingerprint.
//!
//! Clients send rows as "`from_bottom` rows above the bottom at `at_seq`". To pin the same
//! row after more output arrived, every chunk fed to the terminal records how many rows the
//! primary screen has scrolled so far ([`ScrollLog`]), measured with a reference pin near
//! the top of the active area (its distance from the bottom grows by one per scrolled row,
//! whether scrollback grows or old rows are pruned).

use std::collections::{HashMap, VecDeque};

use ghostty_vt::{PinId, Point, Screen, Terminal, TextRegion};
use proto::{AnchorScreen, DetachReason, Seq};

/// Scroll samples kept: enough for a few seconds of chunks during a flood.
const SCROLL_SAMPLES: usize = 4096;
/// The reference pin is moved back near the bottom once this far up, so it is never pruned.
const REFERENCE_RESET: u64 = 1000;

/// Rows the primary screen scrolled, sampled per output chunk.
#[derive(Debug, Default)]
pub(crate) struct ScrollLog {
    reference: Option<PinId>,
    /// `scrolled` = `base + from_bottom(reference)`.
    base: i64,
    scrolled: u64,
    samples: VecDeque<(u64, u64, bool)>,
}

fn from_bottom(term: &Terminal, point: Point) -> u64 {
    (term.total_rows() as u64).saturating_sub(1 + u64::from(point.y))
}

impl ScrollLog {
    /// Called after every chunk fed to `term`, with the offset after it.
    pub fn observe(&mut self, term: &mut Terminal, seq: u64) {
        let on_alternate = term.active_screen() == Screen::Alternate;
        if !on_alternate {
            let point = self.reference.and_then(|pin| term.pin_point(pin));
            match point {
                Some(point) => {
                    let rows_from_bottom = from_bottom(term, point);
                    self.scrolled =
                        (self.base + rows_from_bottom as i64).max(self.scrolled as i64) as u64;
                    if rows_from_bottom > REFERENCE_RESET {
                        self.repin(term);
                    }
                }
                None => self.repin(term),
            }
        }
        if self.samples.back().is_none_or(|&(_, scrolled, alternate)| {
            scrolled != self.scrolled || alternate != on_alternate
        }) {
            self.samples.push_back((seq, self.scrolled, on_alternate));
            if self.samples.len() > SCROLL_SAMPLES {
                self.samples.pop_front();
            }
        }
    }

    /// Call right after the terminal was resized. A resize moves the bottom row without
    /// scrolling anything (rows are added or dropped at the bottom, or pulled back from
    /// scrollback), so the baseline moves instead of `scrolled`: otherwise growing the pane
    /// would count as rows scrolled and push anchors named before it past the top.
    pub fn resized(&mut self, term: &mut Terminal) {
        if let Some(point) = self.reference.and_then(|pin| term.pin_point(pin)) {
            self.base = self.scrolled as i64 - from_bottom(term, point) as i64;
        }
    }

    fn repin(&mut self, term: &mut Terminal) {
        if let Some(old) = self.reference.take() {
            term.unpin(old);
        }
        let top = (term.total_rows() as u32).saturating_sub(u32::from(term.rows()));
        if let Ok(pin) = term.pin_at(Point { y: top, x: 0 }) {
            let rows_from_bottom = term
                .pin_point(pin)
                .map_or(0, |point| from_bottom(term, point));
            self.base = self.scrolled as i64 - rows_from_bottom as i64;
            self.reference = Some(pin);
        }
    }

    /// `(rows scrolled, alternate screen active)` at output offset `seq` (the latest sample
    /// at or before it; the oldest sample if `seq` is older than the log).
    fn at(&self, seq: u64) -> (u64, bool) {
        self.samples
            .iter()
            .rev()
            .find(|(sample_seq, _, _)| *sample_seq <= seq)
            .or(self.samples.front())
            .map_or((self.scrolled, false), |&(_, scrolled, alternate)| {
                (scrolled, alternate)
            })
    }
}

#[derive(Debug)]
struct Pinned {
    pin: PinId,
    screen: AnchorScreen,
    fingerprint: Fingerprint,
    /// The last position seen while live (kept while the primary screen is hidden).
    last_from_bottom: u64,
}

/// Where an anchor is now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AnchorPos {
    /// `from_bottom` rows above the bottom of `screen` at output offset `at_seq`; `y` is the
    /// screen row.
    Live {
        screen: AnchorScreen,
        at_seq: Seq,
        from_bottom: u64,
        y: Option<u32>,
    },
    Detached(DetachReason),
}

/// The pane's anchors, keyed by artifact id.
#[derive(Debug, Default)]
pub(crate) struct Anchors {
    pinned: HashMap<u64, Pinned>,
}

fn row_text(term: &Terminal, y: u32) -> String {
    term.text(TextRegion::Range {
        start: Point { y, x: 0 },
        end: Point {
            y,
            x: term.cols().saturating_sub(1),
        },
    })
    .unwrap_or_default()
    .trim_end()
    .to_owned()
}

/// The anchored row's text, plus the nearest non-empty row above it (ink is often drawn on
/// blank rows under output, whose own text says nothing).
#[derive(Debug)]
struct Fingerprint {
    row: String,
    above: Option<(u32, String)>,
}

/// Rows searched above a blank anchored row for a fingerprint.
const FINGERPRINT_REACH: u32 = 8;

impl Fingerprint {
    fn take(term: &Terminal, y: u32) -> Self {
        let row = row_text(term, y);
        let above = (1..=FINGERPRINT_REACH.min(y))
            .map(|distance| (distance, row_text(term, y - distance)))
            .find(|(_, text)| !text.is_empty());
        Self { row, above }
    }

    fn holds(&self, term: &Terminal, y: u32) -> bool {
        let row = if self.row.is_empty() {
            // A blank row may fill in later (a prompt drawn there); only its neighbour counts.
            true
        } else {
            matches(&self.row, &row_text(term, y))
        };
        let above = match &self.above {
            None => true,
            Some((distance, text)) => {
                y >= *distance && matches(text, &row_text(term, y - distance))
            }
        };
        row && above
    }
}

fn matches(fingerprint: &str, now: &str) -> bool {
    if fingerprint.is_empty() {
        return true;
    }
    !now.is_empty() && (now.starts_with(fingerprint) || fingerprint.starts_with(now))
}

impl Anchors {
    /// Pins the row a client named (`from_bottom` above the bottom at `at_seq`).
    pub fn create(
        &mut self,
        term: &mut Terminal,
        scroll: &ScrollLog,
        seq: u64,
        key: u64,
        at_seq: Seq,
        from_bottom: u64,
    ) -> Result<AnchorPos, String> {
        self.remove(term, key);
        let alternate_now = term.active_screen() == Screen::Alternate;
        let (scrolled_then, alternate_then) = scroll.at(at_seq.0.min(seq));
        if alternate_then != alternate_now {
            return Err("the pane switched screens since; draw again".into());
        }
        let rows_from_bottom = if alternate_now {
            from_bottom
        } else {
            from_bottom + scroll.scrolled.saturating_sub(scrolled_then)
        };
        let total = term.total_rows() as u64;
        if rows_from_bottom >= total {
            return Err("that row is no longer in the pane's scrollback".into());
        }
        let y = (total - 1 - rows_from_bottom) as u32;
        let pin = term
            .pin_at(Point { y, x: 0 })
            .map_err(|error| error.to_string())?;
        let screen = if alternate_now {
            AnchorScreen::Alternate
        } else {
            AnchorScreen::Primary
        };
        self.pinned.insert(
            key,
            Pinned {
                pin,
                screen,
                fingerprint: Fingerprint::take(term, y),
                last_from_bottom: rows_from_bottom,
            },
        );
        Ok(AnchorPos::Live {
            screen,
            at_seq: Seq(seq),
            from_bottom: rows_from_bottom,
            y: Some(y),
        })
    }

    /// Pins the cursor's row (an image displayed at the cursor, a placement with no row).
    pub fn pin_cursor(
        &mut self,
        term: &mut Terminal,
        seq: u64,
        key: u64,
    ) -> Result<AnchorPos, String> {
        self.remove(term, key);
        let y = term.cursor_point().y;
        let pin = term
            .pin_at(Point { y, x: 0 })
            .map_err(|error| error.to_string())?;
        let screen = if term.active_screen() == Screen::Alternate {
            AnchorScreen::Alternate
        } else {
            AnchorScreen::Primary
        };
        let rows_from_bottom = from_bottom(term, Point { y, x: 0 });
        self.pinned.insert(
            key,
            Pinned {
                pin,
                screen,
                fingerprint: Fingerprint::take(term, y),
                last_from_bottom: rows_from_bottom,
            },
        );
        Ok(AnchorPos::Live {
            screen,
            at_seq: Seq(seq),
            from_bottom: rows_from_bottom,
            y: Some(y),
        })
    }

    /// Where `key` is now; `None` if unknown (never created, or already reported detached
    /// and removed).
    pub fn position(&mut self, term: &mut Terminal, seq: u64, key: u64) -> Option<AnchorPos> {
        let anchor = self.pinned.get_mut(&key)?;
        let alternate_now = term.active_screen() == Screen::Alternate;
        let detached = match (anchor.screen, alternate_now) {
            (AnchorScreen::Alternate, false) => Some(DetachReason::AltScreenExited),
            // The primary screen is hidden: nothing can happen to its rows.
            (AnchorScreen::Primary, true) => {
                return Some(AnchorPos::Live {
                    screen: anchor.screen,
                    at_seq: Seq(seq),
                    from_bottom: anchor.last_from_bottom,
                    y: None,
                });
            }
            _ => match term.pin_point(anchor.pin) {
                None => Some(DetachReason::RowGone),
                Some(point) if !anchor.fingerprint.holds(term, point.y) => {
                    Some(DetachReason::RowGone)
                }
                Some(point) => {
                    anchor.last_from_bottom = from_bottom(term, point);
                    return Some(AnchorPos::Live {
                        screen: anchor.screen,
                        at_seq: Seq(seq),
                        from_bottom: anchor.last_from_bottom,
                        y: Some(point.y),
                    });
                }
            },
        };
        let reason = detached.unwrap_or(DetachReason::RowGone);
        self.remove(term, key);
        Some(AnchorPos::Detached(reason))
    }

    pub fn remove(&mut self, term: &mut Terminal, key: u64) {
        if let Some(anchor) = self.pinned.remove(&key) {
            term.unpin(anchor.pin);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(term: &mut Terminal, log: &mut ScrollLog, seq: &mut u64, bytes: &[u8]) {
        term.write(bytes);
        *seq += bytes.len() as u64;
        log.observe(term, *seq);
    }

    #[test]
    fn rows_named_at_an_older_offset_are_found_after_more_output() {
        let mut term = Terminal::new(40, 10).unwrap();
        let mut log = ScrollLog::default();
        let mut seq = 0;
        for i in 0..30 {
            feed(
                &mut term,
                &mut log,
                &mut seq,
                format!("line {i}\r\n").as_bytes(),
            );
        }
        // The client saw "line 25" 4 rows above the bottom (rows: 25,26,27,28,29,cursor).
        let at = seq;
        let rows_from_bottom = (term.total_rows() as u32
            - 1
            - (0..term.total_rows() as u32)
                .find(|&y| row_text(&term, y) == "line 25")
                .unwrap()) as u64;
        for i in 30..200 {
            feed(
                &mut term,
                &mut log,
                &mut seq,
                format!("line {i}\r\n").as_bytes(),
            );
        }
        let mut anchors = Anchors::default();
        let pos = anchors
            .create(&mut term, &log, seq, 1, Seq(at), rows_from_bottom)
            .unwrap();
        let AnchorPos::Live { y: Some(y), .. } = pos else {
            panic!("{pos:?}")
        };
        assert_eq!(row_text(&term, y), "line 25");
        // Clearing the screen and scrollback detaches it.
        feed(&mut term, &mut log, &mut seq, b"\x1b[H\x1b[2J\x1b[3J");
        assert_eq!(
            anchors.position(&mut term, seq, 1),
            Some(AnchorPos::Detached(DetachReason::RowGone))
        );
        assert_eq!(anchors.position(&mut term, seq, 1), None);
    }

    #[test]
    fn growing_the_pane_is_not_scrolling() {
        let mut term = Terminal::new(40, 10).unwrap();
        let mut log = ScrollLog::default();
        let mut seq = 0;
        feed(&mut term, &mut log, &mut seq, b"$ ls\r\none\r\n");
        // A client of the new size names "one" (row 1) before any output follows the resize.
        let at = seq;
        term.resize(40, 30, (8, 16)).unwrap();
        log.resized(&mut term);
        let rows_from_bottom = term.total_rows() as u64 - 2;
        feed(&mut term, &mut log, &mut seq, b"$ ");
        let mut anchors = Anchors::default();
        let pos = anchors
            .create(&mut term, &log, seq, 1, Seq(at), rows_from_bottom)
            .unwrap();
        let AnchorPos::Live { y: Some(y), .. } = pos else {
            panic!("{pos:?}")
        };
        assert_eq!(row_text(&term, y), "one");
    }

    #[test]
    fn alternate_screen_anchor_detaches_on_exit_primary_survives() {
        let mut term = Terminal::new(40, 10).unwrap();
        let mut log = ScrollLog::default();
        let mut seq = 0;
        for i in 0..12 {
            feed(
                &mut term,
                &mut log,
                &mut seq,
                format!("line {i}\r\n").as_bytes(),
            );
        }
        let mut anchors = Anchors::default();
        anchors
            .create(&mut term, &log, seq, 1, Seq(seq), 3)
            .unwrap();
        feed(&mut term, &mut log, &mut seq, b"\x1b[?1049h\x1b[Hvim\r\n");
        anchors
            .create(&mut term, &log, seq, 2, Seq(seq), 9)
            .unwrap();
        assert!(matches!(
            anchors.position(&mut term, seq, 1),
            Some(AnchorPos::Live { y: None, .. })
        ));
        feed(&mut term, &mut log, &mut seq, b"\x1b[?1049l");
        assert_eq!(
            anchors.position(&mut term, seq, 2),
            Some(AnchorPos::Detached(DetachReason::AltScreenExited))
        );
        assert!(matches!(
            anchors.position(&mut term, seq, 1),
            Some(AnchorPos::Live { y: Some(_), .. })
        ));
    }
}
