//! Agents reaching other hosts through the owner's device (`proto::cross_host`).
//!
//! On the agent's host: a terminal tool called with `host` becomes a [`CrossHostRequest`]
//! pushed to the owner's connected devices that announced `Caps::CROSS_HOST`. Nothing here
//! knows the other host: a device claims the request with the owner's signed answer, runs it
//! there over its own connection and sends the reply back. Unclaimed after `drive_ask_wait`,
//! the call fails; while no device is connected, the owner gets a notification.
//!
//! On the target host: a device's [`RemoteCall`] runs as a terminal-tool call of a stand-in
//! caller for the remote agent, so the panes it opens are its own and nobody else's; the
//! owner's yes it carries lets it act in the session the device shows, never at a password
//! prompt.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::sync::Mutex;

use proto::{
    Actor, AuditKind, Consent, CrossHostPush, CrossHostRefusal, CrossHostRequest, CrossHostVerb,
    DaemonId, Decide, HostEntry, OptionId, PairState, PaneId, RemoteAgent, RemoteCall, RequestId,
    ServerCtl, SessionId,
};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::time::{Duration, Instant};

use super::{CallContext, ErrorCode, Result, TermReply, ToolError};
use crate::core::{ConnId, Core, lock};
use crate::mp::{AuditEntry, Authz};

/// Requests one agent here may send to other hosts per minute.
pub(crate) const CROSS_HOST_REQUESTS_PER_MINUTE: u32 = 60;
/// All agents here together may send this many times what one may.
const ALL_AGENTS_SHARE: u32 = 4;
/// The longest host name or id an agent may give, in bytes: far above any name the app shows
/// or a daemon id in hex.
const MAX_HOST_LEN: usize = 255;
/// How long a claimed request may take on the other host: the longest wait a tool allows
/// (240 s), and some room to reach it.
const RESULT_WAIT: Duration = Duration::from_secs(300);
/// How long a request waits for a connected device before the owner is notified as well.
const NOTICE_DELAY: Duration = Duration::from_secs(3);
/// Remote agents with calls relayed to this host at once.
const MAX_REMOTE_AGENTS: usize = 64;
/// Asking panes kept in the rate windows; past it the one quiet longest goes.
const MAX_RATE_WINDOWS: usize = 256;
/// Updates one waiting call can have queued.
const PROGRESS_QUEUE: usize = 8;
/// Entries one device's host list may hold.
const MAX_DIRECTORY: usize = 256;

#[derive(Debug)]
enum Progress {
    /// A device refused, or one left: see whether every device has now said no.
    Changed,
    Claimed(OptionId),
    Result(std::result::Result<String, String>),
    /// The device performing it went away.
    DeviceLeft,
}

struct Open {
    request: CrossHostRequest,
    /// `Claude asked to run $ npm test on ops`.
    summary: String,
    sent_to: HashSet<ConnId>,
    ever_sent: bool,
    refused: Vec<(ConnId, CrossHostRefusal)>,
    claimed_by: Option<ConnId>,
    progress: mpsc::Sender<Progress>,
}

/// The stand-in caller of one remote agent on this host.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RemoteKey {
    host: DaemonId,
    pane_id: PaneId,
    agent_key: u64,
}

/// Requests in the last minute: each asking pane's, and all of them.
#[derive(Default)]
struct Rates {
    by_pane: HashMap<PaneId, VecDeque<Instant>>,
    all: VecDeque<Instant>,
}

/// Where the host an agent named stands with the connected devices.
enum Lookup {
    /// A device lists it.
    Listed,
    /// No device lists it, but one has not sent its list yet.
    Unsure,
    /// Every device sent its list, and none has it.
    Unknown,
}

/// Relaying devices, open requests, agents' keys, rate windows, and remote agents' stand-ins.
#[derive(Default)]
pub(crate) struct CrossHost {
    /// Owner connections that announced `Caps::CROSS_HOST`, with the host list each sent.
    devices: Mutex<HashMap<ConnId, Option<Vec<HostEntry>>>>,
    open: Mutex<HashMap<RequestId, Open>>,
    /// Each asking pane's key, for as long as it is open.
    agents: Mutex<HashMap<PaneId, u64>>,
    rates: Mutex<Rates>,
    remote: Mutex<HashMap<RemoteKey, PaneId>>,
    stand_ins: Mutex<HashMap<PaneId, RemoteAgent>>,
    next_stand_in: std::sync::atomic::AtomicU64,
}

/// What the device must be told to relay `request`.
fn push(request: &CrossHostRequest) -> ServerCtl {
    ServerCtl::CrossHost(CrossHostPush::Request(request.clone()))
}

impl CrossHost {
    /// A device connected: owner devices that relay get every open request.
    pub fn register(&self, core: &Core, conn: ConnId, authz: &Authz, caps: proto::Caps) {
        if !caps.contains(proto::Caps::CROSS_HOST) || !authz.is_owner_device(core) {
            return;
        }
        lock(&self.devices).insert(conn, None);
        let mut open = lock(&self.open);
        for request in open.values_mut().filter(|open| open.claimed_by.is_none()) {
            request.sent_to.insert(conn);
            request.ever_sent = true;
            core.mp.send_to_conn(conn, push(&request.request));
        }
    }

    /// A connection left: requests it was performing fail now, not at the timeout.
    pub fn forget_conn(&self, conn: ConnId) {
        if lock(&self.devices).remove(&conn).is_none() {
            return;
        }
        for open in lock(&self.open).values_mut() {
            open.sent_to.remove(&conn);
            let update = if open.claimed_by == Some(conn) {
                Progress::DeviceLeft
            } else {
                Progress::Changed
            };
            let _ = open.progress.try_send(update);
        }
    }

    fn is_device(&self, conn: ConnId) -> bool {
        lock(&self.devices).contains_key(&conn)
    }

    /// A device's list of its other hosts.
    pub fn directory(&self, conn: ConnId, mut entries: Vec<HostEntry>) {
        entries.truncate(MAX_DIRECTORY);
        if let Some(directory) = lock(&self.devices).get_mut(&conn) {
            *directory = Some(entries);
        }
    }

    /// The asking pane closed: its key goes, and the devices end every yes they hold for it.
    pub fn agent_closed(&self, core: &Core, pane: PaneId) {
        let Some(agent_key) = lock(&self.agents).remove(&pane) else {
            return;
        };
        let gone = ServerCtl::CrossHost(CrossHostPush::AgentGone {
            pane_id: pane,
            agent_key,
        });
        for &conn in lock(&self.devices).keys() {
            core.mp.send_to_conn(conn, gone.clone());
        }
    }

    fn agent_key(&self, pane: PaneId) -> u64 {
        *lock(&self.agents).entry(pane).or_insert_with(|| {
            let mut bytes = [0; 8];
            getrandom::fill(&mut bytes).expect("the OS random source is available");
            u64::from_le_bytes(bytes)
        })
    }

    /// Whether a connected device lists `host` (trimmed) by name or id, as a device matches it.
    fn look_up(&self, host: &str) -> Lookup {
        let devices = lock(&self.devices);
        let mut unsure = false;
        for directory in devices.values() {
            let Some(entries) = directory else {
                unsure = true;
                continue;
            };
            if entries.iter().any(|entry| {
                entry.name.eq_ignore_ascii_case(host) || entry.id.eq_ignore_ascii_case(host)
            }) {
                return Lookup::Listed;
            }
        }
        if unsure || devices.is_empty() {
            Lookup::Unsure
        } else {
            Lookup::Unknown
        }
    }

    /// Counts a request from `pane`; refused past `per_minute` for it in the last minute, or
    /// past `ALL_AGENTS_SHARE` times that for every agent here.
    fn admit(&self, pane: PaneId, per_minute: u32) -> Result<()> {
        let now = Instant::now();
        let expired = |at: &Instant| now.duration_since(*at) >= Duration::from_secs(60);
        let too_many = || ToolError {
            retryable: true,
            ..ToolError::new(
                ErrorCode::Failed,
                "too many requests for other hosts this minute",
            )
            .hint("wait a moment, then try again")
        };
        let mut rates = lock(&self.rates);
        let Rates { by_pane, all } = &mut *rates;
        while all.front().is_some_and(expired) {
            all.pop_front();
        }
        if all.len() >= (per_minute * ALL_AGENTS_SHARE) as usize {
            return Err(too_many());
        }
        if by_pane.len() >= MAX_RATE_WINDOWS && !by_pane.contains_key(&pane) {
            by_pane.retain(|_, window| window.back().is_some_and(|last| !expired(last)));
            if by_pane.len() >= MAX_RATE_WINDOWS {
                let quietest = by_pane
                    .iter()
                    .min_by_key(|(_, window)| window.back().copied())
                    .map(|(pane, _)| *pane);
                if let Some(quietest) = quietest {
                    by_pane.remove(&quietest);
                }
            }
        }
        let window = by_pane.entry(pane).or_default();
        while window.front().is_some_and(expired) {
            window.pop_front();
        }
        if window.len() >= per_minute as usize {
            return Err(too_many());
        }
        window.push_back(now);
        all.push_back(now);
        debug_assert!(by_pane.len() <= MAX_RATE_WINDOWS);
        Ok(())
    }

    /// Opens a request and sends it to every relaying device; how many got it. `None` while the
    /// same pane already waits on one.
    fn open(
        &self,
        core: &Core,
        request: CrossHostRequest,
        summary: String,
        progress: mpsc::Sender<Progress>,
    ) -> Option<usize> {
        let devices: Vec<ConnId> = lock(&self.devices).keys().copied().collect();
        let mut open = lock(&self.open);
        if open
            .values()
            .any(|open| open.request.pane_id == request.pane_id)
        {
            return None;
        }
        for &conn in &devices {
            core.mp.send_to_conn(conn, push(&request));
        }
        open.insert(
            request.id,
            Open {
                request,
                summary,
                sent_to: devices.iter().copied().collect(),
                ever_sent: !devices.is_empty(),
                refused: Vec::new(),
                claimed_by: None,
                progress,
            },
        );
        Some(devices.len())
    }

    /// Closes a request and tells the devices that still had it.
    fn close(&self, core: &Core, id: RequestId) {
        let Some(open) = lock(&self.open).remove(&id) else {
            return;
        };
        let closed = ServerCtl::CrossHost(CrossHostPush::Closed { id });
        for conn in open.sent_to {
            core.mp.send_to_conn(conn, closed.clone());
        }
        crate::ws::agent_unblocked(core, open.request.pane_id);
    }

    /// Every device it went to said no: the first one's reason.
    fn refusal(&self, id: RequestId) -> Option<CrossHostRefusal> {
        let open = lock(&self.open);
        let open = open.get(&id)?;
        let all_refused = !open.sent_to.is_empty()
            && open.claimed_by.is_none()
            && open
                .sent_to
                .iter()
                .all(|conn| open.refused.iter().any(|(by, _)| by == conn));
        all_refused.then(|| open.refused[0].1.clone())
    }

    fn ever_sent(&self, id: RequestId) -> bool {
        lock(&self.open).get(&id).is_some_and(|open| open.ever_sent)
    }

    fn claimed(&self, id: RequestId) -> bool {
        lock(&self.open)
            .get(&id)
            .is_some_and(|open| open.claimed_by.is_some())
    }

    pub fn refuse(&self, conn: ConnId, id: RequestId, refusal: CrossHostRefusal) {
        let mut open = lock(&self.open);
        if let Some(open) = open
            .get_mut(&id)
            .filter(|open| open.sent_to.contains(&conn))
        {
            open.refused.retain(|(by, _)| *by != conn);
            open.refused.push((conn, refusal));
            let _ = open.progress.try_send(Progress::Changed);
        }
    }

    /// The claiming device's outcome; from any other connection it is ignored.
    pub fn result(
        &self,
        conn: ConnId,
        id: RequestId,
        outcome: std::result::Result<String, String>,
    ) {
        if let Some(open) = lock(&self.open)
            .get(&id)
            .filter(|open| open.claimed_by == Some(conn))
        {
            let _ = open.progress.try_send(Progress::Result(outcome));
        }
    }

    /// A device claims a request with the owner's signed answer. The first valid claim wins
    /// and is recorded with its signature; the other devices are told it is gone.
    pub fn claim(&self, core: &Core, conn: ConnId, authz: &Authz, decide: &Decide) -> bool {
        let refuse = |detail: String| {
            core.mp.audit.append(
                AuditKind::Denied,
                AuditEntry {
                    detail,
                    ..authz.audit()
                },
            );
            false
        };
        if !self.is_device(conn) || decide.actor != authz.actor {
            return refuse(format!(
                "a claim of cross-host request {} from a connection that may not",
                decide.request_id
            ));
        }
        let daemon = core.identity.daemon_id();
        if !grants::verify_approval(daemon, decide) {
            return refuse(format!(
                "unsigned or badly signed claim of cross-host request {}",
                decide.request_id
            ));
        }
        let Some(label) = CrossHostRequest::OPTIONS
            .iter()
            .find(|(option, _)| *option == decide.option_id)
            .map(|(_, label)| *label)
        else {
            return false;
        };
        let (pane, tool, summary, others) = {
            let mut open = lock(&self.open);
            let Some(open) = open
                .get_mut(&decide.request_id)
                .filter(|open| open.sent_to.contains(&conn) && open.claimed_by.is_none())
            else {
                return false;
            };
            open.claimed_by = Some(conn);
            let _ = open.progress.try_send(Progress::Claimed(decide.option_id));
            let others: Vec<ConnId> = open
                .sent_to
                .iter()
                .copied()
                .filter(|other| *other != conn)
                .collect();
            open.sent_to.retain(|other| *other == conn);
            (
                open.request.pane_id,
                open.request.tool.clone(),
                open.summary.clone(),
                others,
            )
        };
        let closed = ServerCtl::CrossHost(CrossHostPush::Closed {
            id: decide.request_id,
        });
        for other in others {
            core.mp.send_to_conn(other, closed.clone());
        }
        let name = core.mp.name_of(conn);
        core.mp.audit.append(
            AuditKind::Approval,
            AuditEntry {
                pane_id: Some(pane),
                detail: format!("{name} chose {label:?} for {summary}"),
                approval: Some(proto::ApprovalAudit {
                    request_id: decide.request_id,
                    agent_request: format!("cross-host/{}", decide.request_id.0),
                    option_id: decide.option_id,
                    option: label.to_owned(),
                    tool: Some(tool),
                    summary,
                    signed: proto::approval_signing_bytes(
                        daemon,
                        decide.request_id,
                        decide.option_id,
                        decide.actor,
                    ),
                    sig: decide.sig.clone(),
                }),
                ..authz.audit()
            },
        );
        true
    }

    /// `host_list`: every host the connected devices know, the best state any of them has.
    fn hosts(&self) -> Option<Vec<HostEntry>> {
        let devices = lock(&self.devices);
        if devices.is_empty() {
            return None;
        }
        let mut merged: Vec<HostEntry> = Vec::new();
        for entry in devices.values().flatten().flatten() {
            match merged.iter_mut().find(|known| known.id == entry.id) {
                Some(known) if rank(entry.state) > rank(known.state) => *known = entry.clone(),
                Some(_) => {}
                None => merged.push(entry.clone()),
            }
        }
        merged.sort_by_key(|entry| entry.name.to_lowercase());
        Some(merged)
    }

    /// The stand-in caller for a remote agent, made on its first call.
    fn stand_in(&self, agent: &RemoteAgent) -> Result<PaneId> {
        let key = RemoteKey {
            host: agent.host,
            pane_id: agent.pane_id,
            agent_key: agent.agent_key,
        };
        let mut remote = lock(&self.remote);
        if let Some(&pane) = remote.get(&key) {
            return Ok(pane);
        }
        if remote.len() >= MAX_REMOTE_AGENTS {
            return Err(ToolError::new(
                ErrorCode::Failed,
                format!("{MAX_REMOTE_AGENTS} agents from other hosts already work here"),
            ));
        }
        let index = self
            .next_stand_in
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // Far above any id the layout hands out, so it never names a real pane.
        let pane = PaneId(u64::MAX - index);
        remote.insert(key, pane);
        lock(&self.stand_ins).insert(pane, agent.clone());
        Ok(pane)
    }

    /// A remote agent is gone: the panes it opened go back to the user.
    pub fn remote_gone(&self, core: &Core, host: DaemonId, pane_id: PaneId, agent_key: u64) {
        let key = RemoteKey {
            host,
            pane_id,
            agent_key,
        };
        let Some(stand_in) = lock(&self.remote).remove(&key) else {
            return;
        };
        lock(&self.stand_ins).remove(&stand_in);
        core.term.forget(stand_in);
    }

    pub fn remote_agents(&self) -> usize {
        lock(&self.remote).len()
    }
}

/// Which of two states for the same host `host_list` shows.
fn rank(state: PairState) -> u8 {
    match state {
        PairState::Enabled => 5,
        PairState::OldHelper => 4,
        PairState::Offline => 3,
        PairState::Off => 2,
        PairState::NoHelper => 1,
        PairState::Guest => 0,
    }
}

fn state_name(state: PairState) -> &'static str {
    match state {
        PairState::Enabled => "enabled",
        PairState::Off => "off",
        PairState::Offline => "offline",
        PairState::Guest => "guest",
        PairState::NoHelper => "no_helper",
        PairState::OldHelper => "old_helper",
    }
}

/// `this Mac`, as the owner thinks of this host.
fn here() -> &'static str {
    if cfg!(target_os = "macos") {
        "this Mac"
    } else {
        "this computer"
    }
}

fn no_device() -> ToolError {
    ToolError {
        retryable: true,
        ..ToolError::new(
            ErrorCode::Forbidden,
            format!(
                "No {} device is connected to approve this.",
                brand::PRODUCT_NAME
            ),
        )
        .hint("the owner was notified: try again once they open the app")
    }
}

/// `host_list`.
pub(super) fn host_list(core: &Core) -> Value {
    let Some(hosts) = core.term.cross.hosts() else {
        return json!({ "hosts": [], "note": no_device().message });
    };
    let listed: Vec<Value> = hosts
        .iter()
        .map(|entry| {
            let host = entry.name.clone();
            let note = match entry.state {
                PairState::Enabled => None,
                PairState::Off => Some(CrossHostRefusal::NotEnabled { host }),
                PairState::Offline => Some(CrossHostRefusal::Offline { host }),
                PairState::Guest => Some(CrossHostRefusal::Guest { host }),
                PairState::NoHelper => Some(CrossHostRefusal::NoHelper { host }),
                PairState::OldHelper => Some(CrossHostRefusal::OldHelper { host }),
            };
            json!({
                "name": entry.name,
                "id": entry.id,
                "state": state_name(entry.state),
                "note": note.map(|note| note.message(here())),
            })
        })
        .collect();
    json!({ "hosts": listed, "note": null })
}

/// Closes the request when the call waiting on it ends, however it ends.
struct CloseOnDrop<'a> {
    core: &'a Core,
    id: RequestId,
}

impl Drop for CloseOnDrop<'_> {
    fn drop(&mut self) {
        self.core.term.cross.close(self.core, self.id);
    }
}

/// Asks the owner's devices to run `tool` on `host` and waits for the reply.
pub(super) async fn relay(
    context: &CallContext,
    tool: &str,
    host: String,
    args: Value,
) -> Result<Value> {
    let core = &context.core;
    let caller = context.caller;
    let Some(verb) = CrossHostVerb::of(tool) else {
        return Err(ToolError::new(
            ErrorCode::InvalidArgs,
            format!("{tool} works on this host only"),
        )
        .hint("call it without host"));
    };
    let host = host.trim().to_owned();
    if host.is_empty() || host.len() > MAX_HOST_LEN {
        return Err(ToolError::new(
            ErrorCode::InvalidArgs,
            format!("host must be a name or id of at most {MAX_HOST_LEN} bytes"),
        )
        .hint("host_list shows the hosts"));
    }
    let cross = &core.term.cross;
    if let Lookup::Unknown = cross.look_up(&host) {
        return Err(ToolError::new(
            ErrorCode::NotFound,
            format!(
                "No host named {host} is paired with the {} devices connected here.",
                brand::PRODUCT_NAME
            ),
        )
        .hint("host_list shows the hosts"));
    }
    cross.admit(caller, core.cfg.cross_host_requests_per_minute)?;
    let wait = core.cfg.drive_ask_wait;
    let (agent, kind) = context.caller_names();
    let args_text = args.to_string();
    let action = proto::describe_cross_host(tool, &args_text);
    let request = CrossHostRequest {
        id: crate::agent::next_request_id(),
        pane_id: caller,
        agent_key: cross.agent_key(caller),
        agent: agent.clone(),
        host: host.clone(),
        tool: tool.to_owned(),
        args: args_text,
        guest_driving: core.mp.guest_driving(caller),
        expires_at: proto::UnixMillis(crate::identity::now_millis() + wait.as_millis() as u64),
    };
    let id = request.id;
    let summary = format!("{agent} asked to {action} on {host}");
    let (progress, mut updates) = mpsc::channel(PROGRESS_QUEUE);
    let Some(devices) = cross.open(core, request, summary.clone(), progress) else {
        return Err(ToolError {
            retryable: true,
            ..ToolError::new(
                ErrorCode::AgentBlocked,
                "you are already waiting on a request for another host",
            )
            .hint("one request at a time: wait for its answer")
        });
    };
    let _close = CloseOnDrop { core, id };
    core.mp.audit.append(
        AuditKind::CrossHost,
        AuditEntry {
            pane_id: Some(caller),
            detail: summary.clone(),
            ..AuditEntry::default()
        },
    );
    tracing::info!(%caller, ?verb, devices, "asking the owner's devices to reach another host");
    let notify = || {
        crate::ws::drive_notice(
            core,
            caller,
            kind.clone(),
            id,
            format!("{agent} wants to reach {host}"),
            action.clone(),
        );
    };
    let mut noticed = false;
    if devices == 0 {
        notify();
        noticed = true;
    }
    let notice_at = Instant::now() + NOTICE_DELAY;
    let mut deadline = Instant::now() + wait;
    loop {
        tokio::select! {
            update = updates.recv() => match update {
                Some(Progress::Changed) => {
                    if let Some(refusal) = cross.refusal(id) {
                        return Err(ToolError::new(ErrorCode::Forbidden, refusal.message(here())));
                    }
                }
                Some(Progress::Claimed(CrossHostRequest::DENY)) => {
                    return Err(ToolError::new(
                        ErrorCode::Forbidden,
                        format!("the user said no to {action} on {host}"),
                    )
                    .hint("ask the user what they want, or do it on this host"));
                }
                Some(Progress::Claimed(_)) => {
                    noticed = true;
                    crate::ws::agent_unblocked(core, caller);
                    deadline = Instant::now() + RESULT_WAIT;
                }
                Some(Progress::Result(Ok(reply))) => return relayed(&reply, &host),
                Some(Progress::Result(Err(why))) => {
                    return Err(ToolError {
                        retryable: true,
                        ..ToolError::new(ErrorCode::Failed, format!("{host}: {why}"))
                    });
                }
                Some(Progress::DeviceLeft) => {
                    return Err(ToolError {
                        retryable: true,
                        ..ToolError::new(
                            ErrorCode::Failed,
                            format!("the device running it on {host} disconnected"),
                        )
                    });
                }
                None => return Err(super::closed()),
            },
            () = tokio::time::sleep_until(notice_at), if !noticed => {
                noticed = true;
                notify();
            }
            () = tokio::time::sleep_until(deadline) => {
                if cross.claimed(id) {
                    return Err(ToolError {
                        retryable: true,
                        ..ToolError::new(ErrorCode::Failed, format!("{host} did not answer in time"))
                    });
                }
                if !cross.ever_sent(id) {
                    return Err(no_device());
                }
                return Err(ToolError {
                    retryable: true,
                    ..ToolError::new(
                        ErrorCode::Forbidden,
                        format!("the user did not answer about {action} on {host}"),
                    )
                    .hint("they may be away: try again later")
                });
            }
        }
    }
}

/// The other host's reply, as its own tool's result or refusal.
fn relayed(reply: &str, host: &str) -> Result<Value> {
    match serde_json::from_str::<TermReply>(reply) {
        Ok(TermReply::Ok(value)) => Ok(value),
        Ok(TermReply::Error(error)) => Err(error),
        Err(_) => Err(ToolError::new(
            ErrorCode::Failed,
            format!("{host} answered something unreadable"),
        )),
    }
}

/// The owner's yes a remote agent's call runs under, and where.
pub(super) struct Remote {
    pub agent: RemoteAgent,
    pub session: SessionId,
    pub consent: Consent,
}

/// Runs a call an owner device relays from an agent on another host. `actor` is the device;
/// `shown` the session it shows.
pub(crate) async fn serve_remote(
    core: &Arc<Core>,
    actor: Actor,
    shown: Option<SessionId>,
    call: RemoteCall,
) -> TermReply {
    match remote_call(core, actor, shown, call).await {
        Ok(value) => TermReply::Ok(value),
        Err(error) => TermReply::Error(error),
    }
}

async fn remote_call(
    core: &Arc<Core>,
    actor: Actor,
    shown: Option<SessionId>,
    call: RemoteCall,
) -> Result<Value> {
    let Some(verb) = CrossHostVerb::of(&call.tool) else {
        return Err(ToolError::new(
            ErrorCode::InvalidArgs,
            format!("{} cannot be called from another host", call.tool),
        ));
    };
    if call.consent == Consent::Reads && verb != CrossHostVerb::Read {
        return Err(ToolError::new(
            ErrorCode::Forbidden,
            "only reads are covered by the earlier yes",
        ));
    }
    let args: Value = serde_json::from_str(&call.args)
        .ok()
        .filter(Value::is_object)
        .ok_or_else(|| ToolError::new(ErrorCode::InvalidArgs, "arguments are not an object"))?;
    if args.get("host").is_some() {
        return Err(ToolError::new(
            ErrorCode::InvalidArgs,
            "a call relayed from another host cannot reach a third",
        ));
    }
    let session = {
        let layout = lock(&core.layout);
        shown
            .filter(|session| layout.snapshot(*session).is_some())
            .or_else(|| layout.most_recent())
    }
    .ok_or_else(|| ToolError::new(ErrorCode::NotFound, "this host has no session"))?;
    let agent = call.on_behalf_of;
    let stand_in = core.term.cross.stand_in(&agent)?;
    let action = proto::describe_cross_host(&call.tool, &call.args);
    let consent = match call.consent {
        Consent::Once => "allowed once",
        Consent::Agent => "allowed for this agent",
        Consent::Reads => "a read after a yes",
    };
    core.mp.audit.append(
        AuditKind::CrossHost,
        AuditEntry {
            actor: Some(actor),
            detail: format!(
                "{action} for {} in p{} on {}, {consent}; on_behalf_of={}/p{}",
                agent.agent,
                agent.pane_id.0,
                agent.host_name,
                hex(&agent.host.0),
                agent.pane_id.0
            ),
            ..AuditEntry::default()
        },
    );
    let context = CallContext {
        core: Arc::clone(core),
        caller: stand_in,
        remote: Some(Remote {
            agent,
            session,
            consent: call.consent,
        }),
    };
    context.call(&call.tool, args).await
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
