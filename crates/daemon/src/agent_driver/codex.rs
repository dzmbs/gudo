pub(crate) mod config;
mod history;
#[cfg(test)]
mod live_probe;
pub(crate) mod process;
mod projection;
mod rollout;
mod runtime;
pub(super) mod tail;
#[cfg(test)]
pub(crate) mod tests;
mod transport;

use super::{AgentCapabilities, AgentSession, ReadFuture, TimelineRead};
use crate::core::{Core, lock};
use agents::{CodexBinding, CodexLiveEvents, CodexThreadBinding};
use projection::Projection;
use proto::{
    PaneId, TimelineCursor, TimelineOp, TimelineSnapshot, UnixMillis, WorkspaceResponse, WsError,
};
use rollout::Rollout;
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
    /// Where the app-server records rollouts, as its environment set it at launch.
    codex_home: Mutex<Option<std::path::PathBuf>>,
    observations: Mutex<Option<ObservationSender>>,
    directory: std::path::PathBuf,
    config: Mutex<config::CodexConfig>,
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
    /// The bound thread's rollout, when Codex records it with the ids it streams.
    rollout: Option<std::path::PathBuf>,
}

/// Whether `frame` starts or ends a turn: what a skipped message's outline is read for.
fn is_turn_lifecycle(frame: &str) -> bool {
    #[derive(serde::Deserialize)]
    struct Envelope {
        method: Option<String>,
    }
    serde_json::from_str::<Envelope>(frame).is_ok_and(|envelope| {
        matches!(
            envelope.method.as_deref(),
            Some("turn/started" | "turn/completed")
        )
    })
}

/// The turn and item a skipped message's outline started, completed or streamed into on
/// `thread`, when it is an item Chat shows. Replies and other notifications leave no row.
fn skipped_item(outline: &str, thread: &str) -> Option<(String, String)> {
    #[derive(serde::Deserialize)]
    #[serde(tag = "method")]
    enum Skipped {
        #[serde(rename = "item/started", alias = "item/completed")]
        Item { params: ItemParams },
        #[serde(rename = "item/agentMessage/delta")]
        Delta { params: DeltaParams },
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ItemParams {
        thread_id: String,
        turn_id: String,
        item: Item,
    }
    #[derive(serde::Deserialize)]
    struct Item {
        #[serde(rename = "type")]
        kind: String,
        id: String,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct DeltaParams {
        thread_id: String,
        turn_id: String,
        item_id: String,
    }
    let (thread_id, turn, item) = match serde_json::from_str(outline).ok()? {
        Skipped::Item { params } => {
            let is_shown = matches!(
                params.item.kind.as_str(),
                "userMessage"
                    | "agentMessage"
                    | "commandExecution"
                    | "reasoning"
                    | "fileChange"
                    | "mcpToolCall"
                    | "dynamicToolCall"
                    | "collabAgentToolCall"
                    | "plan"
            );
            is_shown.then_some((params.thread_id, params.turn_id, params.item.id))?
        }
        Skipped::Delta { params } => (params.thread_id, params.turn_id, params.item_id),
    };
    (thread_id == thread && !turn.is_empty() && !item.is_empty()).then_some((turn, item))
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
            rollout: None,
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
        if direction == Direction::FromServer {
            self.observe_event(frame);
        }
    }

    fn observe_event(&mut self, frame: &str) {
        let Some(events) = &mut self.events else {
            return;
        };
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

    /// A message too large to observe went past; the relay forwarded it unchanged. A turn it
    /// started or ended is still read from its `outline`, so status and controls follow it.
    fn skipped(&mut self, direction: Direction, outline: Option<&str>) {
        if self.closed {
            return;
        }
        // An unseen binding request or reply would leave the binding on the wrong thread.
        if direction == Direction::FromTui || self.binding.pending_request().is_some() {
            self.fail();
            return;
        }
        let skipped = self
            .current
            .as_ref()
            .zip(outline)
            .and_then(|(binding, outline)| skipped_item(outline, binding.thread_id()));
        if !self.projection_lost
            && let Some((turn, item)) = skipped
        {
            match self.projection.skipped(turn, &item) {
                Ok(operations) => {
                    for operation in operations {
                        self.push(operation);
                    }
                }
                Err(_) => self.lose_projection(),
            }
        }
        if let Some(outline) = outline.filter(|outline| is_turn_lifecycle(outline)) {
            self.observe_event(outline);
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
        self.rollout = None;
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

    fn setting_notices(&mut self, notices: &[(proto::TimelineNoticeKind, String)]) {
        if self.projection_lost || !self.history_ready {
            return;
        }
        for (kind, text) in notices {
            match self.projection.setting_notice(*kind, text) {
                Ok(operations) => {
                    for operation in operations {
                        self.push(operation);
                    }
                }
                Err(_) => {
                    self.lose_projection();
                    return;
                }
            }
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
        let read = AgentCapabilities::READ
            | AgentCapabilities::STREAMING_DELTAS
            | AgentCapabilities::DIFFS
            | AgentCapabilities::THINKING
            | AgentCapabilities::PLANS;
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

    /// Chat can show the conversation from the app-server stream.
    pub(crate) fn is_chat_ready(&self) -> bool {
        lock(&self.state).is_chat_ready() && !self.fault.load(std::sync::atomic::Ordering::Acquire)
    }

    /// Stops the relay and the app-server's group now and reaps it.
    pub(crate) async fn stop(&self) {
        for task in [&self.task, &self.history_task, &self.control_task] {
            if let Some(task) = lock(task).take() {
                task.abort();
            }
        }
        let process = lock(&self.process).take();
        if let Some(process) = process {
            process::terminate(process).await;
        }
    }

    /// The app-server runs, or its launch is still within its bounded bootstrap.
    pub(crate) fn is_running(&self) -> bool {
        lock(&self.process).is_some()
            || lock(&self.task)
                .as_ref()
                .is_some_and(|task| !task.is_finished())
    }
}

/// The launch's exit fence closed: the agent is gone, so its source goes too.
pub(crate) fn end_launch(entry: &crate::core::PaneEntry) {
    let source = lock(&entry.codex).clone();
    if let Some(source) = source {
        source.control_failed();
    }
    lock(&entry.codex).take();
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
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(process) = process {
            match tokio::runtime::Handle::try_current() {
                Ok(runtime) => {
                    runtime.spawn(process::terminate(process));
                }
                Err(_) => process::kill(&process),
            }
        }
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

pub(super) struct Session {
    source: Weak<Live>,
    cursor: TimelineCursor,
    cached: TimelineSnapshot,
    wake: mpsc::Sender<()>,
    /// The durable store older history and full text are read from, once Codex created it.
    rollout: Option<Rollout>,
}

/// Where the bound thread's rollout is, as the app-server reported it.
struct RolloutSource {
    codex_home: std::path::PathBuf,
    path: std::path::PathBuf,
    thread: String,
}

impl State {
    fn rollout_source(&self, codex_home: Option<std::path::PathBuf>) -> Option<RolloutSource> {
        Some(RolloutSource {
            codex_home: codex_home?,
            path: self.rollout.clone()?,
            thread: self.current.as_ref()?.thread_id().to_owned(),
        })
    }
}

pub(super) fn open(
    core: &Core,
    pane: PaneId,
    wake: mpsc::Sender<()>,
) -> Result<Box<dyn AgentSession>, WsError> {
    let entry = core.pane(pane).ok_or_else(unavailable)?;
    let source = lock(&entry.codex).clone().ok_or_else(unavailable)?;
    let codex_home = lock(&source.codex_home).clone();
    let (mut session, location) = {
        let mut state = lock(&source.state);
        if !state.is_chat_ready() || source.fault.load(std::sync::atomic::Ordering::Acquire) {
            return Err(unavailable());
        }
        state.wake = Some(wake.clone());
        let session = Session {
            source: Arc::downgrade(&source),
            cursor: state.projection.cursor(),
            cached: state.projection.snapshot(projection::SNAPSHOT_ITEMS, None),
            wake,
            rollout: None,
        };
        (session, state.rollout_source(codex_home))
    };
    session.open_rollout(location);
    Ok(Box::new(session))
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

    /// Codex creates the rollout with the thread's first turn, so a fresh thread has none yet.
    fn open_rollout(&mut self, location: Option<RolloutSource>) {
        if self.rollout.is_some() {
            return;
        }
        self.rollout = location.and_then(|location| {
            Rollout::open(&location.codex_home, &location.path, &location.thread).ok()
        });
    }

    /// The snapshot with its older history continuing in the rollout rather than in memory.
    fn linked(&self, mut snapshot: TimelineSnapshot) -> TimelineSnapshot {
        if let Some(rollout) = &self.rollout {
            let ids: Vec<String> = snapshot.items.iter().map(|item| item.id.clone()).collect();
            snapshot.before = rollout
                .before_items(&ids, snapshot.cursor.epoch)
                .unwrap_or(None);
        }
        snapshot
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
        if since.is_some() {
            let mut snapshot = self.cached.clone();
            snapshot.items.clear();
            snapshot.before = None;
            return snapshot;
        }
        self.linked(self.cached.clone())
    }
    fn refresh(&mut self, core: &Core, pane: PaneId) -> Result<Vec<TimelineOp>, WsError> {
        let source = self.check_identity(core, pane)?;
        let codex_home = lock(&source.codex_home).clone();
        let (operations, location) = {
            let state = lock(&source.state);
            let location = state.rollout_source(codex_home);
            let current = state.projection.cursor();
            if current == self.cursor {
                (Vec::new(), location)
            } else {
                let operations = if current.epoch != self.cursor.epoch
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
                if current.epoch != self.cursor.epoch {
                    self.rollout = None;
                }
                self.cached = state.projection.snapshot(projection::SNAPSHOT_ITEMS, None);
                self.cursor = current;
                (operations, location)
            }
        };
        self.open_rollout(location);
        Ok(operations
            .into_iter()
            .map(|operation| match operation {
                TimelineOp::Snapshot(snapshot) => TimelineOp::Snapshot(self.linked(snapshot)),
                operation => operation,
            })
            .collect())
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
        Box::pin(std::future::ready(self.read_now(request)))
    }
    fn wake(&self) -> mpsc::Sender<()> {
        self.wake.clone()
    }
}

impl Session {
    fn read_now(&self, request: TimelineRead) -> Result<WorkspaceResponse, WsError> {
        let source = self.source()?;
        let (cursor, session) = {
            let state = lock(&source.state);
            if !state.is_chat_ready() || state.projection.cursor().epoch != self.cursor.epoch {
                return Err(unavailable());
            }
            if let (TimelineRead::ItemsBefore { before, limit }, None) = (&request, &self.rollout) {
                return state
                    .projection
                    .page(*before, usize::from(*limit), None)
                    .map(WorkspaceResponse::Timeline);
            }
            (
                state.projection.cursor(),
                state.projection.session().clone(),
            )
        };
        let rollout = self.rollout.as_ref().ok_or_else(|| {
            WsError::Unavailable(
                "Codex has not saved this conversation yet. Try again when the turn ends.".into(),
            )
        });
        match request {
            TimelineRead::ItemsBefore { before, limit } => {
                let page = rollout?.page(before, usize::from(limit), cursor.epoch)?;
                Ok(WorkspaceResponse::Timeline(TimelineSnapshot {
                    cursor,
                    session,
                    items: page.items,
                    before: page.before,
                }))
            }
            TimelineRead::ToolOutput {
                handle,
                offset,
                length,
            } => {
                let handle = handle
                    .parse::<proto::OutputHandle>()
                    .map_err(|error| WsError::Invalid(error.to_string()))?;
                if handle.epoch() != cursor.epoch {
                    return Err(WsError::Conflict(
                        "the Codex session changed; reopen Chat".into(),
                    ));
                }
                rollout?
                    .text(&handle, offset, length)
                    .map(WorkspaceResponse::TimelineOutput)
            }
            TimelineRead::ToolDiff { handle } => {
                let handle = handle
                    .parse::<proto::OutputHandle>()
                    .map_err(|error| WsError::Invalid(error.to_string()))?;
                if handle.epoch() != cursor.epoch {
                    return Err(WsError::Conflict(
                        "the Codex session changed; reopen Chat".into(),
                    ));
                }
                rollout?.diff(&handle).map(WorkspaceResponse::TimelineDiff)
            }
        }
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
    WsError::Unavailable(
        "Chat lost track of this Codex conversation. Open Chat again to read it.".into(),
    )
}
