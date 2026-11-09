//! The unified `AgentEvent` schema.
//!
//! One schema covers the PTY lane and the structured lane, so the inbox never needs to know which
//! lane a session runs on. Every enum here serializes as a `snake_case` string; the wire format is
//! versioned by [`SchemaVersion`].

use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

macro_rules! string_id {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub fn new(id: impl Into<String>) -> Self {
                Self(id.into())
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}

string_id! {
    /// A daemon pane, e.g. `p_9f2`.
    PaneId
}
string_id! {
    /// The agent's own session id (Claude UUID, Codex UUIDv7 thread id, …).
    NativeSessionId
}
string_id! {
    /// A stable id for one blocker, used to answer it from any client.
    RequestId
}
string_id! {
    /// The principal (person) who acted.
    ActorId
}
string_id! {
    /// A subagent id inside a lead session.
    SubagentId
}

/// A per-source monotonic sequence number, e.g. nanoseconds from the hook shim's clock.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Seq(pub u64);

/// Milliseconds since the Unix epoch.
///
/// The arbiter measures debounce and staleness windows with this type, so callers should derive it
/// from a monotonic clock anchored to wall time; a wall-clock step would otherwise shift deadlines.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct UnixMillis(pub u64);

impl UnixMillis {
    /// Returns this instant moved forward by `duration`, saturating at the maximum.
    pub fn saturating_add(self, duration: std::time::Duration) -> Self {
        let millis = u64::try_from(duration.as_millis()).unwrap_or(u64::MAX);
        Self(self.0.saturating_add(millis))
    }

    /// Returns the time elapsed from `earlier` to `self`, or zero if `earlier` is later.
    pub fn since(self, earlier: Self) -> std::time::Duration {
        std::time::Duration::from_millis(self.0.saturating_sub(earlier.0))
    }
}

/// The schema version carried in every event's `v` field.
///
/// Serializes as the integer [`SchemaVersion::CURRENT`]; deserializing any other number fails, so
/// a reader never silently misreads a future schema.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SchemaVersion;

impl SchemaVersion {
    /// The version this crate reads and writes.
    pub const CURRENT: u32 = 1;
}

impl Serialize for SchemaVersion {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u32(Self::CURRENT)
    }
}

impl<'de> Deserialize<'de> for SchemaVersion {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let version = u32::deserialize(deserializer)?;
        if version == Self::CURRENT {
            Ok(Self)
        } else {
            Err(serde::de::Error::custom(format!(
                "unsupported AgentEvent schema version {version}, expected {}",
                Self::CURRENT
            )))
        }
    }
}

/// Which coding agent a session runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum AgentKind {
    /// Anthropic Claude Code.
    Claude,
    /// OpenAI Codex CLI.
    Codex,
    /// pi coding agent (`@earendil-works/pi-coding-agent`).
    Pi,
    /// Moonshot Kimi Code CLI.
    Kimi,
}

/// How the daemon talks to a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lane {
    /// The agent's TUI runs in a daemon PTY.
    Pty,
    /// Agent Client Protocol over stdio.
    Acp,
    /// Claude Agent SDK stream-json.
    Sdk,
    /// `codex app-server` JSON-RPC.
    AppServer,
    /// `pi --mode rpc` JSONL.
    Rpc,
}

/// Where a signal came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// A lifecycle hook delivered over the daemon socket.
    Hook,
    /// An OSC 7501 program-status report in the PTY stream.
    Osc7501,
    /// An OSC 9 desktop notification in the PTY stream.
    Osc9,
    /// The terminal title (OSC 0/2) or OSC 9;4 progress, matched by a manifest rule.
    Title,
    /// The visible screen, matched by a manifest rule.
    Screen,
    /// Foreground-process detection.
    Process,
    /// A structured lane (ACP, SDK, app-server, RPC).
    Structured,
    /// Keys the daemon wrote to the PTY (an interrupt hint).
    Keypress,
}

/// How much a signal can be trusted. Ordered from weakest to strongest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Confidence {
    /// A heuristic that may be wrong (inferred text, an unconfirmed screen rule).
    Weak,
    /// A deliberate in-band report or a visible on-screen element.
    Strong,
    /// The agent itself said so through a hook or a structured protocol.
    Authoritative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    /// A session began (fresh or resumed).
    SessionStarted,
    /// The user submitted a prompt or the screen shows work starting.
    TurnStarted,
    /// The agent started a tool call.
    ToolStarted,
    /// The agent needs the user.
    Blocked,
    /// A blocker went away.
    Unblocked,
    /// A turn finished.
    TurnEnded,
    /// The user interrupted a turn.
    Interrupted,
    /// The agent failed.
    Error,
    /// The session or its process ended.
    SessionEnded,
    /// The agent switched to a new native session id (clear, compact, fork).
    SessionIdChanged,
    /// A working state went stale with no PTY output and degraded to unknown.
    Stale,
}

/// The coarse state of an agent, without blocker details.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentState {
    /// Running a turn.
    Working,
    /// Waiting on the user.
    Blocked,
    /// At rest, waiting for the next prompt.
    Idle,
    /// The last turn failed.
    Error,
    /// Not known (no evidence, or the agent process is gone).
    Unknown,
}

/// Why an agent is blocked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockedReason {
    /// Approval to run a tool.
    Permission,
    /// A question the user must answer.
    Question,
    /// A login or credential.
    Auth,
    /// A workspace-trust dialog.
    Trust,
    /// An update dialog.
    Update,
    /// An MCP elicitation form.
    Elicitation,
    /// Anything else, including screen-detected blockers of unknown type.
    Other,
}

/// One answer the user can give to a blocker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalChoice {
    /// Allow this one request.
    AllowOnce,
    /// Allow and don't ask again for the rest of the session.
    AllowSession,
    /// Refuse.
    Deny,
}

/// A choice offered for a blocker, with the label the agent's UI uses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalOption {
    pub id: ApprovalChoice,
    /// Text to show on the button.
    pub label: String,
}

impl ApprovalOption {
    pub fn new(id: ApprovalChoice, label: impl Into<String>) -> Self {
        Self {
            id,
            label: label.into(),
        }
    }
}

/// A way the daemon can deliver an answer to the agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnswerPath {
    /// The waiting hook process returns the decision (Claude/Codex `PermissionRequest`).
    HookDecision,
    /// Reply to an ACP `session/request_permission`.
    AcpPermission,
    /// Type the choice into the PTY after re-verifying the dialog on screen.
    Keystrokes,
    /// Reply on the exact pane-owned app-server.
    AppServer,
}

/// What an agent is blocked on, as reported by a source, before the arbiter assigns a request id.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Blocker {
    pub reason: BlockedReason,
    /// The tool that needs approval, e.g. `Bash`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// One line for people, e.g. the command to run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// The tool input, truncated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<serde_json::Value>,
    /// The answers on offer. Empty means "open the terminal".
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<ApprovalOption>,
    /// How the daemon could deliver an answer.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub answer_paths: Vec<AnswerPath>,
}

impl Blocker {
    pub fn new(reason: BlockedReason) -> Self {
        Self {
            reason,
            tool: None,
            summary: None,
            detail: None,
            options: Vec::new(),
            answer_paths: Vec::new(),
        }
    }

    /// Returns whether `other` plausibly describes the same dialog as `self`.
    ///
    /// Sources see different parts of one dialog (the hook knows the tool, the screen knows
    /// nothing), so a missing field or an `Other` reason never counts as a difference.
    pub(crate) fn is_compatible(&self, other: &Self) -> bool {
        fn agree<T: PartialEq>(left: Option<&T>, right: Option<&T>) -> bool {
            left.zip(right).is_none_or(|(left, right)| left == right)
        }
        let reasons = self.reason == other.reason
            || self.reason == BlockedReason::Other
            || other.reason == BlockedReason::Other;
        let native = self.answer_paths.contains(&AnswerPath::AppServer)
            || other.answer_paths.contains(&AnswerPath::AppServer);
        reasons
            && (!native || self.detail == other.detail)
            && agree(self.tool.as_ref(), other.tool.as_ref())
            && agree(self.summary.as_ref(), other.summary.as_ref())
    }

    /// Fills fields `self` lacks from `richer`, and upgrades an `Other` reason.
    pub(crate) fn merge_from(&mut self, richer: Blocker) {
        if self.reason == BlockedReason::Other {
            self.reason = richer.reason;
        }
        self.tool = self.tool.take().or(richer.tool);
        self.summary = self.summary.take().or(richer.summary);
        self.detail = self.detail.take().or(richer.detail);
        if self.options.is_empty() {
            self.options = richer.options;
        }
        for path in richer.answer_paths {
            if !self.answer_paths.contains(&path) {
                self.answer_paths.push(path);
            }
        }
    }
}

/// A blocker with the id clients use to answer it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Blocked {
    /// Stable for as long as the same dialog is showing.
    pub request_id: RequestId,
    #[serde(flatten)]
    pub blocker: Blocker,
}

/// The effective state of an agent, carrying blocker details when blocked.
///
/// Serializes as `{"state": "blocked", "blocked": {…}}` or `{"state": "idle"}`, matching the
/// `state` and `blocked` fields of the event, without allowing `blocked` on other states.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "state", content = "blocked", rename_all = "snake_case")]
pub enum Status {
    /// Running a turn.
    Working,
    /// Waiting on the user.
    Blocked(Blocked),
    /// At rest.
    Idle,
    /// The last turn failed.
    Error,
    /// Not known.
    Unknown,
}

impl Status {
    pub fn state(&self) -> AgentState {
        match self {
            Self::Working => AgentState::Working,
            Self::Blocked(_) => AgentState::Blocked,
            Self::Idle => AgentState::Idle,
            Self::Error => AgentState::Error,
            Self::Unknown => AgentState::Unknown,
        }
    }

    pub fn blocked(&self) -> Option<&Blocked> {
        match self {
            Self::Blocked(blocked) => Some(blocked),
            _ => None,
        }
    }
}

/// How a turn ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnOutcome {
    /// The agent finished normally.
    Completed,
    /// The user interrupted it.
    Cancelled,
    /// An API or tool error stopped it.
    Failed,
}

/// Details of a finished turn.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Turn {
    pub outcome: TurnOutcome,
    /// The last assistant message or error text, truncated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_message: Option<String>,
}

/// A subagent inside a lead session. Subagent events never change the lead's state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Subagent {
    pub id: SubagentId,
    /// The subagent type, e.g. `Explore`.
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub agent_type: Option<String>,
}

/// The session an event belongs to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub agent: AgentKind,
    /// The agent's own session id, once known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native_id: Option<NativeSessionId>,
    /// The transcript file, if the agent reported one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    pub lane: Lane,
    /// The argv that resumes this session, for display. Persist the native id and rebuild the
    /// argv with the adapter instead, since it re-passes per-launch flags such as `--settings`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub resume_argv: Vec<String>,
}

impl SessionInfo {
    /// Creates session info with no native id yet.
    pub fn new(agent: AgentKind, lane: Lane) -> Self {
        Self {
            agent,
            native_id: None,
            transcript: None,
            cwd: None,
            lane,
            resume_argv: Vec::new(),
        }
    }
}

/// One entry in a session's append-only event log. The inbox state is derived from it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentEvent {
    pub v: SchemaVersion,
    /// The pane, or `None` for structured-lane sessions.
    pub pane_id: Option<PaneId>,
    pub session: SessionInfo,
    /// The originating source's sequence number, when it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<Seq>,
    /// Where the evidence for this event came from.
    pub source: Source,
    /// How far that source is trusted.
    pub confidence: Confidence,
    pub kind: EventKind,
    /// The effective state after this event (`state`, plus `blocked` when blocked).
    #[serde(flatten)]
    pub status: Status,
    /// Present on turn end.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<Turn>,
    /// Present when the event is about a subagent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent: Option<Subagent>,
    /// When the daemon produced the event.
    pub ts: UnixMillis,
}

/// An answer to a blocker from one principal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decision {
    /// The blocker being answered.
    pub request_id: RequestId,
    pub choice: ApprovalChoice,
    pub actor: ActorId,
}

/// The accepted decision for a request, broadcast to every client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decided {
    /// The blocker that was answered.
    pub request_id: RequestId,
    pub choice: ApprovalChoice,
    pub decided_by: ActorId,
    /// When the daemon accepted it.
    pub at: UnixMillis,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blocked_event() -> AgentEvent {
        let mut session = SessionInfo::new(AgentKind::Claude, Lane::Pty);
        session.native_id = Some(NativeSessionId::new("abc123"));
        session.resume_argv = vec!["claude".into(), "--resume".into(), "abc123".into()];
        let mut blocker = Blocker::new(BlockedReason::Permission);
        blocker.tool = Some("Bash".into());
        blocker.summary = Some("rm -rf build/".into());
        blocker.options = vec![
            ApprovalOption::new(ApprovalChoice::AllowOnce, "Yes"),
            ApprovalOption::new(ApprovalChoice::Deny, "No"),
        ];
        blocker.answer_paths = vec![AnswerPath::HookDecision, AnswerPath::Keystrokes];
        AgentEvent {
            v: SchemaVersion,
            pane_id: Some(PaneId::new("p_9f2")),
            session,
            seq: Some(Seq(1_760_780_000_123_456_789)),
            source: Source::Hook,
            confidence: Confidence::Authoritative,
            kind: EventKind::Blocked,
            status: Status::Blocked(Blocked {
                request_id: RequestId::new("p_9f2/1"),
                blocker,
            }),
            turn: None,
            subagent: None,
            ts: UnixMillis(1_760_780_000_123),
        }
    }

    #[test]
    fn serializes_to_the_06_schema_shape() {
        let json = serde_json::to_value(blocked_event()).unwrap();
        assert_eq!(json["v"], 1);
        assert_eq!(json["pane_id"], "p_9f2");
        assert_eq!(json["session"]["agent"], "claude");
        assert_eq!(json["session"]["lane"], "pty");
        assert_eq!(json["source"], "hook");
        assert_eq!(json["confidence"], "authoritative");
        assert_eq!(json["kind"], "blocked");
        assert_eq!(json["state"], "blocked");
        assert_eq!(json["blocked"]["reason"], "permission");
        assert_eq!(json["blocked"]["request_id"], "p_9f2/1");
        assert_eq!(json["blocked"]["options"][0]["id"], "allow_once");
        assert_eq!(json["blocked"]["answer_paths"][0], "hook_decision");
    }

    #[test]
    fn round_trips() {
        let event = blocked_event();
        let json = serde_json::to_string(&event).unwrap();
        let back: AgentEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, event);
    }

    #[test]
    fn non_blocked_state_has_no_blocked_field() {
        let mut event = blocked_event();
        event.status = Status::Idle;
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["state"], "idle");
        assert!(json.get("blocked").is_none());
        let back: AgentEvent = serde_json::from_value(json).unwrap();
        assert_eq!(back.status, Status::Idle);
    }

    #[test]
    fn rejects_other_schema_versions() {
        let mut json = serde_json::to_value(blocked_event()).unwrap();
        json["v"] = 2.into();
        assert!(serde_json::from_value::<AgentEvent>(json).is_err());
    }

    #[test]
    fn source_names_match_the_schema() {
        let names: Vec<String> = [
            Source::Hook,
            Source::Osc7501,
            Source::Osc9,
            Source::Title,
            Source::Screen,
            Source::Process,
            Source::Structured,
            Source::Keypress,
        ]
        .iter()
        .map(|source| {
            serde_json::to_value(source)
                .unwrap()
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect();
        assert_eq!(
            names,
            [
                "hook",
                "osc7501",
                "osc9",
                "title",
                "screen",
                "process",
                "structured",
                "keypress"
            ]
        );
    }

    #[test]
    fn confidence_is_ordered() {
        assert!(Confidence::Weak < Confidence::Strong);
        assert!(Confidence::Strong < Confidence::Authoritative);
    }

    #[test]
    fn blockers_merge_without_losing_detail() {
        let mut screen = Blocker::new(BlockedReason::Other);
        let mut hook = Blocker::new(BlockedReason::Permission);
        hook.tool = Some("Bash".into());
        hook.answer_paths = vec![AnswerPath::HookDecision];
        screen.answer_paths = vec![AnswerPath::Keystrokes];
        assert!(screen.is_compatible(&hook));
        screen.merge_from(hook);
        assert_eq!(screen.reason, BlockedReason::Permission);
        assert_eq!(screen.tool.as_deref(), Some("Bash"));
        assert_eq!(
            screen.answer_paths,
            [AnswerPath::Keystrokes, AnswerPath::HookDecision]
        );
    }

    #[test]
    fn different_tools_are_different_blockers() {
        let mut bash = Blocker::new(BlockedReason::Permission);
        bash.tool = Some("Bash".into());
        let mut write = bash.clone();
        write.tool = Some("Write".into());
        assert!(!bash.is_compatible(&write));
    }
}
