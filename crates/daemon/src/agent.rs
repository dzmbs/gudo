//! Agent integration: launch recipes, the hook socket, and one [`Arbiter`] per agent pane.
//!
//! # Hook socket protocol
//!
//! Agents launched by the daemon run hooks through the shim ([`brand::HOOK_BIN`]), which
//! connects to the Unix socket named by `GUDO_SOCK` (or the path in `GUDO_ENDPOINT_FILE`) and sends
//! one JSON line, a [`HookRequest`]. The daemon answers with one JSON line, a
//! [`HookResponse`], whose `stdout` the shim prints for the agent. A `PermissionRequest` is held
//! open until a client decides (or [`PERMISSION_WAIT`] passes), which is how an approval from a
//! phone reaches Claude Code.
//!
//! The askpass helper ([`crate::askpass::AskpassCall`]), the browser helper and tools
//! ([`crate::browser::BrowserCall`]) and the MCP pull channel ([`crate::art::pull::PullCall`])
//! share the socket; each is told apart by its own field.

use std::collections::HashMap;
use std::io;
use std::os::unix::fs::PermissionsExt;
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

/// How long a `PermissionRequest` hook waits for a decision (Claude allows 600 s; the
/// recipe's hook timeout is 590 s).
pub const PERMISSION_WAIT: Duration = Duration::from_secs(585);
/// The event name the shim sends for Claude Code's status-line input (`gudo-hook claude
/// StatusLine`, the `statusLine` command in the settings the daemon launches Claude with).
pub const STATUS_LINE_EVENT: &str = "StatusLine";

/// The hook shim's agent name for account events (`gudo-hook account SignIn`), which sign-in
/// panes send when the agent's login ends.
pub const ACCOUNT_HOOK: &str = "account";

/// The account event a sign-in pane sends when the agent's login ends.
pub const SIGN_IN_EVENT: &str = "SignIn";
/// Longest hook request line accepted: a browser upload's files fill most of a frame to the app.
const MAX_REQUEST: usize = proto::MAX_FRAME_LEN;

/// One hook invocation, as sent by the shim.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookRequest {
    /// Protocol version, 1.
    pub v: u32,
    /// The token from `GUDO_TOKEN`.
    pub token: String,
    /// The pane id from `GUDO_PANE_ID`.
    pub pane: String,
    /// Which agent ran the hook (`claude`, `codex`).
    pub agent: String,
    /// The hook event name (`PermissionRequest`, …), for logging.
    pub event: String,
    /// Orders a pane's hooks: the boot clock's nanoseconds ([`crate::hook_seq`]), which a
    /// change of the wall clock cannot send back.
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

/// Whether a program-status report names one of our agents in any spelling (`claude-code`,
/// `Claude`, `codex-cli`): clients show such a name with the agent's mark. Outside a pane
/// running that agent it is printed text posing as the agent.
pub(crate) fn names_an_agent(report: &agents::ProgramStatus) -> bool {
    let Some(app) = report.app.as_deref().map(str::to_ascii_lowercase) else {
        return false;
    };
    [AgentKind::Claude, AgentKind::Codex]
        .into_iter()
        .any(|kind| app.contains(program(kind)))
}

/// What a blocked agent asks, as people see and approve it. It may come from printed text
/// (OSC 9, OSC 7501) or a prompt-injected tool call: every line kept, nothing invisible.
fn shown_summary(blocker: &agents::Blocker) -> String {
    let text = blocker.summary.as_ref().or(blocker.tool.as_ref());
    text.map(|text| proto::clean_prompt_text(text, SUMMARY_CHARS))
        .unwrap_or_default()
}

/// Longest blocked summary, in characters (the adapters cut tool calls at 200 already).
const SUMMARY_CHARS: usize = 512;

/// The command that runs `kind`, looked up on `PATH`.
pub(crate) fn program(kind: AgentKind) -> &'static str {
    match kind {
        AgentKind::Claude => "claude",
        AgentKind::Codex => "codex",
    }
}

/// The agent `process` runs, also when a script runtime runs it (`node …/codex`).
pub(crate) fn running_agent(process: &pty::ForegroundProcess) -> Option<AgentKind> {
    let kind = |name: &str| match name {
        "claude" => Some(AgentKind::Claude),
        "codex" => Some(AgentKind::Codex),
        _ => None,
    };
    kind(process.program()).or_else(|| {
        if !matches!(process.program(), "node" | "bun" | "deno") {
            return None;
        }
        let script = process.argv.get(1)?.rsplit('/').next()?;
        kind(script.strip_suffix(".js").unwrap_or(script))
    })
}

fn agent_kind(name: &str) -> Option<AgentKind> {
    match name {
        "claude" | "claude-code" => Some(AgentKind::Claude),
        "codex" => Some(AgentKind::Codex),
        _ => None,
    }
}

/// The arbiter measures debounces and staleness, so it must not see the wall clock's steps.
fn now() -> agents::UnixMillis {
    agents::UnixMillis(crate::clock::steady_millis())
}

/// A random RFC 4122 version-4 UUID, for pinning a Claude session id.
pub(crate) fn new_uuid() -> String {
    let mut bytes = fsutil::random::<16>();
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = fsutil::hex(&bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// Wire request ids start at a random point each run: an answer that outlives the daemon (a
/// lock-screen action token, a stale approval card) must not land on a new run's request that
/// happens to reuse its id.
static NEXT_REQUEST: std::sync::LazyLock<AtomicU64> =
    std::sync::LazyLock::new(|| AtomicU64::new(first_request_id()));

pub(crate) fn next_request_id() -> RequestId {
    RequestId(NEXT_REQUEST.fetch_add(1, Ordering::Relaxed))
}

/// A random id in `[2^32, 2^52)`: far from any earlier run's, and exact as a JSON number.
fn first_request_id() -> u64 {
    let mut bytes = [0; 8];
    getrandom::fill(&mut bytes).expect("the OS random source is available");
    (1 << 32) + u64::from_le_bytes(bytes) % ((1 << 52) - (1 << 32))
}

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
    /// The agent's process, once seen as the pane's foreground job.
    pid: Option<u32>,
    started_at: std::time::SystemTime,
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
            pid: None,
            started_at: std::time::SystemTime::now(),
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

    pub fn session(&self) -> &SessionInfo {
        self.arbiter.session()
    }

    /// When the daemon launched the agent or first saw it running.
    pub fn started_at(&self) -> std::time::SystemTime {
        self.started_at
    }

    pub fn state(&self) -> agents::AgentState {
        self.arbiter.status().state()
    }

    pub fn is_blocked(&self) -> bool {
        self.arbiter.status().blocked().is_some()
    }

    fn wire_request(&mut self, id: &agents::RequestId) -> RequestId {
        if let Some((wire, _)) = self.requests.iter().find(|(_, known)| known == id) {
            return *wire;
        }
        let wire = next_request_id();
        self.requests.push((wire, id.clone()));
        // Old dialogs are never answered again; keep the table short.
        if self.requests.len() > 32 {
            self.requests.remove(0);
        }
        wire
    }

    /// The status for `PaneMeta`.
    pub fn wire_status(&mut self) -> AgentStatus {
        let kind = program(self.kind).to_owned();
        let state = match self.arbiter.status().clone() {
            Status::Working => AgentState::Running,
            Status::Idle | Status::Unknown => AgentState::Idle,
            Status::Error => AgentState::Done,
            Status::Blocked(blocked) => {
                let request_id = self.wire_request(&blocked.request_id);
                AgentState::Blocked(Blocker {
                    request_id,
                    summary: shown_summary(&blocked.blocker),
                    options: blocked
                        .blocker
                        .options
                        .iter()
                        .enumerate()
                        .map(|(i, option)| DecisionOption {
                            id: OptionId(i as u32),
                            label: option.label.clone(),
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
            Err(error) => {
                tracing::debug!("ignoring hook payload: {error}");
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

    /// Notes the agent's process, seen as the pane's foreground job.
    pub fn note_process(&mut self, pid: u32) {
        self.pid = Some(pid);
    }

    /// The agent's process (its process group's leader), once seen in the foreground.
    pub fn pid(&self) -> Option<u32> {
        self.pid
    }

    /// Follows the agent's process through the pane's foreground job: `true` once the process
    /// seen there has exited, or, if it was never seen, once the pane is back at its own shell
    /// (`at_shell`). The shell outlives the agent, and hooks don't report every exit (Claude
    /// quitting at its trust prompt sends no SessionEnd).
    pub fn process_gone(
        &mut self,
        foreground: Option<&pty::ForegroundProcess>,
        at_shell: bool,
        alive: impl FnOnce(u32) -> bool,
    ) -> bool {
        if let Some(process) = foreground
            && running_agent(process) == Some(self.kind)
        {
            self.note_process(process.pid);
            return false;
        }
        match self.pid {
            Some(pid) => foreground.is_none_or(|process| process.pid != pid) && !alive(pid),
            None => at_shell,
        }
    }

    pub fn process_exited(&mut self) -> Option<AgentEvent> {
        let update = self.arbiter.process_exited(now());
        self.take(update)
    }

    /// The wire id of the dialog currently showing, if blocked, with the option that allows
    /// it once.
    pub fn blocked_wire(&mut self) -> Option<(RequestId, agents::RequestId, Option<OptionId>)> {
        let request = self.blocked_request()?;
        let wire = self.wire_request(&request);
        let allow = self
            .approval_options(wire)
            .and_then(|buttons| buttons.approve)
            .map(|(id, _)| id);
        Some((wire, request, allow))
    }

    /// The string id of the dialog currently showing, if blocked.
    pub fn blocked_request(&self) -> Option<agents::RequestId> {
        self.arbiter
            .status()
            .blocked()
            .map(|blocked| blocked.request_id.clone())
    }

    /// For a notification's Approve / Deny buttons: the options of the dialog `id` that allow
    /// this one request and that refuse it, with their labels. `None` unless the agent is
    /// blocked on `id` now.
    pub fn approval_options(&self, id: RequestId) -> Option<ApprovalButtons> {
        let request = self
            .requests
            .iter()
            .find(|(wire, _)| *wire == id)?
            .1
            .clone();
        let blocked = self
            .arbiter
            .status()
            .blocked()
            .filter(|blocked| blocked.request_id == request)?;
        let find = |choice: ApprovalChoice| {
            blocked
                .blocker
                .options
                .iter()
                .position(|option| option.id == choice)
                .map(|i| (OptionId(i as u32), blocked.blocker.options[i].label.clone()))
        };
        Some(ApprovalButtons {
            approve: find(ApprovalChoice::AllowOnce),
            deny: find(ApprovalChoice::Deny),
        })
    }

    /// The dialog the agent is blocked on, for the decision strip. `None` unless blocked.
    pub fn blocked_detail(&mut self) -> Option<BlockedDetail> {
        let blocked = self.arbiter.status().blocked()?.clone();
        let wire = self.wire_request(&blocked.request_id);
        Some(BlockedDetail {
            wire,
            summary: shown_summary(&blocked.blocker),
            options: blocked
                .blocker
                .options
                .iter()
                .map(|option| (option.label.clone(), option.id))
                .collect(),
            request: blocked.request_id,
        })
    }

    /// What an approval policy needs to know about open request `id`: the tool asking, and
    /// for `option`, whether it allows the call. `None` unless the agent is blocked on `id`.
    pub fn request_facts(&self, id: RequestId, option: Option<OptionId>) -> Option<RequestFacts> {
        let request = self
            .requests
            .iter()
            .find(|(wire, _)| *wire == id)?
            .1
            .clone();
        let blocked = self
            .arbiter
            .status()
            .blocked()
            .filter(|blocked| blocked.request_id == request)?;
        let chosen = option.and_then(|option| blocked.blocker.options.get(option.0 as usize));
        Some(RequestFacts {
            tool: blocked.blocker.tool.clone(),
            allows: chosen.map(|chosen| chosen.id != ApprovalChoice::Deny),
            option: chosen.map(|chosen| chosen.label.clone()),
            summary: shown_summary(&blocked.blocker),
            request,
        })
    }

    /// The wire id of the request the agent is blocked on now, if it asked through a hook.
    pub fn open_request(&self) -> Option<RequestId> {
        let blocked = self.arbiter.status().blocked()?;
        self.requests
            .iter()
            .find(|(_, known)| *known == blocked.request_id)
            .map(|(wire, _)| *wire)
    }

    pub fn knows_request(&self, id: RequestId) -> bool {
        self.requests.iter().any(|(wire, _)| *wire == id)
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
            .find(|(wire, _)| *wire == id)
            .map(|(_, known)| known.clone())
            .ok_or(None)?;
        let blocked = self
            .arbiter
            .status()
            .blocked()
            .filter(|blocked| blocked.request_id == request)
            .cloned()
            .ok_or(None)?;
        let chosen = blocked.blocker.options.get(option.0 as usize).ok_or(None)?;
        let choice = chosen.id;
        let details = DecidedRequest {
            choice,
            request: request.clone(),
            option: chosen.label.clone(),
            tool: blocked.blocker.tool.clone(),
            summary: shown_summary(&blocked.blocker),
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
            Err(DecisionError::AlreadyDecided { .. }) => {
                Err(self.last_decided.map(|(_, actor)| actor))
            }
            Err(_) => Err(None),
        }
    }
}

/// What a blocked agent waits for.
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

/// An open approval request, as the approval policy sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RequestFacts {
    /// The tool asking (`Bash`, `Edit`).
    pub tool: Option<String>,
    /// Whether the option asked about allows the call (`None` without an option).
    pub allows: Option<bool>,
    /// That option's label.
    pub option: Option<String>,
    /// What the agent wants to do.
    pub summary: String,
    /// The arbiter's id for the call.
    pub request: agents::RequestId,
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
    /// The agent asking, the tool and its input (for edited approvals and rules).
    agent: Option<AgentKind>,
    tool: String,
    input: Value,
    reply: oneshot::Sender<HookResponse>,
}

/// A hook-held permission request: what the tool wants to do.
#[derive(Debug, Clone)]
pub(crate) struct HeldRequest {
    pub request: agents::RequestId,
    pub agent: Option<AgentKind>,
    pub tool: String,
    pub input: Value,
}

impl HeldRequest {
    /// The text a rule matches and a person may edit: the shell command for shell tools,
    /// nothing for other tools (their rules match the tool alone).
    pub fn command(&self) -> Option<&str> {
        grants::is_shell_tool(&self.tool)
            .then(|| self.input.get("command").and_then(Value::as_str))
            .flatten()
    }

    /// The editable input: Claude Code takes `updatedInput` for its `Bash` tool.
    pub fn editable(&self) -> Option<&str> {
        (self.agent == Some(AgentKind::Claude) && self.tool == "Bash")
            .then(|| self.command())
            .flatten()
    }
}

/// The hook socket and the hook decisions waiting for a client.
pub(crate) struct HookServer {
    socket: PathBuf,
    token: String,
    /// Derives each pane's own token from `token`.
    pane_key: ring::hmac::Key,
    endpoint_file: PathBuf,
    hook_bin: PathBuf,
    state_dir: PathBuf,
    pending: Mutex<HashMap<PaneId, Pending>>,
}

impl HookServer {
    pub fn new(state_dir: &Path, hook_bin: PathBuf) -> io::Result<Self> {
        let token_path = state_dir.join("hook.token");
        let token = match fsutil::read_optional(&token_path)? {
            Some(saved) => String::from_utf8_lossy(&saved).trim().to_owned(),
            None => {
                let fresh = fsutil::hex(&fsutil::random::<16>());
                fsutil::write_atomic(&token_path, fresh.as_bytes())?;
                fresh
            }
        };
        let mut socket = state_dir.join("hook.sock");
        // sun_path is 104 bytes on macOS, 108 on Linux.
        if socket.as_os_str().len() > 100 {
            socket = fsutil::create_private_temp_dir(brand::DIR_NAME)?.join("hook.sock");
        }
        Ok(Self {
            endpoint_file: state_dir.join("hook.endpoint"),
            socket,
            pane_key: ring::hmac::Key::new(ring::hmac::HMAC_SHA256, token.as_bytes()),
            token,
            hook_bin,
            state_dir: state_dir.to_owned(),
            pending: Mutex::new(HashMap::new()),
        })
    }

    /// The token a pane's helpers present (`GUDO_TOKEN`): it speaks for that pane only, so one
    /// pane's programs cannot act as another's.
    pub fn pane_token(&self, pane: PaneId) -> String {
        fsutil::hex(ring::hmac::sign(&self.pane_key, pane.0.to_string().as_bytes()).as_ref())
    }

    /// Whether `token` speaks for `pane`: the pane's own token, or the daemon's, which only
    /// the state directory holds.
    pub fn verify(&self, token: &str, pane: &str) -> bool {
        let own = fsutil::unhex::<32>(token)
            .is_some_and(|tag| ring::hmac::verify(&self.pane_key, pane.as_bytes(), &tag).is_ok());
        own || fsutil::constant_eq(token.as_bytes(), self.token.as_bytes())
    }

    /// Whether `token` is the daemon's own token, which only the state directory holds (not a
    /// pane's).
    pub fn is_daemon_token(&self, token: &str) -> bool {
        fsutil::constant_eq(token.as_bytes(), self.token.as_bytes())
    }

    pub fn launch_context(
        &self,
        pane: PaneId,
        cwd: PathBuf,
        account: agents::AccountContext,
    ) -> LaunchContext {
        LaunchContext {
            pane_id: agents::PaneId::new(pane.0.to_string()),
            socket: self.socket.clone(),
            token: self.pane_token(pane),
            endpoint_file: self.endpoint_file.clone(),
            hook_bin: self.hook_bin.clone(),
            state_dir: self.state_dir.clone(),
            cwd,
            account,
        }
    }

    /// Binds the socket and serves hook connections until the task is aborted.
    pub fn listen(core: &Arc<Core>) -> io::Result<tokio::task::JoinHandle<()>> {
        let hooks = &core.hooks;
        let _ = std::fs::remove_file(&hooks.socket);
        let listener = UnixListener::bind(&hooks.socket)?;
        // Only this user may connect: the directory is private too, and every peer is checked.
        std::fs::set_permissions(&hooks.socket, std::fs::Permissions::from_mode(0o600))?;
        std::fs::write(
            &hooks.endpoint_file,
            hooks.socket.as_os_str().as_encoded_bytes(),
        )?;
        let core = Arc::clone(core);
        let slots = Arc::new(tokio::sync::Semaphore::new(MAX_HOOK_CONNECTIONS));
        Ok(tokio::spawn(async move {
            loop {
                // Past the limit, new connections wait in the socket's backlog.
                let Ok(slot) = Arc::clone(&slots).acquire_owned().await else {
                    return;
                };
                let stream = match listener.accept().await {
                    Ok((stream, _)) => stream,
                    Err(error) => {
                        // Out of descriptors, typically: retrying at once would spin.
                        tracing::warn!("accepting a hook connection: {error}");
                        tokio::time::sleep(ACCEPT_BACKOFF).await;
                        continue;
                    }
                };
                let peer = stream.peer_cred().ok().map(|cred| cred.uid());
                if !same_user(peer) {
                    tracing::warn!(uid = ?peer, "refused a hook connection from another user");
                    continue;
                }
                let core = Arc::clone(&core);
                tokio::spawn(async move {
                    if let Err(error) = serve_hook(&core, stream).await {
                        tracing::debug!("hook connection: {error}");
                    }
                    drop(slot);
                });
            }
        }))
    }

    pub fn resolve(&self, pane: PaneId, request: &agents::RequestId, choice: ApprovalChoice) {
        let mut pending = lock(&self.pending);
        if pending
            .get(&pane)
            .is_some_and(|held| &held.request == request)
        {
            let held = pending.remove(&pane).expect("checked above");
            let stdout = ClaudeCode::permission_response(choice, &held.suggestions).to_string();
            let _ = held.reply.send(HookResponse {
                stdout: Some(stdout),
            });
        }
    }

    /// Answers a held request with "allow", running `command` instead of what the agent
    /// asked for (Claude Code's `updatedInput`). False if the request is no longer held.
    pub fn resolve_edited(&self, pane: PaneId, request: &agents::RequestId, command: &str) -> bool {
        let mut pending = lock(&self.pending);
        if !pending
            .get(&pane)
            .is_some_and(|held| &held.request == request)
        {
            return false;
        }
        let held = pending.remove(&pane).expect("checked above");
        let mut input = held.input.clone();
        if let Some(fields) = input.as_object_mut() {
            fields.insert("command".into(), command.into());
        }
        let stdout = serde_json::json!({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": { "behavior": "allow", "updatedInput": input },
            }
        })
        .to_string();
        let _ = held.reply.send(HookResponse {
            stdout: Some(stdout),
        });
        true
    }

    /// The request a hook holds open on `pane`, if any.
    pub fn held(&self, pane: PaneId) -> Option<HeldRequest> {
        lock(&self.pending).get(&pane).map(|held| HeldRequest {
            request: held.request.clone(),
            agent: held.agent,
            tool: held.tool.clone(),
            input: held.input.clone(),
        })
    }

    /// Whether a hook holds request `request` of `pane` open, so a decision reaches the agent.
    pub fn is_pending(&self, pane: PaneId, request: &agents::RequestId) -> bool {
        lock(&self.pending)
            .get(&pane)
            .is_some_and(|held| &held.request == request)
    }

    pub fn cancel_pending(&self, pane: PaneId) {
        lock(&self.pending).remove(&pane);
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// Removes the socket, and the private directory made for it outside the state dir.
    pub fn remove_socket(&self) {
        let _ = std::fs::remove_file(&self.socket);
        if let Some(dir) = self.socket.parent().filter(|dir| *dir != self.state_dir) {
            let _ = std::fs::remove_dir(dir);
        }
    }

    pub fn endpoint_file(&self) -> &Path {
        &self.endpoint_file
    }
}

/// Whether a hook-socket peer runs as this daemon's user; an unknown peer does not.
fn same_user(peer_uid: Option<u32>) -> bool {
    // SAFETY: getuid has no preconditions and cannot fail.
    peer_uid == Some(unsafe { libc::getuid() })
}

/// Hook-socket connections served at once (an agent's held approval keeps one open).
const MAX_HOOK_CONNECTIONS: usize = 512;
/// Pause after a failed `accept`.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);
/// How long a hook connection may take to send its request line.
const HOOK_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

async fn serve_hook(core: &Arc<Core>, stream: UnixStream) -> io::Result<()> {
    let peer_uid = stream.peer_cred().ok().map(|cred| cred.uid());
    let (read, mut write) = stream.into_split();
    let mut line = String::new();
    let mut reader = BufReader::new(AsyncReadExt::take(read, MAX_REQUEST as u64));
    tokio::time::timeout(HOOK_REQUEST_TIMEOUT, reader.read_line(&mut line))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "no request"))??;
    // The askpass helper shares the socket (docs/DAEMON.md §9).
    if let Ok(call) = serde_json::from_str::<crate::askpass::AskpassCall>(&line) {
        let reply = crate::askpass::serve(core, call, peer_uid, reader).await;
        let mut encoded = serde_json::to_vec(&reply).map_err(io::Error::other)?;
        drop(reply);
        encoded.push(b'\n');
        let written = write.write_all(&encoded).await;
        zeroize::Zeroize::zeroize(&mut encoded);
        written?;
        return write.shutdown().await;
    }
    // So do the browser helper and tools.
    if let Ok(call) = serde_json::from_str::<crate::browser::BrowserCall>(&line) {
        let reply = crate::browser::serve(core, call, peer_uid, reader).await;
        let mut encoded = serde_json::to_vec(&reply).map_err(io::Error::other)?;
        encoded.push(b'\n');
        write.write_all(&encoded).await?;
        return write.shutdown().await;
    }
    // So do the terminal tools.
    if let Ok(call) = serde_json::from_str::<crate::term::TermCall>(&line) {
        let reply = crate::term::serve(core, call, peer_uid, reader).await;
        let mut encoded = serde_json::to_vec(&reply).map_err(io::Error::other)?;
        encoded.push(b'\n');
        write.write_all(&encoded).await?;
        return write.shutdown().await;
    }
    // So does the MCP pull channel (§7.12).
    if let Ok(call) = serde_json::from_str::<crate::art::pull::PullCall>(&line) {
        let reply = crate::art::pull::serve(core, call).await;
        let mut encoded = serde_json::to_vec(&reply).map_err(io::Error::other)?;
        encoded.push(b'\n');
        write.write_all(&encoded).await?;
        return write.shutdown().await;
    }
    // And the local restart into an installed build (`gudo-hostd restart`).
    if let Ok(call) = serde_json::from_str::<crate::upgrade::RestartCall>(&line) {
        let reply = crate::upgrade::serve_restart(core, &call).await;
        let mut encoded = serde_json::to_vec(&reply).map_err(io::Error::other)?;
        encoded.push(b'\n');
        let written = write.write_all(&encoded).await;
        let _ = write.shutdown().await;
        crate::upgrade::after_restart_reply(core, &reply);
        return written;
    }
    let request: HookRequest = serde_json::from_str(&line).map_err(io::Error::other)?;
    let response = handle_hook(core, request).await;
    let mut encoded = serde_json::to_vec(&response).map_err(io::Error::other)?;
    encoded.push(b'\n');
    write.write_all(&encoded).await?;
    write.shutdown().await
}

async fn handle_hook(core: &Arc<Core>, request: HookRequest) -> HookResponse {
    if !core.hooks.verify(&request.token, &request.pane) {
        tracing::warn!("hook with a bad token");
        return HookResponse::default();
    }
    // Claude Code's status-line input (not a hook): its plan limits. The shim prints the
    // user's own status line itself.
    let Some(pane_id) = request.pane.parse().ok().map(PaneId) else {
        return HookResponse::default();
    };
    if request.event == STATUS_LINE_EVENT {
        // It counts for the account of the pane that sent it.
        let account = core
            .pane_account(pane_id)
            .filter(|(agent, _)| *agent == AgentKind::Claude)
            .map_or_else(|| proto::SYSTEM_ACCOUNT.to_owned(), |(_, id)| id);
        core.ws.usage.status_line(&account, &request.payload);
        return HookResponse::default();
    }
    // A sign-in pane's login ended: ask the agent who is signed in now.
    if request.agent == ACCOUNT_HOOK {
        if request.event == SIGN_IN_EVENT
            && let Some((agent, account)) = core.ws.accounts.sign_in_of(pane_id)
        {
            core.check_account(agent, account);
        }
        return HookResponse::default();
    }
    let Some(entry) = core.pane(pane_id) else {
        return HookResponse::default();
    };
    let payload = serde_json::to_vec(&request.payload).unwrap_or_default();
    let mut attached = None;
    let (event, blocked) = {
        let mut agent = lock(&entry.agent);
        // A late SessionEnd must not bring back an agent that already exited.
        if request.event == "SessionEnd"
            && agent
                .as_ref()
                .is_some_and(|runtime| Some(runtime.kind()) != agent_kind(&request.agent))
        {
            return HookResponse::default();
        }
        if request.event != "SessionEnd"
            && let Some(kind) = agent_kind(&request.agent)
            && agent.as_ref().is_none_or(|runtime| runtime.kind() != kind)
        {
            *agent = Some(AgentRuntime::new(kind, pane_id, adapter(kind), false));
            entry.agent_attached.notify_one();
            attached = Some(kind);
        }
        let Some(runtime) = agent.as_mut() else {
            return HookResponse::default();
        };
        let event = runtime.hook(&payload, request.seq);
        // Register wire ids now so a client can answer as soon as it sees the event.
        let _ = runtime.wire_status();
        (event, runtime.blocked_request())
    };
    if let Some(kind) = attached {
        crate::core::record_agent_started_by_hand(core, &entry, kind, None);
    }
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
            agent: agent_kind(&request.agent),
            tool: request
                .payload
                .get("tool_name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            input: request
                .payload
                .get("tool_input")
                .cloned()
                .unwrap_or(Value::Null),
            reply: tx,
        },
    );
    // An auto-approve rule may answer at once; otherwise clients learn what they may do.
    crate::approve::request_held(core, pane_id);
    match tokio::time::timeout(PERMISSION_WAIT, rx).await {
        Ok(Ok(response)) => response,
        // No decision: the agent falls back to its own prompt in the terminal.
        _ => HookResponse::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_app_names_are_recognised() {
        let report = |body| agents::ProgramStatus::parse(body).unwrap();
        assert!(names_an_agent(&report("state=blocked:app=claude-code")));
        assert!(names_an_agent(&report("state=working:app=codex")));
        for app in [
            "claude",
            "Claude-Code",
            "CODEX",
            "codex-cli",
            "-claude",
            "claude.exe",
        ] {
            let body = format!("state=blocked:app={app}");
            let report = agents::ProgramStatus::parse(&body).unwrap();
            assert!(names_an_agent(&report), "{app}");
        }
        assert!(!names_an_agent(&report("state=working:app=terraform")));
        assert!(!names_an_agent(&report("state=working")));
    }

    fn runtime() -> AgentRuntime {
        AgentRuntime::new(
            AgentKind::Claude,
            PaneId(1),
            adapter(AgentKind::Claude),
            false,
        )
    }

    fn job(pid: u32, program: &str) -> pty::ForegroundProcess {
        pty::ForegroundProcess {
            pid,
            name: program.into(),
            argv: vec![program.into()],
        }
    }

    #[test]
    fn only_this_user_may_use_the_hook_socket() {
        // SAFETY: getuid has no preconditions and cannot fail.
        let me = unsafe { libc::getuid() };
        assert!(same_user(Some(me)));
        assert!(!same_user(Some(me + 1)));
        assert!(!same_user(None), "a peer of unknown uid is refused");
    }

    #[test]
    fn a_long_state_dir_puts_the_socket_in_a_private_dir() {
        let base = tempfile::tempdir().unwrap();
        let deep = base.path().join("x".repeat(60)).join("y".repeat(60));
        std::fs::create_dir_all(&deep).unwrap();
        let hooks = HookServer::new(&deep, "/bin/true".into()).unwrap();
        let dir = hooks.socket().parent().unwrap().to_owned();
        assert!(!dir.starts_with(&deep));
        let mode = std::fs::metadata(&dir).unwrap().permissions().mode();
        std::fs::remove_dir(&dir).unwrap();
        assert_eq!(mode & 0o777, 0o700, "{}", dir.display());
    }

    #[test]
    fn the_shell_before_the_agent_starts_is_not_an_exit() {
        let mut runtime = runtime();
        assert!(!runtime.process_gone(Some(&job(10, "zsh")), false, |_| false));
    }

    #[test]
    fn an_agent_never_seen_ends_at_the_shell() {
        let mut runtime = runtime();
        assert!(runtime.process_gone(Some(&job(10, "zsh")), true, |_| false));
    }

    #[test]
    fn the_agent_exiting_back_to_the_shell_is_an_exit() {
        let mut runtime = runtime();
        assert!(!runtime.process_gone(Some(&job(20, "claude")), false, |_| true));
        assert!(runtime.process_gone(Some(&job(10, "zsh")), true, |_| false));
    }

    #[test]
    fn a_suspended_agent_is_still_running() {
        let mut runtime = runtime();
        assert!(!runtime.process_gone(Some(&job(20, "claude")), false, |_| true));
        assert!(!runtime.process_gone(Some(&job(10, "zsh")), true, |pid| pid == 20));
        assert!(!runtime.process_gone(None, false, |pid| pid == 20));
    }
}
