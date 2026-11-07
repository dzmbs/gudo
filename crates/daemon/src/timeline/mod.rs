mod claude;
mod claude_diff;
mod claude_record;
mod commands;
mod complete_diff;
mod native_watch;
mod record_stream;
mod text;
mod transcript;
mod value_weight;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use proto::{
    AgentKind, Caps, PaneId, ServerCtl, TimelineCursor, TimelineOp, TimelineSession,
    TimelineSnapshot, TimelineUpdate, UnixMillis, WorkspaceRequest, WorkspaceResponse, WsError,
};
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore, broadcast, mpsc};
use tokio::task::AbortHandle;

use crate::core::{Core, Event, lock};
use crate::ws::ConnCtx;
use native_watch::NativeWatch;
use transcript::Transcript;

static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);
static NEXT_WATCH: AtomicU64 = AtomicU64::new(1);
const MAX_WATCHES: usize = 4;
const MAX_PUSH_BYTES: usize = 1024 * 1024;
const MAX_BULK_REQUESTS: usize = 4;
const MAX_IO_RETRIES: usize = 3;
const IO_RETRY_DELAY: Duration = Duration::from_millis(250);
const MIN_REFRESH_INTERVAL: Duration = Duration::from_millis(35);
const MAX_COALESCED_EVENTS: usize = 64;

#[derive(Default)]
pub(crate) struct Timelines {
    entries: tokio::sync::Mutex<HashMap<PaneId, Weak<Timeline>>>,
}

struct Timeline {
    state: Mutex<LiveState>,
    updates: broadcast::Sender<Vec<TimelineOp>>,
    worker: Mutex<Option<AbortHandle>>,
}

impl Drop for Timeline {
    fn drop(&mut self) {
        if let Some(worker) = lock(&self.worker).take() {
            worker.abort();
        }
    }
}

impl Timeline {
    fn is_running(&self) -> bool {
        lock(&self.worker)
            .as_ref()
            .is_some_and(|worker| !worker.is_finished())
    }
}

struct WorkerLifetime(Weak<Timeline>);

impl Drop for WorkerLifetime {
    fn drop(&mut self) {
        if let Some(timeline) = self.0.upgrade() {
            // Publish death before the terminal event, including cancellation and unwinding.
            lock(&timeline.worker).take();
            let _ = timeline.updates.send(vec![TimelineOp::Unavailable {
                message: "Chat could not read this session. Open Terminal to continue.".into(),
            }]);
        }
    }
}

pub(crate) struct Watch {
    task: AbortHandle,
    timeline: Arc<Timeline>,
}

impl Drop for Watch {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub(crate) struct Mailbox {
    pub ready: Notify,
    slots: Mutex<HashMap<PaneId, MailboxSlot>>,
    bulk_requests: Arc<Semaphore>,
    bulk_replies: Mutex<HashMap<u64, VecDeque<OwnedSemaphorePermit>>>,
}

impl Default for Mailbox {
    fn default() -> Self {
        Self {
            ready: Notify::new(),
            slots: Mutex::default(),
            bulk_requests: Arc::new(Semaphore::new(MAX_BULK_REQUESTS)),
            bulk_replies: Mutex::default(),
        }
    }
}

struct MailboxSlot {
    watch: u64,
    pending: Option<CachedUpdate>,
}

struct CachedUpdate {
    value: TimelineUpdate,
    wire_bound: usize,
}

impl CachedUpdate {
    fn new(value: TimelineUpdate) -> Self {
        Self {
            wire_bound: value_weight::update(&value),
            value,
        }
    }

    fn bounded(self) -> Self {
        if self.wire_bound <= MAX_PUSH_BYTES {
            return self;
        }
        Self::new(TimelineUpdate {
            pane_id: self.value.pane_id,
            operations: vec![TimelineOp::Unavailable {
                message: "This Chat update is too large. Open Terminal to continue.".into(),
            }],
        })
    }
}

impl Mailbox {
    fn register(&self, pane: PaneId, watch: u64) {
        lock(&self.slots).insert(
            pane,
            MailboxSlot {
                watch,
                pending: None,
            },
        );
    }

    fn push(
        &self,
        watch: u64,
        update: TimelineUpdate,
        snapshot: impl FnOnce() -> TimelineSnapshot,
    ) {
        let mut slots = lock(&self.slots);
        let Some(slot) = slots
            .get_mut(&update.pane_id)
            .filter(|slot| slot.watch == watch)
        else {
            return;
        };
        // Cancellation can leave a forwarder finishing its batch after the watch was replaced.
        let mut update = CachedUpdate::new(update);
        if (slot.pending.is_some() || update.wire_bound > MAX_PUSH_BYTES)
            && !update
                .value
                .operations
                .iter()
                .any(|operation| matches!(operation, TimelineOp::Unavailable { .. }))
        {
            update = CachedUpdate::new(TimelineUpdate {
                pane_id: update.value.pane_id,
                operations: vec![TimelineOp::Snapshot(snapshot())],
            });
        }
        slot.pending = Some(update.bounded());
        self.ready.notify_one();
    }

    pub fn take(&self) -> Vec<ServerCtl> {
        lock(&self.slots)
            .values_mut()
            .filter_map(|slot| slot.pending.take())
            .map(|pending| ServerCtl::Timeline(pending.value))
            .collect()
    }

    pub fn remove(&self, pane: PaneId) {
        lock(&self.slots).remove(&pane);
    }

    pub fn clear(&self) {
        lock(&self.slots).clear();
        lock(&self.bulk_replies).clear();
    }

    pub fn reserve_reply(&self) -> Result<OwnedSemaphorePermit, WsError> {
        Arc::clone(&self.bulk_requests)
            .try_acquire_owned()
            .map_err(|_| WsError::Conflict("Chat is catching up. Try again.".into()))
    }

    pub fn hold_reply(&self, request: u64, permit: OwnedSemaphorePermit) {
        lock(&self.bulk_replies)
            .entry(request)
            .or_default()
            .push_back(permit);
    }

    pub fn reply_sent(&self, request: u64) {
        let mut replies = lock(&self.bulk_replies);
        if let Some(permits) = replies.get_mut(&request) {
            permits.pop_front();
            if permits.is_empty() {
                replies.remove(&request);
            }
        }
    }
}

pub(crate) fn bulk_request(request: &WorkspaceRequest) -> bool {
    matches!(
        request,
        WorkspaceRequest::TimelineWatch { .. }
            | WorkspaceRequest::TimelineWatchVersioned { .. }
            | WorkspaceRequest::TimelineItemsBefore { .. }
            | WorkspaceRequest::TimelineToolOutput { .. }
            | WorkspaceRequest::TimelineToolDiff { .. }
    )
}

pub(crate) fn bulk_reply(result: &Result<WorkspaceResponse, WsError>) -> bool {
    matches!(
        result,
        Ok(WorkspaceResponse::Timeline(_)
            | WorkspaceResponse::TimelineOutput(_)
            | WorkspaceResponse::TimelineDiff(_))
    )
}

#[derive(Clone, PartialEq, Eq)]
struct Source {
    native_session: String,
    path: Option<PathBuf>,
    config_directory: PathBuf,
    working_directory: PathBuf,
    watch_directory: PathBuf,
}

struct LiveState {
    source: Source,
    transcript: Option<Transcript>,
    cursor: TimelineCursor,
    waiting_session: TimelineSession,
    wake: mpsc::Sender<()>,
    watcher: NativeWatch,
}

impl LiveState {
    fn new(source: Source, epoch: u64, wake: mpsc::Sender<()>) -> Result<Self, WsError> {
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
        })
    }

    fn cursor(&self) -> TimelineCursor {
        self.transcript
            .as_ref()
            .map_or(self.cursor, Transcript::cursor)
    }

    fn snapshot(&self, since: Option<UnixMillis>) -> TimelineSnapshot {
        self.transcript.as_ref().map_or_else(
            || TimelineSnapshot {
                cursor: self.cursor,
                session: self.waiting_session.clone(),
                items: Vec::new(),
                before: None,
            },
            |transcript| transcript.snapshot(60, since),
        )
    }

    fn refresh(&mut self, source: Source) -> Result<Vec<TimelineOp>, WsError> {
        self.watcher.check()?;
        if source.native_session != self.source.native_session || source.path != self.source.path {
            let epoch = self.cursor().epoch.wrapping_add(1);
            *self = Self::new(source, epoch, self.wake.clone())?;
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
        self.source = source;
        Ok(operations)
    }
}

impl Timelines {
    async fn open(&self, core: &Arc<Core>, pane: PaneId) -> Result<Arc<Timeline>, WsError> {
        let mut entries = self.entries.lock().await;
        entries.retain(|_, timeline| timeline.strong_count() > 0);
        if let Some(timeline) = entries
            .get(&pane)
            .and_then(Weak::upgrade)
            .filter(|timeline| timeline.is_running())
        {
            return Ok(timeline);
        }
        let (wake, wakes) = mpsc::channel(1);
        NEXT_EPOCH.fetch_max(core.epoch.0, Ordering::Relaxed);
        let epoch = NEXT_EPOCH.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        let source_core = Arc::clone(core);
        let state =
            blocking(move || LiveState::new(source(&source_core, pane)?, epoch, wake)).await?;
        let (updates, _) = broadcast::channel(8);
        let timeline = Arc::new(Timeline {
            state: Mutex::new(state),
            updates,
            worker: Mutex::default(),
        });
        let worker_core = Arc::downgrade(core);
        let worker_timeline = Arc::downgrade(&timeline);
        let lifetime = WorkerLifetime(worker_timeline.clone());
        {
            // Register before an early exit can clear the handle and publish death.
            let mut worker = lock(&timeline.worker);
            let task = tokio::spawn(async move {
                let _lifetime = lifetime;
                run(worker_core, pane, worker_timeline, wakes).await;
            });
            *worker = Some(task.abort_handle());
        }
        entries.insert(pane, Arc::downgrade(&timeline));
        Ok(timeline)
    }
}

async fn run(
    core: Weak<Core>,
    pane: PaneId,
    timeline: Weak<Timeline>,
    mut wakes: mpsc::Receiver<()>,
) {
    let Some(initial_core) = core.upgrade() else {
        return;
    };
    let mut events = initial_core.events.subscribe();
    drop(initial_core);
    let mut next_refresh = tokio::time::Instant::now();
    let mut failures = 0;
    while wait_for_wake(pane, &mut wakes, &mut events).await {
        // Throttle only already-pending work; idle timelines have no active timer or strong lease.
        tokio::time::sleep_until(next_refresh).await;
        drain_pending(&mut wakes, &mut events);
        let (Some(core), Some(timeline)) = (core.upgrade(), timeline.upgrade()) else {
            return;
        };
        match refresh_live(core, pane, Arc::clone(&timeline)).await {
            Ok(operations) => {
                failures = 0;
                if !operations.is_empty() {
                    let _ = timeline.updates.send(operations);
                }
            }
            Err(error) if retry_io(&mut failures, &error) => {
                retry_after(timeline).await;
                continue;
            }
            Err(_) => return,
        }
        drop(timeline);
        next_refresh = tokio::time::Instant::now() + MIN_REFRESH_INTERVAL;
    }
}

async fn wait_for_wake(
    pane: PaneId,
    wakes: &mut mpsc::Receiver<()>,
    events: &mut broadcast::Receiver<Event>,
) -> bool {
    loop {
        tokio::select! {
            wake = wakes.recv() => return wake.is_some(),
            event = events.recv() => match event {
                Ok(Event::PaneMeta(changed)
                    | Event::PaneClosed(changed)
                    | Event::Agent { pane_id: changed, .. }) if changed == pane => return true,
                Err(broadcast::error::RecvError::Lagged(_)) => return true,
                Err(broadcast::error::RecvError::Closed) => return false,
                _ => {},
            },
        }
    }
}

fn drain_pending(wakes: &mut mpsc::Receiver<()>, events: &mut broadcast::Receiver<Event>) {
    // Drain before reading current state, never after it: a concurrent append must stay queued.
    let _ = wakes.try_recv();
    for _ in 0..MAX_COALESCED_EVENTS {
        match events.try_recv() {
            Ok(_) | Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            Err(_) => break,
        }
    }
}

async fn refresh_live(
    core: Arc<Core>,
    pane: PaneId,
    timeline: Arc<Timeline>,
) -> Result<Vec<TimelineOp>, WsError> {
    blocking(move || {
        let mut state = lock(&timeline.state);
        let operations = state.refresh(source(&core, pane)?);
        // Reopens must not reuse an epoch consumed by a local transcript rewrite.
        NEXT_EPOCH.fetch_max(state.cursor().epoch, Ordering::Relaxed);
        let operations = operations?;
        if value_weight::operations(&operations) > MAX_PUSH_BYTES {
            Ok(vec![TimelineOp::Snapshot(state.snapshot(None))])
        } else {
            Ok(operations)
        }
    })
    .await
}

fn retry_io(failures: &mut usize, error: &WsError) -> bool {
    if !matches!(error, WsError::Failed(_)) || *failures >= MAX_IO_RETRIES {
        return false;
    }
    *failures += 1;
    true
}

async fn retry_after(timeline: Arc<Timeline>) {
    let wake = lock(&timeline.state).wake.clone();
    // Do not keep an abandoned pane's worker alive while backing off.
    drop(timeline);
    tokio::time::sleep(IO_RETRY_DELAY).await;
    let _ = wake.try_send(());
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
        Some(transcript::validate_path(
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

fn negotiate_request(request: WorkspaceRequest) -> Result<WorkspaceRequest, WsError> {
    let WorkspaceRequest::TimelineWatchVersioned { pane_id, version } = request else {
        return Ok(request);
    };
    let version = proto::TimelineVersion::negotiate(version)
        .map_err(|error| WsError::Invalid(error.to_string()))?;
    match version {
        proto::TimelineVersion::V1 => Ok(WorkspaceRequest::TimelineWatch { pane_id }),
    }
}

pub(crate) async fn handle(
    core: &Arc<Core>,
    connection: &ConnCtx,
    request: WorkspaceRequest,
) -> Result<WorkspaceResponse, WsError> {
    if !connection.caps.contains(Caps::AGENT_TIMELINE) {
        return Err(WsError::Unavailable("update the app to use Chat".into()));
    }
    match negotiate_request(request)? {
        WorkspaceRequest::TimelineUnwatch { pane_id } => {
            lock(&connection.timeline_watches).remove(&pane_id);
            connection.timeline_mailbox.remove(pane_id);
            Ok(WorkspaceResponse::Done)
        }
        WorkspaceRequest::TimelineWatch { pane_id } => {
            {
                let watches = lock(&connection.timeline_watches);
                if watches.len() >= MAX_WATCHES && !watches.contains_key(&pane_id) {
                    return Err(WsError::Invalid("too many Chat panes are open".into()));
                }
            }
            let timeline = core.ws.timelines.open(core, pane_id).await?;
            let mut updates = timeline.updates.subscribe();
            // Subscribe before checking liveness so a concurrent exit cannot be missed.
            if !timeline.is_running() {
                return Err(WsError::Unavailable(
                    "Chat stopped; reopen it to retry".into(),
                ));
            }
            let snapshot = proto::TimelineVersion::V1
                .snapshot(lock(&timeline.state).snapshot(connection.timeline_since));
            let mut watches = lock(&connection.timeline_watches);
            if watches.len() >= MAX_WATCHES && !watches.contains_key(&pane_id) {
                return Err(WsError::Invalid("too many Chat panes are open".into()));
            }
            let watch_token = NEXT_WATCH.fetch_add(1, Ordering::Relaxed);
            connection.timeline_mailbox.register(pane_id, watch_token);
            let mut visible: HashSet<String> =
                snapshot.items.iter().map(|item| item.id.clone()).collect();
            let mailbox = Arc::clone(&connection.timeline_mailbox);
            let since = connection.timeline_since;
            let watched = Arc::clone(&timeline);
            let task = tokio::spawn(async move {
                loop {
                    let operations = match updates.recv().await {
                        Ok(operations) => proto::TimelineVersion::V1.operations(filter(
                            operations,
                            since,
                            &mut visible,
                        )),
                        Err(broadcast::error::RecvError::Lagged(_)) => {
                            let snapshot = proto::TimelineVersion::V1
                                .snapshot(lock(&watched.state).snapshot(since));
                            visible = snapshot.items.iter().map(|item| item.id.clone()).collect();
                            vec![TimelineOp::Snapshot(snapshot)]
                        }
                        Err(broadcast::error::RecvError::Closed) => return,
                    };
                    if visible.len() > 3000 {
                        visible.clear();
                    }
                    let unavailable = operations
                        .iter()
                        .any(|operation| matches!(operation, TimelineOp::Unavailable { .. }));
                    mailbox.push(
                        watch_token,
                        TimelineUpdate {
                            pane_id,
                            operations,
                        },
                        || {
                            proto::TimelineVersion::V1
                                .snapshot(lock(&watched.state).snapshot(since))
                        },
                    );
                    if unavailable {
                        return;
                    }
                }
            });
            let watch = Watch {
                task: task.abort_handle(),
                timeline,
            };
            watches.insert(pane_id, watch);
            Ok(WorkspaceResponse::Timeline(snapshot))
        }
        WorkspaceRequest::TimelineItemsBefore {
            pane_id,
            before,
            limit,
        } => {
            read_timeline(core, connection, pane_id, move |transcript, since| {
                transcript
                    .page(before, limit as usize, since)
                    .map(WorkspaceResponse::Timeline)
            })
            .await
        }
        WorkspaceRequest::TimelineToolOutput {
            pane_id,
            handle,
            offset,
            len,
        } => {
            read_timeline(core, connection, pane_id, move |transcript, since| {
                transcript
                    .output(&handle, offset, len, since)
                    .map(WorkspaceResponse::TimelineOutput)
            })
            .await
        }
        WorkspaceRequest::TimelineToolDiff { pane_id, handle } => {
            read_timeline(core, connection, pane_id, move |transcript, since| {
                transcript
                    .tool_diff(&handle, since)
                    .map(WorkspaceResponse::TimelineDiff)
            })
            .await
        }
        _ => Err(WsError::Invalid("not a Chat request".into())),
    }
}

async fn read_timeline(
    core: &Arc<Core>,
    connection: &ConnCtx,
    pane: PaneId,
    work: impl FnOnce(&mut Transcript, Option<UnixMillis>) -> Result<WorkspaceResponse, WsError>
    + Send
    + 'static,
) -> Result<WorkspaceResponse, WsError> {
    let timeline = watched(connection, pane)?;
    let core = Arc::clone(core);
    let since = connection.timeline_since;
    blocking(move || {
        let current = source(&core, pane)?;
        let mut state = lock(&timeline.state);
        if current.native_session != state.source.native_session
            || current.path != state.source.path
        {
            return Err(WsError::Conflict(
                "the agent session changed; reopen Chat".into(),
            ));
        }
        let transcript = state
            .transcript
            .as_mut()
            .ok_or_else(|| WsError::Unavailable("the conversation has not started yet".into()))?;
        work(transcript, since).map(|response| match response {
            WorkspaceResponse::Timeline(snapshot) => {
                WorkspaceResponse::Timeline(proto::TimelineVersion::V1.snapshot(snapshot))
            }
            response => response,
        })
    })
    .await
}

fn watched(connection: &ConnCtx, pane: PaneId) -> Result<Arc<Timeline>, WsError> {
    lock(&connection.timeline_watches)
        .get(&pane)
        .filter(|watch| watch.timeline.is_running())
        .map(|watch| Arc::clone(&watch.timeline))
        .ok_or_else(|| WsError::Unavailable("open Chat before reading its history".into()))
}

fn filter(
    operations: Vec<TimelineOp>,
    since: Option<UnixMillis>,
    visible: &mut HashSet<String>,
) -> Vec<TimelineOp> {
    let Some(since) = since else {
        return operations;
    };
    operations
        .into_iter()
        .map(|operation| match operation {
            TimelineOp::Upsert { cursor, item } if item.at < since => {
                TimelineOp::Checkpoint { cursor }
            }
            TimelineOp::Upsert { cursor, item } => {
                visible.insert(item.id.clone());
                TimelineOp::Upsert { cursor, item }
            }
            TimelineOp::Append {
                cursor,
                id,
                field,
                text,
            } => {
                if visible.contains(&id) {
                    TimelineOp::Append {
                        cursor,
                        id,
                        field,
                        text,
                    }
                } else {
                    TimelineOp::Checkpoint { cursor }
                }
            }
            TimelineOp::Remove { cursor, id } => {
                if visible.remove(&id) {
                    TimelineOp::Remove { cursor, id }
                } else {
                    TimelineOp::Checkpoint { cursor }
                }
            }
            TimelineOp::Snapshot(mut snapshot) => {
                snapshot.items.retain(|item| item.at >= since);
                if snapshot.items.is_empty() {
                    snapshot.before = None;
                }
                *visible = snapshot.items.iter().map(|item| item.id.clone()).collect();
                TimelineOp::Snapshot(snapshot)
            }
            operation => operation,
        })
        .collect()
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, WsError> + Send + 'static,
) -> Result<T, WsError> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|error| WsError::Failed(error.to_string()))?
}

#[cfg(test)]
#[path = "service_tests.rs"]
mod tests;
