//! Each pane's screen and newest scrollback on disk (`<state>/screens/<pane>.zst`, `0600`),
//! so a pane comes back showing what it showed when the daemon or the computer restarts.
//!
//! A screen is saved a while after output (`Config::screen_save_delay`), on the blocking pool,
//! and once more for every pane on shutdown. A file lives as long as its pane is in the saved
//! layout. On restore the text is the start of the new pane's output, so clients see it as
//! ordinary scrollback above a dim separator.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use proto::{PaneId, Seq, UnixMillis};
use tokio::sync::Notify;

use crate::core::{Core, lock};
use crate::fsutil::{create_private_dir, read_optional, write_atomic};
use crate::pane::Pane;

const DIR: &str = "screens";
const EXTENSION: &str = "zst";
/// The first line of a saved screen; the time it was saved follows on the second.
const FORMAT_LINE: &str = "screen 1";
/// Longest styled text kept per pane; older rows go first.
const MAX_SCREEN_BYTES: usize = 1 << 20;
/// Compressed bytes of every pane's screen together; a screen that does not fit is not saved.
const MAX_TOTAL_BYTES: u64 = 64 << 20;
const ZSTD_LEVEL: i32 = 3;
const RESTORED_LABEL: &str = "Restored after restart";

/// What a saved screen brings back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SavedScreen {
    pub saved_at: UnixMillis,
    pub text: String,
}

#[derive(Debug, Clone, Copy)]
struct SavedFile {
    seq: Seq,
    compressed_bytes: u64,
}

#[derive(Debug)]
pub(crate) struct Screens {
    dir: PathBuf,
    changed: Notify,
    saved: Mutex<HashMap<PaneId, SavedFile>>,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum ScreenError {
    #[error("reading the terminal: {0}")]
    Terminal(#[from] ghostty_vt::Error),
    #[error("{0}")]
    Io(#[from] io::Error),
    #[error("the saved screens would take more than {MAX_TOTAL_BYTES} bytes")]
    OverBudget,
}

impl Screens {
    pub fn new(state_dir: &Path) -> Self {
        Self {
            dir: state_dir.join(DIR),
            changed: Notify::new(),
            saved: Mutex::new(HashMap::new()),
        }
    }

    /// A pane wrote output: its screen is saved after the delay.
    pub fn note_output(&self) {
        self.changed.notify_one();
    }

    fn path(&self, pane_id: PaneId) -> PathBuf {
        self.dir.join(format!("{}.{EXTENSION}", pane_id.0))
    }

    /// Saves `pane`'s screen if it changed since the last save. Blocks on the terminal's lock
    /// and the file system.
    pub fn save(&self, pane: &Pane) -> Result<(), ScreenError> {
        let since = lock(&self.saved)
            .get(&pane.id)
            .map_or(Seq(u64::MAX), |file| file.seq);
        let Some((seq, text)) = pane.restorable_screen(since)? else {
            return Ok(());
        };
        let compressed = encode(&SavedScreen {
            saved_at: UnixMillis(crate::identity::now_millis()),
            text,
        })?;
        let others: u64 = lock(&self.saved)
            .iter()
            .filter(|(id, _)| **id != pane.id)
            .map(|(_, file)| file.compressed_bytes)
            .sum();
        if others + compressed.len() as u64 > MAX_TOTAL_BYTES {
            return Err(ScreenError::OverBudget);
        }
        create_private_dir(&self.dir)?;
        write_atomic(&self.path(pane.id), &compressed)?;
        lock(&self.saved).insert(
            pane.id,
            SavedFile {
                seq,
                compressed_bytes: compressed.len() as u64,
            },
        );
        Ok(())
    }

    /// Saves every pane whose screen changed. Blocks.
    pub fn save_all(&self, core: &Core) {
        for (pane_id, entry) in core.pane_entries() {
            if let Err(error) = self.save(&entry.pane) {
                tracing::warn!(pane = %pane_id, "saving the screen: {error}");
            }
        }
    }

    /// The screen saved for `pane_id`, if any can be read.
    pub fn load(&self, pane_id: PaneId) -> Option<SavedScreen> {
        let path = self.path(pane_id);
        let compressed = read_optional(&path)
            .inspect_err(|error| tracing::warn!(pane = %pane_id, "reading the screen: {error}"))
            .ok()??;
        let saved = decode(&compressed);
        if saved.is_none() {
            tracing::warn!(pane = %pane_id, "the saved screen is unreadable");
        }
        saved
    }

    /// Removes the screens of panes not in `panes`. Blocks.
    pub fn keep_only(&self, panes: &HashSet<PaneId>) {
        lock(&self.saved).retain(|pane_id, _| panes.contains(pane_id));
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let pane_id = path
                .extension()
                .filter(|extension| *extension == EXTENSION)
                .and_then(|_| path.file_stem()?.to_str()?.parse().ok())
                .map(PaneId);
            if pane_id.is_some_and(|pane_id| !panes.contains(&pane_id))
                && let Err(error) = std::fs::remove_file(&path)
            {
                tracing::warn!("removing {}: {error}", path.display());
            }
        }
    }
}

/// Saves changed screens a while after output, until the daemon stops.
pub(crate) async fn run(core: Arc<Core>) {
    loop {
        core.screens.changed.notified().await;
        tokio::time::sleep(core.cfg.screen_save_delay).await;
        let saving = Arc::clone(&core);
        let _ = tokio::task::spawn_blocking(move || saving.screens.save_all(&saving)).await;
    }
}

fn encode(screen: &SavedScreen) -> io::Result<Vec<u8>> {
    let text = newest_part(&screen.text, MAX_SCREEN_BYTES);
    let plain = format!("{FORMAT_LINE}\n{}\n{text}", screen.saved_at.0);
    zstd::encode_all(plain.as_bytes(), ZSTD_LEVEL)
}

fn decode(compressed: &[u8]) -> Option<SavedScreen> {
    let plain = zstd::decode_all(compressed).ok()?;
    let plain = String::from_utf8(plain).ok()?;
    let (format, rest) = plain.split_once('\n')?;
    if format != FORMAT_LINE {
        return None;
    }
    let (saved_at, text) = rest.split_once('\n')?;
    Some(SavedScreen {
        saved_at: UnixMillis(saved_at.parse().ok()?),
        text: text.to_owned(),
    })
}

/// The end of `text`, at most `max_bytes` long, starting on a line.
fn newest_part(text: &str, max_bytes: usize) -> &str {
    if text.len() <= max_bytes {
        return text;
    }
    let cut = text.len() - max_bytes;
    match text[cut..].find('\n') {
        Some(line_end) => &text[cut + line_end + 1..],
        None => "",
    }
}

/// The output a restored pane starts with: its saved screen, if any, then a dim line that
/// says it was restored.
pub(crate) fn restored_preamble(saved: Option<&SavedScreen>) -> Vec<u8> {
    let mut preamble = Vec::new();
    let label = match saved {
        Some(saved) => {
            preamble.extend_from_slice(saved.text.as_bytes());
            preamble.extend_from_slice(b"\x1b[0m\r\n");
            format!("{RESTORED_LABEL} \u{b7} {}", local_time(saved.saved_at))
        }
        None => RESTORED_LABEL.to_owned(),
    };
    preamble.extend_from_slice(format!("\x1b[2m{label}\x1b[0m\r\n").as_bytes());
    preamble
}

/// `at` in this computer's time zone, `2026-11-08 23:04`.
fn local_time(at: UnixMillis) -> String {
    let seconds = (at.0 / 1000) as libc::time_t;
    // SAFETY: an all-zero `tm` is a valid value for `localtime_r` to overwrite.
    let mut local: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are valid for the call; `localtime_r` is the thread-safe variant.
    if unsafe { libc::localtime_r(&seconds, &mut local) }.is_null() {
        return String::new();
    }
    format!(
        "{}-{:02}-{:02} {:02}:{:02}",
        local.tm_year + 1900,
        local.tm_mon + 1,
        local.tm_mday,
        local.tm_hour,
        local.tm_min
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_saved_screen_reads_back() {
        let screen = SavedScreen {
            saved_at: UnixMillis(1_762_639_440_000),
            text: "\x1b[31mred\x1b[0m\r\n$ ".to_owned(),
        };
        assert_eq!(decode(&encode(&screen).unwrap()), Some(screen));
        assert_eq!(decode(b"not zstd"), None);
        let other_format = zstd::encode_all(&b"screen 9\n1\ntext"[..], 3).unwrap();
        assert_eq!(decode(&other_format), None);
    }

    #[test]
    fn long_screens_keep_their_newest_lines() {
        assert_eq!(newest_part("one\ntwo\nthree", 9), "three");
        assert_eq!(newest_part("one\ntwo", 100), "one\ntwo");
    }

    #[test]
    fn files_of_panes_no_longer_in_the_layout_are_removed() {
        let state = tempfile::tempdir().unwrap();
        let screens = Screens::new(state.path());
        std::fs::create_dir_all(state.path().join(DIR)).unwrap();
        for pane in [1, 2] {
            std::fs::write(screens.path(PaneId(pane)), b"x").unwrap();
        }
        screens.keep_only(&HashSet::from([PaneId(2)]));
        assert!(!screens.path(PaneId(1)).exists());
        assert!(screens.path(PaneId(2)).exists());
    }
}
