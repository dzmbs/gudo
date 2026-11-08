#[cfg(test)]
mod live_probe;
mod projection;
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

pub(crate) struct Live {
    owner: tokio::sync::watch::Sender<Option<u32>>,
    fault: std::sync::atomic::AtomicBool,
    state: Mutex<State>,
    process: Mutex<Option<tokio::process::Child>>,
    task: Mutex<Option<tokio::task::AbortHandle>>,
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
        }
    }

    fn observe(&mut self, frame: &str, outgoing: bool) {
        #[derive(serde::Deserialize)]
        struct Method<'a> {
            method: Option<&'a str>,
        }
        if outgoing
            && serde_json::from_str::<Method<'_>>(frame)
                .ok()
                .is_some_and(|request| {
                    matches!(request.method, Some("thread/resume" | "thread/fork"))
                })
        {
            self.fail();
        }
        if self.closed {
            return;
        }
        let result = if outgoing {
            self.binding.observe_tui(frame)
        } else {
            self.binding.observe_server(frame)
        };
        if result.is_err() {
            self.fail();
            return;
        }
        if self.current.as_ref() != self.binding.binding() {
            self.current = self.binding.binding().cloned();
            self.events = self.current.clone().map(CodexLiveEvents::new);
            self.projection = Projection::new(
                self.current
                    .as_ref()
                    .map_or("", CodexThreadBinding::thread_id)
                    .to_owned(),
            );
            self.operations.clear();
            self.operation_bytes = 0;
            self.push(TimelineOp::Snapshot(self.projection.snapshot(60, None)));
        }
        if !outgoing && let Some(events) = &mut self.events {
            match events.observe(&self.binding, frame) {
                Ok(Some(event)) => match self.projection.apply(event) {
                    Ok(operations) => {
                        for operation in operations {
                            self.push(operation);
                        }
                    }
                    Err(_) => self.fail(),
                },
                Ok(None) => {}
                Err(_) => self.fail(),
            }
        }
    }

    fn push(&mut self, operation: TimelineOp) {
        let bytes = serde_json::to_vec(&operation).map_or(usize::MAX, |bytes| bytes.len());
        if bytes > 1024 * 1024 {
            self.fail();
            return;
        }
        self.operation_bytes = self.operation_bytes.saturating_add(bytes);
        self.operations.push_back(operation);
        while self.operations.len() > 256 || self.operation_bytes > 1024 * 1024 {
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

    fn fail(&mut self) {
        self.closed = true;
        self.binding.close();
        self.operations.clear();
        self.operation_bytes = 0;
        if let Some(wake) = &self.wake {
            let _ = wake.try_send(());
        }
    }
}

impl Live {
    pub(crate) fn set_owner(&self, pid: u32) {
        self.owner.send_replace(Some(pid));
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
    if state.closed || source.fault.load(std::sync::atomic::Ordering::Acquire) {
        return Err(unavailable());
    }
    state.wake = Some(wake.clone());
    Ok(Box::new(Session {
        source: Arc::downgrade(&source),
        cursor: state.projection.cursor(),
        cached: state.projection.snapshot(60, None),
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
            || lock(&source.state).closed
        {
            return Err(unavailable());
        }
        Ok(source)
    }
}

impl AgentSession for Session {
    fn capabilities(&self) -> AgentCapabilities {
        AgentCapabilities::READ | AgentCapabilities::STREAMING_DELTAS
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
            vec![TimelineOp::Snapshot(state.projection.snapshot(60, None))]
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
        self.cached = state.projection.snapshot(60, None);
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
            if state.closed || state.projection.cursor().epoch != self.cursor.epoch {
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
