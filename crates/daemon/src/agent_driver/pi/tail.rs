//! Chat for a pane's pi: its session file, read as pi writes it.

use std::path::PathBuf;

use proto::{
    AgentKind, PaneId, TimelineBody, TimelineCursor, TimelineItem, TimelineOp, TimelineSession,
    TimelineSnapshot, UnixMillis, WorkspaceResponse, WsError,
};
use tokio::sync::mpsc;

use super::session::{self, PiSession, Shaped};
use crate::agent_driver::{AgentCapabilities, AgentSession, ReadFuture, TimelineRead};
use crate::core::{Core, PaneEntry, lock};
use crate::resumable::{ResumableProgram, pi_session_dir, pi_session_file};
use crate::timeline::native_watch::NativeWatch;
use crate::timeline::record_stream::RecordStream;

#[cfg(test)]
mod tests;

const SNAPSHOT_ITEMS: usize = 60;

/// Which session the pane's pi writes, as far as is known yet.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Target {
    root: PathBuf,
    folder: PathBuf,
    session: Option<String>,
}

struct Reading {
    session: PiSession,
    stream: RecordStream,
    watcher: NativeWatch,
}

pub(super) struct SessionTail {
    target: Target,
    reading: Option<Reading>,
    /// Kept rows with the offset of the record each came from, oldest first.
    items: Vec<(u64, TimelineItem)>,
    cursor: TimelineCursor,
    session: TimelineSession,
    wake: mpsc::Sender<()>,
    controls: AgentCapabilities,
}

pub(super) fn open(
    core: &Core,
    pane: PaneId,
    epoch: u64,
    wake: mpsc::Sender<()>,
) -> Result<Box<dyn AgentSession>, WsError> {
    let entry = core
        .pane(pane)
        .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
    // Typing into a pi started by hand could reach its shell once it exits; one the daemon
    // launched has an exit fence.
    let controls = if lock(&entry.pane.agent_input_gate).has_launch() {
        AgentCapabilities::SEND | AgentCapabilities::ACKNOWLEDGED_SEND
    } else {
        AgentCapabilities(0)
    };
    let mut tail = SessionTail {
        target: target(core, &entry)?,
        reading: None,
        items: Vec::new(),
        cursor: TimelineCursor { epoch, sequence: 0 },
        session: session(None, &Shaped::default()),
        wake,
        controls,
    };
    if tail.start()? {
        tail.note_recorded(&entry, &tail.items);
    }
    Ok(Box::new(tail))
}

fn session(id: Option<&str>, shaped: &Shaped) -> TimelineSession {
    TimelineSession {
        agent: AgentKind::Pi,
        native_session: id.unwrap_or_default().to_owned(),
        title: shaped.title.clone(),
        model: shaped.model.clone(),
        permission_mode: None,
        commands: Vec::new(),
    }
}

fn target(core: &Core, entry: &PaneEntry) -> Result<Target, WsError> {
    let (session, cwd) = lock(&entry.record)
        .resumable
        .as_ref()
        .filter(|agent| agent.program == ResumableProgram::Pi)
        .map(|agent| (agent.session_id.clone(), agent.cwd.clone()))
        .ok_or_else(|| WsError::Unavailable("Chat is available for agent panes".into()))?;
    let cwd = cwd
        .or_else(|| lock(&entry.record).cwd.clone())
        .map(PathBuf::from)
        .unwrap_or_default();
    let pid = lock(&entry.resumable_process).map(|(pid, _)| pid);
    let env = |name: &str| {
        pid.and_then(|pid| crate::procinfo::process_env_var(pid, name))
            .or_else(|| {
                core.cfg
                    .pane_var(name)
                    .map(|value| value.to_string_lossy().into_owned())
            })
    };
    let home = env("HOME").map(PathBuf::from).ok_or_else(|| {
        WsError::Unavailable(
            "Chat can't find pi's sessions folder because the helper has no home folder. Use Terminal."
                .into(),
        )
    })?;
    let directory = pi_session_dir(&env, &home, &cwd);
    if !directory.root.is_dir() {
        return Err(WsError::Unavailable(
            "Chat can't find pi's sessions folder. If pi keeps sessions elsewhere, set PI_CODING_AGENT_DIR for the helper, or use Terminal."
                .into(),
        ));
    }
    Ok(Target {
        root: directory.root,
        folder: directory.folder,
        session,
    })
}

/// Keeps the newest rows, dropping whole records so a page below them starts at a record.
fn trim(items: &mut Vec<(u64, TimelineItem)>) {
    let mut excess = items.len().saturating_sub(SNAPSHOT_ITEMS);
    if excess == 0 {
        return;
    }
    let cut = items[excess - 1].0;
    while items.get(excess).is_some_and(|(offset, _)| *offset == cut) {
        excess += 1;
    }
    items.drain(..excess);
}

impl SessionTail {
    /// Opens the session file once pi wrote it: with the conversation's first message.
    fn start(&mut self) -> Result<bool, WsError> {
        let Some(id) = &self.target.session else {
            return Ok(false);
        };
        let Some(path) = pi_session_file(&self.target.folder, id) else {
            return Ok(false);
        };
        let file = PiSession::open(&self.target.root, &path, id)?;
        let watcher = NativeWatch::new(&self.target.folder, self.wake.clone())?;
        let end = file.end()?;
        let shaped = if end == 0 {
            Shaped::default()
        } else {
            file.newest(end, self.cursor.epoch)?
        };
        self.session = session::merge(session(Some(id), &shaped), &self.session);
        self.items = shaped.items;
        trim(&mut self.items);
        self.reading = Some(Reading {
            session: file,
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
        self.session = session(None, &Shaped::default());
        self.cursor.epoch = crate::timeline::next_epoch();
        self.start()?;
        self.advance();
        Ok(vec![TimelineOp::Snapshot(self.snapshot(None))])
    }

    fn upsert(&mut self, offset: u64, mut item: TimelineItem) -> TimelineOp {
        if let Some(index) = self.items.iter().position(|(_, kept)| kept.id == item.id) {
            item.revision = self.items[index].1.revision.saturating_add(1);
            self.items[index].1 = item.clone();
        } else {
            self.items.push((offset, item.clone()));
            trim(&mut self.items);
        }
        TimelineOp::Upsert {
            cursor: self.advance(),
            item: Box::new(item),
        }
    }

    /// What pi recorded in its session tells the pane's input fence its field was submitted.
    fn note_recorded(&self, entry: &PaneEntry, items: &[(u64, TimelineItem)]) {
        let Some(session) = self.target.session.as_deref() else {
            return;
        };
        let prompts = items.iter().filter_map(|(_, item)| match &item.body {
            TimelineBody::User { text, .. } => Some(text.as_str()),
            _ => None,
        });
        lock(&entry.pane.agent_input_gate).recorded_in_session(session, prompts);
    }

    fn changed(&self, current: &Target) -> bool {
        current.root != self.target.root
            || current.folder != self.target.folder
            || (current.session.is_some() && current.session != self.target.session)
    }
}

impl AgentSession for SessionTail {
    fn capabilities(&self) -> AgentCapabilities {
        AgentCapabilities::READ | self.controls
    }

    fn cursor(&self) -> TimelineCursor {
        self.cursor
    }

    fn check_history_scope(&self, since: Option<UnixMillis>) -> Result<(), WsError> {
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
        snapshot.items = self.items.iter().map(|(_, item)| item.clone()).collect();
        snapshot.before = self
            .items
            .first()
            .map(|(offset, _)| *offset)
            .filter(|offset| *offset > 0);
        snapshot
    }

    fn refresh(&mut self, core: &Core, pane: PaneId) -> Result<Vec<TimelineOp>, WsError> {
        let entry = core
            .pane(pane)
            .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
        let current = target(core, &entry)?;
        if self.changed(&current) {
            let operations = self.restart(current)?;
            self.note_recorded(&entry, &self.items);
            return Ok(operations);
        }
        let Some(reading) = &mut self.reading else {
            if self.start()? {
                self.note_recorded(&entry, &self.items);
                self.advance();
                return Ok(vec![TimelineOp::Snapshot(self.snapshot(None))]);
            }
            return Ok(Vec::new());
        };
        reading.watcher.check()?;
        let (shaped, more) = reading
            .session
            .appended(&mut reading.stream, self.cursor.epoch)?;
        if more {
            let _ = self.wake.try_send(());
        }
        if !shaped.items.is_empty() || !shaped.results.is_empty() {
            self.note_recorded(&entry, &shaped.items);
        }
        let mut operations = Vec::new();
        let renamed = session::merge(
            session(self.target.session.as_deref(), &shaped),
            &self.session,
        );
        if renamed != self.session {
            self.session = renamed;
            operations.push(TimelineOp::Session {
                cursor: self.advance(),
                session: self.session.clone(),
            });
        }
        for result in &shaped.results {
            let call = session::tool_id(result.call());
            if let Some((offset, item)) = self.items.iter().find(|(_, item)| item.id == call) {
                let (offset, mut item) = (*offset, item.clone());
                session::finish(&mut item, result, self.cursor.epoch);
                operations.push(self.upsert(offset, item));
            }
        }
        for (offset, item) in shaped.items {
            operations.push(self.upsert(offset, item));
        }
        Ok(operations)
    }

    fn check_current(&self, core: &Core, pane: PaneId) -> Result<(), WsError> {
        let entry = core
            .pane(pane)
            .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
        if self.changed(&target(core, &entry)?) {
            return Err(WsError::Conflict(
                "the pi session changed; reopen Chat".into(),
            ));
        }
        Ok(())
    }

    fn read(&mut self, request: TimelineRead, since: Option<UnixMillis>) -> ReadFuture {
        let response = self.check_history_scope(since).and_then(|()| {
            let reading = self.reading.as_ref().ok_or_else(|| {
                WsError::Unavailable("pi has not saved this conversation yet.".into())
            })?;
            match request {
                TimelineRead::ItemsBefore { before, limit } => {
                    let page =
                        reading
                            .session
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
                            "the pi session changed; reopen Chat".into(),
                        ));
                    }
                    reading
                        .session
                        .text(&handle, offset, length)
                        .map(WorkspaceResponse::TimelineOutput)
                }
                TimelineRead::ToolDiff { .. } => Err(WsError::Unavailable(
                    "Chat shows the start of pi's file changes. Open Terminal to see all of them."
                        .into(),
                )),
            }
        });
        Box::pin(std::future::ready(response))
    }

    fn wake(&self) -> mpsc::Sender<()> {
        self.wake.clone()
    }
}
