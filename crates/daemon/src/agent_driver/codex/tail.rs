//! Chat for a Codex the daemon does not drive (started by hand, a version without the native
//! path, or a native conversation Chat lost track of): its rollout, read as Codex writes it.

use std::path::{Path, PathBuf};

use proto::{
    AgentKind, PaneId, TimelineCursor, TimelineItem, TimelineOp, TimelineSession, TimelineSnapshot,
    UnixMillis, WorkspaceResponse, WsError,
};
use tokio::sync::mpsc;

use super::projection::SNAPSHOT_ITEMS;
use super::rollout::Rollout;
use crate::agent_driver::{AgentCapabilities, AgentSession, ReadFuture, TimelineRead};
use crate::core::{Core, lock};
use crate::timeline::native_watch::NativeWatch;
use crate::timeline::record_stream::RecordStream;

#[cfg(test)]
mod tests;

/// Which conversation the pane's Codex writes, as far as is known yet.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Target {
    codex_home: PathBuf,
    thread: Option<String>,
}

struct Reading {
    rollout: Rollout,
    stream: RecordStream,
    watcher: NativeWatch,
}

pub(super) struct RolloutTail {
    target: Target,
    reading: Option<Reading>,
    items: Vec<TimelineItem>,
    cursor: TimelineCursor,
    session: TimelineSession,
    wake: mpsc::Sender<()>,
    controls: AgentCapabilities,
}

pub(in crate::agent_driver) fn open(
    core: &Core,
    pane: PaneId,
    epoch: u64,
    wake: mpsc::Sender<()>,
) -> Result<Box<dyn AgentSession>, WsError> {
    let entry = core
        .pane(pane)
        .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
    // Typing into a Codex started by hand could reach its shell once it exits; a launched one
    // has an exit fence.
    let controls =
        if lock(&entry.codex).is_none() && lock(&entry.pane.agent_input_gate).has_launch() {
            AgentCapabilities::SEND | AgentCapabilities::ACKNOWLEDGED_SEND
        } else {
            AgentCapabilities(0)
        };
    let mut tail = RolloutTail {
        target: target(core, pane)?,
        reading: None,
        items: Vec::new(),
        cursor: TimelineCursor { epoch, sequence: 0 },
        session: session(None),
        wake,
        controls,
    };
    tail.start()?;
    Ok(Box::new(tail))
}

fn session(thread: Option<&str>) -> TimelineSession {
    TimelineSession {
        agent: AgentKind::Codex,
        native_session: thread.unwrap_or_default().to_owned(),
        title: None,
        model: None,
        permission_mode: None,
        commands: Vec::new(),
    }
}

fn target(core: &Core, pane: PaneId) -> Result<Target, WsError> {
    let entry = core
        .pane(pane)
        .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
    let recorded = lock(&entry.record)
        .agent
        .as_ref()
        .filter(|agent| agent.kind == AgentKind::Codex)
        .map(|agent| agent.session_id.clone())
        .ok_or_else(|| WsError::Unavailable("Chat is available for agent panes".into()))?;
    let codex_home = crate::core::agent_dir(core, &entry, AgentKind::Codex).ok_or_else(|| {
        WsError::Unavailable(
            "Chat can't find this Codex's home folder. Set CODEX_HOME for the helper, or use Terminal."
                .into(),
        )
    })?;
    let running = lock(&entry.agent).as_ref().and_then(|runtime| {
        runtime
            .session()
            .native_id
            .as_ref()
            .map(ToString::to_string)
    });
    let thread = running
        .or(recorded)
        .or_else(|| crate::codex_session::from_open_files(entry.pane.pty().pid()));
    Ok(Target { codex_home, thread })
}

impl RolloutTail {
    /// Opens the rollout once Codex wrote it: with the conversation's first turn.
    fn start(&mut self) -> Result<bool, WsError> {
        let Some(thread) = &self.target.thread else {
            return Ok(false);
        };
        let Some(path) = crate::codex_session::rollout_path(&self.target.codex_home, thread) else {
            return Ok(false);
        };
        let rollout = Rollout::open(&self.target.codex_home, &path, thread)?;
        let watcher = NativeWatch::new(parent(&path)?, self.wake.clone())?;
        let end = rollout.end()?;
        self.items = if end == 0 {
            Vec::new()
        } else {
            rollout.page(end, SNAPSHOT_ITEMS, self.cursor.epoch)?.items
        };
        self.session = session(Some(thread));
        self.reading = Some(Reading {
            rollout,
            stream: RecordStream::at_boundary(end),
            watcher,
        });
        Ok(true)
    }

    fn advance(&mut self) -> TimelineCursor {
        self.cursor.sequence = self.cursor.sequence.wrapping_add(1);
        self.cursor
    }

    fn restart(&mut self, target: Target) -> Result<Vec<TimelineOp>, WsError> {
        self.target = target;
        self.reading = None;
        self.items.clear();
        self.session = session(None);
        self.cursor.epoch = crate::timeline::next_epoch();
        self.start()?;
        self.advance();
        Ok(vec![TimelineOp::Snapshot(self.snapshot(None))])
    }

    fn upsert(&mut self, mut item: TimelineItem) -> TimelineOp {
        if let Some(index) = self.items.iter().position(|kept| kept.id == item.id) {
            item.revision = self.items[index].revision.saturating_add(1);
            self.items[index] = item.clone();
        } else {
            self.items.push(item.clone());
            let excess = self.items.len().saturating_sub(SNAPSHOT_ITEMS);
            self.items.drain(..excess);
        }
        TimelineOp::Upsert {
            cursor: self.advance(),
            item: Box::new(item),
        }
    }
}

fn parent(path: &Path) -> Result<&Path, WsError> {
    path.parent()
        .ok_or_else(|| WsError::Invalid("the rollout has no folder".into()))
}

impl AgentSession for RolloutTail {
    fn capabilities(&self) -> AgentCapabilities {
        AgentCapabilities::READ
            | AgentCapabilities::DIFFS
            | AgentCapabilities::THINKING
            | AgentCapabilities::PLANS
            | self.controls
    }

    fn cursor(&self) -> TimelineCursor {
        self.cursor
    }

    fn check_history_scope(&self, since: Option<UnixMillis>) -> Result<(), WsError> {
        // Turn notices carry no time, so a since-join guest could not be shown a safe subset.
        if since.is_some() {
            return Err(WsError::Unavailable(
                "This source does not support since-join Chat yet. Use Terminal.".into(),
            ));
        }
        Ok(())
    }

    fn snapshot(&self, since: Option<UnixMillis>) -> TimelineSnapshot {
        let mut snapshot = TimelineSnapshot {
            cursor: self.cursor,
            session: self.session.clone(),
            items: Vec::new(),
            before: None,
        };
        if since.is_some() {
            return snapshot;
        }
        snapshot.items = self.items.clone();
        if let Some(reading) = &self.reading {
            let ids: Vec<String> = self.items.iter().map(|item| item.id.clone()).collect();
            snapshot.before = reading
                .rollout
                .before_items(&ids, self.cursor.epoch)
                .ok()
                .flatten()
                .filter(|_| !ids.is_empty());
        }
        snapshot
    }

    fn refresh(&mut self, core: &Core, pane: PaneId) -> Result<Vec<TimelineOp>, WsError> {
        let current = target(core, pane)?;
        if current.codex_home != self.target.codex_home
            || (current.thread.is_some() && current.thread != self.target.thread)
        {
            return self.restart(current);
        }
        let Some(reading) = &mut self.reading else {
            if self.start()? {
                self.advance();
                return Ok(vec![TimelineOp::Snapshot(self.snapshot(None))]);
            }
            return Ok(Vec::new());
        };
        reading.watcher.check()?;
        let appended = reading
            .rollout
            .appended(&mut reading.stream, self.cursor.epoch)?;
        if appended.more {
            let _ = self.wake.try_send(());
        }
        if appended.rolled_back {
            let target = self.target.clone();
            return self.restart(target);
        }
        Ok(appended
            .items
            .into_iter()
            .map(|item| self.upsert(item))
            .collect())
    }

    fn check_current(&self, core: &Core, pane: PaneId) -> Result<(), WsError> {
        let current = target(core, pane)?;
        if current.codex_home != self.target.codex_home
            || (current.thread.is_some() && current.thread != self.target.thread)
        {
            return Err(WsError::Conflict(
                "the Codex session changed; reopen Chat".into(),
            ));
        }
        Ok(())
    }

    fn read(&mut self, request: TimelineRead, since: Option<UnixMillis>) -> ReadFuture {
        let response = self.check_history_scope(since).and_then(|()| {
            let reading = self.reading.as_ref().ok_or_else(|| {
                WsError::Unavailable("Codex has not saved this conversation yet.".into())
            })?;
            match request {
                TimelineRead::ItemsBefore { before, limit } => {
                    let page =
                        reading
                            .rollout
                            .page(before, usize::from(limit), self.cursor.epoch)?;
                    Ok(WorkspaceResponse::Timeline(TimelineSnapshot {
                        cursor: self.cursor,
                        session: self.session.clone(),
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
                    if handle.epoch() != self.cursor.epoch {
                        return Err(WsError::Conflict(
                            "the Codex session changed; reopen Chat".into(),
                        ));
                    }
                    reading
                        .rollout
                        .text(&handle, offset, length)
                        .map(WorkspaceResponse::TimelineOutput)
                }
                TimelineRead::ToolDiff { handle } => {
                    let handle = handle
                        .parse::<proto::OutputHandle>()
                        .map_err(|error| WsError::Invalid(error.to_string()))?;
                    if handle.epoch() != self.cursor.epoch {
                        return Err(WsError::Conflict(
                            "the Codex session changed; reopen Chat".into(),
                        ));
                    }
                    reading
                        .rollout
                        .diff(&handle)
                        .map(WorkspaceResponse::TimelineDiff)
                }
            }
        });
        Box::pin(std::future::ready(response))
    }

    fn wake(&self) -> mpsc::Sender<()> {
        self.wake.clone()
    }
}
