//! Coding-agent integration for the host daemon: pure logic, no I/O, no async, no clock.
//!
//!
//! - [`AgentEvent`] is the unified, versioned event schema shared by the PTY and structured lanes.
//! - [`AgentAdapter`] is everything agent-specific: the launch recipe ([`LaunchSpec`]), hook-payload
//!   parsing, in-band signals (OSC 7501 via [`ProgramStatus`], OSC 9) and a screen [`Manifest`].
//!   [`ClaudeCode`] and [`Codex`] are the MVP adapters.
//! - Every parser produces a [`Signal`]; the per-pane [`Arbiter`] merges them into one effective
//!   [`Status`], emits events, decides when to notify, and accepts the first [`Decision`] per
//!   blocker.
//!
//! The adapter is a trait rather than an enum so a new agent (pi, Kimi) is one new implementation
//! plus a manifest, with no edits to the schema, the manifest engine or the arbiter; the crate's
//! tests add a third adapter from outside the crate to prove it.
//!
//! The bundled screen manifests are copied from herdr (Apache-2.0); see `manifests/LICENSE-herdr`.

mod adapter;
mod arbiter;
mod claude;
mod codex;
mod event;
mod hook;
mod launch;
mod manifest;
mod program_status;
mod signal;

pub use adapter::{AgentAdapter, HookCoverage, HookError};
pub use arbiter::{Arbiter, ArbiterConfig, DecisionError, Notify, Update};
pub use claude::ClaudeCode;
pub use codex::Codex;
pub use event::{
    ActorId, AgentEvent, AgentKind, AgentState, AnswerPath, ApprovalChoice, ApprovalOption,
    Blocked, BlockedReason, Blocker, Confidence, Decided, Decision, EventKind, Lane,
    NativeSessionId, PaneId, RequestId, SchemaVersion, Seq, SessionInfo, Source, Status, Subagent,
    SubagentId, Turn, TurnOutcome, UnixMillis,
};
pub use launch::{
    ACTING_TOOLS, LaunchContext, LaunchMode, LaunchSpec, SupportFile, mcp_args, mcp_server_name,
    pane_env,
};
pub use manifest::{
    ENGINE_VERSION, Manifest, ManifestError, Region, ScreenInput, ScreenMatch, ScreenVerdict,
};
pub use program_status::{ProgramKind, ProgramState, ProgramStatus};
pub use signal::{Claim, SessionUpdate, Signal};
