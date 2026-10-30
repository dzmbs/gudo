//! Corrupt snapshots and history records must fail cleanly, never crash.
//!
//! A client decodes snapshots and history its host sends, and a guest's host is someone else's
//! machine, so these bytes are untrusted. Each case mutates a real snapshot (bit flips, byte
//! runs, length-field edits, truncation, splices) and runs every decode path on it. For a
//! deeper soak, raise `CORRUPT_SEEDS` and build libghostty-vt with its safety checks on:
//! `LIBGHOSTTY_VT_OPTIMIZE=safe CORRUPT_SEEDS=20000 cargo test -p ghostty-vt --test it corrupt`.

use ghostty_vt::{
    SnapshotDecoder, StreamingRestore, Terminal, TextRegion, history_chunks, ready_len, screen_len,
};

use crate::Rng;

const DEFAULT_SEEDS: u64 = 400;

/// A snapshot with scrollback on both screens, styles, hyperlinks, prompts and images.
fn sample() -> Vec<u8> {
    let mut t = Terminal::new(24, 6).unwrap();
    t.resize(24, 6, (8, 16)).unwrap();
    t.set_scrollback_max_bytes(None).unwrap();
    for i in 0..60 {
        let line = format!(
            "\x1b[3{}m{i} línea 中文 😀\x1b[0m \x1b]8;;https://e.x/{i}\x1b\\link\x1b]8;;\x1b\\\r\n",
            i % 8
        );
        t.write(line.as_bytes());
        if i % 20 == 0 {
            t.write(b"\x1b]133;A\x07$ \x1b]133;B\x07ls\x1b]133;C\x07\r\n");
            t.write(b"\x1b_Ga=T,f=32,s=1,v=1,q=2;/wAA/w==\x1b\\\r\n");
        }
    }
    t.write(b"\x1b[?1049h");
    for i in 0..20 {
        t.write(format!("alt {i}\r\n").as_bytes());
    }
    t.encode_snapshot().unwrap()
}

fn mutate(rng: &mut Rng, base: &[u8]) -> Vec<u8> {
    let mut s = base.to_vec();
    for _ in 0..=rng.below(4) {
        if s.is_empty() {
            break;
        }
        let at = rng.below(s.len());
        match rng.below(6) {
            0 => s[at] ^= 1 << rng.below(8),
            1 => {
                let end = (at + 1 + rng.below(16)).min(s.len());
                let byte = *rng.pick(&[0x00, 0xff, 0x7f, 0x80]);
                s[at..end].fill(byte);
            }
            // A record length field (any 4 bytes really) set to an extreme.
            2 if at + 4 <= s.len() => {
                let value = *rng.pick(&[0u32, 1, 0x7fff_ffff, u32::MAX, 0x0100_0000]);
                s[at..at + 4].copy_from_slice(&value.to_le_bytes());
            }
            3 => s.truncate(at),
            4 => {
                let from = rng.below(s.len());
                let len = rng.below(64).min(s.len() - from);
                let run = s[from..from + len].to_vec();
                s.splice(at..at, run);
            }
            _ => {
                let end = (at + 1 + rng.below(32)).min(s.len());
                s.drain(at..end);
            }
        }
    }
    if rng.below(4) != 0 {
        fix_checksums(&mut s);
    }
    s
}

/// Recomputes each record's CRC32C (over tag, length and payload) after the 10-byte envelope.
fn fix_checksums(s: &mut [u8]) {
    let mut pos = 10;
    while pos + 10 <= s.len() {
        let len = u32::from_le_bytes(s[pos + 2..pos + 6].try_into().unwrap()) as usize;
        let Some(end) = (pos + 10).checked_add(len).filter(|&e| e <= s.len()) else {
            break;
        };
        let crc = crc32c(s[pos..pos + 6].iter().chain(&s[pos + 10..end]));
        s[pos + 6..pos + 10].copy_from_slice(&crc.to_le_bytes());
        pos = end;
    }
}

fn crc32c<'a>(bytes: impl Iterator<Item = &'a u8>) -> u32 {
    !bytes.fold(!0u32, |mut crc, &byte| {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0x82f6_3b78 & 0u32.wrapping_sub(crc & 1));
        }
        crc
    })
}

/// Uses a restored terminal the ways a client does: render, select, re-encode, keep writing.
fn touch(t: &mut Terminal) {
    let _ = t.text(TextRegion::All);
    let _ = t.vt(TextRegion::Active);
    let _ = t.kitty_placements();
    let _ = t.encode_snapshot();
    t.write(b"\x1b[2J\x1b[Hafter\r\n");
    let _ = t.resize(10, 3, (8, 16));
}

fn exercise(bytes: &[u8]) {
    if let Ok(mut decoder) = SnapshotDecoder::new(bytes)
        && let Ok(mut t) = decoder.decode()
    {
        touch(&mut t);
    }

    if let Ok(decoder) = SnapshotDecoder::new(bytes)
        && let Ok(mut restore) = decoder.ready()
    {
        restore.write(b"live");
        for _ in 0..10_000 {
            match restore.next_page() {
                Ok(Some(_)) => {}
                _ => break,
            }
        }
        touch(&mut restore.into_terminal());
    }

    let _ = (ready_len(bytes), screen_len(bytes));
    let Some(ready) = ready_len(bytes) else {
        return;
    };
    if let Ok(mut restore) = StreamingRestore::new(&bytes[..ready]) {
        for (start, end) in history_chunks(bytes, ready, 512) {
            if restore.push(&bytes[start..end]).is_err() {
                // The terminal must stay usable, and later pushes must not crash either.
                let _ = restore.push(&bytes[start..end]);
                break;
            }
        }
        restore.write(b"tail");
        touch(&mut restore.into_terminal());
    }
}

#[test]
fn corrupt_snapshots_fail_cleanly() {
    let base = sample();
    exercise(&base);
    let seeds = std::env::var("CORRUPT_SEEDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_SEEDS);
    for seed in 0..seeds {
        let mut rng = Rng::new(seed);
        exercise(&mutate(&mut rng, &base));
    }
}

/// Seeds that break libghostty-vt 1.4.0's invariants (docs/security/supply-chain.md, "Residual
/// risk"): an out-of-bounds bitmap access in `findFreeChunks`, `unreachable` for GR = G0 in
/// the formatter, and a cursor-flags assertion in `index`. Silent in `ReleaseFast`, so this
/// only fails with the checks on:
/// `LIBGHOSTTY_VT_OPTIMIZE=safe cargo test -p ghostty-vt --test it -- --ignored upstream`.
/// Un-ignore once the pinned Ghostty fixes them.
#[test]
#[ignore = "fails until upstream Ghostty fixes its snapshot decoder"]
fn upstream_decoder_bugs() {
    let base = sample();
    for seed in [4253, 5620, 27383] {
        exercise(&mutate(&mut Rng::new(seed), &base));
    }
}

#[test]
fn arbitrary_records_fail_cleanly() {
    let base = sample();
    let ready = ready_len(&base).unwrap();
    for seed in 0..DEFAULT_SEEDS {
        let mut rng = Rng::new(seed);
        let mut restore = StreamingRestore::new(&base[..ready]).unwrap();
        let tail = mutate(&mut rng, &base[ready..]);
        let mut at = 0;
        while at < tail.len() {
            let n = (1 + rng.below(700)).min(tail.len() - at);
            if restore.push(&tail[at..at + n]).is_err() {
                break;
            }
            at += n;
        }
    }
}
