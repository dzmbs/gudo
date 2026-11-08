mod claude;
mod claude_diff;
mod claude_record;
pub(crate) mod claude_source;
mod commands;
mod complete_diff;
mod native_watch;
mod record_stream;
mod text;
mod transcript;
mod value_weight;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use proto::{
    Caps, PaneId, ServerCtl, TimelineOp, TimelineSnapshot, TimelineUpdate, UnixMillis,
    WorkspaceRequest, WorkspaceResponse, WsError,
};
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore, broadcast, mpsc};
use tokio::task::AbortHandle;

use crate::agent_driver::{AgentSession, TimelineRead};
use crate::core::{Core, Event, lock};
use crate::ws::ConnCtx;

#[cfg(test)]
use claude_source::{ClaudeSession as LiveState, Source};
#[cfg(test)]
use proto::{AgentKind, TimelineCursor, TimelineSession};

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
    state: Mutex<Box<dyn AgentSession>>,
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
            | WorkspaceRequest::TimelineWatchCapabilities { .. }
            | WorkspaceRequest::TimelineItemsBefore { .. }
            | WorkspaceRequest::TimelineToolOutput { .. }
            | WorkspaceRequest::TimelineToolDiff { .. }
    )
}

pub(crate) fn bulk_reply(result: &Result<WorkspaceResponse, WsError>) -> bool {
    matches!(
        result,
        Ok(WorkspaceResponse::AgentTimeline(_)
            | WorkspaceResponse::Timeline(_)
            | WorkspaceResponse::TimelineOutput(_)
            | WorkspaceResponse::TimelineDiff(_))
    )
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
        let state = blocking(move || {
            let entry = source_core
                .pane(pane)
                .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
            let kind = lock(&entry.record)
                .agent
                .as_ref()
                .map(|agent| agent.kind)
                .ok_or_else(|| WsError::Unavailable("Chat is available for agent panes".into()))?;
            crate::agent_driver::driver(kind).open(&source_core, pane, epoch, wake)
        })
        .await?;
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
        let operations = state.refresh(&core, pane);
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
    let wake = lock(&timeline.state).wake();
    // Do not keep an abandoned pane's worker alive while backing off.
    drop(timeline);
    tokio::time::sleep(IO_RETRY_DELAY).await;
    let _ = wake.try_send(());
}

fn negotiate_request(request: WorkspaceRequest) -> Result<WorkspaceRequest, WsError> {
    let (WorkspaceRequest::TimelineWatchVersioned { pane_id, version }
    | WorkspaceRequest::TimelineWatchCapabilities { pane_id, version }) = request
    else {
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
    let wants_capabilities = matches!(request, WorkspaceRequest::TimelineWatchCapabilities { .. });
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
            let (snapshot, capabilities) = {
                let state = lock(&timeline.state);
                (
                    proto::TimelineVersion::V1.snapshot(state.snapshot(connection.timeline_since)),
                    state.capabilities(),
                )
            };
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
            if wants_capabilities {
                Ok(WorkspaceResponse::AgentTimeline(
                    proto::AgentTimelineSnapshot {
                        snapshot,
                        capabilities,
                    },
                ))
            } else {
                Ok(WorkspaceResponse::Timeline(snapshot))
            }
        }
        WorkspaceRequest::TimelineItemsBefore {
            pane_id,
            before,
            limit,
        } => {
            read_timeline(
                core,
                connection,
                pane_id,
                TimelineRead::ItemsBefore { before, limit },
            )
            .await
        }
        WorkspaceRequest::TimelineToolOutput {
            pane_id,
            handle,
            offset,
            len,
        } => {
            read_timeline(
                core,
                connection,
                pane_id,
                TimelineRead::ToolOutput {
                    handle,
                    offset,
                    length: len,
                },
            )
            .await
        }
        WorkspaceRequest::TimelineToolDiff { pane_id, handle } => {
            read_timeline(core, connection, pane_id, TimelineRead::ToolDiff { handle }).await
        }
        _ => Err(WsError::Invalid("not a Chat request".into())),
    }
}

async fn read_timeline(
    core: &Arc<Core>,
    connection: &ConnCtx,
    pane: PaneId,
    request: TimelineRead,
) -> Result<WorkspaceResponse, WsError> {
    let timeline = watched(connection, pane)?;
    let core = Arc::clone(core);
    let since = connection.timeline_since;
    let reading = Arc::clone(&timeline);
    let read_core = Arc::clone(&core);
    let (epoch, pending) = blocking(move || {
        let mut state = lock(&reading.state);
        state.check_current(&read_core, pane)?;
        Ok((state.cursor().epoch, state.read(request, since)))
    })
    .await?;
    let response = pending.await?;
    blocking(move || {
        let state = lock(&timeline.state);
        validate_read(state.as_ref(), &core, pane, epoch)?;
        Ok(match response {
            WorkspaceResponse::Timeline(snapshot) => {
                WorkspaceResponse::Timeline(proto::TimelineVersion::V1.snapshot(snapshot))
            }
            response => response,
        })
    })
    .await
}

pub(crate) fn validate_read(
    session: &dyn AgentSession,
    core: &Core,
    pane: PaneId,
    epoch: u64,
) -> Result<(), WsError> {
    session.check_current(core, pane)?;
    if session.cursor().epoch != epoch {
        return Err(WsError::Conflict(
            "the agent session changed; reopen Chat".into(),
        ));
    }
    Ok(())
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
