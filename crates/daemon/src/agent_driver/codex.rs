mod history;
#[cfg(test)]
mod live_probe;
mod projection;
mod runtime;
#[cfg(test)]
mod tests;
mod transport;

use super::{AgentCapabilities, AgentSession, ReadFuture, TimelineRead};
use crate::core::{Core, lock};
use agents::{CodexBinding, CodexLiveEvents, CodexThreadBinding};
use projection::Projection;
use proto::{
    PaneId, TimelineCursor, TimelineOp, TimelineSnapshot, UnixMillis, WorkspaceResponse, WsError,
};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, Weak};
use tokio::sync::mpsc;
use transport::Direction;

const MAX_CAPTURED_EVENTS: usize = 256;
const MAX_CAPTURED_BYTES: usize = 1024 * 1024;
const MAX_OPERATIONS: usize = 256;
const MAX_OPERATION_BYTES: usize = 1024 * 1024;

type ObservationSender = mpsc::Sender<transport::Observation>;
type HistoryReply = (CodexThreadBinding, std::io::Result<String>);

pub(crate) struct Live {
    owner: tokio::sync::watch::Sender<Option<runtime::Owner>>,
    runtime: Mutex<runtime::Runtime>,
    fault: std::sync::atomic::AtomicBool,
    state: Mutex<State>,
    process: Mutex<Option<tokio::process::Child>>,
    task: Mutex<Option<tokio::task::AbortHandle>>,
    history_task: Mutex<Option<tokio::task::AbortHandle>>,
    controls: Mutex<Option<transport::control::Sender>>,
    control_task: Mutex<Option<tokio::task::AbortHandle>>,
    history_result: Mutex<Option<HistoryReply>>,
    observations: Mutex<Option<ObservationSender>>,
    directory: std::path::PathBuf,
}

struct State {
    binding: CodexBinding,
    current: Option<CodexThreadBinding>,
    events: Option<CodexLiveEvents>,
    projection: Projection,
    operations: VecDeque<TimelineOp>,
    operation_bytes: usize,
    wake: Option<mpsc::Sender<()>>,
    closed: bool,
    projection_lost: bool,
    suspended: bool,
    requires_history: bool,
    history_ready: bool,
    deferred_history: bool,
    captured: Vec<agents::CodexLiveEvent>,
    captured_bytes: usize,
    effects: Vec<runtime::Effect>,
}

impl State {
    fn new() -> Self {
        Self {
            binding: CodexBinding::default(),
            current: None,
            events: None,
            projection: Projection::new(String::new()),
            operations: VecDeque::new(),
            operation_bytes: 0,
            wake: None,
            closed: false,
            projection_lost: false,
            suspended: false,
            requires_history: false,
            history_ready: true,
            deferred_history: false,
            captured: Vec::new(),
            captured_bytes: 0,
            effects: Vec::new(),
        }
    }

    fn observe(&mut self, frame: &str, direction: Direction) {
        if self.closed {
            return;
        }
        let result = match direction {
            Direction::FromTui => self.binding.observe_tui(frame),
            Direction::FromServer => self.binding.observe_server(frame),
        };
        if result.is_err() {
            self.fail();
            return;
        }
        if direction == Direction::FromTui {
            history::observe_tui(self, frame);
            if self.closed {
                return;
            }
        }
        let Some(binding) = self.binding.binding().cloned() else {
            if self.current.is_some() && !self.suspended {
                self.suspended = true;
                self.effects.push(runtime::Effect::Lost);
                if let Some(wake) = &self.wake {
                    let _ = wake.try_send(());
                }
            }
            return;
        };
        if self.current.as_ref() != Some(&binding) {
            self.bind_reply(binding, frame);
            if self.closed {
                return;
            }
        }
        if direction == Direction::FromServer
            && let Some(events) = &mut self.events
        {
            match events.observe(&self.binding, frame) {
                Ok(Some(event)) => {
                    if let Some(effect) = runtime::Effect::from_event(&event) {
                        self.effects.push(effect);
                    }
                    self.project(event, frame.len());
                }
                Ok(None) => {}
                Err(_) => self.fail(),
            }
        }
    }

    fn project(&mut self, event: agents::CodexLiveEvent, frame_bytes: usize) {
        if self.projection_lost {
            return;
        }
        if !self.history_ready {
            self.captured_bytes = self.captured_bytes.saturating_add(frame_bytes);
            if self.captured.len() >= MAX_CAPTURED_EVENTS
                || self.captured_bytes > MAX_CAPTURED_BYTES
            {
                self.lose_projection();
                return;
            }
            self.captured.push(event.clone());
        }
        match self.projection.apply(event) {
            Ok(operations) => {
                for operation in operations {
                    self.push(operation);
                }
            }
            Err(_) => self.lose_projection(),
        }
    }

    /// A message too large to observe went past; the relay forwarded it unchanged.
    fn skipped(&mut self, direction: Direction) {
        if self.closed {
            return;
        }
        // An unseen binding request or reply would leave the binding on the wrong thread.
        if direction == Direction::FromTui || self.binding.pending_request().is_some() {
            self.fail();
            return;
        }
        if self.projection_lost || self.current.is_none() {
            return;
        }
        match self.projection.skipped() {
            Ok(operations) => {
                for operation in operations {
                    self.push(operation);
                }
            }
            Err(_) => self.lose_projection(),
        }
    }

    fn is_bound(&self) -> bool {
        !self.closed
            && self
                .current
                .as_ref()
                .is_some_and(|binding| self.binding.is_current(binding))
    }

    fn is_ready(&self) -> bool {
        self.is_bound() && self.history_ready
    }

    fn is_chat_ready(&self) -> bool {
        self.is_ready() && !self.projection_lost
    }

    fn bind_reply(&mut self, binding: CodexThreadBinding, frame: &str) {
        self.suspended = false;
        self.projection_lost = false;
        self.captured.clear();
        self.captured_bytes = 0;
        self.history_ready = !self.deferred_history;
        self.events = Some(CodexLiveEvents::new(binding.clone()));
        self.projection = Projection::new(binding.thread_id().to_owned());
        let thread = binding.thread_id().to_owned();
        let effect_index = self.effects.len();
        self.current = Some(binding);
        self.operations.clear();
        self.operation_bytes = 0;
        let cwd = match history::hydrate(self, frame) {
            Ok(cwd) => cwd,
            Err(error) => {
                self.effects
                    .insert(effect_index, runtime::Effect::Bound(thread, None));
                if error.closes_observation() {
                    self.fail();
                } else {
                    self.lose_projection();
                }
                return;
            }
        };
        self.effects
            .insert(effect_index, runtime::Effect::Bound(thread, cwd));
        if self.history_ready {
            self.push(TimelineOp::Snapshot(
                self.projection.snapshot(projection::SNAPSHOT_ITEMS, None),
            ));
        } else if let Some(binding) = &self.current {
            self.effects.push(runtime::Effect::Hydrate(binding.clone()));
        }
    }

    fn push(&mut self, operation: TimelineOp) {
        let bytes = serde_json::to_vec(&operation).map_or(usize::MAX, |bytes| bytes.len());
        if bytes > MAX_OPERATION_BYTES {
            self.lose_projection();
            return;
        }
        self.operation_bytes = self.operation_bytes.saturating_add(bytes);
        self.operations.push_back(operation);
        while self.operations.len() > MAX_OPERATIONS || self.operation_bytes > MAX_OPERATION_BYTES {
            if let Some(operation) = self.operations.pop_front() {
                self.operation_bytes = self
                    .operation_bytes
                    .saturating_sub(serde_json::to_vec(&operation).map_or(0, |bytes| bytes.len()));
            }
        }
        if let Some(wake) = &self.wake {
            let _ = wake.try_send(());
        }
    }

    /// Chat can no longer show this conversation; status and approvals keep flowing.
    fn lose_projection(&mut self) {
        if self.closed || self.projection_lost {
            return;
        }
        self.projection_lost = true;
        self.history_ready = true;
        self.captured.clear();
        self.captured_bytes = 0;
        self.operations.clear();
        self.operation_bytes = 0;
        if let Some(wake) = &self.wake {
            let _ = wake.try_send(());
        }
    }

    fn fail(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        self.captured.clear();
        self.captured_bytes = 0;
        self.effects.push(runtime::Effect::Lost);
        self.binding.close();
        self.operations.clear();
        self.operation_bytes = 0;
        if let Some(wake) = &self.wake {
            let _ = wake.try_send(());
        }
    }
}

impl Live {
    pub(crate) fn capabilities(&self) -> AgentCapabilities {
        let read = AgentCapabilities::READ | AgentCapabilities::STREAMING_DELTAS;
        if lock(&self.controls).is_some()
            && lock(&self.state).is_ready()
            && !self.fault.load(std::sync::atomic::Ordering::Acquire)
        {
            read | AgentCapabilities::SEND
                | AgentCapabilities::ACKNOWLEDGED_SEND
                | AgentCapabilities::STOP
                | AgentCapabilities::APPROVALS
        } else {
            read
        }
    }

    pub(crate) fn is_running(&self) -> bool {
        !self.fault.load(std::sync::atomic::Ordering::Acquire) || lock(&self.process).is_some()
    }
}

impl Drop for Live {
    fn drop(&mut self) {
        if let Some(task) = lock(&self.task).take() {
            task.abort();
        }
        if let Some(task) = lock(&self.history_task).take() {
            task.abort();
        }
        if let Some(task) = lock(&self.control_task).take() {
            task.abort();
        }
        let process = self
            .process
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // Tokio's kill-on-drop child reaper must not block a pane close on waitpid.
        process.take();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

pub(super) struct Session {
    source: Weak<Live>,
    cursor: TimelineCursor,
    cached: TimelineSnapshot,
    wake: mpsc::Sender<()>,
}

pub(super) fn open(
    core: &Core,
    pane: PaneId,
    wake: mpsc::Sender<()>,
) -> Result<Box<dyn AgentSession>, WsError> {
    let entry = core.pane(pane).ok_or_else(unavailable)?;
    let source = lock(&entry.codex).clone().ok_or_else(unavailable)?;
    let mut state = lock(&source.state);
    if !state.is_chat_ready() || source.fault.load(std::sync::atomic::Ordering::Acquire) {
        return Err(unavailable());
    }
    state.wake = Some(wake.clone());
    Ok(Box::new(Session {
        source: Arc::downgrade(&source),
        cursor: state.projection.cursor(),
        cached: state.projection.snapshot(projection::SNAPSHOT_ITEMS, None),
        wake,
    }))
}

impl Session {
    fn source(&self) -> Result<Arc<Live>, WsError> {
        self.source.upgrade().ok_or_else(unavailable)
    }
    fn check_identity(&self, core: &Core, pane: PaneId) -> Result<Arc<Live>, WsError> {
        let source = self.source()?;
        let entry = core.pane(pane).ok_or_else(unavailable)?;
        if !lock(&entry.codex)
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, &source))
            || source.fault.load(std::sync::atomic::Ordering::Acquire)
            || !lock(&source.state).is_chat_ready()
        {
            return Err(unavailable());
        }
        Ok(source)
    }
}

impl AgentSession for Session {
    fn capabilities(&self) -> AgentCapabilities {
        self.source
            .upgrade()
            .map_or(AgentCapabilities::READ, |source| source.capabilities())
    }
    fn cursor(&self) -> TimelineCursor {
        self.cursor
    }
    fn check_history_scope(&self, since: Option<UnixMillis>) -> Result<(), WsError> {
        // Projection time cannot establish whether a buffered item preceded the guest's join.
        if since.is_some() {
            return Err(WsError::Unavailable(
                "This source does not support since-join Chat yet. Use Terminal.".into(),
            ));
        }
        Ok(())
    }
    fn snapshot(&self, since: Option<UnixMillis>) -> TimelineSnapshot {
        let mut snapshot = self.cached.clone();
        if since.is_some() {
            snapshot.items.clear();
            snapshot.before = None;
        }
        snapshot
    }
    fn refresh(&mut self, core: &Core, pane: PaneId) -> Result<Vec<TimelineOp>, WsError> {
        let source = self.check_identity(core, pane)?;
        let state = lock(&source.state);
        let current = state.projection.cursor();
        if current == self.cursor {
            return Ok(Vec::new());
        }
        let result = if current.epoch != self.cursor.epoch
            || (state.operations.len() as u64)
                < current.sequence.saturating_sub(self.cursor.sequence)
        {
            vec![TimelineOp::Snapshot(
                state.projection.snapshot(projection::SNAPSHOT_ITEMS, None),
            )]
        } else {
            state
                .operations
                .iter()
                .filter(|operation| {
                    operation_cursor(operation)
                        .is_some_and(|cursor| cursor.sequence > self.cursor.sequence)
                })
                .cloned()
                .collect()
        };
        self.cached = state.projection.snapshot(projection::SNAPSHOT_ITEMS, None);
        self.cursor = current;
        Ok(result)
    }
    fn check_current(&self, core: &Core, pane: PaneId) -> Result<(), WsError> {
        let source = self.check_identity(core, pane)?;
        if lock(&source.state).projection.cursor().epoch != self.cursor.epoch {
            return Err(WsError::Conflict("the Codex session changed".into()));
        }
        Ok(())
    }
    fn read(&mut self, request: TimelineRead, since: Option<UnixMillis>) -> ReadFuture {
        if let Err(error) = self.check_history_scope(since) {
            return Box::pin(async move { Err(error) });
        }
        let result = self.source().and_then(|source| {
            let state = lock(&source.state);
            if !state.is_chat_ready() || state.projection.cursor().epoch != self.cursor.epoch {
                return Err(unavailable());
            }
            match request {
                TimelineRead::ItemsBefore { before, limit } => state
                    .projection
                    .page(before, usize::from(limit), since)
                    .map(WorkspaceResponse::Timeline),
                _ => Err(WsError::Unavailable(
                    "Use Terminal for this tool's full output or changes.".into(),
                )),
            }
        });
        Box::pin(std::future::ready(result))
    }
    fn wake(&self) -> mpsc::Sender<()> {
        self.wake.clone()
    }
}

fn operation_cursor(operation: &TimelineOp) -> Option<TimelineCursor> {
    match operation {
        TimelineOp::Snapshot(snapshot) => Some(snapshot.cursor),
        TimelineOp::Upsert { cursor, .. }
        | TimelineOp::Append { cursor, .. }
        | TimelineOp::Remove { cursor, .. }
        | TimelineOp::Session { cursor, .. }
        | TimelineOp::Checkpoint { cursor } => Some(*cursor),
        TimelineOp::Unavailable { .. } => None,
    }
}

fn unavailable() -> WsError {
    WsError::Unavailable("Codex Chat is unavailable. Continue in Terminal.".into())
}
