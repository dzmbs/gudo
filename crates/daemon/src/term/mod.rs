//!
//! `un-hook mcp` (and `un-hook term`) send one [`TermCall`] line on the hook socket per tool
//! call; the daemon answers one [`TermReply`] line. The caller is the pane named in the call,
//! proven by its own token (`UN_TOKEN`), and omitted targets mean that pane.
//!
//! What a caller may do: read any pane of its own session; type into, run in and close only
//! the panes it created (or that those created), never its own; split and open tabs next to
//! itself. Nothing it opens takes focus from the user. Input is refused at a password prompt.

mod output;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{
    AgentKind, Axis, CommandMark, InputPayload, KeyAction, KeyEvent, LayoutOp, OpOutcome, PaneId,
    PaneLaunch, Seq, SessionId, TabId,
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::time::Instant;

use crate::assist::marks::Phase;
use crate::core::{Core, PaneEntry, lock};

pub use output::Output;

/// The protocol version in [`TermCall::v`].
pub const TERM_VERSION: u32 = 1;

const DEFAULT_WAIT: Duration = Duration::from_secs(30);
const MAX_WAIT: Duration = Duration::from_secs(240);
const DEFAULT_MAX_BYTES: usize = 16 * 1024;
const MAX_BYTES: usize = 256 * 1024;
const DEFAULT_TAIL: usize = 80;
/// How long a new pane's shell gets to draw its first prompt before a command is typed anyway.
const PROMPT_WAIT: Duration = Duration::from_secs(10);
/// How long after typing a command its start mark may take before the shell is taken to have
/// no integration.
const START_WAIT: Duration = Duration::from_secs(2);
const TICK: Duration = Duration::from_millis(50);

/// What the shim sends on the hook socket: one JSON line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TermCall {
    /// [`TERM_VERSION`].
    pub v: u32,
    /// The pane's token.
    pub token: String,
    /// The calling pane's id from its environment.
    pub pane: String,
    /// The tool and its arguments.
    pub term: TermAsk,
}

/// One tool call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TermAsk {
    /// `pane_split`, `cmd_run`, …
    pub tool: String,
    /// A JSON object.
    #[serde(default)]
    pub args: Value,
}

/// The daemon's answer: one JSON line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TermReply {
    /// The tool's structured result.
    Ok(Value),
    /// Why it did nothing.
    Error(ToolError),
}

/// A refusal or failure the agent can act on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolError {
    pub code: ErrorCode,
    pub message: String,
    /// Trying again unchanged may work.
    pub retryable: bool,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidArgs,
    NotFound,
    /// Not the caller's to do; the user can do it, or open a pane the caller owns.
    Forbidden,
    /// A command is already running there.
    PaneBusy,
    /// The program is asking for a password: input is the user's.
    SecretPrompt,
    /// The output asked for has left the pane's buffer.
    CursorExpired,
    /// The pane has exited.
    Closed,
    /// The agent waits on the user (an approval, a question, a sign-in).
    AgentBlocked,
    /// The agent is still working, or not ready for a prompt yet.
    AgentBusy,
    Failed,
}

impl ToolError {
    fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: false,
            hint: None,
        }
    }

    fn hint(mut self, hint: impl Into<String>) -> Self {
        self.hint = Some(hint.into());
        self
    }
}

type Result<T> = std::result::Result<T, ToolError>;

/// Which pane created which, for ownership.
#[derive(Default)]
pub(crate) struct Term {
    creators: Mutex<HashMap<PaneId, PaneId>>,
}

impl Term {
    /// Whether `caller` created `pane`, directly or through panes it created.
    fn owns(&self, caller: PaneId, pane: PaneId) -> bool {
        let creators = lock(&self.creators);
        let mut at = pane;
        // A chain is at most as long as there are panes; the bound guards a cycle.
        for _ in 0..=creators.len() {
            match creators.get(&at) {
                Some(&creator) if creator == caller => return true,
                Some(&creator) => at = creator,
                None => return false,
            }
        }
        false
    }

    fn created(&self, caller: PaneId, pane: PaneId) {
        lock(&self.creators).insert(pane, caller);
    }

    pub fn forget(&self, pane: PaneId) {
        lock(&self.creators).remove(&pane);
    }
}

/// Answers one call.
pub(crate) async fn serve(core: &Arc<Core>, call: TermCall, peer_uid: Option<u32>) -> TermReply {
    if !core.hooks.verify(&call.token, &call.pane) {
        tracing::warn!("term call with a bad token");
        return TermReply::Error(ToolError::new(ErrorCode::Forbidden, "bad token"));
    }
    // SAFETY: getuid has no preconditions and cannot fail.
    if peer_uid.is_some_and(|uid| uid != unsafe { libc::getuid() }) {
        return TermReply::Error(ToolError::new(ErrorCode::Forbidden, "another user"));
    }
    if call.v != TERM_VERSION {
        return TermReply::Error(ToolError::new(
            ErrorCode::InvalidArgs,
            format!("unsupported term version {}", call.v),
        ));
    }
    let Some(caller) = call
        .pane
        .parse()
        .ok()
        .map(PaneId)
        .filter(|p| core.pane(*p).is_some())
    else {
        return TermReply::Error(ToolError::new(
            ErrorCode::NotFound,
            "the calling pane is gone",
        ));
    };
    let ctx = Ctx {
        core: Arc::clone(core),
        caller,
    };
    match ctx.call(&call.term.tool, call.term.args).await {
        Ok(value) => TermReply::Ok(value),
        Err(e) => TermReply::Error(e),
    }
}

struct Ctx {
    core: Arc<Core>,
    caller: PaneId,
}

fn args<T: for<'de> Deserialize<'de>>(value: Value) -> Result<T> {
    let value = if value.is_null() { json!({}) } else { value };
    serde_json::from_value(value).map_err(|e| ToolError::new(ErrorCode::InvalidArgs, e.to_string()))
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ListArgs {
    #[serde(default)]
    scope: ListScope,
}

#[derive(Deserialize, Default, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum ListScope {
    Tab,
    #[default]
    Session,
}

#[derive(Deserialize, Default, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum Direction {
    #[default]
    Right,
    Down,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SplitArgs {
    #[serde(default)]
    of: Option<String>,
    #[serde(default)]
    direction: Direction,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    agent: Option<AgentName>,
    #[serde(default)]
    focus: bool,
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum AgentName {
    Claude,
    Codex,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TabArgs {
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    focus: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PaneArg {
    pane: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RunArgs {
    command: String,
    #[serde(default)]
    pane: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    timeout_ms: Option<u64>,
    #[serde(default)]
    max_bytes: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReadArgs {
    #[serde(default)]
    pane: Option<String>,
    #[serde(default)]
    since: Option<String>,
    #[serde(default)]
    command: Option<CommandRef>,
    #[serde(default)]
    screen: bool,
    #[serde(default)]
    tail: Option<usize>,
    #[serde(default)]
    grep: Option<String>,
    #[serde(default)]
    context: usize,
    #[serde(default)]
    max_bytes: Option<usize>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum CommandRef {
    Id(u64),
    Name(String),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WaitArgs {
    #[serde(default)]
    pane: Option<String>,
    #[serde(default, rename = "match")]
    pattern: Option<String>,
    #[serde(default)]
    since: Option<String>,
    #[serde(default)]
    prompt: bool,
    #[serde(default)]
    quiet_ms: Option<u64>,
    #[serde(default)]
    exit: Option<u64>,
    /// Until the program reports one of these states (`blocked`, `done`, …).
    #[serde(default)]
    status: Vec<String>,
    #[serde(default)]
    timeout_ms: Option<u64>,
    #[serde(default)]
    max_bytes: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SpawnArgs {
    kind: AgentName,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    of: Option<String>,
    #[serde(default)]
    direction: Direction,
    #[serde(default)]
    timeout_ms: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PromptArgs {
    pane: String,
    text: String,
    #[serde(default)]
    wait: bool,
    #[serde(default)]
    timeout_ms: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AgentWaitArgs {
    panes: Vec<String>,
    #[serde(default)]
    until: Vec<String>,
    #[serde(default)]
    all: bool,
    #[serde(default)]
    timeout_ms: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StatusArgs {
    state: String,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    progress: Option<u8>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SendArgs {
    pane: String,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    keys: Vec<String>,
    #[serde(default)]
    submit: bool,
}

/// A command as tools report it.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CommandInfo {
    id: u64,
    pane: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    command: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cwd: Option<String>,
    status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    duration_ms: Option<u64>,
}

impl CommandInfo {
    fn of(mark: &CommandMark) -> Self {
        Self {
            id: mark.command_id,
            pane: pane_ref(mark.pane_id),
            command: mark.command.clone(),
            cwd: mark.cwd.clone(),
            status: if mark.finished.is_some() {
                "exited"
            } else {
                "running"
            },
            exit_code: mark.finished.and_then(|f| f.exit),
            duration_ms: mark.finished.map(|f| f.duration_ms),
        }
    }
}

fn pane_ref(id: PaneId) -> String {
    format!("p{}", id.0)
}

fn tab_ref(id: TabId) -> String {
    format!("t{}", id.0)
}

fn wait_for(timeout_ms: Option<u64>) -> Duration {
    timeout_ms
        .map_or(DEFAULT_WAIT, Duration::from_millis)
        .min(MAX_WAIT)
}

fn max_bytes(asked: Option<usize>) -> usize {
    asked.unwrap_or(DEFAULT_MAX_BYTES).clamp(256, MAX_BYTES)
}

impl Ctx {
    async fn call(&self, tool: &str, value: Value) -> Result<Value> {
        match tool {
            "whoami" => self.whoami(),
            "pane_list" => self.pane_list(args(value)?),
            "pane_split" => self.pane_split(args(value)?).await,
            "tab_new" => self.tab_new(args(value)?).await,
            "pane_close" => self.pane_close(args(value)?),
            "cmd_run" => self.cmd_run(args(value)?).await,
            "pane_read" => self.pane_read(args(value)?).await,
            "pane_wait" => self.pane_wait(args(value)?).await,
            "pane_send" => self.pane_send(args(value)?).await,
            "status_set" => self.status_set(args(value)?),
            "agent_spawn" => self.agent_spawn(args(value)?).await,
            "agent_prompt" => self.agent_prompt(args(value)?).await,
            "agent_wait" => self.agent_wait(args(value)?).await,
            "agent_result" => self.agent_result(args(value)?),
            other => Err(ToolError::new(
                ErrorCode::NotFound,
                format!("no tool {other}"),
            )),
        }
    }

    // --- targets and permissions -----------------------------------------------------------

    /// `self`, `p12` or `12`.
    fn resolve(&self, target: Option<&str>) -> Result<(PaneId, Arc<PaneEntry>)> {
        let id = match target.map(str::trim) {
            None | Some("" | "self") => self.caller,
            Some(t) => t
                .strip_prefix('p')
                .unwrap_or(t)
                .parse()
                .map(PaneId)
                .map_err(|_| {
                    ToolError::new(ErrorCode::InvalidArgs, format!("{t} is not a pane id"))
                        .hint("pane ids look like p12; pane_list lists them")
                })?,
        };
        let entry = self.core.pane(id).ok_or_else(|| {
            ToolError::new(ErrorCode::NotFound, format!("no pane {}", pane_ref(id)))
                .hint("pane_list lists the panes you can reach")
        })?;
        Ok((id, entry))
    }

    fn session(&self) -> Option<SessionId> {
        self.core.session_of_pane(self.caller)
    }

    fn may_read(&self, pane: PaneId) -> Result<()> {
        if self.core.session_of_pane(pane) == self.session() {
            return Ok(());
        }
        Err(ToolError::new(
            ErrorCode::Forbidden,
            format!("{} is in another session", pane_ref(pane)),
        ))
    }

    fn may_drive(&self, pane: PaneId) -> Result<()> {
        if pane == self.caller {
            return Err(
                ToolError::new(ErrorCode::Forbidden, "that is your own pane")
                    .hint("run commands in a pane of your own: cmd_run without a pane opens one"),
            );
        }
        if self.core.term.owns(self.caller, pane) {
            return Ok(());
        }
        Err(
            ToolError::new(ErrorCode::Forbidden, format!("{} is the user's", pane_ref(pane)))
                .hint("you may read it; to run something, open your own pane (pane_split or cmd_run without a pane)"),
        )
    }

    // --- discovery --------------------------------------------------------------------------

    fn pane_info(&self, id: PaneId, entry: &PaneEntry) -> Value {
        let meta = self.core.pane_meta(id);
        let line = entry.pane.line_snapshot();
        let commands = entry.pane.commands(None).commands;
        let last = commands.last().map(|c| CommandInfo::of(&c.mark));
        let kind = match &lock(&entry.record).launch {
            PaneLaunch::Agent { .. } => "agent",
            PaneLaunch::Command { .. } => "command",
            _ => "shell",
        };
        let foreground = self
            .core
            .assist
            .foreground(id)
            .map(|f| json!({ "pid": f.pid, "name": f.name }));
        let session = self.core.session_of_pane(id).unwrap_or_default();
        let tab = lock(&self.core.layout).snapshot(session);
        let tab_id = tab.and_then(|s| {
            s.tabs
                .iter()
                .find(|t| crate::layout::leaves(&t.root).any(|l| l == id))
                .map(|t| tab_ref(t.tab_id))
        });
        let owned = self.core.term.owns(self.caller, id);
        let mut scopes = vec!["read"];
        if owned {
            scopes.extend(["input", "manage"]);
        }
        json!({
            "id": pane_ref(id),
            "tab": tab_id,
            "title": meta.as_ref().map(|m| m.title.clone()).unwrap_or_default(),
            "cwd": meta.as_ref().and_then(|m| m.cwd.clone()),
            "kind": kind,
            "isSelf": id == self.caller,
            "createdByYou": owned,
            "scopes": scopes,
            "atPrompt": line.view.phase == Phase::Prompt,
            "altScreen": line.alt,
            "secretPrompt": entry.pane.echo().is_hidden_input(),
            "exited": meta.as_ref().and_then(|m| m.exit).is_some(),
            "foreground": foreground,
            "lastCommand": last,
            "status": status(&self.core, id, entry),
            "cursor": output::cursor(entry.pane.head()),
        })
    }

    fn whoami(&self) -> Result<Value> {
        let (id, entry) = self.resolve(None)?;
        let session = self.session();
        let layout = session.and_then(|s| lock(&self.core.layout).snapshot(s));
        Ok(json!({
            "pane": self.pane_info(id, &entry),
            "session": layout.as_ref().map(|l| json!({ "id": format!("s{}", l.session_id.0), "name": l.name })),
            "host": crate::info::hostname(),
            "limits": {
                "maxWaitMs": MAX_WAIT.as_millis() as u64,
                "maxOutputBytes": MAX_BYTES,
            },
            "protocol": TERM_VERSION,
        }))
    }

    fn pane_list(&self, a: ListArgs) -> Result<Value> {
        let Some(session) = self.session() else {
            return Ok(json!({ "panes": [] }));
        };
        let Some(layout) = lock(&self.core.layout).snapshot(session) else {
            return Ok(json!({ "panes": [] }));
        };
        let my_tab = layout
            .tabs
            .iter()
            .find(|t| crate::layout::leaves(&t.root).any(|l| l == self.caller))
            .map(|t| t.tab_id);
        let panes: Vec<Value> = layout
            .tabs
            .iter()
            .filter(|t| matches!(a.scope, ListScope::Session) || Some(t.tab_id) == my_tab)
            .flat_map(|t| crate::layout::leaves(&t.root).collect::<Vec<_>>())
            .filter_map(|id| self.core.pane(id).map(|e| self.pane_info(id, &e)))
            .collect();
        Ok(json!({ "panes": panes }))
    }

    // --- layout -----------------------------------------------------------------------------

    fn launch(
        command: Option<String>,
        agent: Option<AgentName>,
        cwd: Option<String>,
    ) -> PaneLaunch {
        match (agent, command) {
            (Some(agent), _) => PaneLaunch::Agent {
                agent: match agent {
                    AgentName::Claude => AgentKind::Claude,
                    AgentName::Codex => AgentKind::Codex,
                },
                resume: None,
                cwd,
            },
            (None, Some(command)) => PaneLaunch::Command {
                argv: vec![command],
                cwd,
            },
            (None, None) => PaneLaunch::Shell { cwd },
        }
    }

    /// The focused pane of `pane`'s tab, to give focus back after a change the user did not
    /// ask for.
    fn focused_in_tab_of(&self, pane: PaneId) -> Option<PaneId> {
        let session = self.core.session_of_pane(pane)?;
        let layout = lock(&self.core.layout).snapshot(session)?;
        layout
            .tabs
            .iter()
            .find(|t| crate::layout::leaves(&t.root).any(|l| l == pane))
            .map(|t| t.focused)
    }

    async fn pane_split(&self, a: SplitArgs) -> Result<Value> {
        let (of, _) = self.resolve(a.of.as_deref())?;
        self.may_read(of)?;
        let pane = self.split(
            of,
            a.direction,
            Self::launch(a.command, a.agent, a.cwd),
            a.focus,
        )?;
        let entry = self.core.pane(pane).ok_or_else(closed)?;
        Ok(json!({ "pane": self.pane_info(pane, &entry) }))
    }

    fn split(
        &self,
        of: PaneId,
        direction: Direction,
        launch: PaneLaunch,
        focus: bool,
    ) -> Result<PaneId> {
        let focused = self.focused_in_tab_of(of);
        let axis = match direction {
            Direction::Right => Axis::Horizontal,
            Direction::Down => Axis::Vertical,
        };
        let pane = match self.core.apply_op(LayoutOp::Split {
            pane_id: of,
            axis,
            launch,
        }) {
            OpOutcome::PaneCreated { pane_id } => pane_id,
            OpOutcome::Failed { message, .. } => {
                return Err(ToolError::new(ErrorCode::Failed, message));
            }
            other => return Err(ToolError::new(ErrorCode::Failed, format!("{other:?}"))),
        };
        self.core.term.created(self.caller, pane);
        if !focus && let Some(focused) = focused {
            self.core.apply_op(LayoutOp::Focus { pane_id: focused });
        }
        Ok(pane)
    }

    async fn tab_new(&self, a: TabArgs) -> Result<Value> {
        let session = self.session().ok_or_else(closed)?;
        let before = lock(&self.core.layout)
            .snapshot(session)
            .and_then(|l| l.active_tab);
        let (tab, pane) = match self.core.apply_op(LayoutOp::NewTab {
            session_id: session,
            name: a.title.unwrap_or_default(),
            launch: Self::launch(a.command, None, a.cwd),
        }) {
            OpOutcome::TabCreated { tab_id, pane_id } => (tab_id, pane_id),
            OpOutcome::Failed { message, .. } => {
                return Err(ToolError::new(ErrorCode::Failed, message));
            }
            other => return Err(ToolError::new(ErrorCode::Failed, format!("{other:?}"))),
        };
        self.core.term.created(self.caller, pane);
        if !a.focus
            && let Some(before) = before
        {
            self.core.apply_op(LayoutOp::SelectTab { tab_id: before });
        }
        let entry = self.core.pane(pane).ok_or_else(closed)?;
        Ok(json!({ "tab": tab_ref(tab), "pane": self.pane_info(pane, &entry) }))
    }

    fn pane_close(&self, a: PaneArg) -> Result<Value> {
        let Ok((pane, _)) = self.resolve(Some(&a.pane)) else {
            return Ok(json!({ "closed": false, "alreadyClosed": true }));
        };
        self.may_drive(pane)?;
        match self.core.apply_op(LayoutOp::ClosePane { pane_id: pane }) {
            OpOutcome::Failed { message, .. } => Err(ToolError::new(ErrorCode::Failed, message)),
            _ => {
                self.core.term.forget(pane);
                Ok(json!({ "closed": true, "alreadyClosed": false }))
            }
        }
    }

    // --- output -----------------------------------------------------------------------------

    /// The output from `since` to now, rendered.
    async fn output_since(&self, entry: &PaneEntry, since: Seq) -> Result<(String, Seq)> {
        let head = entry.pane.head();
        let mut sub = entry.pane.subscribe_from(since).map_err(|e| {
            ToolError::new(ErrorCode::CursorExpired, e.to_string())
                .hint("read the latest with `tail`, then follow with the cursor it returns")
        })?;
        let mut bytes = Vec::new();
        while sub.position().get() < head.0 {
            match tokio::time::timeout(Duration::from_secs(1), sub.recv()).await {
                Ok(Ok(chunk)) => bytes.extend_from_slice(&chunk.data),
                _ => break,
            }
        }
        Ok((
            output::render(&bytes, entry.pane.size().cols),
            position(&sub),
        ))
    }

    /// The last `lines` lines, scrollback included.
    async fn tail(&self, entry: &PaneEntry, lines: usize) -> Result<(String, Seq)> {
        let head = entry.pane.head();
        let start = Seq(head.0.saturating_sub(MAX_BYTES as u64 * 4));
        let start = match entry.pane.subscribe_from(start) {
            Ok(_) => start,
            Err(pty::ReadError::Evicted { oldest, .. }) => Seq(oldest.get()),
            Err(_) => head,
        };
        let (text, at) = self.output_since(entry, start).await?;
        let keep: Vec<&str> = text.lines().collect();
        let from = keep.len().saturating_sub(lines);
        Ok((keep[from..].join("\n"), at))
    }

    async fn pane_read(&self, a: ReadArgs) -> Result<Value> {
        let (pane, entry) = self.resolve(a.pane.as_deref())?;
        self.may_read(pane)?;
        let max = max_bytes(a.max_bytes);
        let alt = entry.pane.alt_screen();
        let mut command = None;
        let (mut text, at) = if let Some(since) = &a.since {
            let since = output::parse_cursor(since).ok_or_else(|| {
                ToolError::new(ErrorCode::InvalidArgs, "a cursor looks like c1234")
            })?;
            self.output_since(&entry, since).await?
        } else if let Some(which) = a.command {
            let id = match which {
                CommandRef::Id(id) => Some(id),
                CommandRef::Name(name) if name == "last" => None,
                CommandRef::Name(name) => name.trim_start_matches('c').parse().ok(),
            };
            let out = entry.pane.command_output(None, id).map_err(|_| {
                ToolError::new(ErrorCode::NotFound, "no such command")
                    .hint("commands are known where the shell has integration (bash, zsh, fish)")
            })?;
            command = Some(CommandInfo::of(&out.mark));
            (out.text, entry.pane.head())
        } else if a.screen || alt {
            (entry.pane.screen_text(), entry.pane.head())
        } else {
            self.tail(&entry, a.tail.unwrap_or(DEFAULT_TAIL)).await?
        };
        if let Some(pattern) = &a.grep {
            let re = Regex::new(pattern)
                .map_err(|e| ToolError::new(ErrorCode::InvalidArgs, e.to_string()))?;
            text = output::grep(&text, &re, a.context);
        }
        let line = entry.pane.line_snapshot();
        Ok(json!({
            "output": Output::new(text, max, at),
            "altScreen": alt,
            "atPrompt": line.view.phase == Phase::Prompt,
            "command": command,
        }))
    }

    // --- running and waiting ----------------------------------------------------------------

    async fn cmd_run(&self, a: RunArgs) -> Result<Value> {
        if a.command.trim().is_empty() {
            return Err(ToolError::new(ErrorCode::InvalidArgs, "no command"));
        }
        let (pane, entry) = match &a.pane {
            Some(target) => {
                let (pane, entry) = self.resolve(Some(target))?;
                self.may_drive(pane)?;
                (pane, entry)
            }
            None => {
                let launch = PaneLaunch::Shell { cwd: a.cwd.clone() };
                let pane = self.split(self.caller, Direction::Down, launch, false)?;
                (pane, self.core.pane(pane).ok_or_else(closed)?)
            }
        };
        let deadline = Instant::now() + wait_for(a.timeout_ms);
        // A new shell first draws its prompt; typing before that lands in its startup.
        let prompt_by = Instant::now() + PROMPT_WAIT.min(wait_for(a.timeout_ms));
        while entry.pane.line_snapshot().view.phase == Phase::Idle && Instant::now() < prompt_by {
            tokio::time::sleep(TICK).await;
        }
        match entry.pane.line_snapshot().view.phase {
            Phase::Running(_) => {
                return Err(ToolError::new(
                    ErrorCode::PaneBusy,
                    format!("{} is running a command", pane_ref(pane)),
                )
                .hint("wait for it with pane_wait {prompt: true}, or run in a new pane"));
            }
            _ if entry.pane.echo().is_hidden_input() => return Err(secret_prompt(pane)),
            _ => {}
        }
        let before = entry
            .pane
            .commands(None)
            .commands
            .last()
            .map(|c| c.mark.command_id);
        let start = entry.pane.head();
        let mut line = a.command.clone();
        if let Some(cwd) = a.cwd.as_deref().filter(|_| a.pane.is_some()) {
            line = format!("cd {} && {line}", crate::core::shell_quote(cwd));
        }
        write(&entry, entry.pane.encode_input(InputPayload::Paste(line))).await?;
        tokio::time::sleep(Duration::from_millis(30)).await;
        write(&entry, b"\r".to_vec()).await?;
        let max = max_bytes(a.max_bytes);

        // The command's own mark, once the shell reports it.
        let started_by = Instant::now() + START_WAIT;
        let mark = loop {
            let newest = entry.pane.commands(None).commands.pop().map(|c| c.mark);
            if let Some(mark) = newest.filter(|m| Some(m.command_id) > before) {
                if mark.finished.is_some() || Instant::now() >= deadline {
                    break Some(mark);
                }
            } else if Instant::now() >= started_by.min(deadline) {
                break None;
            }
            tokio::time::sleep(TICK).await;
        };
        let Some(mark) = mark else {
            // No integration: settle on a quiet pane instead.
            let status = wait_quiet(&entry, Duration::from_millis(500), deadline).await;
            let (text, at) = self.output_since(&entry, start).await?;
            return Ok(json!({
                "pane": pane_ref(pane),
                "status": if status { "unknown" } else { "timeout" },
                "output": Output::new(text, max, at),
                "note": "this shell does not report commands, so there is no exit code",
            }));
        };
        let finished = mark.finished.is_some();
        let output = if finished {
            let out = entry.pane.command_output(None, Some(mark.command_id)).ok();
            out.map(|o| Output::new(o.text, max, entry.pane.head()))
        } else {
            let (text, at) = self.output_since(&entry, start).await?;
            Some(Output::new(text, max, at))
        };
        Ok(json!({
            "pane": pane_ref(pane),
            "command": CommandInfo::of(&mark),
            "status": if finished { "exited" } else { "timeout" },
            "output": output,
        }))
    }

    async fn pane_wait(&self, a: WaitArgs) -> Result<Value> {
        let (pane, entry) = self.resolve(a.pane.as_deref())?;
        self.may_read(pane)?;
        let re = a
            .pattern
            .as_deref()
            .map(Regex::new)
            .transpose()
            .map_err(|e| ToolError::new(ErrorCode::InvalidArgs, e.to_string()))?;
        if re.is_none()
            && !a.prompt
            && a.quiet_ms.is_none()
            && a.exit.is_none()
            && a.status.is_empty()
        {
            return Err(ToolError::new(
                ErrorCode::InvalidArgs,
                "wait for what? give match, prompt, quietMs, exit or status",
            ));
        }
        if let Some(bad) = a
            .status
            .iter()
            .find(|s| agents::ProgramState::parse(s).is_none())
        {
            return Err(
                ToolError::new(ErrorCode::InvalidArgs, format!("no status {bad}"))
                    .hint("statuses are idle, working, done, blocked and error"),
            );
        }
        let since = match &a.since {
            Some(c) => output::parse_cursor(c).ok_or_else(|| {
                ToolError::new(ErrorCode::InvalidArgs, "a cursor looks like c1234")
            })?,
            None => entry.pane.head(),
        };
        let deadline = Instant::now() + wait_for(a.timeout_ms);
        let max = max_bytes(a.max_bytes);
        let mut sub = entry
            .pane
            .subscribe_from(since)
            .map_err(|e| ToolError::new(ErrorCode::CursorExpired, e.to_string()))?;
        let mut bytes = Vec::new();
        let mut last_output = Instant::now();
        let cols = entry.pane.size().cols;
        loop {
            // Each condition is checked against the state after the newest output.
            let mut text = None;
            if let Some(re) = &re {
                let rendered = output::render(&bytes, cols);
                if let Some(found) = rendered.lines().find_map(|l| {
                    re.captures(l).map(|c| {
                        (
                            l.to_owned(),
                            c.iter()
                                .skip(1)
                                .map(|g| g.map(|g| g.as_str().to_owned()))
                                .collect::<Vec<_>>(),
                        )
                    })
                }) {
                    return Ok(json!({
                        "status": "matched",
                        "match": { "line": found.0, "groups": found.1 },
                        "output": Output::new(rendered, max, position(&sub)),
                    }));
                }
                text = Some(rendered);
            }
            if !a.status.is_empty() {
                let now = status(&self.core, pane, &entry);
                if now["state"]
                    .as_str()
                    .is_some_and(|s| a.status.iter().any(|w| w == s))
                {
                    let mut done = self.waited(
                        "status",
                        text.clone(),
                        &bytes,
                        cols,
                        max,
                        position(&sub),
                        None,
                    )?;
                    done["programStatus"] = now;
                    return Ok(done);
                }
            }
            let phase = entry.pane.line_snapshot().view.phase;
            if a.prompt && phase == Phase::Prompt {
                let last = entry
                    .pane
                    .commands(None)
                    .commands
                    .last()
                    .map(|c| CommandInfo::of(&c.mark));
                return self.waited("prompt", text, &bytes, cols, max, position(&sub), last);
            }
            if let Some(id) = a.exit {
                let mark = entry
                    .pane
                    .commands(None)
                    .commands
                    .into_iter()
                    .map(|c| c.mark)
                    .find(|m| m.command_id == id);
                match mark {
                    Some(m) if m.finished.is_some() => {
                        return self.waited(
                            "exited",
                            text,
                            &bytes,
                            cols,
                            max,
                            position(&sub),
                            Some(CommandInfo::of(&m)),
                        );
                    }
                    None => {
                        return Err(ToolError::new(
                            ErrorCode::NotFound,
                            format!("no command c{id}"),
                        ));
                    }
                    _ => {}
                }
            }
            if let Some(quiet) = a.quiet_ms
                && last_output.elapsed() >= Duration::from_millis(quiet)
            {
                return self.waited("quiet", text, &bytes, cols, max, position(&sub), None);
            }
            if self.core.pane_meta(pane).and_then(|m| m.exit).is_some() {
                return self.waited("closed", text, &bytes, cols, max, position(&sub), None);
            }
            let now = Instant::now();
            if now >= deadline {
                return self.waited("timeout", text, &bytes, cols, max, position(&sub), None);
            }
            match tokio::time::timeout(TICK.min(deadline - now), sub.recv()).await {
                Ok(Ok(chunk)) => {
                    bytes.extend_from_slice(&chunk.data);
                    last_output = Instant::now();
                }
                Ok(Err(_)) => tokio::time::sleep(TICK).await,
                Err(_) => {}
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn waited(
        &self,
        status: &str,
        text: Option<String>,
        bytes: &[u8],
        cols: u16,
        max: usize,
        at: Seq,
        command: Option<CommandInfo>,
    ) -> Result<Value> {
        let text = text.unwrap_or_else(|| output::render(bytes, cols));
        Ok(json!({ "status": status, "output": Output::new(text, max, at), "command": command }))
    }

    // --- agents -----------------------------------------------------------------------------

    /// A worker agent: its pane, kind, state and finished turns.
    fn agent_info(&self, pane: PaneId, entry: &PaneEntry) -> Value {
        let kind = match &lock(&entry.record).launch {
            PaneLaunch::Agent { agent, .. } => Some(crate::agent::program(*agent)),
            _ => None,
        };
        let turns = lock(&entry.meta).turns;
        let exited = self.core.pane_meta(pane).and_then(|m| m.exit).is_some();
        let status = status(&self.core, pane, entry);
        let state = if exited {
            "exited"
        } else {
            status["state"].as_str().unwrap_or("starting")
        };
        json!({
            "pane": pane_ref(pane),
            "kind": kind,
            "state": state,
            "status": status,
            "turns": turns,
        })
    }

    /// Waits until the agent in `entry` is ready for a prompt: idle, and its screen settled.
    async fn agent_ready(&self, pane: PaneId, entry: &PaneEntry, deadline: Instant) -> Result<()> {
        let mut quiet_since = None;
        let mut head = entry.pane.head();
        while Instant::now() < deadline {
            let info = self.agent_info(pane, entry);
            match info["state"].as_str() {
                Some("exited") => return Err(closed()),
                Some("blocked") => return Err(agent_blocked(pane, &info)),
                Some("idle" | "done") => {
                    let now = entry.pane.head();
                    if now != head {
                        head = now;
                        quiet_since = None;
                    }
                    let since = *quiet_since.get_or_insert_with(Instant::now);
                    if since.elapsed() >= Duration::from_millis(400) {
                        return Ok(());
                    }
                }
                _ => quiet_since = None,
            }
            tokio::time::sleep(TICK).await;
        }
        Err(ToolError::new(
            ErrorCode::AgentBusy,
            format!("{} is not ready for a prompt", pane_ref(pane)),
        )
        .hint("wait for it with agent_wait, then prompt it"))
    }

    async fn deliver(&self, entry: &PaneEntry, text: String) -> Result<()> {
        write(entry, entry.pane.encode_input(InputPayload::Paste(text))).await?;
        // Let the agent's input box take the paste before Enter arrives.
        tokio::time::sleep(Duration::from_millis(80)).await;
        write(entry, b"\r".to_vec()).await?;
        Ok(())
    }

    async fn agent_spawn(&self, a: SpawnArgs) -> Result<Value> {
        let (of, _) = self.resolve(a.of.as_deref())?;
        self.may_read(of)?;
        let launch = Self::launch(None, Some(a.kind), a.cwd);
        let pane = self.split(of, a.direction, launch, false)?;
        let entry = self.core.pane(pane).ok_or_else(closed)?;
        if let Some(prompt) = a.prompt.filter(|p| !p.trim().is_empty()) {
            let deadline = Instant::now() + wait_for(a.timeout_ms.or(Some(60_000)));
            self.agent_ready(pane, &entry, deadline).await?;
            self.deliver(&entry, prompt).await?;
        }
        Ok(json!({ "agent": self.agent_info(pane, &entry) }))
    }

    async fn agent_prompt(&self, a: PromptArgs) -> Result<Value> {
        let (pane, entry) = self.resolve(Some(&a.pane))?;
        self.may_drive(pane)?;
        if entry.pane.echo().is_hidden_input() {
            return Err(secret_prompt(pane));
        }
        let info = self.agent_info(pane, &entry);
        match info["state"].as_str() {
            Some("exited") => return Err(closed()),
            Some("blocked") => return Err(agent_blocked(pane, &info)),
            Some("working") => {
                return Err(ToolError::new(
                    ErrorCode::AgentBusy,
                    format!("{} is working", pane_ref(pane)),
                )
                .hint("wait for it with agent_wait, then prompt it"));
            }
            _ => {}
        }
        let turns = lock(&entry.meta).turns;
        self.deliver(&entry, a.text).await?;
        if !a.wait {
            return Ok(json!({ "delivered": true, "agent": self.agent_info(pane, &entry) }));
        }
        let deadline = Instant::now() + wait_for(a.timeout_ms);
        loop {
            let info = self.agent_info(pane, &entry);
            let finished = lock(&entry.meta).turns > turns;
            let stuck = matches!(info["state"].as_str(), Some("blocked" | "exited"));
            if finished || stuck || Instant::now() >= deadline {
                let result = finished.then(|| self.last_turn(&entry));
                return Ok(json!({
                    "delivered": true,
                    "status": if finished { "finished" } else if stuck { info["state"].as_str().unwrap_or("blocked") } else { "timeout" },
                    "agent": info,
                    "result": result,
                }));
            }
            tokio::time::sleep(TICK).await;
        }
    }

    async fn agent_wait(&self, a: AgentWaitArgs) -> Result<Value> {
        if a.panes.is_empty() {
            return Err(ToolError::new(
                ErrorCode::InvalidArgs,
                "no panes to wait for",
            ));
        }
        let until: Vec<String> = if a.until.is_empty() {
            ["idle", "done", "blocked", "error", "exited"]
                .map(String::from)
                .into()
        } else {
            a.until
        };
        let agents = a
            .panes
            .iter()
            .map(|p| {
                let (pane, entry) = self.resolve(Some(p))?;
                self.may_read(pane)?;
                Ok((pane, entry))
            })
            .collect::<Result<Vec<_>>>()?;
        let deadline = Instant::now() + wait_for(a.timeout_ms);
        loop {
            let infos: Vec<Value> = agents.iter().map(|(p, e)| self.agent_info(*p, e)).collect();
            let reached = |i: &Value| {
                i["state"]
                    .as_str()
                    .is_some_and(|s| until.iter().any(|u| u == s))
            };
            let done = if a.all {
                infos.iter().all(reached)
            } else {
                infos.iter().any(reached)
            };
            if done || Instant::now() >= deadline {
                return Ok(
                    json!({ "status": if done { "ok" } else { "timeout" }, "agents": infos }),
                );
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    fn agent_result(&self, a: PaneArg) -> Result<Value> {
        let (pane, entry) = self.resolve(Some(&a.pane))?;
        self.may_read(pane)?;
        Ok(json!({ "agent": self.agent_info(pane, &entry), "result": self.last_turn(&entry) }))
    }

    fn last_turn(&self, entry: &PaneEntry) -> Value {
        let meta = lock(&entry.meta);
        let Some(turn) = &meta.last_turn else {
            return Value::Null;
        };
        json!({
            "outcome": match turn.outcome {
                agents::TurnOutcome::Completed => "completed",
                agents::TurnOutcome::Cancelled => "cancelled",
                agents::TurnOutcome::Failed => "failed",
            },
            "message": turn.message,
            "endedAt": turn.at.0,
            "transcriptPath": turn.transcript.as_ref().map(|p| p.to_string_lossy()),
        })
    }

    /// Reports the caller's own status, as OSC 7501 would, for agents that cannot print it.
    fn status_set(&self, a: StatusArgs) -> Result<Value> {
        let state = agents::ProgramState::parse(&a.state).ok_or_else(|| {
            ToolError::new(ErrorCode::InvalidArgs, format!("no status {}", a.state))
                .hint("statuses are idle, working, done, blocked, error, and clear to remove it")
        })?;
        let kind = a
            .kind
            .as_deref()
            .map(|k| {
                agents::ProgramKind::parse(k).ok_or_else(|| {
                    ToolError::new(ErrorCode::InvalidArgs, format!("no kind {k}"))
                        .hint("kinds are permission, question and auth")
                })
            })
            .transpose()?
            .filter(|_| state == agents::ProgramState::Blocked);
        let (_, entry) = self.resolve(None)?;
        lock(&entry.meta).program =
            (state != agents::ProgramState::Clear).then(|| agents::ProgramStatus {
                state,
                kind,
                id: None,
                app: None,
                progress: a.progress.map(|p| p.min(100)),
                title: None,
                msg: a.message,
                seq: None,
            });
        Ok(json!({ "status": status(&self.core, self.caller, &entry) }))
    }

    // --- input ------------------------------------------------------------------------------

    async fn pane_send(&self, a: SendArgs) -> Result<Value> {
        let (pane, entry) = self.resolve(Some(&a.pane))?;
        self.may_drive(pane)?;
        if entry.pane.echo().is_hidden_input() {
            return Err(secret_prompt(pane));
        }
        // Every key is checked before anything is written.
        let keys = a
            .keys
            .iter()
            .map(|k| parse_key(k))
            .collect::<Result<Vec<_>>>()?;
        let mut written = 0;
        if let Some(text) = a.text.filter(|t| !t.is_empty()) {
            written += write(&entry, entry.pane.encode_input(InputPayload::Paste(text))).await?;
        }
        for key in keys {
            written += write(&entry, entry.pane.encode_input(InputPayload::Key(key))).await?;
        }
        if a.submit {
            // Let a program's input box take a paste before Enter arrives.
            tokio::time::sleep(Duration::from_millis(80)).await;
            written += write(&entry, b"\r".to_vec()).await?;
        }
        Ok(json!({ "written": written, "cursor": output::cursor(entry.pane.head()) }))
    }
}

/// What the program in the pane says it is doing: its own last report, else what an agent
/// integration knows, else nothing.
fn status(core: &Core, id: PaneId, entry: &PaneEntry) -> Value {
    if let Some(report) = &lock(&entry.meta).program {
        return json!({
            "state": report.state.as_str(),
            "kind": report.kind.map(agents::ProgramKind::as_str),
            "app": report.app,
            "message": report.msg,
            "progress": report.progress,
        });
    }
    let Some(agent) = core.pane_meta(id).and_then(|m| m.agent) else {
        return Value::Null;
    };
    let (state, kind) = match agent.state {
        proto::AgentState::Idle => ("idle", None),
        proto::AgentState::Running => ("working", None),
        proto::AgentState::Blocked(_) => ("blocked", Some("permission")),
        proto::AgentState::Done => ("done", None),
    };
    json!({ "state": state, "kind": kind, "app": agent.kind })
}

fn position(sub: &pty::Subscriber) -> Seq {
    Seq(sub.position().get())
}

async fn write(entry: &PaneEntry, bytes: Vec<u8>) -> Result<usize> {
    let len = bytes.len();
    entry.pane.write(bytes).await.map_err(|_| closed())?;
    Ok(len)
}

/// Whether the pane went `quiet` without output before `deadline`.
async fn wait_quiet(entry: &PaneEntry, quiet: Duration, deadline: Instant) -> bool {
    let mut head = entry.pane.head();
    let mut since = Instant::now();
    while Instant::now() < deadline {
        tokio::time::sleep(TICK).await;
        let now = entry.pane.head();
        if now != head {
            head = now;
            since = Instant::now();
        } else if since.elapsed() >= quiet {
            return true;
        }
    }
    false
}

fn agent_blocked(pane: PaneId, info: &Value) -> ToolError {
    let what = info
        .pointer("/status/kind")
        .and_then(Value::as_str)
        .unwrap_or("the user");
    ToolError::new(
        ErrorCode::AgentBlocked,
        format!("{} is waiting on {what}", pane_ref(pane)),
    )
    .hint("the user answers it on their device; agent_wait tells you when it moves on")
}

fn closed() -> ToolError {
    ToolError::new(ErrorCode::Closed, "the pane has exited")
}

fn secret_prompt(pane: PaneId) -> ToolError {
    ToolError::new(
        ErrorCode::SecretPrompt,
        format!("{} is asking for a password", pane_ref(pane)),
    )
    .hint("passwords are the user's to type; tell them what is waiting")
}

/// `enter`, `esc`, `up`, `ctrl+c`, `shift+tab`, `f5`, `a`.
fn parse_key(name: &str) -> Result<KeyEvent> {
    use ghostty_vt::{Key, Mods};
    let bad = || {
        ToolError::new(ErrorCode::InvalidArgs, format!("unknown key {name}")).hint(
            "keys look like enter, esc, tab, up, ctrl+c, shift+tab, f5; send text with `text`",
        )
    };
    let lower = name.trim().to_ascii_lowercase();
    let mut parts: Vec<&str> = lower.split('+').collect();
    let base = parts.pop().filter(|b| !b.is_empty()).ok_or_else(bad)?;
    let mut mods = Mods::NONE;
    for m in parts {
        mods = mods
            | match m {
                "ctrl" | "control" => Mods::CTRL,
                "alt" | "option" | "meta" => Mods::ALT,
                "shift" => Mods::SHIFT,
                "cmd" | "super" => Mods::SUPER,
                _ => return Err(bad()),
            };
    }
    let named = match base {
        "enter" | "return" => Some(Key::ENTER),
        "esc" | "escape" => Some(Key::ESCAPE),
        "tab" => Some(Key::TAB),
        "backspace" => Some(Key::BACKSPACE),
        "delete" | "del" => Some(Key::DELETE),
        "space" => Some(Key::SPACE),
        "up" => Some(Key::ARROW_UP),
        "down" => Some(Key::ARROW_DOWN),
        "left" => Some(Key::ARROW_LEFT),
        "right" => Some(Key::ARROW_RIGHT),
        "home" => Some(Key::HOME),
        "end" => Some(Key::END),
        "pageup" => Some(Key::PAGE_UP),
        "pagedown" => Some(Key::PAGE_DOWN),
        "insert" => Some(Key::INSERT),
        _ => base
            .strip_prefix('f')
            .and_then(|n| n.parse::<u8>().ok())
            .and_then(function_key),
    };
    let (key, text) = match named {
        Some(key) => (key, (base == "space").then(|| " ".to_owned())),
        None => {
            let mut chars = base.chars();
            let c = chars
                .next()
                .filter(|_| chars.next().is_none())
                .ok_or_else(bad)?;
            let key = letter_key(c).ok_or_else(bad)?;
            (key, Some(c.to_string()))
        }
    };
    let text = text.filter(|_| mods == Mods::NONE || mods == Mods::SHIFT);
    Ok(KeyEvent {
        key: key.0,
        mods: mods.0,
        action: KeyAction::Press,
        text,
    })
}

fn function_key(n: u8) -> Option<ghostty_vt::Key> {
    use ghostty_vt::Key;
    Some(match n {
        1 => Key::F1,
        2 => Key::F2,
        3 => Key::F3,
        4 => Key::F4,
        5 => Key::F5,
        6 => Key::F6,
        7 => Key::F7,
        8 => Key::F8,
        9 => Key::F9,
        10 => Key::F10,
        11 => Key::F11,
        12 => Key::F12,
        _ => return None,
    })
}

fn letter_key(c: char) -> Option<ghostty_vt::Key> {
    use ghostty_vt::Key;
    const LETTERS: [Key; 26] = [
        Key::A,
        Key::B,
        Key::C,
        Key::D,
        Key::E,
        Key::F,
        Key::G,
        Key::H,
        Key::I,
        Key::J,
        Key::K,
        Key::L,
        Key::M,
        Key::N,
        Key::O,
        Key::P,
        Key::Q,
        Key::R,
        Key::S,
        Key::T,
        Key::U,
        Key::V,
        Key::W,
        Key::X,
        Key::Y,
        Key::Z,
    ];
    const DIGITS: [Key; 10] = [
        Key::DIGIT_0,
        Key::DIGIT_1,
        Key::DIGIT_2,
        Key::DIGIT_3,
        Key::DIGIT_4,
        Key::DIGIT_5,
        Key::DIGIT_6,
        Key::DIGIT_7,
        Key::DIGIT_8,
        Key::DIGIT_9,
    ];
    match c {
        'a'..='z' => Some(LETTERS[(c as u8 - b'a') as usize]),
        '0'..='9' => Some(DIGITS[(c as u8 - b'0') as usize]),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_parse_with_modifiers() {
        let c = parse_key("ctrl+c").unwrap();
        assert_eq!(c.key, ghostty_vt::Key::C.0);
        assert_eq!(c.mods, ghostty_vt::Mods::CTRL.0);
        assert_eq!(c.text, None);
        assert_eq!(parse_key("Enter").unwrap().key, ghostty_vt::Key::ENTER.0);
        assert_eq!(parse_key("f5").unwrap().key, ghostty_vt::Key::F5.0);
        assert!(parse_key("hyper+x").is_err());
        assert!(parse_key("ab").is_err());
    }

    #[test]
    fn ownership_follows_the_chain() {
        let term = Term::default();
        term.created(PaneId(1), PaneId(2));
        term.created(PaneId(2), PaneId(3));
        assert!(term.owns(PaneId(1), PaneId(3)));
        assert!(!term.owns(PaneId(3), PaneId(1)));
        assert!(!term.owns(PaneId(4), PaneId(2)));
    }
}
