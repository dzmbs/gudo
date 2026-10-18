//! One pane: a PTY, the authoritative libghostty-vt terminal fed by its output hook, in-band
//! resize records, cached snapshots, input encoding, and the text features (search, links,
//! command output) that read the terminal.
//!
//! Lock order: `Vt` is taken by the PTY's I/O thread inside the ring lock (the output hook), so
//! nothing may call into the PTY's ring ([`PtyActor::head`], `read_from`, `subscribe*`) while
//! holding `Vt`. Resizing, snapshotting and the text features take `Vt` alone.

use std::collections::VecDeque;
use std::io;
use std::path::Path;
use std::process::Command;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use ghostty_vt::{KeyEncoder, MouseEncoder, Screen, Terminal, TextRegion, Wrap, history_chunk};
use proto::{
    CommandList, CommandOutput, InputPayload, LinkSource, Links, PaneId, PaneSize, RpcError,
    SearchPage, SearchQuery, Seq, SnapGen,
};
use pty::{EchoState, PtyActor, ReadError, SpawnOptions, Subscriber, WinSize};
use tokio::sync::{mpsc, watch};

use crate::commands::{CommandLog, CommandUpdate};
use crate::osc::{Osc, OscScanner};
use crate::scan::{self, LinkCollector, ScreenText};

/// Resize records kept for streams that lag behind; older ones are covered by snapshots.
const MAX_RESIZES: usize = 64;
const ZSTD_LEVEL: i32 = 3;
/// Output-activity notifications to the pane task are coalesced to this interval.
const ACTIVITY_INTERVAL: Duration = Duration::from_millis(100);
/// Full snapshots kept for history paging: the newest few sent to clients.
const HISTORY_SNAPSHOTS: usize = 2;
/// Longest command output returned; longer output keeps its end.
const MAX_OUTPUT: usize = 2 << 20;

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
    /// Shell integration reported a prompt or command step.
    Command(CommandUpdate),
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
    pane: PaneId,
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
    commands: CommandLog,
    keys: KeyEncoder,
    mouse: MouseEncoder,
    events: mpsc::UnboundedSender<VtEvent>,
}

impl Vt {
    fn feed(&mut self, seq: pty::Seq, data: &[u8]) {
        self.term.write(data);
        self.seq = seq.get() + data.len() as u64;
        let prompts = self.term.take_semantic_prompts();
        if !prompts.is_empty() {
            let updates = self
                .commands
                .apply(&mut self.term, self.pane, Seq(self.seq), prompts);
            for update in updates {
                let _ = self.events.send(VtEvent::Command(update));
            }
        }
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

    /// Plain text of a region, or empty when it cannot be read.
    fn text(&self, region: TextRegion) -> String {
        self.term
            .text_wrapped(region, Wrap::Join)
            .unwrap_or_default()
    }
}

/// A snapshot at a known stream position: the READY prefix compressed for the wire, and the
/// whole encoding for history paging.
#[derive(Debug)]
pub(crate) struct Snapshot {
    pub seq: Seq,
    /// Resizes with an index below this are reflected in the snapshot.
    pub resize_count: u64,
    pub raw_len: u32,
    pub zstd: Vec<u8>,
    /// The complete snapshot; history records follow the first `raw_len` bytes.
    full: Vec<u8>,
}

/// One page of history records, from [`Pane::history_page`].
#[derive(Debug)]
pub(crate) struct HistoryChunk {
    pub next_offset: u64,
    pub total_len: u64,
    pub raw_len: u32,
    pub pages: u32,
    pub done: bool,
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

/// Plain text of the whole screen at one output position, reused by paged searches.
#[derive(Debug)]
struct TextCache {
    seq: u64,
    resize_count: u64,
    text: Arc<ScreenText>,
}

pub(crate) struct Pane {
    pub id: PaneId,
    pub snap_gen: SnapGen,
    pty: PtyActor,
    vt: Arc<Mutex<Vt>>,
    cache: Mutex<Option<Arc<Snapshot>>>,
    history: Mutex<VecDeque<Arc<Snapshot>>>,
    text_cache: Mutex<Option<TextCache>>,
    resized: watch::Sender<u64>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn internal(e: impl std::fmt::Display) -> RpcError {
    RpcError::Internal(e.to_string())
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
        term.record_semantic_prompts().map_err(io::Error::other)?;
        let vt = Arc::new(Mutex::new(Vt {
            pane: id,
            term,
            seq: 0,
            resizes: VecDeque::new(),
            resize_count: 0,
            size,
            scanner: OscScanner::default(),
            alt: false,
            last_activity: None,
            commands: CommandLog::default(),
            keys: KeyEncoder::new().map_err(io::Error::other)?,
            mouse: MouseEncoder::new().map_err(io::Error::other)?,
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
            history: Mutex::new(VecDeque::new()),
            text_cache: Mutex::new(None),
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

    /// The current snapshot, encoded at most once per stream position. The newest few are
    /// kept whole so clients can page through their history.
    pub fn snapshot(&self) -> Result<Arc<Snapshot>, SnapshotError> {
        let (full, seq, resize_count) = {
            let vt = lock(&self.vt);
            if let Some(cached) = lock(&self.cache).as_ref()
                && cached.seq.0 == vt.seq
                && cached.resize_count == vt.resize_count
            {
                return Ok(Arc::clone(cached));
            }
            (vt.term.encode_snapshot()?, Seq(vt.seq), vt.resize_count)
        };
        let ready = ghostty_vt::ready_len(&full).ok_or(ghostty_vt::Error::InvalidValue)?;
        let zstd = zstd::bulk::compress(&full[..ready], ZSTD_LEVEL)?;
        let snapshot = Arc::new(Snapshot {
            seq,
            resize_count,
            raw_len: ready as u32,
            zstd,
            full,
        });
        *lock(&self.cache) = Some(Arc::clone(&snapshot));
        let mut history = lock(&self.history);
        history.retain(|s| s.seq != seq);
        history.push_back(Arc::clone(&snapshot));
        while history.len() > HISTORY_SNAPSHOTS {
            history.pop_front();
        }
        Ok(snapshot)
    }

    /// History records of the snapshot at `snapshot_seq` from `offset`: whole records up to
    /// about `max_bytes`, ending after a page or at FINISH. `None` if that snapshot is gone or
    /// the offset is not a record boundary after READY.
    pub fn history_page(
        &self,
        snapshot_seq: Seq,
        offset: u64,
        max_bytes: u32,
    ) -> Option<HistoryChunk> {
        let snapshot = lock(&self.history)
            .iter()
            .rev()
            .find(|s| s.seq == snapshot_seq)
            .cloned()?;
        let start = usize::try_from(offset).ok()?;
        if start < snapshot.raw_len as usize {
            return None;
        }
        let (end, done) = history_chunk(&snapshot.full, start, max_bytes as usize)?;
        let records = &snapshot.full[start..end];
        Some(HistoryChunk {
            next_offset: end as u64,
            total_len: snapshot.full.len() as u64,
            raw_len: records.len() as u32,
            pages: ghostty_vt::count_pages(records),
            done,
            zstd: zstd::bulk::compress(records, ZSTD_LEVEL).ok()?,
        })
    }

    /// Encodes client input for the program's current modes: keys and mouse through
    /// libghostty-vt's encoders, paste bracketed and sanitized. Empty when the event sends
    /// nothing (for example a mouse click while the program does not track the mouse).
    pub fn encode_input(&self, payload: InputPayload) -> Vec<u8> {
        if let InputPayload::Bytes(bytes) = payload {
            return bytes;
        }
        let mut guard = lock(&self.vt);
        let vt = &mut *guard;
        let encoded = match payload {
            InputPayload::Bytes(bytes) => Ok(bytes),
            InputPayload::Paste(text) => Ok(vt.term.encode_paste(&text)),
            InputPayload::Key(k) => vt.keys.encode(&vt.term, &crate::input::key(k)),
            InputPayload::KeyFull(k) => vt.keys.encode(&vt.term, &crate::input::full_key(k)),
            InputPayload::Mouse(m) => {
                let size = vt.size;
                let cell_px = (
                    size.width_px / size.cols.max(1),
                    size.height_px / size.rows.max(1),
                );
                vt.mouse.encode(&vt.term, &crate::input::mouse(m), cell_px)
            }
        };
        encoded.unwrap_or_else(|e| {
            tracing::debug!(pane = %self.id, "encoding input: {e}");
            Vec::new()
        })
    }

    /// One page of matches for `query` over the whole screen, newest first.
    pub fn search(
        &self,
        query: &SearchQuery,
        cursor: u32,
        limit: u32,
    ) -> Result<SearchPage, RpcError> {
        let re = scan::compile(query).map_err(RpcError::BadRequest)?;
        let (text, seq) = self.screen_text_cached()?;
        let all = text.search(&re);
        let total = all.len();
        let start = (cursor as usize).min(total);
        let end = start.saturating_add(limit.max(1) as usize).min(total);
        Ok(SearchPage {
            at_seq: Seq(seq),
            total_rows: text.total_rows,
            total: total as u32,
            matches: all[start..end].to_vec(),
            next: (end < total).then_some(end as u32),
        })
    }

    fn screen_text_cached(&self) -> Result<(Arc<ScreenText>, u64), RpcError> {
        let (joined, cols, total_rows, seq, resize_count) = {
            let vt = lock(&self.vt);
            if let Some(c) = lock(&self.text_cache).as_ref()
                && c.seq == vt.seq
                && c.resize_count == vt.resize_count
            {
                return Ok((Arc::clone(&c.text), c.seq));
            }
            let joined = vt
                .term
                .text_wrapped(TextRegion::All, Wrap::Join)
                .map_err(internal)?;
            (
                joined,
                vt.term.cols(),
                vt.term.total_rows() as u64,
                vt.seq,
                vt.resize_count,
            )
        };
        let text = Arc::new(ScreenText::new(&joined, cols, total_rows));
        *lock(&self.text_cache) = Some(TextCache {
            seq,
            resize_count,
            text: Arc::clone(&text),
        });
        Ok((text, seq))
    }

    /// Links on screen and in the last `commands` finished commands' output.
    pub fn links(&self, commands: u16, cwd: Option<&Path>, home: Option<&Path>) -> Links {
        // Extract under the lock, scan (regexes, file system checks) after releasing it.
        let regions: Vec<(LinkSource, String, String)> = {
            let vt = lock(&self.vt);
            let mut regions = vec![(
                LinkSource::Screen,
                vt.term.vt(TextRegion::Active).unwrap_or_default(),
                vt.text(TextRegion::Active),
            )];
            let ids: Vec<u64> = vt
                .commands
                .finished()
                .take(usize::from(commands))
                .map(|m| m.command_id)
                .collect();
            for id in ids {
                if let Some((Some(region), _)) = vt.commands.output_range(&vt.term, id) {
                    regions.push((
                        LinkSource::Command { command_id: id },
                        vt.term.vt(region).unwrap_or_default(),
                        vt.text(region),
                    ));
                }
            }
            regions
        };
        let mut collector = LinkCollector::new(cwd, home);
        for (source, vt, plain) in &regions {
            collector.scan(vt, plain, *source);
        }
        Links {
            cwd: cwd.map(|c| c.to_string_lossy().into_owned()),
            links: collector.links,
        }
    }

    /// The shell-integration commands the pane remembers.
    pub fn commands(&self) -> CommandList {
        let vt = lock(&self.vt);
        CommandList {
            at_seq: Seq(vt.seq),
            total_rows: vt.term.total_rows() as u64,
            commands: vt.commands.list(&vt.term),
        }
    }

    /// The output of command `id`, or of the most recent finished command.
    pub fn command_output(&self, id: Option<u64>) -> Result<CommandOutput, RpcError> {
        let vt = lock(&self.vt);
        let mark = match id {
            Some(id) => vt
                .commands
                .list(&vt.term)
                .into_iter()
                .map(|c| c.mark)
                .find(|m| m.command_id == id),
            None => vt.commands.finished().next().cloned(),
        }
        .ok_or(RpcError::NotFound)?;
        let (region, mut truncated) = vt
            .commands
            .output_range(&vt.term, mark.command_id)
            .ok_or(RpcError::NotFound)?;
        let mut text = region.map(|r| vt.text(r)).unwrap_or_default();
        drop(vt);
        let trimmed = text.trim_end_matches('\n').len();
        text.truncate(trimmed);
        if text.len() > MAX_OUTPUT {
            let mut cut = text.len() - MAX_OUTPUT;
            while !text.is_char_boundary(cut) {
                cut += 1;
            }
            text.drain(..cut);
            truncated = true;
        }
        Ok(CommandOutput {
            mark,
            text,
            truncated,
        })
    }

    /// Queues input for the child. Returns the output offset at the time of writing, which
    /// the input's echo (if any) follows.
    pub async fn write(&self, data: Vec<u8>) -> Result<Seq, pty::Closed> {
        let at = self.head();
        if !data.is_empty() {
            self.pty.write(data).await?;
        }
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
