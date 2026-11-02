//! The event stream scripts and agents subscribe to, as JSON (never on the QUIC wire).
//!
//! One schema for both sources: `un events --json` (a client, one event per line, built from
//! what its connection is shown) and the terminal tools' `events_wait` on the hook socket (an
//! agent, the events of its own session). Ids are the tools' `p12`, `t3`, `s1`. Version
//! [`SCRIPT_EVENTS_VERSION`] only ever gains event types and optional fields; a consumer
//! ignores types it does not know. Documented in docs/DAEMON.md ("Scripting").

use serde::{Deserialize, Serialize};

use crate::ids::{PaneId, SessionId, TabId};

/// The schema version in [`ScriptEvent::v`].
pub const SCRIPT_EVENTS_VERSION: u32 = 1;

/// One event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptEvent {
    /// [`SCRIPT_EVENTS_VERSION`].
    pub v: u32,
    /// Position in the stream, increasing by one per event the subscriber may see or miss.
    pub seq: u64,
    /// Milliseconds since the Unix epoch.
    pub at: u64,
    /// The session, `s1`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    /// The pane, `p12`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    /// What happened.
    #[serde(flatten)]
    pub kind: ScriptEventKind,
}

/// What happened, tagged by `type`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ScriptEventKind {
    /// A pane appeared in the session.
    #[serde(rename = "pane.opened")]
    PaneOpened {
        /// Its tab, `t3`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tab: Option<String>,
    },
    /// A pane closed.
    #[serde(rename = "pane.closed")]
    PaneClosed,
    /// A command started at a shell prompt (OSC 133).
    #[serde(rename = "command.started", rename_all = "camelCase")]
    CommandStarted {
        /// The command's number in its pane.
        id: u64,
        /// The command line, when the shell reported it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<String>,
        /// Where it runs.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    /// A command finished.
    #[serde(rename = "command.finished", rename_all = "camelCase")]
    CommandFinished {
        /// The command's number in its pane.
        id: u64,
        /// The command line, when the shell reported it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<String>,
        /// Its exit code, when the shell reported one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
        /// How long it ran.
        duration_ms: u64,
    },
    /// The agent (or any program reporting its status) in a pane changed state.
    #[serde(rename = "agent.state")]
    AgentState {
        /// `idle`, `working`, `blocked`, `done`, `error`, or `none` once nothing is reported.
        state: String,
        /// For `blocked`: `permission`, `question` or `auth`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        kind: Option<String>,
        /// The agent or program (`claude`, `codex`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app: Option<String>,
    },
    /// The session's tabs, splits, floating panes or projects changed: read the layout again.
    #[serde(rename = "layout.changed")]
    LayoutChanged,
    /// Events were dropped before the subscriber read them (it fell too far behind): state
    /// read before this may be stale.
    #[serde(rename = "events.lost")]
    Lost {
        /// How many.
        missed: u64,
    },
}

/// `p12`.
pub fn pane_ref(id: PaneId) -> String {
    format!("p{}", id.0)
}

/// `t3`.
pub fn tab_ref(id: TabId) -> String {
    format!("t{}", id.0)
}

/// `s1`.
pub fn session_ref(id: SessionId) -> String {
    format!("s{}", id.0)
}
