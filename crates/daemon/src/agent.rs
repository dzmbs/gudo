//! Agent integration: launch recipes, the hook socket, and one [`Arbiter`] per agent pane.
//!
//! # Hook socket protocol
//!
//! Agents launched by the daemon run hooks through the shim ([`brand::HOOK_BIN`]), which
//! connects to the Unix socket named by `UN_SOCK` (or the path in `UN_ENDPOINT_FILE`) and sends
//! one JSON line, a [`HookRequest`]. The daemon answers with one JSON line, a
//! [`HookResponse`], whose `stdout` the shim prints for the agent. A `PermissionRequest` is held
//! open until a client decides (or [`PERMISSION_WAIT`] passes), which is how an approval from a
//! phone reaches Claude Code.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agents::{
    AgentAdapter, AgentEvent, ApprovalChoice, Arbiter, ArbiterConfig, ClaudeCode, Codex, Decision,
    DecisionError, LaunchContext, ScreenInput, SessionInfo, Status,
};
use proto::{
    Actor, AgentKind, AgentState, AgentStatus, Blocker, DecisionOption, OptionId, PaneId, RequestId,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::oneshot;

use crate::core::{Core, lock};
use crate::fsutil;
use crate::identity::now_millis;

/// How long a `PermissionRequest` hook waits for a decision (Claude allows 600 s; the
/// recipe's hook timeout is 590 s).
pub const PERMISSION_WAIT: Duration = Duration::from_secs(585);
/// The event name the shim sends for Claude Code's status-line input (`un-hook claude
/// StatusLine`, the `statusLine` command in the settings the daemon launches Claude with).
pub const STATUS_LINE_EVENT: &str = "StatusLine";
/// Longest hook request line accepted.
const MAX_REQUEST: usize = 1024 * 1024;

/// One hook invocation, as sent by the shim.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookRequest {
    /// Protocol version, 1.
    pub v: u32,
    /// The token from `UN_TOKEN`.
    pub token: String,
    /// The pane id from `UN_PANE_ID`.
    pub pane: String,
    /// Which agent ran the hook (`claude`, `codex`).
    pub agent: String,
    /// The hook event name (`PermissionRequest`, …), for logging.
    pub event: String,
    /// Monotonic per-pane sequence (nanoseconds since the epoch is fine).
    pub seq: u64,
    /// The agent's hook payload, verbatim.
    pub payload: Value,
}

/// The daemon's answer to a [`HookRequest`].
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HookResponse {
    /// Text the shim prints on stdout for the agent, if any.
    pub stdout: Option<String>,
}

pub(crate) fn adapter(kind: AgentKind) -> Box<dyn AgentAdapter + Send + Sync> {
    match kind {
        AgentKind::Claude => Box::new(ClaudeCode::new()),
        AgentKind::Codex => Box::new(Codex::new()),
    }
}

fn agent_kind(name: &str) -> Option<AgentKind> {
    match name {
        "claude" | "claude-code" => Some(AgentKind::Claude),
        "codex" => Some(AgentKind::Codex),
        _ => None,
    }
}

fn now() -> agents::UnixMillis {
    agents::UnixMillis(now_millis())
}

/// A random RFC 4122 version-4 UUID, for pinning a Claude session id.
pub(crate) fn new_uuid() -> String {
    let mut b = fsutil::random::<16>();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = fsutil::hex(&b);
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);

/// A dialog's approving and refusing options, with labels (for push notification actions).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ApprovalButtons {
    pub approve: Option<(OptionId, String)>,
    pub deny: Option<(OptionId, String)>,
}

/// The agent side of one pane.
pub(crate) struct AgentRuntime {
    kind: AgentKind,
    adapter: Box<dyn AgentAdapter + Send + Sync>,
    arbiter: Arbiter,
    /// Wire ids for the arbiter's string request ids.
    requests: Vec<(RequestId, agents::RequestId)>,
    last_decided: Option<(RequestId, Actor)>,
    /// Notifications the arbiter asked for, with the event that caused them, until the core
    /// takes them for the attention feed.
    notices: Vec<(agents::Notify, Option<AgentEvent>)>,
}

impl AgentRuntime {
    pub fn new(
        kind: AgentKind,
        pane: PaneId,
        adapter: Box<dyn AgentAdapter + Send + Sync>,
        restored: bool,
    ) -> Self {
        let config = ArbiterConfig::new(adapter.hook_coverage());
        let session = SessionInfo::new(adapter.kind(), agents::Lane::Pty);
        let pane_id = Some(agents::PaneId::new(pane.0.to_string()));
        let arbiter = if restored {
            Arbiter::restored(config, pane_id, session, now())
        } else {
            Arbiter::new(config, pane_id, session, now())
        };
        Self {
            kind,
            adapter,
            arbiter,
            requests: Vec::new(),
            last_decided: None,
            notices: Vec::new(),
        }
    }

    fn take(&mut self, update: agents::Update) -> Option<AgentEvent> {
        if let Some(notify) = update.notify {
            self.notices.push((notify, update.event.clone()));
        }
        update.event
    }

    /// The notifications collected since the last call.
    pub fn take_notices(&mut self) -> Vec<(agents::Notify, Option<AgentEvent>)> {
        std::mem::take(&mut self.notices)
    }

    pub fn kind(&self) -> AgentKind {
        self.kind
    }

    /// Whether the agent is blocked now.
    pub fn is_blocked(&self) -> bool {
        self.arbiter.status().blocked().is_some()
    }

    fn wire_request(&mut self, id: &agents::RequestId) -> RequestId {
        if let Some((wire, _)) = self.requests.iter().find(|(_, r)| r == id) {
            return *wire;
        }
        let wire = RequestId(NEXT_REQUEST.fetch_add(1, Ordering::Relaxed));
        self.requests.push((wire, id.clone()));
        // Old dialogs are never answered again; keep the table short.
        if self.requests.len() > 32 {
            self.requests.remove(0);
        }
        wire
    }

    /// The status for `PaneMeta`.
    pub fn wire_status(&mut self) -> AgentStatus {
        let kind = match self.kind {
            AgentKind::Claude => "claude",
            AgentKind::Codex => "codex",
        }
        .to_owned();
        let state = match self.arbiter.status().clone() {
            Status::Working => AgentState::Running,
            Status::Idle | Status::Unknown => AgentState::Idle,
            Status::Error => AgentState::Done,
            Status::Blocked(blocked) => {
                let request_id = self.wire_request(&blocked.request_id);
                AgentState::Blocked(Blocker {
                    request_id,
                    summary: blocked
                        .blocker
                        .summary
                        .clone()
                        .or(blocked.blocker.tool.clone())
                        .unwrap_or_default(),
                    options: blocked
                        .blocker
                        .options
                        .iter()
                        .enumerate()
                        .map(|(i, o)| DecisionOption {
                            id: OptionId(i as u32),
                            label: o.label.clone(),
                        })
                        .collect(),
                })
            }
        };
        AgentStatus { kind, state }
    }

    pub fn pty_output(&mut self) {
        self.arbiter.pty_output(now());
    }

    pub fn osc9(&mut self, body: &str) -> Option<AgentEvent> {
        let signal = self.adapter.parse_osc9(body)?;
        let update = self.arbiter.apply(signal, now());
        self.take(update)
    }

    pub fn program_status(&mut self, body: &str) -> Option<AgentEvent> {
        let signal = self.adapter.parse_program_status(body)?;
        let update = self.arbiter.apply(signal, now());
        self.take(update)
    }

    pub fn hook(&mut self, payload: &[u8], seq: u64) -> Option<AgentEvent> {
        match self.adapter.parse_hook(payload, agents::Seq(seq)) {
            Ok(Some(signal)) => {
                let update = self.arbiter.apply(signal, now());
                self.take(update)
            }
            Ok(None) => None,
            Err(e) => {
                tracing::debug!("ignoring hook payload: {e}");
                None
            }
        }
    }

    /// Timers, plus a screen check when output arrived since the last tick.
    pub fn tick(&mut self, screen: Option<&str>, title: &str) -> Vec<AgentEvent> {
        let mut events = Vec::new();
        if let Some(screen) = screen {
            let verdict = self.adapter.detect_screen(ScreenInput {
                screen,
                osc_title: title,
                ..ScreenInput::default()
            });
            let update = self.arbiter.observe_screen(&verdict, now());
            events.extend(self.take(update));
        }
        let update = self.arbiter.tick(now());
        events.extend(self.take(update));
        events
    }

    pub fn process_exited(&mut self) -> Option<AgentEvent> {
        let update = self.arbiter.process_exited(now());
        self.take(update)
    }

    /// The string id of the dialog currently showing, if blocked.
    pub fn blocked_request(&self) -> Option<agents::RequestId> {
        self.arbiter
            .status()
            .blocked()
            .map(|b| b.request_id.clone())
    }

    /// For a notification's Approve / Deny buttons: the options of the dialog `id` that allow
    /// this one request and that refuse it, with their labels. `None` unless the agent is
    /// blocked on `id` now.
    pub fn approval_options(&self, id: RequestId) -> Option<ApprovalButtons> {
        let request = self.requests.iter().find(|(w, _)| *w == id)?.1.clone();
        let blocked = self
            .arbiter
            .status()
            .blocked()
            .filter(|b| b.request_id == request)?;
        let find = |choice: ApprovalChoice| {
            blocked
                .blocker
                .options
                .iter()
                .position(|o| o.id == choice)
                .map(|i| (OptionId(i as u32), blocked.blocker.options[i].label.clone()))
        };
        Some(ApprovalButtons {
            approve: find(ApprovalChoice::AllowOnce),
            deny: find(ApprovalChoice::Deny),
        })
    }

    /// The dialog the agent is blocked on, for the decision strip (D9). `None` unless blocked.
    pub fn blocked_detail(&mut self) -> Option<BlockedDetail> {
        let blocked = self.arbiter.status().blocked()?.clone();
        let wire = self.wire_request(&blocked.request_id);
        Some(BlockedDetail {
            wire,
            summary: blocked
                .blocker
                .summary
                .clone()
                .or(blocked.blocker.tool.clone())
                .unwrap_or_default(),
            options: blocked
                .blocker
                .options
                .iter()
                .map(|o| (o.label.clone(), o.id))
                .collect(),
            request: blocked.request_id,
        })
    }

    pub fn knows_request(&self, id: RequestId) -> bool {
        self.requests.iter().any(|(w, _)| *w == id)
    }

    /// Accepts the first decision for a request. On refusal returns who decided first, if
    /// known.
    pub fn decide(
        &mut self,
        id: RequestId,
        option: OptionId,
        actor: Actor,
    ) -> Result<DecidedRequest, Option<Actor>> {
        if let Some((done, by)) = self.last_decided
            && done == id
        {
            return Err(Some(by));
        }
        let request = self
            .requests
            .iter()
            .find(|(w, _)| *w == id)
            .map(|(_, r)| r.clone())
            .ok_or(None)?;
        let blocked = self
            .arbiter
            .status()
            .blocked()
            .filter(|b| b.request_id == request)
            .cloned()
            .ok_or(None)?;
        let chosen = blocked.blocker.options.get(option.0 as usize).ok_or(None)?;
        let choice = chosen.id;
        let details = DecidedRequest {
            choice,
            request: request.clone(),
            option: chosen.label.clone(),
            tool: blocked.blocker.tool.clone(),
            summary: blocked
                .blocker
                .summary
                .clone()
                .or(blocked.blocker.tool.clone())
                .unwrap_or_default(),
        };
        let decision = Decision {
            request_id: request,
            choice,
            actor: agents::ActorId::new(fsutil::hex(&actor.principal.0)),
        };
        match self.arbiter.decide(decision, now()) {
            Ok(_) => {
                self.last_decided = Some((id, actor));
                Ok(details)
            }
            Err(DecisionError::AlreadyDecided { .. }) => Err(self.last_decided.map(|(_, a)| a)),
            Err(_) => Err(None),
        }
    }
}

/// What a blocked agent waits for (D9).
#[derive(Debug, Clone)]
pub(crate) struct BlockedDetail {
    /// The wire id clients decide with.
    pub wire: RequestId,
    /// The arbiter's id.
    pub request: agents::RequestId,
    pub summary: String,
    /// The hook's options, in order: `(label, choice)`.
    pub options: Vec<(String, ApprovalChoice)>,
}

/// An accepted decision, with what the audit log records about it.
pub(crate) struct DecidedRequest {
    /// The answer for the hook.
    pub choice: ApprovalChoice,
    /// The arbiter's id for the blocked tool call (the agent event's request id).
    pub request: agents::RequestId,
    /// The chosen option's label.
    pub option: String,
    /// The tool asking.
    pub tool: Option<String>,
    /// What it wanted to do.
    pub summary: String,
}

struct Pending {
    request: agents::RequestId,
    suggestions: Vec<Value>,
    reply: oneshot::Sender<HookResponse>,
}

/// The hook socket and the hook decisions waiting for a client.
pub(crate) struct HookServer {
    socket: PathBuf,
    token: String,
    endpoint_file: PathBuf,
    hook_bin: PathBuf,
    state_dir: PathBuf,
    pending: Mutex<HashMap<PaneId, Pending>>,
}

impl HookServer {
    pub fn new(state_dir: &Path, hook_bin: PathBuf) -> io::Result<Self> {
        let token_path = state_dir.join("hook.token");
        let token = match fsutil::read_optional(&token_path)? {
            Some(t) => String::from_utf8_lossy(&t).trim().to_owned(),
            None => {
                let t = fsutil::hex(&fsutil::random::<16>());
                fsutil::write_atomic(&token_path, t.as_bytes())?;
                t
            }
        };
        let mut socket = state_dir.join("hook.sock");
        // sun_path is 104 bytes on macOS, 108 on Linux.
        if socket.as_os_str().len() > 100 {
            socket = std::env::temp_dir().join(format!(
                "{}-{}.sock",
                brand::DIR_NAME,
                fsutil::hex(&fsutil::random::<6>())
            ));
        }
        Ok(Self {
            endpoint_file: state_dir.join("hook.endpoint"),
            socket,
            token,
            hook_bin,
            state_dir: state_dir.to_owned(),
            pending: Mutex::new(HashMap::new()),
        })
    }

    pub fn launch_context(&self, pane: PaneId, cwd: PathBuf) -> LaunchContext {
        LaunchContext {
            pane_id: agents::PaneId::new(pane.0.to_string()),
            socket: self.socket.clone(),
            token: self.token.clone(),
            endpoint_file: self.endpoint_file.clone(),
            hook_bin: self.hook_bin.clone(),
            state_dir: self.state_dir.clone(),
            cwd,
        }
    }

    /// Binds the socket and serves hook connections until the task is aborted.
    pub fn listen(core: &Arc<Core>) -> io::Result<tokio::task::JoinHandle<()>> {
        let hooks = &core.hooks;
        let _ = std::fs::remove_file(&hooks.socket);
        let listener = UnixListener::bind(&hooks.socket)?;
        std::fs::write(
            &hooks.endpoint_file,
            hooks.socket.as_os_str().as_encoded_bytes(),
        )?;
        let core = Arc::clone(core);
        Ok(tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    continue;
                };
                let core = Arc::clone(&core);
                tokio::spawn(async move {
                    if let Err(e) = serve_hook(&core, stream).await {
                        tracing::debug!("hook connection: {e}");
                    }
                });
            }
        }))
    }

    pub fn resolve(&self, pane: PaneId, request: &agents::RequestId, choice: ApprovalChoice) {
        let mut pending = lock(&self.pending);
        if pending.get(&pane).is_some_and(|p| &p.request == request) {
            let p = pending.remove(&pane).expect("checked above");
            let stdout = ClaudeCode::permission_response(choice, &p.suggestions).to_string();
            let _ = p.reply.send(HookResponse {
                stdout: Some(stdout),
            });
        }
    }

    /// Whether a hook holds request `request` of `pane` open, so a decision reaches the agent.
    pub fn is_pending(&self, pane: PaneId, request: &agents::RequestId) -> bool {
        lock(&self.pending)
            .get(&pane)
            .is_some_and(|p| &p.request == request)
    }

    pub fn cancel_pending(&self, pane: PaneId) {
        lock(&self.pending).remove(&pane);
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    pub fn endpoint_file(&self) -> &Path {
        &self.endpoint_file
    }
}

async fn serve_hook(core: &Arc<Core>, stream: UnixStream) -> io::Result<()> {
    let peer_uid = stream.peer_cred().ok().map(|c| c.uid());
    let (read, mut write) = stream.into_split();
    let mut line = String::new();
    let mut reader = BufReader::new(AsyncReadExt::take(read, MAX_REQUEST as u64));
    reader.read_line(&mut line).await?;
    // The askpass helper shares the socket (docs/DAEMON.md §9).
    if let Ok(call) = serde_json::from_str::<crate::askpass::AskpassCall>(&line) {
        let reply = crate::askpass::serve(core, call, peer_uid, reader).await;
        let mut out = serde_json::to_vec(&reply).map_err(io::Error::other)?;
        drop(reply);
        out.push(b'\n');
        let written = write.write_all(&out).await;
        zeroize::Zeroize::zeroize(&mut out);
        written?;
        return write.shutdown().await;
    }
    let request: HookRequest = serde_json::from_str(&line).map_err(io::Error::other)?;
    let response = handle_hook(core, request).await;
    let mut out = serde_json::to_vec(&response).map_err(io::Error::other)?;
    out.push(b'\n');
    write.write_all(&out).await?;
    write.shutdown().await
}

async fn handle_hook(core: &Arc<Core>, request: HookRequest) -> HookResponse {
    if request.token != core.hooks.token {
        tracing::warn!("hook with a bad token");
        return HookResponse::default();
    }
    // shim prints the user's own status line itself.
    if request.event == STATUS_LINE_EVENT {
        core.ws.usage.status_line(&request.payload);
        return HookResponse::default();
    }
    let Some(pane_id) = request.pane.parse().ok().map(PaneId) else {
        return HookResponse::default();
    };
    let Some(entry) = core.pane(pane_id) else {
        return HookResponse::default();
    };
    let payload = serde_json::to_vec(&request.payload).unwrap_or_default();
    let (event, blocked) = {
        let mut agent = lock(&entry.agent);
        if agent.is_none()
            && let Some(kind) = agent_kind(&request.agent)
        {
            *agent = Some(AgentRuntime::new(kind, pane_id, adapter(kind), false));
        }
        let Some(rt) = agent.as_mut() else {
            return HookResponse::default();
        };
        let event = rt.hook(&payload, request.seq);
        // Register wire ids now so a client can answer as soon as it sees the event.
        let _ = rt.wire_status();
        (event, rt.blocked_request())
    };
    core.agent_event(pane_id, event);
    if request.event != "PermissionRequest" {
        return HookResponse::default();
    }
    let Some(request_id) = blocked else {
        return HookResponse::default();
    };
    let suggestions = request
        .payload
        .get("permission_suggestions")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let (tx, rx) = oneshot::channel();
    lock(&core.hooks.pending).insert(
        pane_id,
        Pending {
            request: request_id,
            suggestions,
            reply: tx,
        },
    );
    match tokio::time::timeout(PERMISSION_WAIT, rx).await {
        Ok(Ok(response)) => response,
        // No decision: the agent falls back to its own prompt in the terminal.
        _ => HookResponse::default(),
    }
}
