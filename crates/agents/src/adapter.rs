//! The per-agent integration point.

use std::fmt;

use crate::event::{AgentKind, Seq};
use crate::launch::{LaunchContext, LaunchMode, LaunchSpec};
use crate::manifest::{Manifest, ScreenInput, ScreenVerdict};
use crate::program_status::ProgramStatus;
use crate::signal::Signal;

/// How much of the agent's lifecycle its hooks report, which decides how far the arbiter trusts
/// them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HookCoverage {
    /// Hooks report every transition, interrupts included (pi extension, Kimi ≥ 0.14). Hook
    /// state is authoritative; only a visible blocker or a lasting visible idle prompt overrides
    /// it.
    FullLifecycle,
    /// Hooks reliably report entering `blocked` and turn end, but not cancellation (Claude, Codex).
    /// A newer visible screen state also overrides them.
    Partial,
}

/// An error parsing a hook payload.
#[derive(Debug)]
#[non_exhaustive]
pub enum HookError {
    /// The payload was not the JSON the agent documents.
    Json(serde_json::Error),
}

impl fmt::Display for HookError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Json(err) => write!(f, "malformed hook payload: {err}"),
        }
    }
}

impl std::error::Error for HookError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Json(err) => Some(err),
        }
    }
}

impl From<serde_json::Error> for HookError {
    fn from(err: serde_json::Error) -> Self {
        Self::Json(err)
    }
}

/// Everything agent-specific: how to launch it, and how to read its hooks, in-band reports and
/// screen.
///
/// The trait is object-safe so the daemon can hold `Box<dyn AgentAdapter>` per pane. Adding an
/// agent means one new implementation plus a manifest; the event schema, the manifest engine and
/// the [`Arbiter`](crate::Arbiter) stay as they are.
pub trait AgentAdapter {
    fn kind(&self) -> AgentKind;

    /// The OSC 7501 `app` value the agent's hook shim writes, e.g. `claude-code`.
    fn program_status_app(&self) -> &str;

    fn hook_coverage(&self) -> HookCoverage;

    fn manifest(&self) -> &Manifest;

    /// Builds the argv, env and support files to start or resume a session.
    fn launch(&self, ctx: &LaunchContext, mode: &LaunchMode) -> LaunchSpec;

    /// Parses one hook payload relayed by the shim, stamped with the shim's sequence number.
    ///
    /// Returns `Ok(None)` for events that carry nothing the daemon uses.
    ///
    /// # Errors
    ///
    /// Returns [`HookError::Json`] if the payload is not valid JSON of the documented shape.
    fn parse_hook(&self, payload: &[u8], seq: Seq) -> Result<Option<Signal>, HookError>;

    /// Parses an OSC 9 notification body (the text after `9;`). Most agents emit none.
    fn parse_osc9(&self, body: &str) -> Option<Signal> {
        let _ = body;
        None
    }

    /// Parses an OSC 7501 body (the text after `7501;`), keeping only this agent's reports.
    fn parse_program_status(&self, body: &str) -> Option<Signal> {
        ProgramStatus::parse(body)?.to_signal(self.program_status_app())
    }

    /// Reads the state from the screen and title with the agent's manifest.
    fn detect_screen(&self, input: ScreenInput<'_>) -> ScreenVerdict {
        self.manifest().evaluate(input)
    }
}
