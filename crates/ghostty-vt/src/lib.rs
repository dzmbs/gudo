//! Safe wrapper over the pinned libghostty-vt: terminal state, text, snapshots, input encoding
//! (keys, mouse, paste) and shell-integration marks.
//!
//! The daemon keeps one [`Terminal`] per pane as the source of truth and feeds it raw PTY
//! bytes. When a client falls behind or resumes, the daemon sends
//! [`Terminal::encode_snapshot`] and the client restores it with a [`SnapshotDecoder`]:
//! [`SnapshotDecoder::ready`] yields a renderable terminal as soon as the visible screen has
//! arrived, and older scrollback follows page by page. Snapshots carry unfinished parser input,
//! so the byte stream can resume from any offset, even mid escape sequence.
//!
//! Snapshot format v1 has no compatibility guarantee: both ends must link the same
//! `vendor/ghostty` commit.
//!
//! # Examples
//!
//! ```
//! # fn main() -> Result<(), ghostty_vt::Error> {
//! use ghostty_vt::{SnapshotDecoder, Terminal, TextRegion};
//!
//! let mut daemon = Terminal::new(80, 24)?;
//! daemon.write(b"hello \x1b[1;3"); // cut in the middle of an SGR sequence
//! let snapshot = daemon.encode_snapshot()?;
//!
//! let mut client = SnapshotDecoder::new(&snapshot)?.decode()?;
//! for terminal in [&mut daemon, &mut client] {
//!     terminal.write(b"1mworld\x1b[0m");
//! }
//! assert_eq!(client.text(TextRegion::Active)?, daemon.text(TextRegion::Active)?);
//! assert_eq!(client.cursor(), daemon.cursor());
//! # Ok(())
//! # }
//! ```

// Parts of this crate (result mapping, formatter options) are adapted from herdr's
// `crates/ghostty-vt/src/lib.rs`, Copyright herdr contributors, licensed under Apache-2.0.

mod error;
mod history;
mod input;
mod snapshot;
mod terminal;

pub use error::Error;
pub use history::{StreamingRestore, count_pages, history_chunk, history_chunks};
pub use input::{
    Key, KeyAction, KeyEncoder, KeyEvent, Mods, MouseAction, MouseButton, MouseEncoder, MouseEvent,
    char_width, encode_paste, paste_is_safe,
};
pub use snapshot::{HistoryPage, Restore, SnapshotDecoder, ready_len, snapshot_format};
pub use terminal::{
    CONTINUATION_MAX_BYTES, Cursor, Mode, PinId, Point, PromptKind, ReplySink, Screen,
    SemanticPrompt, SemanticPromptKind, Terminal, TextRegion, Wrap,
};
