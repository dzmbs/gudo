use std::path::PathBuf;
use std::sync::Arc;

use proto::{
    AgentKind, PaneId, TimelineCursor, TimelineOp, TimelineSession, TimelineSnapshot, UnixMillis,
    WorkspaceResponse, WsError,
};
use tokio::sync::mpsc;

use super::{commands, native_watch::NativeWatch, transcript::Transcript};
use crate::agent_driver::{AgentSession, ReadFuture, TimelineRead};
use crate::core::{Core, lock};

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Source {
    pub native_session: String,
    pub path: Option<PathBuf>,
    pub config_directory: PathBuf,
    pub working_directory: PathBuf,
    pub watch_directory: PathBuf,
}

pub(crate) struct ClaudeSession {
    source: Source,
    pub(super) transcript: Option<Transcript>,
    cursor: TimelineCursor,
    waiting_session: TimelineSession,
    wake: mpsc::Sender<()>,
    pub(super) watcher: NativeWatch,
    display: Option<super::display_overlay::DisplayOverlay>,
}

impl ClaudeSession {
    pub(crate) fn open(
        core: &Core,
        pane: PaneId,
        epoch: u64,
        wake: mpsc::Sender<()>,
    ) -> Result<Self, WsError> {
        let mut session = Self::new(source(core, pane)?, epoch, wake.clone())?;
        if core.cfg.claude_chat_streaming
            && let Some(entry) = core.pane(pane)
        {
            core.hooks.display.subscribe(pane, &entry, &wake);
            session.display = Some(super::display_overlay::DisplayOverlay::new(
                Arc::clone(&core.hooks.display),
                pane,
                &entry,
            ));
            if let (Some(display), Some(transcript)) =
                (&mut session.display, &mut session.transcript)
            {
                display.refresh(&session.source, transcript);
            }
        }
        Ok(session)
    }

    pub(super) fn new(source: Source, epoch: u64, wake: mpsc::Sender<()>) -> Result<Self, WsError> {
        let watcher = NativeWatch::new(&source.watch_directory, wake.clone())?;
        let cursor = TimelineCursor { epoch, sequence: 0 };
        let commands = commands::discover(&source.config_directory, &source.working_directory);
        let mut transcript = source
            .path
            .as_ref()
            .map(|path| Transcript::open(path.clone(), source.native_session.clone(), epoch))
            .transpose()?;
        if let Some(transcript) = &mut transcript {
            transcript.set_commands(commands.clone());
        }
        let waiting_session = TimelineSession {
            agent: AgentKind::Claude,
            native_session: source.native_session.clone(),
            title: None,
            model: None,
            permission_mode: None,
            commands,
        };
        Ok(Self {
            source,
            transcript,
            cursor,
            waiting_session,
            wake,
            watcher,
            display: None,
        })
    }

    pub(super) fn refresh(&mut self, source: Source) -> Result<Vec<TimelineOp>, WsError> {
        self.watcher.check()?;
        if source.native_session != self.source.native_session || source.path != self.source.path {
            let epoch = self.cursor().epoch.wrapping_add(1);
            let mut display = self.display.take();
            if let Some(display) = &mut display {
                display.reset();
            }
            *self = Self::new(source, epoch, self.wake.clone())?;
            self.display = display;
            if let (Some(display), Some(transcript)) = (&mut self.display, &mut self.transcript) {
                display.refresh(&self.source, transcript);
            }
            return Ok(vec![TimelineOp::Snapshot(self.snapshot(None))]);
        }
        let mut operations = self
            .transcript
            .as_mut()
            .map_or(Ok(Vec::new()), Transcript::refresh)?;
        if self
            .transcript
            .as_ref()
            .is_some_and(Transcript::has_backlog)
        {
            let _ = self.wake.try_send(());
        }
        if source.config_directory != self.source.config_directory
            || source.working_directory != self.source.working_directory
        {
            let commands = commands::discover(&source.config_directory, &source.working_directory);
            if let Some(transcript) = &mut self.transcript {
                if let Some(operation) = transcript.set_commands(commands) {
                    operations.push(operation);
                }
            } else if self.waiting_session.commands != commands {
                self.waiting_session.commands = commands;
                self.cursor.sequence = self.cursor.sequence.wrapping_add(1);
                operations.push(TimelineOp::Session {
                    cursor: self.cursor,
                    session: self.waiting_session.clone(),
                });
            }
        }
        if source.watch_directory != self.source.watch_directory {
            self.watcher = NativeWatch::new(&source.watch_directory, self.wake.clone())?;
        }
        if let (Some(display), Some(transcript)) = (&mut self.display, &mut self.transcript) {
            if operations
                .iter()
                .any(|operation| matches!(operation, TimelineOp::Snapshot(_)))
            {
                display.reset();
            }
            operations.extend(display.refresh(&source, transcript));
            display.filter_operations(transcript, &mut operations);
        }
        self.source = source;
        Ok(operations)
    }
}

impl AgentSession for ClaudeSession {
    fn capabilities(&self) -> crate::agent_driver::AgentCapabilities {
        let mut capabilities = crate::agent_driver::driver(AgentKind::Claude).capabilities();
        if self
            .display
            .as_ref()
            .is_some_and(|display| display.is_streaming)
        {
            capabilities |= crate::agent_driver::AgentCapabilities::STREAMING_DELTAS;
        }
        capabilities
    }

    fn cursor(&self) -> TimelineCursor {
        self.transcript
            .as_ref()
            .map_or(self.cursor, Transcript::cursor)
    }

    fn check_history_scope(&self, _since: Option<UnixMillis>) -> Result<(), WsError> {
        // Every transcript read filters by record time, so the whole session is never refused.
        Ok(())
    }

    fn snapshot(&self, since: Option<UnixMillis>) -> TimelineSnapshot {
        self.transcript.as_ref().map_or_else(
            || TimelineSnapshot {
                cursor: self.cursor,
                session: self.waiting_session.clone(),
                items: Vec::new(),
                before: None,
            },
            |transcript| {
                self.display.as_ref().map_or_else(
                    || transcript.snapshot(60, since),
                    |display| display.snapshot(transcript, since),
                )
            },
        )
    }

    fn refresh(&mut self, core: &Core, pane: PaneId) -> Result<Vec<TimelineOp>, WsError> {
        self.refresh(source(core, pane)?)
    }

    fn check_current(&self, core: &Core, pane: PaneId) -> Result<(), WsError> {
        let current = source(core, pane)?;
        if current.native_session != self.source.native_session || current.path != self.source.path
        {
            return Err(WsError::Conflict(
                "the agent session changed; reopen Chat".into(),
            ));
        }
        Ok(())
    }

    fn read(&mut self, request: TimelineRead, since: Option<UnixMillis>) -> ReadFuture {
        let mut response = self
            .transcript
            .as_mut()
            .ok_or_else(|| WsError::Unavailable("the conversation has not started yet".into()))
            .and_then(|transcript| match request {
                TimelineRead::ItemsBefore { before, limit } => transcript
                    .page(before, limit as usize, since)
                    .map(WorkspaceResponse::Timeline),
                TimelineRead::ToolOutput {
                    handle,
                    offset,
                    length,
                } => transcript
                    .output(&handle, offset, length, since)
                    .map(WorkspaceResponse::TimelineOutput),
                TimelineRead::ToolDiff { handle } => transcript
                    .tool_diff(&handle, since)
                    .map(WorkspaceResponse::TimelineDiff),
            });
        if let (Some(display), Ok(WorkspaceResponse::Timeline(snapshot))) =
            (&self.display, &mut response)
        {
            display.filter_snapshot(snapshot);
        }
        Box::pin(std::future::ready(response))
    }

    fn wake(&self) -> mpsc::Sender<()> {
        self.wake.clone()
    }
}

fn source(core: &Core, pane: PaneId) -> Result<Source, WsError> {
    let entry = core
        .pane(pane)
        .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
    let record = lock(&entry.record).clone();
    let agent = record
        .agent
        .ok_or_else(|| WsError::Unavailable("Chat is available for agent panes".into()))?;
    if agent.kind != AgentKind::Claude {
        return Err(WsError::Unavailable(
            "Chat is not available for this agent".into(),
        ));
    }
    let (native_session, hook_path) = {
        let runtime = lock(&entry.agent);
        let session = runtime.as_ref().map(|runtime| runtime.session());
        (
            session
                .and_then(|session| session.native_id.as_ref())
                .map(ToString::to_string)
                .or(agent.session_id),
            session.and_then(|session| session.transcript.clone()),
        )
    };
    let account = agent.account.as_deref().unwrap_or(proto::SYSTEM_ACCOUNT);
    let context = core.ws.accounts.context(agent.kind, account);
    if context.is_none() && account != proto::SYSTEM_ACCOUNT {
        return Err(WsError::Unavailable(
            "the agent account is no longer available".into(),
        ));
    }
    let config_directory = context
        .and_then(|context| context.dir)
        .or_else(|| core.cfg.pane_var(agents::CLAUDE_DIR_VAR).map(PathBuf::from))
        .unwrap_or_else(|| core.cfg.home().join(".claude"));
    let working_directory = record
        .cwd
        .map(PathBuf::from)
        .unwrap_or_else(|| core.cfg.home());
    let native_session = native_session.unwrap_or_default();
    if !native_session.is_empty() && !crate::claude_session::is_session_id(&native_session) {
        return Err(WsError::Invalid("the agent session id is invalid".into()));
    }
    let expected = hook_path.unwrap_or_else(|| {
        crate::claude_session::project_dir(&config_directory, &working_directory)
            .join(format!("{native_session}.jsonl"))
    });
    let path = if !native_session.is_empty() && expected.exists() {
        Some(super::transcript::validate_path(
            &config_directory.join("projects"),
            &expected,
            &native_session,
        )?)
    } else {
        None
    };
    let watch_directory = expected
        .parent()
        .into_iter()
        .flat_map(|parent| parent.ancestors())
        .find(|path| path.is_dir())
        .unwrap_or(&config_directory)
        .to_owned();
    Ok(Source {
        native_session,
        path,
        config_directory,
        working_directory,
        watch_directory,
    })
}
