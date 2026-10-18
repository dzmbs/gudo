//! One `pane/<id>` stream to one client: raw bytes while the client keeps up, a snapshot when

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

use iroh::endpoint::{Connection, SendStream};
use proto::{InputSeq, PaneOutput, Seq};
use pty::{RecvError, Subscriber};
use tokio::sync::{mpsc, watch};

use crate::net::NetError;
use crate::pane::{Pane, ResizeRecord};

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
    fn budget_params(self) -> (Duration, usize, usize) {
        match self {
            Self::Focused => (Duration::from_millis(50), 64 << 10, 1 << 20),
            Self::Visible | Self::Background => (Duration::from_millis(10), 16 << 10, 256 << 10),
        }
    }

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
        .filter(|p| p.is_selected())
        .map(|p| {
            // Delivery rate ≈ cwnd / RTT: what the path can drain per second.
            let rtt = p.rtt().as_secs_f64().max(1e-4);
            p.stats().cwnd as f64 / rtt
        })
        .next();
    match rate {
        Some(rate) => ((rate * delay.as_secs_f64()) as usize).clamp(min, max),
        None => min,
    }
}

/// Instructions from the connection to a running stream.
#[derive(Debug)]
pub(crate) enum StreamCmd {
    InputAck { input_seq: InputSeq, at_seq: Seq },
    Class(Class),
}

/// Where a new stream starts.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Start {
    /// Continue from the client's own state at this offset if the ring still has it.
    Resume(Seq),
    /// Start with a snapshot.
    Snapshot,
}

/// Wire bytes sent but not yet acknowledged, keyed by the offset each frame brings the client
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

/// Counters a stream exposes, for tests and logs.
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
}

struct State {
    sub: Option<Subscriber>,
    /// Index of the next resize record to send.
    next_resize: u64,
    in_flight: InFlight,
    dirty: bool,
    last_snapshot: Option<Instant>,
    retry_at: Option<Instant>,
    budget: usize,
    budget_at: Instant,
    buf: Vec<u8>,
    stats: StreamStats,
}

impl PaneStream {
    pub async fn run(mut self, start: Start) -> Result<StreamStats, NetError> {
        let mut st = State {
            sub: None,
            next_resize: 0,
            in_flight: InFlight::default(),
            dirty: true,
            last_snapshot: None,
            retry_at: None,
            budget: budget(self.class, &self.conn),
            budget_at: Instant::now(),
            buf: Vec::with_capacity(64 << 10),
            stats: StreamStats::default(),
        };
        if let Start::Resume(seq) = start
            && let (Ok(sub), Some(idx)) = (
                self.pane.subscribe_from(seq),
                self.pane.resize_index_at(seq),
            )
        {
            st.sub = Some(sub);
            st.next_resize = idx;
            st.dirty = false;
            self.flush_resizes(&mut st).await?;
        }
        let mut resizes = self.pane.resize_updates();
        loop {
            if st.dirty && st.in_flight.is_empty() {
                let due = self.snapshot_due(&st);
                if due <= Instant::now() {
                    self.send_snapshot(&mut st).await?;
                    if self.one_shot && !st.dirty {
                        self.send.finish().ok();
                        return Ok(st.stats);
                    }
                }
            }
            if st.budget_at.elapsed() > Duration::from_millis(100) {
                st.budget = budget(self.class, &self.conn);
                st.budget_at = Instant::now();
            }
            let can_read = !st.dirty && st.in_flight.bytes < st.budget && st.sub.is_some();
            let wake = (st.dirty && st.in_flight.is_empty()).then(|| self.snapshot_due(&st));
            tokio::select! {
                biased;
                cmd = self.cmds.recv() => match cmd {
                    Some(StreamCmd::InputAck { input_seq, at_seq }) => {
                        self.write(&mut st, &PaneOutput::InputAck { input_seq, at_seq }, None).await?;
                    }
                    Some(StreamCmd::Class(class)) => {
                        self.class = class;
                        let _ = self.send.set_priority(class.priority());
                        st.budget = budget(class, &self.conn);
                    }
                    None => return Ok(st.stats),
                },
                changed = self.acks.changed() => {
                    if changed.is_err() {
                        return Ok(st.stats);
                    }
                    let acked = *self.acks.borrow_and_update();
                    st.in_flight.ack(acked);
                }
                _ = resizes.changed() => {
                    if !st.dirty {
                        self.flush_resizes(&mut st).await?;
                    }
                }
                () = sleep_until(wake), if wake.is_some() => {}
                read = recv(st.sub.as_mut()), if can_read => match read {
                    Ok(chunk) => self.send_bytes(&mut st, Seq(chunk.seq.get()), &chunk.data).await?,
                    Err(RecvError::Evicted { .. }) => st.dirty = true,
                    Err(RecvError::Closed) => {
                        self.flush_resizes(&mut st).await?;
                        self.send.finish().ok();
                        return Ok(st.stats);
                    }
                },
            }
        }
    }

    fn snapshot_due(&self, st: &State) -> Instant {
        let by_rate = st
            .last_snapshot
            .map_or_else(Instant::now, |t| t + self.class.snapshot_interval());
        st.retry_at.map_or(by_rate, |r| r.max(by_rate))
    }

    async fn write(
        &mut self,
        st: &mut State,
        msg: &PaneOutput,
        end: Option<Seq>,
    ) -> Result<(), NetError> {
        st.buf.clear();
        proto::frame::encode(msg, &mut st.buf)?;
        self.send.write_all(&st.buf).await?;
        if let Some(end) = end {
            st.in_flight.push(end, st.buf.len());
        }
        Ok(())
    }

    async fn send_snapshot(&mut self, st: &mut State) -> Result<(), NetError> {
        let pane = Arc::clone(&self.pane);
        let snapshot = tokio::task::spawn_blocking(move || pane.snapshot())
            .await
            .map_err(|e| NetError::Frame(proto::FrameError::Io(std::io::Error::other(e))))?;
        let snapshot = match snapshot {
            Ok(s) => s,
            Err(e) => {
                tracing::debug!(pane = %self.pane.id, "snapshot deferred: {e}");
                st.retry_at = Some(Instant::now() + Duration::from_millis(20));
                return Ok(());
            }
        };
        st.retry_at = None;
        let sub = match st.sub.take() {
            Some(mut sub) => sub.seek(pty::Seq::new(snapshot.seq.0)).map(|()| sub),
            None => self.pane.subscribe_from(snapshot.seq),
        };
        let Ok(sub) = sub else {
            // The snapshot fell out of the ring already (extreme flood): take another.
            st.retry_at = Some(Instant::now());
            return Ok(());
        };
        let msg = PaneOutput::SnapshotZstd {
            seq: snapshot.seq,
            snap_gen: self.pane.snap_gen,
            raw_len: snapshot.raw_len,
            data: snapshot.zstd.clone(),
        };
        self.write(st, &msg, Some(snapshot.seq)).await?;
        st.sub = Some(sub);
        st.next_resize = snapshot.resize_count;
        st.dirty = false;
        st.last_snapshot = Some(Instant::now());
        st.stats.snapshots += 1;
        Ok(())
    }

    /// Sends resize records up to the subscriber's position.
    async fn flush_resizes(&mut self, st: &mut State) -> Result<(), NetError> {
        let Some(pos) = st.sub.as_ref().map(|s| Seq(s.position().get())) else {
            return Ok(());
        };
        let records = match self.pane.resizes_from(st.next_resize) {
            Ok(r) => r,
            Err(_) => {
                st.dirty = true;
                return Ok(());
            }
        };
        for r in records.into_iter().take_while(|r| r.at <= pos) {
            self.send_resize(st, r).await?;
        }
        Ok(())
    }

    async fn send_resize(&mut self, st: &mut State, r: ResizeRecord) -> Result<(), NetError> {
        let msg = PaneOutput::Resized {
            seq: r.at,
            size: r.size,
        };
        self.write(st, &msg, Some(r.at)).await?;
        st.next_resize = r.index + 1;
        Ok(())
    }

    /// Sends `data` (starting at `seq`), interleaving resizes at their offsets. Over budget it
    /// drops the bytes and marks the pane dirty; a snapshot follows once everything is acked.
    async fn send_bytes(&mut self, st: &mut State, seq: Seq, data: &[u8]) -> Result<(), NetError> {
        let end = Seq(seq.0 + data.len() as u64);
        // Always let one frame through when nothing is in flight, so progress never stalls.
        if !st.in_flight.is_empty() && st.in_flight.bytes + data.len() > st.budget {
            st.dirty = true;
            return Ok(());
        }
        let records = match self.pane.resizes_from(st.next_resize) {
            Ok(r) => r,
            Err(_) => {
                st.dirty = true;
                return Ok(());
            }
        };
        let mut pos = seq;
        let mut rest = data;
        for r in records.into_iter().take_while(|r| r.at <= end) {
            let split = (r.at.0.saturating_sub(pos.0) as usize).min(rest.len());
            if split > 0 {
                let (now, later) = rest.split_at(split);
                self.write_bytes(st, pos, now).await?;
                pos = Seq(pos.0 + split as u64);
                rest = later;
            }
            self.send_resize(st, r).await?;
        }
        if !rest.is_empty() {
            self.write_bytes(st, pos, rest).await?;
        }
        Ok(())
    }

    async fn write_bytes(&mut self, st: &mut State, seq: Seq, data: &[u8]) -> Result<(), NetError> {
        let end = Seq(seq.0 + data.len() as u64);
        let msg = PaneOutput::Bytes {
            seq,
            data: data.to_vec(),
        };
        st.stats.bytes_frames += 1;
        self.write(st, &msg, Some(end)).await
    }
}

async fn recv(sub: Option<&mut Subscriber>) -> Result<pty::Chunk, RecvError> {
    match sub {
        Some(sub) => sub.recv().await,
        None => std::future::pending().await,
    }
}

async fn sleep_until(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at.into()).await,
        None => std::future::pending().await,
    }
}
