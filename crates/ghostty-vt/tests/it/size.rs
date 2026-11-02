//! Snapshot size and speed for a 200x60 terminal with 10k lines of scrollback.

use std::time::{Duration, Instant};

use ghostty_vt::{Error, Screen, SnapshotDecoder, Terminal, TextRegion};

use crate::Rng;

const COLS: u16 = 200;
const ROWS: u16 = 60;
const HISTORY_LINES: usize = 10_000;
const READY_TARGET: usize = 50 * 1024;
const RUNS: usize = 5;

#[derive(Debug, Clone, Copy)]
enum Workload {
    /// `cat` of source code: plain text, 0-100 columns.
    Source,
    /// Colored log lines: timestamp, level in color, 60-160 columns.
    Logs,
    /// Every row full width, a different color every word.
    Dense,
}

impl Workload {
    fn line(self, rng: &mut Rng, line_number: usize) -> String {
        let words = |rng: &mut Rng, len: usize| -> String {
            const WORDS: &[&str] = &[
                "let", "fn", "match", "self", "terminal", "snapshot", "Ok(())", "=>", "{", "}",
                "return", "decoder", "pub", "struct", "impl", "&mut", "write", "bytes", "//",
            ];
            let mut line = String::new();
            while line.len() < len {
                line.push_str(rng.pick(WORDS));
                line.push(' ');
            }
            line.truncate(len);
            line
        };
        match self {
            Self::Source => {
                let indent = " ".repeat(4 * rng.below(4));
                let len = rng.below(90);
                format!("{indent}{}", words(rng, len))
            }
            Self::Logs => {
                let (color, level) =
                    *rng.pick(&[(32, "INFO"), (33, "WARN"), (31, "ERROR"), (36, "DEBUG")]);
                let len = 40 + rng.below(100);
                format!(
                    "\x1b[2m2026-10-18T12:{:02}:{:02}.{line_number:06}Z\x1b[0m \x1b[{color}m{level:5}\x1b[0m \x1b[1mhostd::pane\x1b[0m {}",
                    line_number / 60 % 60,
                    line_number % 60,
                    words(rng, len)
                )
            }
            Self::Dense => {
                let mut line = String::new();
                let mut width = 0;
                while width < usize::from(COLS) {
                    let len = 3 + rng.below(8);
                    let word = words(rng, len);
                    let word = &word[..word.len().min(usize::from(COLS) - width)];
                    width += word.len();
                    line.push_str(&format!("\x1b[38;5;{}m{word}", rng.below(256)));
                }
                line.push_str("\x1b[0m");
                line
            }
        }
    }
}

struct Measurement {
    label: String,
    primary_history: u64,
    ready_bytes: usize,
    /// READY compressed as it goes on the wire (zstd level 3).
    ready_zstd_bytes: usize,
    full_bytes: usize,
    vt_redraw_bytes: usize,
    encode: Duration,
    decode_ready: Duration,
    decode_full: Duration,
}

fn median(mut samples: Vec<Duration>) -> Duration {
    samples.sort();
    samples[samples.len() / 2]
}

fn measure(label: &str, terminal: &Terminal) -> Result<Measurement, Error> {
    let snapshot = terminal.encode_snapshot()?;
    // Set SNAPSHOT_FUZZ_DUMP=<dir> to write the snapshots out, e.g. to try transport compression.
    if let Some(dir) = std::env::var_os("SNAPSHOT_FUZZ_DUMP") {
        let name = label.replace(' ', "_").replace('+', "");
        std::fs::write(
            std::path::Path::new(&dir).join(format!("{name}.snap")),
            &snapshot,
        )
        .expect("write snapshot dump");
    }
    let mut encode = Vec::new();
    let mut decode_ready = Vec::new();
    let mut decode_full = Vec::new();
    let mut ready_bytes = 0;
    let mut primary_history = 0;
    for _ in 0..RUNS {
        let start = Instant::now();
        let again = terminal.encode_snapshot()?;
        encode.push(start.elapsed());
        assert_eq!(again.len(), snapshot.len());

        let start = Instant::now();
        let restore = SnapshotDecoder::new(&snapshot)?.ready()?;
        decode_ready.push(start.elapsed());
        ready_bytes = restore.source_offset().expect("offset known after READY");
        primary_history = restore
            .history_rows(Screen::Primary)
            .expect("primary screen");
        assert_eq!(restore.terminal().cursor(), terminal.cursor());

        let start = Instant::now();
        let restored = SnapshotDecoder::new(&snapshot)?.decode()?;
        decode_full.push(start.elapsed());
        assert_eq!(restored.scrollback_rows(), terminal.scrollback_rows());
    }
    Ok(Measurement {
        label: label.to_owned(),
        primary_history,
        ready_bytes,
        ready_zstd_bytes: zstd::bulk::compress(&snapshot[..ready_bytes], 3)
            .expect("zstd compress")
            .len(),
        full_bytes: snapshot.len(),
        vt_redraw_bytes: terminal.vt(TextRegion::Active)?.len(),
        encode: median(encode),
        decode_ready: median(decode_ready),
        decode_full: median(decode_full),
    })
}

fn filled(workload: Workload, seed: u64) -> Result<Terminal, Error> {
    let mut terminal = Terminal::new(COLS, ROWS)?;
    terminal.set_scrollback_max_bytes(None)?;
    let mut rng = Rng::new(seed);
    let mut bytes = Vec::new();
    for line_number in 0..HISTORY_LINES + usize::from(ROWS) - 1 {
        bytes.extend_from_slice(workload.line(&mut rng, line_number).as_bytes());
        bytes.extend_from_slice(b"\r\n");
    }
    bytes.extend_from_slice(b"\x1b[1;32mme@host\x1b[0m:\x1b[1;34m~/projects/gudo\x1b[0m$ cargo te");
    terminal.write(&bytes);
    Ok(terminal)
}

#[test]
fn snapshot_size_200x60_with_10k_lines() -> Result<(), Error> {
    let mut results = Vec::new();
    for (seed, workload) in [Workload::Source, Workload::Logs, Workload::Dense]
        .into_iter()
        .enumerate()
    {
        let mut terminal = filled(workload, seed as u64)?;
        assert!(terminal.scrollback_rows() >= HISTORY_LINES);
        results.push(measure(&format!("{workload:?}"), &terminal)?);

        // The same history behind a full-screen TUI on the alternate screen.
        terminal.write(b"\x1b[?1049h\x1b[H");
        let mut rng = Rng::new(99);
        for row in 0..ROWS {
            let line = workload.line(&mut rng, usize::from(row));
            terminal.write(format!("\x1b[{};1H{line}", row + 1).as_bytes());
        }
        assert_eq!(terminal.active_screen(), Screen::Alternate);
        results.push(measure(
            &format!("{workload:?} + alt-screen TUI"),
            &terminal,
        )?);
    }

    println!();
    println!(
        "| workload | primary history rows | READY bytes | READY zstd | VT redraw of active area | full bytes | encode | decode READY | decode full | zstd READY < 50 KB |"
    );
    println!("|---|---:|---:|---:|---:|---:|---:|---:|---:|---|");
    for measurement in &results {
        println!(
            "| {} | {} | {} ({:.1} KB) | {:.1} KB | {} | {} ({:.1} MB) | {:.2} ms | {:.2} ms | {:.2} ms | {} |",
            measurement.label,
            measurement.primary_history,
            measurement.ready_bytes,
            measurement.ready_bytes as f64 / 1024.0,
            measurement.ready_zstd_bytes as f64 / 1024.0,
            measurement.vt_redraw_bytes,
            measurement.full_bytes,
            measurement.full_bytes as f64 / (1024.0 * 1024.0),
            measurement.encode.as_secs_f64() * 1e3,
            measurement.decode_ready.as_secs_f64() * 1e3,
            measurement.decode_full.as_secs_f64() * 1e3,
            if measurement.ready_zstd_bytes < READY_TARGET {
                "pass"
            } else {
                "FAIL"
            },
        );
    }

    // Guard the "typical" claim on what actually goes on the wire: zstd-compressed READY for a
    // shell on the primary screen over plain or colored output. Raw READY is platform-dependent:
    // libghostty-vt sizes pages from the OS page size, so Linux (4 KiB) encodes ~3-4x more raw
    // bytes than Apple Silicon (16 KiB) for the same screen.
    for measurement in results
        .iter()
        .filter(|measurement| measurement.label == "Source" || measurement.label == "Logs")
    {
        assert!(
            measurement.ready_zstd_bytes < READY_TARGET,
            "{}: zstd READY is {} bytes",
            measurement.label,
            measurement.ready_zstd_bytes
        );
    }
    Ok(())
}
