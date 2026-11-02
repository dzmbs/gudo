//! One `pane/<id>` stream to one client: raw bytes while the client keeps up, a snapshot when
//! it falls behind, with the unacked budget sized from a delay target.

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

use iroh::endpoint::{Connection, SendStream};
use proto::{InputSeq, PaneOutput, Seq};
use pty::{RecvError, Subscriber};
use tokio::sync::{mpsc, watch};

use crate::net::NetError;
use crate::pane::{Pane, ResizeRecord};

/// Stream priorities; higher is sent first.
pub(crate) mod priority {
    pub const CTL: i32 = 100;
    pub const FOCUSED: i32 = 80;
    pub const VISIBLE: i32 = 50;
    pub const BACKGROUND: i32 = 10;
    pub const BULK: i32 = 1;
}

/// How much a pane matters to the client right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Class {
    Focused,
    Visible,
    Background,
}

impl Class {
    pub fn priority(self) -> i32 {
        match self {
            Self::Focused => priority::FOCUSED,
            Self::Visible => priority::VISIBLE,
            Self::Background => priority::BACKGROUND,
        }
    }

    /// Delay this pane's in-flight bytes may add in front of a keystroke, and budget bounds.
    /// The budget is link rate × allowed delay, not bandwidth × RTT.
    fn budget_params(self) -> (Duration, usize, usize) {
        match self {
            Self::Focused => (Duration::from_millis(50), 64 << 10, 1 << 20),
            Self::Visible | Self::Background => (Duration::from_millis(10), 16 << 10, 256 << 10),
        }
    }

    /// Minimum time between snapshots of a flooding pane.
    fn snapshot_interval(self) -> Duration {
        match self {
            Self::Focused => Duration::from_millis(33),
            Self::Visible | Self::Background => Duration::from_millis(250),
        }
    }
}

/// Unacked budget for `class` on `conn`'s current path.
fn budget(class: Class, conn: &Connection) -> usize {
    let (delay, min, max) = class.budget_params();
    let rate = conn
        .paths()
        .iter()
        .filter(|path| path.is_selected())
        .map(|path| {
            // Delivery rate ≈ cwnd / RTT: what the path can drain per second.
            let rtt = path.rtt().as_secs_f64().max(1e-4);
            path.stats().cwnd as f64 / rtt
        })
        .next();
    match rate {
        Some(rate) => ((rate * delay.as_secs_f64()) as usize).clamp(min, max),
        None => min,
    }
}

#[derive(Debug)]
pub(crate) enum StreamCmd {
    InputAck { input_seq: InputSeq, at_seq: Seq },
    Class(Class),
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Start {
    /// Continue from the client's own state at this offset if the ring still has it.
    Resume(Seq),
    Snapshot,
}

/// Wire bytes sent but not yet acknowledged, keyed by the offset each frame brings the client
/// to: a snapshot moves `seq` far but costs only its size.
#[derive(Debug, Default)]
struct InFlight {
    frames: VecDeque<(Seq, usize)>,
    bytes: usize,
}

impl InFlight {
    fn push(&mut self, end: Seq, len: usize) {
        self.frames.push_back((end, len));
        self.bytes += len;
    }

    fn ack(&mut self, acked: Seq) {
        while let Some(&(end, len)) = self.frames.front() {
            if end > acked {
                break;
            }
            self.frames.pop_front();
            self.bytes -= len;
        }
    }

    fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct StreamStats {
    pub snapshots: u64,
    pub bytes_frames: u64,
}

pub(crate) struct PaneStream {
    pub pane: Arc<Pane>,
    pub send: SendStream,
    pub conn: Connection,
    pub acks: watch::Receiver<Seq>,
    pub cmds: mpsc::UnboundedReceiver<StreamCmd>,
    pub class: Class,
    pub one_shot: bool,
    /// Snapshots come from this principal's since-join view (multiplayer).
    pub viewer: Option<proto::PrincipalId>,
}

struct State {
    subscriber: Option<Subscriber>,
    next_resize: u64,
    in_flight: InFlight,
    dirty: bool,
    last_snapshot: Option<Instant>,
    retry_at: Option<Instant>,
    budget: usize,
    budget_at: Instant,
    frame_buf: Vec<u8>,
    stats: StreamStats,
}

impl PaneStream {
    pub async fn run(mut self, start: Start) -> Result<StreamStats, NetError> {
        let mut state = State {
            subscriber: None,
            next_resize: 0,
            in_flight: InFlight::default(),
            dirty: true,
            last_snapshot: None,
            retry_at: None,
            budget: budget(self.class, &self.conn),
            budget_at: Instant::now(),
            frame_buf: Vec::with_capacity(64 << 10),
            stats: StreamStats::default(),
        };
        if let Start::Resume(seq) = start
            && let (Ok(subscriber), Some(resize_index)) = (
                self.pane.subscribe_from(seq),
                self.pane.resize_index_at(seq),
            )
        {
            state.subscriber = Some(subscriber);
            state.next_resize = resize_index;
            state.dirty = false;
            self.flush_resizes(&mut state).await?;
        }
        let mut resizes = self.pane.resize_updates();
        loop {
            if state.dirty && state.in_flight.is_empty() {
                let due = self.snapshot_due(&state);
                if due <= Instant::now() {
                    self.send_snapshot(&mut state).await?;
                    if self.one_shot && !state.dirty {
                        self.send.finish().ok();
                        return Ok(state.stats);
                    }
                }
            }
            if state.budget_at.elapsed() > Duration::from_millis(100) {
                state.budget = budget(self.class, &self.conn);
                state.budget_at = Instant::now();
            }
            let can_read =
                !state.dirty && state.in_flight.bytes < state.budget && state.subscriber.is_some();
            let wake =
                (state.dirty && state.in_flight.is_empty()).then(|| self.snapshot_due(&state));
            tokio::select! {
                biased;
                cmd = self.cmds.recv() => match cmd {
                    Some(StreamCmd::InputAck { input_seq, at_seq }) => {
                        self.write(&mut state, &PaneOutput::InputAck { input_seq, at_seq }, None).await?;
                    }
                    Some(StreamCmd::Class(class)) => {
                        self.class = class;
                        let _ = self.send.set_priority(class.priority());
                        state.budget = budget(class, &self.conn);
                    }
                    None => return Ok(state.stats),
                },
                changed = self.acks.changed() => {
                    if changed.is_err() {
                        return Ok(state.stats);
                    }
                    let acked = *self.acks.borrow_and_update();
                    state.in_flight.ack(acked);
                }
                _ = resizes.changed() => {
                    if !state.dirty {
                        self.flush_resizes(&mut state).await?;
                    }
                }
                () = sleep_until(wake), if wake.is_some() => {}
                read = recv(state.subscriber.as_mut()), if can_read => match read {
                    Ok(chunk) => self.send_bytes(&mut state, Seq(chunk.seq.get()), &chunk.data).await?,
                    Err(RecvError::Evicted { .. }) => state.dirty = true,
                    Err(RecvError::Closed) => {
                        self.flush_resizes(&mut state).await?;
                        self.send.finish().ok();
                        return Ok(state.stats);
                    }
                },
            }
        }
    }

    fn snapshot_due(&self, state: &State) -> Instant {
        let by_rate = state
            .last_snapshot
            .map_or_else(Instant::now, |last| last + self.class.snapshot_interval());
        state
            .retry_at
            .map_or(by_rate, |retry_at| retry_at.max(by_rate))
    }

    async fn write(
        &mut self,
        state: &mut State,
        msg: &PaneOutput,
        end: Option<Seq>,
    ) -> Result<(), NetError> {
        state.frame_buf.clear();
        proto::frame::encode(msg, &mut state.frame_buf)?;
        self.send.write_all(&state.frame_buf).await?;
        if let Some(end) = end {
            state.in_flight.push(end, state.frame_buf.len());
        }
        Ok(())
    }

    async fn send_snapshot(&mut self, state: &mut State) -> Result<(), NetError> {
        let pane = Arc::clone(&self.pane);
        let viewer = self.viewer;
        let snapshot = tokio::task::spawn_blocking(move || pane.snapshot_as(viewer))
            .await
            .map_err(|error| {
                NetError::Frame(proto::FrameError::Io(std::io::Error::other(error)))
            })?;
        let snapshot = match snapshot {
            Ok(snapshot) => snapshot,
            Err(error) => {
                // Unencodable until the current escape sequence ends; keep trying.
                tracing::debug!(pane = %self.pane.id, "snapshot deferred: {error}");
                state.retry_at = Some(Instant::now() + Duration::from_millis(20));
                return Ok(());
            }
        };
        state.retry_at = None;
        let subscriber = match state.subscriber.take() {
            Some(mut subscriber) => subscriber
                .seek(pty::Seq::new(snapshot.seq.0))
                .map(|()| subscriber),
            None => self.pane.subscribe_from(snapshot.seq),
        };
        let Ok(subscriber) = subscriber else {
            // The snapshot fell out of the ring already (extreme flood): take another.
            state.retry_at = Some(Instant::now());
            return Ok(());
        };
        let msg = PaneOutput::SnapshotZstd {
            seq: snapshot.seq,
            snap_gen: self.pane.snap_gen,
            raw_len: snapshot.raw_len,
            data: snapshot.zstd.clone(),
        };
        self.write(state, &msg, Some(snapshot.seq)).await?;
        state.subscriber = Some(subscriber);
        state.next_resize = snapshot.resize_count;
        state.dirty = false;
        state.last_snapshot = Some(Instant::now());
        state.stats.snapshots += 1;
        Ok(())
    }

    /// Sends resize records up to the subscriber's position.
    async fn flush_resizes(&mut self, state: &mut State) -> Result<(), NetError> {
        let Some(position) = state
            .subscriber
            .as_ref()
            .map(|subscriber| Seq(subscriber.position().get()))
        else {
            return Ok(());
        };
        let records = match self.pane.resizes_from(state.next_resize) {
            Ok(records) => records,
            Err(_) => {
                state.dirty = true;
                return Ok(());
            }
        };
        for record in records
            .into_iter()
            .take_while(|record| record.at <= position)
        {
            self.send_resize(state, record).await?;
        }
        Ok(())
    }

    async fn send_resize(
        &mut self,
        state: &mut State,
        record: ResizeRecord,
    ) -> Result<(), NetError> {
        let msg = PaneOutput::Resized {
            seq: record.at,
            size: record.size,
        };
        self.write(state, &msg, Some(record.at)).await?;
        state.next_resize = record.index + 1;
        Ok(())
    }

    /// Sends `data` (starting at `seq`), interleaving resizes at their offsets. Over budget it
    /// drops the bytes and marks the pane dirty; a snapshot follows once everything is acked.
    async fn send_bytes(
        &mut self,
        state: &mut State,
        seq: Seq,
        data: &[u8],
    ) -> Result<(), NetError> {
        let end = Seq(seq.0 + data.len() as u64);
        // Always let one frame through when nothing is in flight, so progress never stalls.
        if !state.in_flight.is_empty() && state.in_flight.bytes + data.len() > state.budget {
            state.dirty = true;
            return Ok(());
        }
        let records = match self.pane.resizes_from(state.next_resize) {
            Ok(records) => records,
            Err(_) => {
                state.dirty = true;
                return Ok(());
            }
        };
        let mut position = seq;
        let mut rest = data;
        for record in records.into_iter().take_while(|record| record.at <= end) {
            let split = (record.at.0.saturating_sub(position.0) as usize).min(rest.len());
            if split > 0 {
                let (now, later) = rest.split_at(split);
                self.write_bytes(state, position, now).await?;
                position = Seq(position.0 + split as u64);
                rest = later;
            }
            self.send_resize(state, record).await?;
        }
        if !rest.is_empty() {
            self.write_bytes(state, position, rest).await?;
        }
        Ok(())
    }

    async fn write_bytes(
        &mut self,
        state: &mut State,
        seq: Seq,
        data: &[u8],
    ) -> Result<(), NetError> {
        let end = Seq(seq.0 + data.len() as u64);
        let msg = PaneOutput::Bytes {
            seq,
            data: data.to_vec(),
        };
        state.stats.bytes_frames += 1;
        self.write(state, &msg, Some(end)).await
    }
}

async fn recv(subscriber: Option<&mut Subscriber>) -> Result<pty::Chunk, RecvError> {
    match subscriber {
        Some(subscriber) => subscriber.recv().await,
        None => std::future::pending().await,
    }
}

async fn sleep_until(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at.into()).await,
        None => std::future::pending().await,
    }
}
