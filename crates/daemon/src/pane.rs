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

use ghostty_vt::{
    DefaultColors, KeyEncoder, MouseEncoder, Screen, Terminal, TextRegion, Wrap, history_chunk,
};
use proto::{
    CommandList, CommandOutput, InputPayload, LinkSource, Links, PaneId, PaneSize, PrincipalId,
    RpcError, SearchPage, SearchQuery, Seq, SnapGen, UnixMillis,
};
use pty::{EchoState, PtyActor, ReadError, SpawnOptions, Subscriber, WinSize};
use tokio::sync::{mpsc, watch};

use crate::anchor::{AnchorPos, Anchors, ScrollLog};
use crate::commands::{CommandLog, CommandUpdate};
use crate::osc::{Osc, OscScanner};
use crate::scan::{self, LinkCollector, ScreenText};

/// Resize records kept for streams that lag behind; older ones are covered by snapshots.
const MAX_RESIZES: usize = 64;
/// zstd level for snapshots, measured as the best speed/size trade-off.
const ZSTD_LEVEL: i32 = 3;
/// Output-activity notifications to the pane task are coalesced to this interval.
const ACTIVITY_INTERVAL: Duration = Duration::from_millis(100);
/// Full snapshots kept for history paging: the newest few sent to clients.
const HISTORY_SNAPSHOTS: usize = 2;
/// Bytes of full snapshots kept for history paging, past the newest: one snapshot of a pane
/// full of kitty images can be tens of MB.
const HISTORY_BYTES: usize = 48 << 20;
/// A snapshot this recent is shared by every stream that asks for one, although output moved
/// on (each continues with the bytes since): many clients following a flooding pane would
/// otherwise each encode the whole terminal, under its lock, several times a second.
const SHARE_SNAPSHOT: Duration = Duration::from_millis(30);
/// Longest command output returned; longer output keeps its end.
const MAX_OUTPUT: usize = 2 << 20;
/// Cell size in pixels for clients that report none: kitty images need one to have a size.
const DEFAULT_CELL_PX: (u16, u16) = (10, 20);

/// How long input waits for room while the program is not taking it (`pty::MAX_QUEUED_INPUT`
/// is queued) before it is refused: one stuck pane must not hold up a client's input to the
/// others, which shares its stream.
const INPUT_STALL: Duration = Duration::from_secs(2);

#[derive(Debug, thiserror::Error)]
pub(crate) enum InputError {
    #[error("the pane has closed")]
    Closed,
    #[error("the program has not been reading its input")]
    Stalled,
}

/// Events queued for the pane's task beyond which new ones are dropped: a program printing
/// shell-integration marks, notifications or terminal queries faster than they can be handled
/// must not grow the daemon. Titles and directories are kept as the latest value instead.
const MAX_VT_EVENTS: usize = 1024;

/// The pane task's inbox, filled on the PTY's I/O thread without ever blocking it (it holds
/// the ring and VT locks there).
#[derive(Clone)]
pub(crate) struct VtEvents {
    tx: mpsc::Sender<VtEvent>,
    latest: Arc<LatestMeta>,
}

impl VtEvents {
    fn send(&self, event: VtEvent) {
        match event {
            VtEvent::Osc(Osc::Title(title)) => self.latest.set(|latest| latest.title = Some(title)),
            VtEvent::Osc(Osc::Cwd(cwd)) => self.latest.set(|latest| latest.cwd = Some(cwd)),
            // Dropped when full: the pane's state stays in the VT and command log, only the
            // notification is lost.
            event => drop(self.tx.try_send(event)),
        }
    }
}

/// The newest title and directory a program set, not yet picked up by the pane's task.
#[derive(Debug, Default)]
pub(crate) struct LatestMeta {
    slot: Mutex<Latest>,
    pub changed: tokio::sync::Notify,
}

#[derive(Debug, Default)]
pub(crate) struct Latest {
    pub title: Option<String>,
    pub cwd: Option<String>,
}

impl LatestMeta {
    fn set(&self, update: impl FnOnce(&mut Latest)) {
        update(&mut lock(&self.slot));
        self.changed.notify_one();
    }

    /// Takes what changed since the last call.
    pub fn take(&self) -> Latest {
        std::mem::take(&mut lock(&self.slot))
    }
}

#[derive(Debug)]
pub(crate) enum VtEvent {
    Osc(Osc),
    /// The alternate screen was entered or left.
    AltScreen,
    /// Replies to terminal queries, to be written back to the PTY.
    Reply(Vec<u8>),
    /// Output arrived (coalesced).
    Activity,
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
    events: VtEvents,
    /// Rows scrolled per output chunk, for resolving client row positions.
    scroll: ScrollLog,
    anchors: Anchors,
    /// Limits for since-join views' terminals.
    scrollback_bytes: usize,
    image_storage_bytes: u64,
    /// Guests who see only what was written after they joined (multiplayer `since_join`).
    views: Vec<View>,
}

/// A guest's copy of the pane's terminal that started without scrollback (multiplayer
/// `History::SinceJoin`). It is fed the same output and resizes in the same order as the
/// pane's own terminal, under the same lock, so its snapshot at any output offset is the
/// pane's screen with only the history written since the view opened.
struct View {
    principal: PrincipalId,
    term: Terminal,
    /// When the view opened: commands that started before are not shown.
    since: UnixMillis,
    /// The output offset it opened at: a stream may only resume from here on.
    from: Seq,
    /// The newest snapshots, for history paging; the last one is the cache.
    snapshots: VecDeque<Arc<Snapshot>>,
}

/// A pane's terminal side, its latest title and directory, and its task's inbox.
type StartedVt = (Arc<Mutex<Vt>>, Arc<LatestMeta>, mpsc::Receiver<VtEvent>);

impl Vt {
    /// The terminal side of a pane whose output is at `seq`, with the pane task's inbox. It
    /// answers queries as the pane's terminal, in `colors`.
    #[allow(clippy::too_many_arguments)]
    fn start(
        pane: PaneId,
        mut term: Terminal,
        size: PaneSize,
        limits: VtLimits,
        colors: &DefaultColors,
        seq: Seq,
        resize_count: u64,
        resizes: Vec<ResizeRecord>,
    ) -> io::Result<StartedVt> {
        let (tx, events_rx) = mpsc::channel(MAX_VT_EVENTS);
        let latest = Arc::new(LatestMeta::default());
        let events = VtEvents {
            tx,
            latest: Arc::clone(&latest),
        };
        let replies = events.clone();
        term.set_reply_sink(Box::new(move |bytes| {
            replies.send(VtEvent::Reply(bytes.to_vec()));
        }))
        .map_err(io::Error::other)?;
        term.answer_queries(&crate::theme::identity())
            .map_err(io::Error::other)?;
        term.set_default_colors(colors).map_err(io::Error::other)?;
        term.record_semantic_prompts().map_err(io::Error::other)?;
        let alt = term.active_screen() == Screen::Alternate;
        let vt = Self {
            pane,
            term,
            seq: seq.0,
            resizes: resizes.into_iter().rev().take(MAX_RESIZES).rev().collect(),
            resize_count,
            size,
            scanner: OscScanner::default(),
            alt,
            last_activity: None,
            commands: CommandLog::default(),
            keys: KeyEncoder::new().map_err(io::Error::other)?,
            mouse: MouseEncoder::new().map_err(io::Error::other)?,
            events,
            scroll: ScrollLog::default(),
            anchors: Anchors::default(),
            scrollback_bytes: limits.scrollback_bytes,
            image_storage_bytes: limits.image_storage_bytes,
            views: Vec::new(),
        };
        Ok((Arc::new(Mutex::new(vt)), latest, events_rx))
    }

    fn view(&self, principal: PrincipalId) -> Option<&View> {
        self.views.iter().find(|view| view.principal == principal)
    }

    /// Rows of the pane's terminal above the view's oldest row: the history the view lacks.
    fn hidden_rows(&self, view: &View) -> u64 {
        (self.term.total_rows() as u64).saturating_sub(view.term.total_rows() as u64)
    }

    fn feed(&mut self, seq: pty::Seq, data: &[u8]) {
        self.term.write(data);
        for view in &mut self.views {
            view.term.write(data);
        }
        self.seq = seq.get() + data.len() as u64;
        let prompts = self.term.take_semantic_prompts();
        if !prompts.is_empty() {
            let updates = self
                .commands
                .apply(&mut self.term, self.pane, Seq(self.seq), prompts);
            for update in updates {
                self.events.send(VtEvent::Command(update));
            }
        }
        self.commands.after_output(&mut self.term);
        let events = &self.events;
        self.scanner
            .feed(data, |osc| events.send(VtEvent::Osc(osc)));
        let alt = self.term.active_screen() == Screen::Alternate;
        if alt != self.alt {
            self.alt = alt;
            self.events.send(VtEvent::AltScreen);
        }
        self.scroll.observe(&mut self.term, self.seq);
        let now = Instant::now();
        if self
            .last_activity
            .is_none_or(|last| now.duration_since(last) >= ACTIVITY_INTERVAL)
        {
            self.last_activity = Some(now);
            self.events.send(VtEvent::Activity);
        }
    }

    fn text(&self, region: TextRegion) -> String {
        self.term
            .text_wrapped(region, Wrap::Join)
            .unwrap_or_default()
    }
}

/// A snapshot at a known stream position: the prefix that shows the screen (READY and the
/// pixels of the images in view) compressed for the wire, and the whole encoding for history
/// paging.
#[derive(Debug)]
pub(crate) struct Snapshot {
    pub seq: Seq,
    /// Resizes with an index below this are reflected in the snapshot.
    pub resize_count: u64,
    pub raw_len: u32,
    pub zstd: Vec<u8>,
    /// The complete snapshot; history (and the other images' pixels) follow the first
    /// `raw_len` bytes.
    full: Vec<u8>,
    made: Instant,
}

#[derive(Debug)]
pub(crate) struct HistoryChunk {
    pub next_offset: u64,
    pub total_len: u64,
    pub raw_len: u32,
    pub pages: u32,
    pub done: bool,
    pub zstd: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum SnapshotError {
    /// The parser is inside an unencodable sequence; retry after more output.
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
    pub(crate) agent_input_gate: Mutex<crate::agent_input::AgentInputGate>,
    vt: Arc<Mutex<Vt>>,
    cache: Mutex<Option<Arc<Snapshot>>>,
    history: Mutex<VecDeque<Arc<Snapshot>>>,
    text_cache: Mutex<Option<TextCache>>,
    resized: watch::Sender<u64>,
    latest: Arc<LatestMeta>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn internal(error: impl std::fmt::Display) -> RpcError {
    RpcError::Internal(error.to_string())
}

impl Pane {
    pub fn spawn(
        id: PaneId,
        snap_gen: SnapGen,
        command: Command,
        size: PaneSize,
        ring_capacity: usize,
        limits: VtLimits,
        colors: &DefaultColors,
    ) -> io::Result<(Arc<Self>, mpsc::Receiver<VtEvent>)> {
        let size = with_pixels(size);
        let term = new_terminal(size, limits).map_err(io::Error::other)?;
        let (vt, latest, events_rx) =
            Vt::start(id, term, size, limits, colors, Seq(0), 0, Vec::new())?;
        let hook_vt = Arc::clone(&vt);
        let options = SpawnOptions::new(win_size(size))
            .ring_capacity(ring_capacity)
            .output_hook(move |seq, data| lock(&hook_vt).feed(seq, data));
        let pty = PtyActor::spawn(command, options)?;
        Ok((Self::new(id, snap_gen, pty, vt, latest), events_rx))
    }

    fn new(
        id: PaneId,
        snap_gen: SnapGen,
        pty: PtyActor,
        vt: Arc<Mutex<Vt>>,
        latest: Arc<LatestMeta>,
    ) -> Arc<Self> {
        let resize_count = lock(&vt).resize_count;
        Arc::new(Self {
            id,
            snap_gen,
            pty,
            agent_input_gate: Mutex::new(crate::agent_input::AgentInputGate::default()),
            vt,
            cache: Mutex::new(None),
            history: Mutex::new(VecDeque::new()),
            text_cache: Mutex::new(None),
            resized: watch::Sender::new(resize_count),
            latest,
        })
    }

    /// Stops the pane for the daemon build that replaces this process with `exec`
    /// ([`pty::PtyActor::hand_off`]) and captures its terminal at the stream position where
    /// output stopped, so the successor shows the same screens and scrollback and clients
    /// resume their streams without a gap. The pane neither reads nor writes afterwards.
    pub fn hand_off(&self) -> io::Result<PaneHandOff> {
        let pty = self.pty.hand_off()?;
        let vt = lock(&self.vt);
        let snapshot = if vt.seq == pty.head.get() {
            vt.term
                .encode_snapshot()
                .inspect_err(|error| {
                    tracing::warn!(pane = %self.id, "the screen cannot be carried over: {error}");
                })
                .ok()
        } else {
            tracing::warn!(pane = %self.id, "the screen lags its output; not carried over");
            None
        };
        Ok(PaneHandOff {
            snapshot,
            size: vt.size,
            resize_count: vt.resize_count,
            resizes: vt.resizes.iter().copied().collect(),
            last_command_id: vt.commands.last_id(),
            snap_gen: self.snap_gen,
            pty,
        })
    }

    /// Continues a pane the previous daemon build handed off: its PTY (`master`, inherited
    /// across `exec`) and child, its output history and its terminal. If the terminal could
    /// not be carried, it starts blank under `fresh_gen`, so clients take a new snapshot
    /// instead of resuming.
    pub fn adopt(
        id: PaneId,
        master: std::os::fd::OwnedFd,
        state: &PaneHandOff,
        fresh_gen: SnapGen,
        limits: VtLimits,
        colors: &DefaultColors,
    ) -> Result<(Arc<Self>, mpsc::Receiver<VtEvent>), pty::AdoptError> {
        let size = with_pixels(state.size);
        let restored = state.snapshot.as_deref().and_then(|snapshot| {
            restore_terminal(snapshot, size, limits)
                .inspect_err(|error| {
                    tracing::warn!(pane = %id, "the carried screen does not decode: {error}");
                })
                .ok()
        });
        let (term, snap_gen) = match restored {
            Some(term) => (Ok(term), state.snap_gen),
            None => (
                new_terminal(size, limits).map_err(io::Error::other),
                fresh_gen,
            ),
        };
        let started = term.and_then(|term| {
            Vt::start(
                id,
                term,
                size,
                limits,
                colors,
                Seq(state.pty.head.get()),
                state.resize_count,
                state.resizes.clone(),
            )
        });
        let (vt, latest, events_rx) = match started {
            Ok(started) => started,
            Err(error) => {
                pty::abandon(master, state.pty.pid, ABANDON_GRACE);
                return Err(error.into());
            }
        };
        lock(&vt).commands.continue_numbering(state.last_command_id);
        let hook_vt = Arc::clone(&vt);
        let hook: pty::OutputHook = Box::new(move |seq, data| lock(&hook_vt).feed(seq, data));
        let pty = PtyActor::adopt(master, &state.pty, Some(hook))?;
        Ok((Self::new(id, snap_gen, pty, vt, latest), events_rx))
    }

    pub fn pty(&self) -> &PtyActor {
        &self.pty
    }

    /// Answers the program's color queries with `colors` from now on.
    pub fn set_colors(&self, colors: &DefaultColors) {
        if let Err(error) = lock(&self.vt).term.set_default_colors(colors) {
            tracing::warn!(pane = %self.id, "colors not applied: {error}");
        }
    }

    pub fn latest_meta(&self) -> &LatestMeta {
        &self.latest
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

    pub(crate) fn screen_view(&self) -> crate::term::ScreenView {
        crate::term::screen_view(&lock(&self.vt).term)
    }

    /// The text of the cursor's row on the primary screen, for spotting password prompts;
    /// `None` on the alternate screen.
    pub fn cursor_line(&self) -> Option<String> {
        let vt = lock(&self.vt);
        if vt.alt {
            return None;
        }
        let cursor = vt.term.cursor_point();
        let cols = vt.term.cols();
        let region = TextRegion::Range {
            start: ghostty_vt::Point { y: cursor.y, x: 0 },
            end: ghostty_vt::Point {
                y: cursor.y,
                x: cols.saturating_sub(1),
            },
        };
        vt.term.text(region).ok()
    }

    pub fn subscribe_from(&self, seq: Seq) -> Result<Subscriber, ReadError> {
        self.pty.subscribe_from(pty::Seq::new(seq.0))
    }

    /// Resizes the terminal and PTY when columns or rows change; ignores pixel-only changes.
    ///
    /// A grid change without pixels gets [`DEFAULT_CELL_PX`] cells, recorded and reported to the
    /// program and clients as if the client had sent it.
    pub fn resize(&self, size: PaneSize) -> io::Result<bool> {
        if size.cols == 0 || size.rows == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty size"));
        }
        let size = with_pixels(size);
        let mut vt = lock(&self.vt);
        if vt.size.cols == size.cols && vt.size.rows == size.rows {
            return Ok(false);
        }
        vt.term
            .resize(size.cols, size.rows, size.cell_px())
            .map_err(io::Error::other)?;
        for view in &mut vt.views {
            if let Err(error) = view.term.resize(size.cols, size.rows, size.cell_px()) {
                tracing::warn!(pane = %self.id, "resizing a since-join view: {error}");
            }
        }
        let vt = &mut *vt;
        vt.scroll.resized(&mut vt.term);
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

    pub fn resize_updates(&self) -> watch::Receiver<u64> {
        self.resized.subscribe()
    }

    /// Resize records with `index >= from`, oldest first, and the next index. Records older
    /// than the retained window are gone; a stream that needs them must take a snapshot.
    pub fn resizes_from(&self, from: u64) -> Result<Vec<ResizeRecord>, u64> {
        let vt = lock(&self.vt);
        let oldest = vt
            .resizes
            .front()
            .map_or(vt.resize_count, |record| record.index);
        if from < oldest {
            return Err(oldest);
        }
        Ok(vt
            .resizes
            .iter()
            .filter(|record| record.index >= from)
            .copied()
            .collect())
    }

    /// Index of the first resize at or after `seq` (what a stream resuming at `seq` must
    /// replay; re-applying the same size is harmless).
    pub fn resize_index_at(&self, seq: Seq) -> Option<u64> {
        let vt = lock(&self.vt);
        let first = vt.resizes.iter().find(|record| record.at >= seq);
        match first {
            Some(record) => Some(record.index),
            // All retained resizes are before `seq`; if the window still covers `seq` the next
            // index is right, otherwise a resize may have been forgotten.
            None if vt.resizes.front().is_none_or(|record| record.at <= seq) => {
                Some(vt.resize_count)
            }
            None => None,
        }
    }

    /// The current snapshot, encoded at most once per stream position, or one from the last
    /// [`SHARE_SNAPSHOT`] that the ring can still continue from. The newest few are kept whole
    /// so clients can page through their history.
    pub fn snapshot(&self) -> Result<Arc<Snapshot>, SnapshotError> {
        // Read before the VT lock: the PTY thread feeds the VT while holding the ring's lock.
        let oldest = self.pty.oldest().get();
        let (full, seq, resize_count) = {
            let vt = lock(&self.vt);
            let cache = lock(&self.cache);
            if let Some(cached) = cache.as_ref()
                && cached.resize_count == vt.resize_count
                && (cached.seq.0 == vt.seq || shareable(cached, oldest))
            {
                return Ok(Arc::clone(cached));
            }
            let hint = cache.as_deref().map_or(0, Snapshot::size_hint);
            drop(cache);
            (
                vt.term.encode_snapshot_sized(hint)?,
                Seq(vt.seq),
                vt.resize_count,
            )
        };
        let snapshot = Arc::new(Snapshot::compress(full, seq, resize_count)?);
        *lock(&self.cache) = Some(Arc::clone(&snapshot));
        let mut history = lock(&self.history);
        keep_snapshot(&mut history, &snapshot);
        Ok(snapshot)
    }

    /// The current snapshot as `viewer` may see it: the pane's own for `None`, the
    /// principal's since-join view otherwise (opened now if it is missing, which only ever
    /// hides more).
    pub fn snapshot_as(&self, viewer: Option<PrincipalId>) -> Result<Arc<Snapshot>, SnapshotError> {
        let Some(principal) = viewer else {
            return self.snapshot();
        };
        let oldest = self.pty.oldest().get();
        let (full, seq, resize_count) = {
            let mut vt = lock(&self.vt);
            open_view(&mut vt, principal)?;
            let view = vt.view(principal).ok_or(ghostty_vt::Error::InvalidValue)?;
            if let Some(cached) = view.snapshots.back()
                && cached.resize_count == vt.resize_count
                && (cached.seq.0 == vt.seq || shareable(cached, oldest))
            {
                return Ok(Arc::clone(cached));
            }
            let hint = view.snapshots.back().map_or(0, |cached| cached.size_hint());
            (
                view.term.encode_snapshot_sized(hint)?,
                Seq(vt.seq),
                vt.resize_count,
            )
        };
        let snapshot = Arc::new(Snapshot::compress(full, seq, resize_count)?);
        if let Some(view) = lock(&self.vt)
            .views
            .iter_mut()
            .find(|view| view.principal == principal)
        {
            keep_snapshot(&mut view.snapshots, &snapshot);
        }
        Ok(snapshot)
    }

    /// Starts a since-join view for `principal` (no-op if it has one): from now on its
    /// snapshots, history, search and command output hold only what is written after this.
    ///
    /// # Errors
    ///
    /// If no terminal could be made for it.
    pub fn open_view(&self, principal: PrincipalId) -> Result<(), ghostty_vt::Error> {
        open_view(&mut lock(&self.vt), principal)
    }

    /// The output offset `principal`'s since-join view opened at (opening it now if
    /// missing): bytes before it must not be replayed to that principal.
    pub fn view_start(&self, principal: PrincipalId) -> Seq {
        let mut vt = lock(&self.vt);
        match open_view(&mut vt, principal) {
            Ok(()) => vt.view(principal).map_or(Seq(u64::MAX), |view| view.from),
            Err(_) => Seq(u64::MAX),
        }
    }

    pub fn view_principals(&self) -> Vec<PrincipalId> {
        lock(&self.vt)
            .views
            .iter()
            .map(|view| view.principal)
            .collect()
    }

    pub fn close_view(&self, principal: PrincipalId) {
        lock(&self.vt)
            .views
            .retain(|view| view.principal != principal);
    }

    /// History records of the snapshot at `snapshot_seq` from `offset`: whole records up to
    /// about `max_bytes`, ending after a page or at FINISH. `None` if that snapshot is gone or
    /// the offset is not a record boundary after READY. A `viewer` pages through its own
    /// since-join snapshots.
    pub fn history_page(
        &self,
        viewer: Option<PrincipalId>,
        snapshot_seq: Seq,
        offset: u64,
        max_bytes: u32,
    ) -> Option<HistoryChunk> {
        let find = |snapshots: &VecDeque<Arc<Snapshot>>| {
            snapshots
                .iter()
                .rev()
                .find(|snapshot| snapshot.seq == snapshot_seq)
                .cloned()
        };
        let snapshot = match viewer {
            None => find(&lock(&self.history)),
            Some(principal) => find(&lock(&self.vt).view(principal)?.snapshots),
        }?;
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
        if let InputPayload::Bytes(bytes) | InputPayload::GeneratedBytes(bytes) = payload {
            return bytes;
        }
        let mut guard = lock(&self.vt);
        let vt = &mut *guard;
        let encoded = match payload {
            InputPayload::Bytes(bytes) | InputPayload::GeneratedBytes(bytes) => Ok(bytes),
            InputPayload::Paste(text) => Ok(vt.term.encode_paste(&text)),
            InputPayload::Key(key) => vt.keys.encode(&vt.term, &crate::input::key(key)),
            InputPayload::KeyFull(key) => vt.keys.encode(&vt.term, &crate::input::full_key(key)),
            InputPayload::Mouse(mouse) => {
                let size = vt.size;
                let cell_px = (
                    size.width_px / size.cols.max(1),
                    size.height_px / size.rows.max(1),
                );
                vt.mouse
                    .encode(&vt.term, &crate::input::mouse(mouse), cell_px)
            }
        };
        encoded.unwrap_or_else(|error| {
            tracing::debug!(pane = %self.id, "encoding input: {error}");
            Vec::new()
        })
    }

    /// One page of matches for `query` over the whole screen, newest first.
    pub fn search(
        &self,
        viewer: Option<PrincipalId>,
        query: &SearchQuery,
        cursor: u32,
        limit: u32,
    ) -> Result<SearchPage, RpcError> {
        let pattern = scan::compile(query).map_err(RpcError::BadRequest)?;
        let (text, seq) = match viewer {
            None => self.screen_text_cached()?,
            Some(principal) => self.view_text(principal)?,
        };
        let all = text.search(&pattern);
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
            if let Some(cached) = lock(&self.text_cache).as_ref()
                && cached.seq == vt.seq
                && cached.resize_count == vt.resize_count
            {
                return Ok((Arc::clone(&cached.text), cached.seq));
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

    /// The whole text of `principal`'s since-join view (not cached: few guests search).
    fn view_text(&self, principal: PrincipalId) -> Result<(Arc<ScreenText>, u64), RpcError> {
        let mut vt = lock(&self.vt);
        open_view(&mut vt, principal).map_err(internal)?;
        let view = vt.view(principal).ok_or(RpcError::NotFound)?;
        let joined = view
            .term
            .text_wrapped(TextRegion::All, Wrap::Join)
            .map_err(internal)?;
        let text = ScreenText::new(&joined, view.term.cols(), view.term.total_rows() as u64);
        Ok((Arc::new(text), vt.seq))
    }

    /// Links on screen and in the last `commands` finished commands' output (for a
    /// `viewer`, only commands that started after its since-join view opened).
    pub fn links(
        &self,
        viewer: Option<PrincipalId>,
        commands: u16,
        cwd: Option<&Path>,
        home: Option<&Path>,
    ) -> Links {
        // Extract under the lock, scan (regexes, file system checks) after releasing it.
        let regions: Vec<(LinkSource, String, String)> = {
            let vt = lock(&self.vt);
            let since = viewer.map(|principal| {
                vt.view(principal)
                    .map_or(UnixMillis(u64::MAX), |view| view.since)
            });
            let mut regions = vec![(
                LinkSource::Screen,
                vt.term.vt(TextRegion::Active).unwrap_or_default(),
                vt.text(TextRegion::Active),
            )];
            let ids: Vec<u64> = vt
                .commands
                .finished()
                .filter(|mark| since.is_none_or(|since| mark.started_at >= since))
                .take(usize::from(commands))
                .map(|mark| mark.command_id)
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
        for (source, vt_text, plain) in &regions {
            collector.scan(vt_text, plain, *source);
        }
        Links {
            cwd: cwd.map(|cwd| cwd.to_string_lossy().into_owned()),
            links: collector.links,
        }
    }

    /// The shell-integration commands the pane remembers. A `viewer` gets those that started
    /// after its since-join view opened, with rows in the view's coordinates.
    pub fn commands(&self, viewer: Option<PrincipalId>) -> CommandList {
        let vt = lock(&self.vt);
        let all = vt.commands.list(&vt.term);
        let Some(view) = viewer.map(|principal| vt.view(principal)) else {
            return CommandList {
                at_seq: Seq(vt.seq),
                total_rows: vt.term.total_rows() as u64,
                commands: all,
            };
        };
        let Some(view) = view else {
            return CommandList {
                at_seq: Seq(vt.seq),
                total_rows: 0,
                commands: Vec::new(),
            };
        };
        let hidden = vt.hidden_rows(view);
        let shift = |row: Option<u64>| row.and_then(|row| row.checked_sub(hidden));
        CommandList {
            at_seq: Seq(vt.seq),
            total_rows: view.term.total_rows() as u64,
            commands: all
                .into_iter()
                .filter(|command| command.mark.started_at >= view.since)
                .map(|mut command| {
                    command.rows.prompt = shift(command.rows.prompt);
                    command.rows.output = shift(command.rows.output);
                    command.rows.end = shift(command.rows.end);
                    command
                })
                .collect(),
        }
    }

    /// The output of command `id`, or of the most recent finished command (for a `viewer`,
    /// only commands that started after its since-join view opened).
    pub fn command_output(
        &self,
        viewer: Option<PrincipalId>,
        id: Option<u64>,
    ) -> Result<CommandOutput, RpcError> {
        let vt = lock(&self.vt);
        let since = viewer.map(|principal| {
            vt.view(principal)
                .map_or(UnixMillis(u64::MAX), |view| view.since)
        });
        let visible =
            |mark: &proto::CommandMark| since.is_none_or(|since| mark.started_at >= since);
        let mark = match id {
            Some(id) => vt
                .commands
                .list(&vt.term)
                .into_iter()
                .map(|command| command.mark)
                .find(|mark| mark.command_id == id),
            None => vt.commands.finished().find(|mark| visible(mark)).cloned(),
        }
        .filter(visible)
        .ok_or(RpcError::NotFound)?;
        let (region, mut truncated) = vt
            .commands
            .output_range(&vt.term, mark.command_id)
            .ok_or(RpcError::NotFound)?;
        let mut text = region.map(|region| vt.text(region)).unwrap_or_default();
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

    /// The prompt marks and the rows around the input line, read in one go.
    pub fn line_snapshot(&self) -> crate::assist::LineSnapshot {
        let vt = lock(&self.vt);
        let view = vt.commands.line_marks();
        let screen = (view.phase == crate::assist::marks::Phase::Prompt && !vt.alt)
            .then(|| crate::assist::line::Screen::capture(&vt.term, &view))
            .flatten();
        crate::assist::LineSnapshot {
            screen,
            alt: vt.alt,
            bracketed: vt.term.mode(ghostty_vt::Mode::BRACKETED_PASTE),
            at_seq: Seq(vt.seq),
            view,
        }
    }

    /// Whether command `id` was typed with a leading space (kept out of history).
    pub fn command_private(&self, id: u64) -> bool {
        lock(&self.vt).commands.is_private(id)
    }

    /// Queues input for the child. Returns the output offset at the time of writing, which
    /// the input's echo (if any) follows.
    pub async fn write(&self, data: Vec<u8>) -> Result<Seq, InputError> {
        let _input = (!data.is_empty())
            .then(|| crate::agent_input::begin_unproven_write(&self.agent_input_gate));
        let head = self.head();
        if !data.is_empty() {
            tokio::time::timeout(INPUT_STALL, self.pty.write(data))
                .await
                .map_err(|_| InputError::Stalled)?
                .map_err(|_| InputError::Closed)?;
        }
        Ok(head)
    }

    /// Anchors ink `key` to the row `from_bottom` rows above the bottom at `at_seq`; also
    /// returns the shell-integration command whose block holds the row.
    pub fn anchor_create(
        &self,
        key: u64,
        at_seq: Seq,
        from_bottom: u64,
    ) -> Result<(AnchorPos, Option<u64>), String> {
        let mut guard = lock(&self.vt);
        let vt = &mut *guard;
        let position =
            vt.anchors
                .create(&mut vt.term, &vt.scroll, vt.seq, key, at_seq, from_bottom)?;
        let command = match position {
            AnchorPos::Live { y: Some(y), .. } if !vt.alt => vt
                .commands
                .list(&vt.term)
                .into_iter()
                .filter(|command| {
                    command
                        .rows
                        .prompt
                        .is_some_and(|prompt| prompt <= u64::from(y))
                })
                .filter(|command| command.rows.end.is_none_or(|end| end >= u64::from(y)))
                .map(|command| command.mark.command_id)
                .next_back(),
            _ => None,
        };
        Ok((position, command))
    }

    /// Pins the cursor's row under `key`.
    pub fn anchor_cursor(&self, key: u64) -> Result<AnchorPos, String> {
        let mut guard = lock(&self.vt);
        let vt = &mut *guard;
        vt.anchors.pin_cursor(&mut vt.term, vt.seq, key)
    }

    /// Where anchor `key` is now (`None`: unknown, or detached and already reported).
    pub fn anchor_position(&self, key: u64) -> Option<AnchorPos> {
        let mut guard = lock(&self.vt);
        let vt = &mut *guard;
        vt.anchors.position(&mut vt.term, vt.seq, key)
    }

    pub fn anchor_remove(&self, key: u64) {
        let mut guard = lock(&self.vt);
        let vt = &mut *guard;
        vt.anchors.remove(&mut vt.term, key);
    }

    pub fn hang_up(&self) {
        let _ = self.pty.signal(pty::Signal::Hangup);
    }
}

impl Snapshot {
    /// Room for the next snapshot of the same pane. Encoding a large one (kitty images) into a
    /// growing buffer leaves a chain of freed large blocks the allocator keeps resident, which
    /// for a client watching an image-heavy pane adds up to gigabytes.
    fn size_hint(&self) -> usize {
        self.full.len() + self.full.len() / 8
    }

    fn compress(full: Vec<u8>, seq: Seq, resize_count: u64) -> Result<Self, SnapshotError> {
        let ready = ghostty_vt::screen_len(&full).ok_or(ghostty_vt::Error::InvalidValue)?;
        let zstd = zstd::bulk::compress(&full[..ready], ZSTD_LEVEL)?;
        Ok(Self {
            seq,
            resize_count,
            raw_len: ready as u32,
            zstd,
            full,
            made: Instant::now(),
        })
    }
}

/// Whether a stream may start from `snapshot` although output moved on since: it is recent
/// and the bytes after it were still in the ring (oldest offset `oldest`) a moment ago. If they
/// left since, the stream's seek fails and it asks again.
fn shareable(snapshot: &Snapshot, oldest: u64) -> bool {
    snapshot.made.elapsed() < SHARE_SNAPSHOT && oldest <= snapshot.seq.0
}

/// Keeps `snapshot` among the newest few for history paging: older ones only while all kept
/// stay within [`HISTORY_BYTES`] (a client paging a dropped one starts over from the newest).
fn keep_snapshot(snapshots: &mut VecDeque<Arc<Snapshot>>, snapshot: &Arc<Snapshot>) {
    snapshots.retain(|kept| kept.seq != snapshot.seq);
    snapshots.push_back(Arc::clone(snapshot));
    let mut total: usize = snapshots.iter().map(|kept| kept.full.len()).sum();
    while snapshots.len() > HISTORY_SNAPSHOTS || (snapshots.len() > 1 && total > HISTORY_BYTES) {
        if let Some(old) = snapshots.pop_front() {
            total -= old.full.len();
        }
    }
}

/// Opens `principal`'s since-join view if it has none: a copy of the terminal as it is now,
/// screens kept, history erased. If the terminal cannot be encoded at this instant (inside an
/// unencodable sequence) the view starts blank instead, which only hides more.
fn open_view(vt: &mut Vt, principal: PrincipalId) -> Result<(), ghostty_vt::Error> {
    if vt.view(principal).is_some() {
        return Ok(());
    }
    // Only the screens, the rows sharing their pages and the images in view; older history
    // is never decoded, and `forget_history` drops the rest.
    let limits = VtLimits {
        scrollback_bytes: vt.scrollback_bytes,
        image_storage_bytes: vt.image_storage_bytes,
    };
    let copy = vt.term.encode_snapshot().and_then(|bytes| {
        let screen = ghostty_vt::screen_len(&bytes).ok_or(ghostty_vt::Error::InvalidValue)?;
        Ok(ghostty_vt::StreamingRestore::new(&bytes[..screen])?.into_terminal())
    });
    let mut term = match copy {
        Ok(mut term) => {
            term.set_kitty_image_storage_limit(limits.image_storage_bytes)?;
            term
        }
        Err(error) => {
            tracing::debug!(pane = %vt.pane, "since-join view starts blank: {error}");
            new_terminal(vt.size, limits)?
        }
    };
    term.forget_history()?;
    term.set_scrollback_max_bytes(Some(limits.scrollback_bytes))?;
    vt.views.push(View {
        principal,
        term,
        since: UnixMillis(crate::identity::now_millis()),
        from: Seq(vt.seq),
        snapshots: VecDeque::new(),
    });
    Ok(())
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct VtLimits {
    pub scrollback_bytes: usize,
    pub image_storage_bytes: u64,
}

/// How long a carried pane that cannot be continued may outlive its hangup.
const ABANDON_GRACE: Duration = Duration::from_secs(3);

/// A pane stopped for the next daemon build ([`Pane::hand_off`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PaneHandOff {
    pub pty: pty::HandedOff,
    /// The terminal at `pty.head` (`Terminal::encode_snapshot`), unless it could not be
    /// encoded.
    pub snapshot: Option<Vec<u8>>,
    pub snap_gen: SnapGen,
    pub size: PaneSize,
    pub resize_count: u64,
    pub resizes: Vec<ResizeRecord>,
    pub last_command_id: u64,
}

/// The terminal a snapshot describes, sized and limited like a pane's own.
fn restore_terminal(
    snapshot: &[u8],
    size: PaneSize,
    limits: VtLimits,
) -> Result<Terminal, ghostty_vt::Error> {
    let mut term = ghostty_vt::SnapshotDecoder::new(snapshot)?.decode()?;
    term.resize(size.cols, size.rows, size.cell_px())?;
    term.set_scrollback_max_bytes(Some(limits.scrollback_bytes))?;
    term.set_kitty_image_storage_limit(limits.image_storage_bytes)?;
    Ok(term)
}

/// A terminal of `size` (pixels included) within `limits`. Kitty graphics files and shared
/// memory stay off (libghostty-vt's default): clients mirror the byte stream and could not
/// read the host's files, so programs fall back to sending pixels inline.
fn new_terminal(size: PaneSize, limits: VtLimits) -> Result<Terminal, ghostty_vt::Error> {
    let mut term = Terminal::new(size.cols, size.rows)?;
    term.resize(size.cols, size.rows, size.cell_px())?;
    term.set_scrollback_max_bytes(Some(limits.scrollback_bytes))?;
    term.set_kitty_image_storage_limit(limits.image_storage_bytes)?;
    Ok(term)
}

/// `size`, with [`DEFAULT_CELL_PX`] cells for whichever pixel dimension the client left out.
fn with_pixels(size: PaneSize) -> PaneSize {
    let fill = |px: u16, cells: u16, cell: u16| {
        if px > 0 {
            px
        } else {
            cells.saturating_mul(cell)
        }
    };
    PaneSize {
        width_px: fill(size.width_px, size.cols, DEFAULT_CELL_PX.0),
        height_px: fill(size.height_px, size.rows, DEFAULT_CELL_PX.1),
        ..size
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

#[cfg(test)]
mod tests {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;

    use super::*;

    fn snapshot(seq: u64, len: usize) -> Arc<Snapshot> {
        Arc::new(Snapshot {
            seq: Seq(seq),
            resize_count: 0,
            raw_len: 0,
            zstd: Vec::new(),
            full: vec![0; len],
            made: Instant::now(),
        })
    }

    #[tokio::test]
    async fn pixel_only_changes_do_not_resize_the_pty_or_emit_resize_records() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "exec sleep 30"]);
        let original = PaneSize {
            cols: 80,
            rows: 24,
            width_px: 800,
            height_px: 480,
        };
        let (pane, _events) = Pane::spawn(
            PaneId(1),
            SnapGen(1),
            command,
            original,
            1 << 20,
            VtLimits {
                scrollback_bytes: 1 << 20,
                image_storage_bytes: 0,
            },
            &DefaultColors::default(),
        )
        .unwrap();
        let updates = pane.resize_updates();
        let pixels_only = PaneSize {
            width_px: 1600,
            height_px: 960,
            ..original
        };
        assert!(!pane.resize(pixels_only).unwrap());
        assert_eq!(pane.size(), original);
        assert!(!updates.has_changed().unwrap());
        assert!(pane.resizes_from(0).unwrap().is_empty());
        let changed_grid = PaneSize {
            rows: 25,
            height_px: 1000,
            ..pixels_only
        };
        assert!(pane.resize(changed_grid).unwrap());
        assert_eq!(pane.size(), changed_grid);
        assert!(updates.has_changed().unwrap());
        assert_eq!(pane.resizes_from(0).unwrap().len(), 1);
        assert!(
            !pane
                .resize(PaneSize {
                    width_px: 0,
                    height_px: 0,
                    ..changed_grid
                })
                .unwrap()
        );
        assert_eq!(pane.size(), changed_grid);
        let _ = pane.pty().signal(pty::Signal::Kill);
    }

    /// Many streams asking for snapshots of a flooding pane share recent ones. Checking that
    /// the ring still holds a shared one's offset under the VT lock deadlocked with the PTY
    /// thread, which feeds the VT under the ring's lock.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn snapshots_of_a_flooding_pane_are_shared_without_deadlock() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "exec yes"]);
        let size = PaneSize {
            cols: 80,
            rows: 24,
            width_px: 0,
            height_px: 0,
        };
        let limits = VtLimits {
            scrollback_bytes: 1 << 20,
            image_storage_bytes: 1 << 20,
        };
        let (pane, _events) = Pane::spawn(
            PaneId(1),
            SnapGen(1),
            command,
            size,
            1 << 20,
            limits,
            &DefaultColors::default(),
        )
        .unwrap();
        let pane = Arc::new(pane);
        while pane.head().0 < 4 << 20 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        // Plain threads: a deadlocked one must not keep the test from failing.
        let (tx, rx) = std::sync::mpsc::channel();
        for _ in 0..4 {
            let (pane, tx) = (Arc::clone(&pane), tx.clone());
            std::thread::spawn(move || {
                let (mut asked, mut distinct) = (0, std::collections::HashSet::new());
                let end = Instant::now() + Duration::from_secs(2);
                while Instant::now() < end {
                    asked += 1;
                    if let Ok(snapshot) = pane.snapshot() {
                        distinct.insert(snapshot.seq);
                    }
                }
                let _ = tx.send((asked, distinct.len()));
            });
        }
        let (mut asked, mut encoded) = (0, 0);
        for _ in 0..4 {
            let (thread_asked, thread_encoded) = rx
                .recv_timeout(Duration::from_secs(30))
                .expect("snapshots deadlocked with the PTY thread");
            asked += thread_asked;
            encoded += thread_encoded;
        }
        assert!(
            encoded * 2 < asked,
            "{encoded} snapshots encoded for {asked} requests"
        );
        let _ = pane.pty().signal(pty::Signal::Kill);
    }

    /// Snapshots of an image-heavy pane are tens of MB each; older ones for paging must not
    /// multiply that.
    #[test]
    fn large_snapshots_keep_no_older_copies() {
        let mut kept = VecDeque::new();
        for seq in 1..=3 {
            keep_snapshot(&mut kept, &snapshot(seq, 1 << 20));
        }
        assert_eq!(
            kept.iter()
                .map(|snapshot| snapshot.seq.0)
                .collect::<Vec<_>>(),
            [2, 3],
            "small ones: the newest two"
        );
        keep_snapshot(&mut kept, &snapshot(4, 40 << 20));
        keep_snapshot(&mut kept, &snapshot(5, 40 << 20));
        assert_eq!(
            kept.iter()
                .map(|snapshot| snapshot.seq.0)
                .collect::<Vec<_>>(),
            [5]
        );
        keep_snapshot(&mut kept, &snapshot(6, 80 << 20));
        assert_eq!(
            kept.iter()
                .map(|snapshot| snapshot.seq.0)
                .collect::<Vec<_>>(),
            [6],
            "the newest is kept whatever its size"
        );
    }

    /// A program printing marks and titles faster than the pane's task handles them must not
    /// queue every event, or an OSC 133 flood grows the daemon without bound.
    #[tokio::test]
    async fn an_event_flood_is_bounded_and_keeps_the_last_title() {
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "i=0; while [ $i -lt 5000 ]; do printf '\\033]133;A\\007\\033]0;t%d\\007\\033]9;n\\007' $i; \
             i=$((i+1)); done",
        ]);
        let size = PaneSize {
            cols: 80,
            rows: 24,
            width_px: 0,
            height_px: 0,
        };
        let limits = VtLimits {
            scrollback_bytes: 1 << 20,
            image_storage_bytes: 1 << 20,
        };
        let (pane, events) = Pane::spawn(
            PaneId(1),
            SnapGen(1),
            command,
            size,
            1 << 20,
            limits,
            &DefaultColors::default(),
        )
        .unwrap();
        tokio::time::timeout(Duration::from_secs(60), pane.pty().wait())
            .await
            .unwrap()
            .unwrap();
        // Let the I/O thread read the last output.
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(
            events.len() <= MAX_VT_EVENTS,
            "{} events queued",
            events.len()
        );
        assert_eq!(pane.latest_meta().take().title.as_deref(), Some("t4999"));
    }

    fn terminal() -> (Terminal, Arc<Mutex<Vec<u8>>>) {
        let size = with_pixels(PaneSize {
            cols: 80,
            rows: 24,
            width_px: 0,
            height_px: 0,
        });
        let limits = VtLimits {
            scrollback_bytes: 1 << 20,
            image_storage_bytes: ghostty_vt::KITTY_IMAGE_STORAGE_LIMIT,
        };
        let mut term = new_terminal(size, limits).unwrap();
        let replies = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&replies);
        term.set_reply_sink(Box::new(move |bytes| lock(&sink).extend_from_slice(bytes)))
            .unwrap();
        (term, replies)
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02X}")).collect()
    }

    /// Program output must never get its own bytes typed back into the shell (title report,
    /// DECRQSS and XTGETTCAP echoes, clipboard reads, kitty error text, screen checksums).
    #[test]
    fn queries_never_echo_program_data() {
        let (mut term, replies) = terminal();
        let mark = "MARK;touch /tmp/pwned";
        let path = STANDARD.encode(format!("/tmp/{mark}"));
        let hostile = [
            format!("\x1b]2;{mark}\x07\x1b[21t\x1b[20t"),
            format!("\x1bP$q{mark}\x1b\\"),
            format!("\x1bP+q{}\x1b\\", hex(mark.as_bytes())),
            "\x1b]52;c;?\x07\x1b]52;p;?\x1b\\".to_owned(),
            format!("\x1b_Gi=9,a=q,t=f;{path}\x1b\\"),
            format!("\x1b_Gi=9,a=t,t=d,f=999;{path}\x1b\\"),
            "\x1b[1;1;1;1;24;80*y".to_owned(),
            "\x05".to_owned(),
            // Answered, so the sink is live.
            "\x1b[5n".to_owned(),
        ];
        for sequence in hostile {
            term.write(sequence.as_bytes());
        }
        let replies = String::from_utf8_lossy(&lock(&replies)).into_owned();
        assert!(replies.ends_with("\x1b[0n"), "{replies:?}");
        assert!(!replies.contains("MARK"), "{replies:?}");
        assert!(!replies.contains(&hex(b"MARK")), "{replies:?}");
        assert!(!replies.contains(['\r', '\n']), "{replies:?}");
        assert!(
            !replies.contains("!~"),
            "screen checksum answered: {replies:?}"
        );
    }

    /// Kitty graphics may not read or delete the host's files: file and temporary-file
    /// transmissions are refused, whatever the path.
    #[test]
    fn kitty_graphics_cannot_touch_host_files() {
        let (mut term, _) = terminal();
        let dir = tempfile::tempdir().unwrap();
        let pixel = [0xffu8, 0, 0, 0xff];
        let file = dir.path().join("secret");
        std::fs::write(&file, pixel).unwrap();
        let temp = dir.path().join("tty-graphics-protocol-1");
        std::fs::write(&temp, pixel).unwrap();
        for (id, medium, path) in [(1, 'f', &file), (2, 't', &temp)] {
            let path = STANDARD.encode(path.to_str().unwrap());
            term.write(format!("\x1b_Ga=t,t={medium},f=32,s=1,v=1,i={id};{path}\x1b\\").as_bytes());
            assert!(
                term.kitty_image(id).is_none(),
                "t={medium} loaded a host file"
            );
        }
        assert!(temp.exists(), "t=t deleted a host file");
        let data = STANDARD.encode(pixel);
        term.write(format!("\x1b_Ga=t,f=32,s=1,v=1,i=3;{data}\x1b\\").as_bytes());
        assert!(term.kitty_image(3).is_some());
    }
}
