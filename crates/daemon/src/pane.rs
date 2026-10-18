//! One pane: a PTY, the authoritative libghostty-vt terminal fed by its output hook, in-band
//! resize records, and cached READY snapshots.
//!
//! Lock order: `Vt` is taken by the PTY's I/O thread inside the ring lock (the output hook), so
//! nothing may call into the PTY's ring ([`PtyActor::head`], `read_from`, `subscribe*`) while
//! holding `Vt`. Resizing and snapshotting take `Vt` alone.

use std::collections::VecDeque;
use std::io;
use std::process::Command;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use ghostty_vt::{Screen, Terminal, TextRegion};
use proto::{PaneId, PaneSize, Seq, SnapGen};
use pty::{EchoState, PtyActor, ReadError, SpawnOptions, Subscriber, WinSize};
use tokio::sync::{mpsc, watch};

use crate::osc::{Osc, OscScanner};

/// Resize records kept for streams that lag behind; older ones are covered by snapshots.
const MAX_RESIZES: usize = 64;
const ZSTD_LEVEL: i32 = 3;
/// Output-activity notifications to the pane task are coalesced to this interval.
const ACTIVITY_INTERVAL: Duration = Duration::from_millis(100);

/// What the output hook reports to the pane's task.
#[derive(Debug)]
pub(crate) enum VtEvent {
    Osc(Osc),
    /// The alternate screen was entered or left.
    AltScreen,
    /// Replies to terminal queries, to be written back to the PTY.
    Reply(Vec<u8>),
    /// Output arrived (coalesced).
    Activity,
}

/// A resize applied at an output offset, numbered in order of application.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ResizeRecord {
    pub index: u64,
    pub at: Seq,
    pub size: PaneSize,
}

/// The terminal side of a pane, shared with the PTY's I/O thread.
struct Vt {
    term: Terminal,
    /// Offset one past the last byte fed to `term`.
    seq: u64,
    /// Resizes; `resize_count` is the index the next one gets.
    resizes: VecDeque<ResizeRecord>,
    resize_count: u64,
    size: PaneSize,
    scanner: OscScanner,
    alt: bool,
    last_activity: Option<Instant>,
    events: mpsc::UnboundedSender<VtEvent>,
}

impl Vt {
    fn feed(&mut self, seq: pty::Seq, data: &[u8]) {
        self.term.write(data);
        self.seq = seq.get() + data.len() as u64;
        let events = &self.events;
        self.scanner.feed(data, |osc| {
            let _ = events.send(VtEvent::Osc(osc));
        });
        let alt = self.term.active_screen() == Screen::Alternate;
        if alt != self.alt {
            self.alt = alt;
            let _ = self.events.send(VtEvent::AltScreen);
        }
        let now = Instant::now();
        if self
            .last_activity
            .is_none_or(|t| now.duration_since(t) >= ACTIVITY_INTERVAL)
        {
            self.last_activity = Some(now);
            let _ = self.events.send(VtEvent::Activity);
        }
    }
}

/// A READY snapshot, compressed, at a known stream position.
#[derive(Debug)]
pub(crate) struct Snapshot {
    pub seq: Seq,
    /// Resizes with an index below this are reflected in the snapshot.
    pub resize_count: u64,
    pub raw_len: u32,
    pub zstd: Vec<u8>,
}

/// Errors creating a snapshot.
#[derive(Debug, thiserror::Error)]
pub(crate) enum SnapshotError {
    #[error("terminal state is not encodable right now: {0}")]
    Encode(#[from] ghostty_vt::Error),
    #[error("compressing snapshot: {0}")]
    Compress(#[from] io::Error),
}

pub(crate) struct Pane {
    pub id: PaneId,
    pub snap_gen: SnapGen,
    pty: PtyActor,
    vt: Arc<Mutex<Vt>>,
    cache: Mutex<Option<Arc<Snapshot>>>,
    resized: watch::Sender<u64>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Pane {
    /// Spawns `cmd` in a PTY of `size` and wires its output into a fresh terminal.
    pub fn spawn(
        id: PaneId,
        snap_gen: SnapGen,
        cmd: Command,
        size: PaneSize,
        ring_capacity: usize,
        scrollback_bytes: usize,
    ) -> io::Result<(Arc<Self>, mpsc::UnboundedReceiver<VtEvent>)> {
        let (events, events_rx) = mpsc::unbounded_channel();
        let mut term = Terminal::new(size.cols, size.rows).map_err(io::Error::other)?;
        term.set_scrollback_max_bytes(Some(scrollback_bytes))
            .map_err(io::Error::other)?;
        let replies = events.clone();
        term.set_reply_sink(Box::new(move |bytes| {
            let _ = replies.send(VtEvent::Reply(bytes.to_vec()));
        }))
        .map_err(io::Error::other)?;
        let vt = Arc::new(Mutex::new(Vt {
            term,
            seq: 0,
            resizes: VecDeque::new(),
            resize_count: 0,
            size,
            scanner: OscScanner::default(),
            alt: false,
            last_activity: None,
            events,
        }));
        let hook_vt = Arc::clone(&vt);
        let options = SpawnOptions::new(win_size(size))
            .ring_capacity(ring_capacity)
            .output_hook(move |seq, data| lock(&hook_vt).feed(seq, data));
        let pty = PtyActor::spawn(cmd, options)?;
        let pane = Arc::new(Self {
            id,
            snap_gen,
            pty,
            vt,
            cache: Mutex::new(None),
            resized: watch::Sender::new(0),
        });
        Ok((pane, events_rx))
    }

    pub fn pty(&self) -> &PtyActor {
        &self.pty
    }

    pub fn head(&self) -> Seq {
        Seq(self.pty.head().get())
    }

    pub fn size(&self) -> PaneSize {
        lock(&self.vt).size
    }

    pub fn alt_screen(&self) -> bool {
        lock(&self.vt).alt
    }

    pub fn echo(&self) -> EchoState {
        self.pty.echo_state()
    }

    pub fn echo_updates(&self) -> watch::Receiver<EchoState> {
        self.pty.echo_updates()
    }

    /// The visible screen as plain text, for screen-based agent detection.
    pub fn screen_text(&self) -> String {
        lock(&self.vt)
            .term
            .text(TextRegion::Active)
            .unwrap_or_default()
    }

    /// A subscriber replaying from `seq`.
    pub fn subscribe_from(&self, seq: Seq) -> Result<Subscriber, ReadError> {
        self.pty.subscribe_from(pty::Seq::new(seq.0))
    }

    /// Resizes the terminal and the PTY. Returns `false` if the size is unchanged.
    pub fn resize(&self, size: PaneSize) -> io::Result<bool> {
        if size.cols == 0 || size.rows == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty size"));
        }
        let mut vt = lock(&self.vt);
        if vt.size == size {
            return Ok(false);
        }
        vt.term
            .resize(size.cols, size.rows)
            .map_err(io::Error::other)?;
        // Inside the Vt lock, so no output can be fed between the record and the ioctl: every
        // byte before `at` was produced for the old size as far as the VT is concerned.
        self.pty.resize(win_size(size))?;
        let record = ResizeRecord {
            index: vt.resize_count,
            at: Seq(vt.seq),
            size,
        };
        vt.resize_count += 1;
        vt.resizes.push_back(record);
        if vt.resizes.len() > MAX_RESIZES {
            vt.resizes.pop_front();
        }
        vt.size = size;
        self.resized.send_replace(vt.resize_count);
        Ok(true)
    }

    /// Notified whenever a resize is recorded.
    pub fn resize_updates(&self) -> watch::Receiver<u64> {
        self.resized.subscribe()
    }

    /// Resize records with `index >= from`, oldest first, and the next index. Records older
    /// than the retained window are gone; a stream that needs them must take a snapshot.
    pub fn resizes_from(&self, from: u64) -> Result<Vec<ResizeRecord>, u64> {
        let vt = lock(&self.vt);
        let oldest = vt.resizes.front().map_or(vt.resize_count, |r| r.index);
        if from < oldest {
            return Err(oldest);
        }
        Ok(vt
            .resizes
            .iter()
            .filter(|r| r.index >= from)
            .copied()
            .collect())
    }

    /// Index of the first resize at or after `seq` (what a stream resuming at `seq` must
    /// replay; re-applying the same size is harmless).
    pub fn resize_index_at(&self, seq: Seq) -> Option<u64> {
        let vt = lock(&self.vt);
        let first = vt.resizes.iter().find(|r| r.at >= seq);
        match first {
            Some(r) => Some(r.index),
            // All retained resizes are before `seq`; if the window still covers `seq` the next
            // index is right, otherwise a resize may have been forgotten.
            None if vt.resizes.front().is_none_or(|r| r.at <= seq) => Some(vt.resize_count),
            None => None,
        }
    }

    /// The current READY snapshot, encoded at most once per stream position.
    pub fn snapshot(&self) -> Result<Arc<Snapshot>, SnapshotError> {
        let (raw, seq, resize_count) = {
            let vt = lock(&self.vt);
            if let Some(cached) = lock(&self.cache).as_ref()
                && cached.seq.0 == vt.seq
                && cached.resize_count == vt.resize_count
            {
                return Ok(Arc::clone(cached));
            }
            (
                vt.term.encode_ready_snapshot()?,
                Seq(vt.seq),
                vt.resize_count,
            )
        };
        let zstd = zstd::bulk::compress(&raw, ZSTD_LEVEL)?;
        let snapshot = Arc::new(Snapshot {
            seq,
            resize_count,
            raw_len: raw.len() as u32,
            zstd,
        });
        *lock(&self.cache) = Some(Arc::clone(&snapshot));
        Ok(snapshot)
    }

    /// Queues input for the child. Returns the output offset at the time of writing, which
    /// the input's echo (if any) follows.
    pub async fn write(&self, data: Vec<u8>) -> Result<Seq, pty::Closed> {
        let at = self.head();
        self.pty.write(data).await?;
        Ok(at)
    }

    /// Hangs up the child's session.
    pub fn hang_up(&self) {
        let _ = self.pty.signal(pty::Signal::Hangup);
    }
}

pub(crate) fn win_size(size: PaneSize) -> WinSize {
    WinSize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: size.width_px,
        pixel_height: size.height_px,
    }
}
