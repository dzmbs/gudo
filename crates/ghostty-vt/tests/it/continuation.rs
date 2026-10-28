//! Snapshot at every cut point of random VT streams, restore, continue, compare.
//!
//! Terminal A is fed the stream one byte at a time. At every cut point A is snapshotted and
//! restored twice: fully into B, and from only the READY prefix into C. The rest of the
//! stream then goes to B and C, and both must match R, a terminal that got the whole stream
//! in one write and was never "disconnected".
//!
//! "Match" means equal plain text (active area and scrollback), cursor, active screen, and
//! VT-formatter output with every extra enabled (styles, hyperlinks, modes, palette, charsets,
//! scrolling region, tab stops, ...). Re-encoded snapshot bytes are *not* compared: snapshots
//! are not canonical (page splits and style ids depend on history), so the test only counts
//! how often they differ.

use std::fmt::Write as _;

use ghostty_vt::{Error, Screen, SnapshotDecoder, Terminal, TextRegion};

use crate::Rng;

const COLS: u16 = 20;
const ROWS: u16 = 6;
/// Streams per test run; override with `SPIKE_B_SEEDS` for a longer soak.
const DEFAULT_SEEDS: u64 = 32;
const TOKENS_PER_STREAM: usize = 90;

fn new_terminal() -> Result<Terminal, Error> {
    let mut terminal = Terminal::new(COLS, ROWS)?;
    terminal.set_scrollback_max_bytes(None)?;
    Ok(terminal)
}

/// Appends one random VT token: text, UTF-8, control, CSI, OSC, DCS or a mode switch.
fn push_token(rng: &mut Rng, out: &mut Vec<u8>) {
    const UTF8: &[&str] = &[
        "é",
        "ñ",
        "€",
        "中文",
        "😀",
        "👍🏽",
        "e\u{301}",
        "─│┌",
        "🇩🇪",
        "ｗ",
        "\u{200d}",
    ];
    const FIXED: &[&str] = &[
        "\r\n",
        "\n",
        "\r",
        "\t",
        "\x08",
        "\x07",
        "\x1b[0m",
        "\x1b[1;31m",
        "\x1b[4:3m",
        "\x1b[7;3m",
        "\x1b[K",
        "\x1b[1K",
        "\x1b[2K",
        "\x1b[J",
        "\x1b[1J",
        "\x1b[2J",
        "\x1b[?1049h",
        "\x1b[?1049l",
        "\x1b[?47h",
        "\x1b[?47l",
        "\x1b[?7l",
        "\x1b[?7h",
        "\x1b[4h",
        "\x1b[4l",
        "\x1b[?25l",
        "\x1b[?25h",
        "\x1b[?6h",
        "\x1b[?6l",
        "\x1b7",
        "\x1b8",
        "\x1b[s",
        "\x1b[u",
        "\x1bM",
        "\x1bD",
        "\x1bE",
        "\x1b(0lqk\x1b(B",
        "\x1b(0",
        "\x1b(B",
        "\x1b[r",
        "\x1b]0;window title\x07",
        "\x1b]2;title st\x1b\\",
        "\x1b]7;file://host/tmp/dir\x07",
        "\x1b]133;A\x07",
        "\x1b]133;C\x1b\\",
        "\x1b]8;;https://example.com/a\x1b\\link\x1b]8;;\x1b\\",
        "\x1b]4;1;rgb:ff/00/00\x07",
        "\x1bP$qm\x1b\\",
        "\x1b[>4;1m",
        "\x1b[=1;1u",
        "\x1b[?2004h",
        "\x1b[?1000h\x1b[?1006h",
        "\x1b[c",
        "\x1bc",
    ];
    match rng.below(10) {
        0..=2 => {
            let max = if rng.below(4) == 0 { 40 } else { 8 };
            let len = 1 + rng.below(max);
            out.extend((0..len).map(|_| b' ' + rng.below(95) as u8));
        }
        3 => out.extend_from_slice(rng.pick(UTF8).as_bytes()),
        4 => {
            let sgr = match rng.below(3) {
                0 => format!("\x1b[38;5;{}m", rng.below(256)),
                1 => format!(
                    "\x1b[48;2;{};{};{}m",
                    rng.below(256),
                    rng.below(256),
                    rng.below(256)
                ),
                _ => format!(
                    "\x1b[{}m",
                    rng.pick(&[1, 2, 3, 5, 9, 22, 39, 49, 53, 91, 107])
                ),
            };
            out.extend_from_slice(sgr.as_bytes());
        }
        5 => {
            let n = 1 + rng.below(usize::from(ROWS) + 2);
            let m = 1 + rng.below(usize::from(COLS) + 2);
            let csi = match rng.below(9) {
                0 => format!("\x1b[{n};{m}H"),
                1 => format!("\x1b[{n}A"),
                2 => format!("\x1b[{n}B"),
                3 => format!("\x1b[{m}C"),
                4 => format!("\x1b[{m}D"),
                5 => format!("\x1b[{n};{}r", n + rng.below(4)),
                6 => format!("\x1b[{n}L"),
                7 => format!("\x1b[{n}M"),
                _ => format!("\x1b[{m}{}", rng.pick(&["@", "P", "X", "G", "S", "T", "d"])),
            };
            out.extend_from_slice(csi.as_bytes());
        }
        6 => {
            // Invalid or truncated UTF-8 and stray C1 bytes.
            let bytes: &[&[u8]] = &[
                b"\xff",
                b"\xc3",
                b"\xe2\x82",
                b"\xf0\x9f\x98",
                b"\x9b",
                b"\x1b\x1b",
            ];
            out.extend_from_slice(rng.pick(bytes));
        }
        _ => out.extend_from_slice(rng.pick(FIXED).as_bytes()),
    }
}

fn stream(seed: u64) -> Vec<u8> {
    let mut rng = Rng::new(seed);
    let mut out = Vec::new();
    for _ in 0..TOKENS_PER_STREAM {
        push_token(&mut rng, &mut out);
    }
    out
}

/// Everything a reconnecting client must agree on.
#[derive(Debug, PartialEq, Eq)]
struct State {
    active: String,
    all: Option<String>,
    cursor: ghostty_vt::Cursor,
    screen: Screen,
    /// Styles, modes, palette, cursor pen, charsets and so on, as VT sequences.
    vt: String,
}

impl State {
    fn of(terminal: &Terminal, with_history: bool) -> Result<Self, Error> {
        let region = if with_history {
            TextRegion::All
        } else {
            TextRegion::Active
        };
        Ok(Self {
            active: terminal.text(TextRegion::Active)?,
            all: with_history
                .then(|| terminal.text(TextRegion::All))
                .transpose()?,
            cursor: terminal.cursor(),
            screen: terminal.active_screen(),
            vt: canonical_hyperlinks(&terminal.vt(region)?),
        })
    }

    /// Describes each differing field, with context around the first differing character.
    fn diff(&self, want: &Self) -> String {
        fn text(name: &str, got: &str, want: &str, out: &mut String) {
            if got == want {
                return;
            }
            let at = got
                .char_indices()
                .zip(want.chars())
                .find(|((_, a), b)| a != b)
                .map_or(got.len().min(want.len()), |((i, _), _)| i);
            let window = |s: &str| {
                let start = s.floor_char_boundary(at.saturating_sub(60));
                let end = s.ceil_char_boundary((at + 60).min(s.len()));
                format!("{:?}", &s[start..end])
            };
            writeln!(
                out,
                "  {name} differs at byte {at}:\n    got:  {}\n    want: {}",
                window(got),
                window(want)
            )
            .ok();
        }
        let mut out = String::new();
        text("active", &self.active, &want.active, &mut out);
        text(
            "all",
            self.all.as_deref().unwrap_or(""),
            want.all.as_deref().unwrap_or(""),
            &mut out,
        );
        text("vt", &self.vt, &want.vt, &mut out);
        if (self.cursor, self.screen) != (want.cursor, want.screen) {
            writeln!(
                out,
                "  cursor/screen: got {:?} {:?}, want {:?} {:?}",
                self.cursor, self.screen, want.cursor, want.screen
            )
            .ok();
        }
        out
    }
}

/// Moves OSC 8 hyperlink transitions to a canonical place in formatter output.
///
/// The formatter tracks hyperlink state per page, so where it closes or re-opens a link depends
/// on page boundaries, which differ between a restored terminal and the original. A close is
/// delayed to just before the next printed character, and a re-open of the link that is
/// already open is dropped. The set of linked cells is unchanged.
fn canonical_hyperlinks(vt: &str) -> String {
    const CLOSE: &str = "\x1b]8;;\x1b\\";
    let mut out = String::with_capacity(vt.len());
    let mut open: Option<&str> = None;
    let mut pending_close = false;
    let mut rest = vt;
    while let Some(c) = rest.chars().next() {
        if let Some(after) = rest.strip_prefix(CLOSE) {
            pending_close = true;
            rest = after;
            continue;
        }
        if c != '\x1b' {
            if pending_close && c != '\r' && c != '\n' {
                out.push_str(CLOSE);
                (open, pending_close) = (None, false);
            }
            out.push(c);
            rest = &rest[c.len_utf8()..];
            continue;
        }
        // Copy one escape sequence: CSI up to its final byte, OSC up to ST or BEL, else ESC+1.
        let bytes = rest.as_bytes();
        let len = match bytes.get(1) {
            Some(b'[') => {
                2 + bytes[2..]
                    .iter()
                    .position(|b| (0x40..=0x7e).contains(b))
                    .map_or(0, |i| i + 1)
            }
            Some(b']') => {
                let st = rest.find("\x1b\\").map(|i| i + 2);
                let bel = rest.find('\x07').map(|i| i + 1);
                st.into_iter().chain(bel).min().unwrap_or(rest.len())
            }
            Some(b'(' | b')') => 3,
            _ => 2,
        };
        let sequence = &rest[..len.min(rest.len())];
        rest = &rest[sequence.len()..];
        if sequence.starts_with("\x1b]8;") {
            if open == Some(sequence) {
                pending_close = false;
                continue;
            }
            (open, pending_close) = (Some(sequence), false);
        }
        out.push_str(sequence);
    }
    if pending_close {
        out.push_str(CLOSE);
    }
    out
}

fn escape(bytes: &[u8]) -> String {
    bytes.escape_ascii().to_string()
}

/// Splits a snapshot into `(tag, payload)` records after the 10-byte envelope.
fn records(snapshot: &[u8]) -> Vec<(u16, &[u8])> {
    let mut rest = &snapshot[10..];
    let mut out = Vec::new();
    while rest.len() >= 10 {
        let tag = u16::from_le_bytes([rest[0], rest[1]]);
        let len = u32::from_le_bytes([rest[2], rest[3], rest[4], rest[5]]) as usize;
        out.push((tag, &rest[10..10 + len]));
        rest = &rest[10 + len..];
    }
    out
}

/// Describes the first record that differs between two snapshots, if any.
fn record_diff(got: &[u8], want: &[u8]) -> Option<String> {
    if got == want {
        return None;
    }
    let (got, want) = (records(got), records(want));
    let index = got
        .iter()
        .zip(&want)
        .position(|(a, b)| a != b)
        .unwrap_or(got.len().min(want.len()));
    let (Some((got_tag, got_payload)), Some((want_tag, want_payload))) =
        (got.get(index), want.get(index))
    else {
        return Some(format!("record counts {} vs {}", got.len(), want.len()));
    };
    let byte = got_payload
        .iter()
        .zip(*want_payload)
        .position(|(a, b)| a != b);
    Some(format!(
        "record {index}: tag {got_tag} ({} B) vs tag {want_tag} ({} B), first differing byte {byte:?}",
        got_payload.len(),
        want_payload.len()
    ))
}

/// Counters across all checked cut points.
#[derive(Debug, Default)]
struct Stats {
    cuts: usize,
    /// Cut points where the restored terminal, re-encoded, is not byte-identical to the
    /// reference snapshot even though every observable state matches.
    reencode_differs: usize,
    first_reencode_diff: Option<String>,
}

/// What every restored terminal must match: the never-disconnected reference.
struct Expected {
    full: State,
    ready: State,
    /// `None` when the stream ends where a snapshot is not possible.
    snapshot: Option<Vec<u8>>,
}

/// Snapshots `source` (which has seen `head`), restores it two ways, feeds both `rest`, and
/// describes any difference from `expected`.
fn check_cut(
    source: &Terminal,
    rest: &[u8],
    expected: &Expected,
    stats: &mut Stats,
) -> Result<Option<String>, String> {
    let at = |what: &'static str| move |error: Error| format!("{what}: {error}");
    let snapshot = source.encode_snapshot().map_err(at("encode"))?;
    let mut report = String::new();

    let mut full = SnapshotDecoder::new(&snapshot)
        .and_then(|mut decoder| decoder.decode())
        .map_err(at("full decode"))?;
    full.write(rest);
    let got = State::of(&full, true).map_err(at("format"))?;
    if got != expected.full {
        writeln!(report, "full decode differs:\n{}", got.diff(&expected.full)).ok();
    } else if let Some(diff) = expected.snapshot.as_deref().and_then(|want| {
        full.encode_snapshot()
            .ok()
            .and_then(|got| record_diff(&got, want))
    }) {
        stats.reencode_differs += 1;
        stats.first_reencode_diff.get_or_insert(diff);
    }

    let ready_len = SnapshotDecoder::new(&snapshot)
        .and_then(SnapshotDecoder::ready)
        .map_err(at("READY decode"))?
        .source_offset()
        .expect("offset known after READY");
    let mut ready = SnapshotDecoder::new(&snapshot[..ready_len])
        .and_then(SnapshotDecoder::ready)
        .map_err(at("READY-prefix decode"))?;
    ready.write(rest);
    let got = State::of(ready.terminal(), false).map_err(at("format"))?;
    if got != expected.ready {
        writeln!(
            report,
            "READY-prefix decode differs:\n{}",
            got.diff(&expected.ready)
        )
        .ok();
    }
    Ok((!report.is_empty()).then_some(report))
}

/// Checks every cut point of one stream, describing the first mismatch or error.
fn check_stream(seed: u64, stats: &mut Stats) -> Result<(), String> {
    let bytes = stream(seed);
    let setup = |error: Error| format!("seed {seed}: reference failed: {error}");
    let mut reference = new_terminal().map_err(setup)?;
    reference.write(&bytes);
    let expected = Expected {
        full: State::of(&reference, true).map_err(setup)?,
        ready: State::of(&reference, false).map_err(setup)?,
        snapshot: reference.encode_snapshot().ok(),
    };

    let mut source = new_terminal().map_err(setup)?;
    for cut in 0..=bytes.len() {
        if cut > 0 {
            source.write(&bytes[cut - 1..cut]);
        }
        stats.cuts += 1;
        let (head, rest) = bytes.split_at(cut);
        let report = match check_cut(&source, rest, &expected, stats) {
            Ok(None) => continue,
            Ok(Some(report)) => report,
            Err(error) => format!("error in {error}"),
        };
        return Err(format!(
            "seed {seed}, cut {cut}/{}\nhead: {}\nrest: {}\n{report}",
            bytes.len(),
            escape(head),
            escape(rest),
        ));
    }
    Ok(())
}

#[test]
fn snapshot_at_every_cut_point_continues_identically() {
    let env = |name: &str, default: u64| {
        std::env::var(name)
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(default)
    };
    let first = env("SPIKE_B_FIRST_SEED", 0);
    let seeds = env("SPIKE_B_SEEDS", DEFAULT_SEEDS);
    let mut stats = Stats::default();
    for seed in first..first + seeds {
        if let Err(failure) = check_stream(seed, &mut stats) {
            panic!("{failure}");
        }
    }
    println!(
        "continuation: {seeds} streams, {} cut points, all identical; \
         re-encoded snapshot bytes differ at {} cut points (first: {})",
        stats.cuts,
        stats.reencode_differs,
        stats.first_reencode_diff.as_deref().unwrap_or("none"),
    );
}

/// Live bytes arrive while history is still streaming in: the client renders and accepts
/// input right after READY, then prepends scrollback page by page.
#[test]
fn history_streams_in_after_live_input() -> Result<(), Error> {
    let mut daemon = Terminal::new(40, 5)?;
    daemon.set_scrollback_max_bytes(None)?;
    for line in 0..5_000 {
        daemon.write(format!("\x1b[3{}mline {line}\x1b[0m\r\n", line % 8).as_bytes());
    }
    daemon.write(b"$ echo hi\x1b[");
    let snapshot = daemon.encode_snapshot()?;

    let mut restore = SnapshotDecoder::new(&snapshot)?.ready()?;
    let declared = restore.history_rows(Screen::Primary);
    assert_eq!(declared, Some(daemon.scrollback_rows() as u64));
    assert!(restore.terminal().scrollback_rows() < daemon.scrollback_rows());
    let live = b"1mX\x1b[0m\r\nhi\r\n$ ";
    restore.write(live);
    daemon.write(live);
    assert_eq!(
        State::of(restore.terminal(), false)?,
        State::of(&daemon, false)?
    );

    let mut pages = 0;
    while let Some(page) = restore.next_page()? {
        assert_eq!(page.screen, Screen::Primary);
        assert!(page.rows > 0, "page skipped after live input");
        pages += 1;
    }
    assert!(pages > 1);
    let client = restore.into_terminal();
    assert_eq!(State::of(&client, true)?, State::of(&daemon, true)?);
    Ok(())
}

/// A raw C1 byte (0x90 DCS, 0x9B CSI, 0x9D OSC) inside an APC string (`ESC _`) starts a new
/// sequence, and a snapshot taken there replays from it.
#[test]
fn c1_byte_inside_apc_snapshots() -> Result<(), Error> {
    for c1 in [0x90, 0x9b, 0x9d] {
        let mut terminal = new_terminal()?;
        terminal.write(&[0x1b, b'_', c1]);
        terminal.encode_snapshot()?;
        terminal.write(b"m\x1b\\\x07ok");
        terminal.encode_snapshot()?;
    }
    for prefix in [&b"\x1bP"[..], b"\x1b]0;"] {
        let mut terminal = new_terminal()?;
        terminal.write(prefix);
        terminal.write(&[0x9b]);
        terminal.encode_snapshot()?;
    }
    Ok(())
}
