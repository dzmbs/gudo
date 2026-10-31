//!
//! A client with [`Caps::AGENT_USAGE`](crate::Caps::AGENT_USAGE) sends
//! [`WorkspaceRequest::UsageWatch`](crate::WorkspaceRequest::UsageWatch) to a daemon offering
//! [`DaemonFeatures::AGENT_USAGE`](crate::DaemonFeatures::AGENT_USAGE). The answer is the
//! current [`AgentUsageReport`]; while the connection watches, every change arrives as
//! [`ServerCtl::AgentUsage`](crate::ServerCtl::AgentUsage).
//! [`WorkspaceRequest::UsageUnwatch`](crate::WorkspaceRequest::UsageUnwatch) stops the pushes.
//!
//! The daemon reads what the tools themselves wrote on the host (Codex's session rollouts,
//! Claude Code's status-line input) and runs their documented usage commands. It never reads
//! the tools' sign-ins or calls the providers' undocumented usage endpoints.

use serde::{Deserialize, Serialize};

use crate::ids::UnixMillis;
use crate::layout::AgentKind;

/// How a client watches agent usage.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageWatch {
    /// Unused: kept for wire compatibility. Clients send `false`; daemons ignore it (they used
    /// to ask the providers' undocumented usage endpoints with the host's sign-in when set).
    pub api_fallback: bool,
}

/// Usage of every agent the host has, as far as the daemon knows it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentUsageReport {
    /// One entry per agent installed or used on the host; agents the host has never seen are
    /// absent.
    pub agents: Vec<AgentUsage>,
}

/// One agent's plan and limit windows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentUsage {
    /// The agent.
    pub agent: AgentKind,
    /// The plan as the tool names it (`plus`, `pro`, `max`), if it says.
    pub plan: Option<String>,
    /// The limit windows the tool reports (a 5-hour and a weekly one, typically), shortest
    /// first. Empty when nothing is known.
    pub windows: Vec<UsageWindow>,
    /// Where the numbers come from.
    pub source: UsageSource,
    /// When the tool reported them; `None` when nothing is known.
    pub as_of: Option<UnixMillis>,
    /// Why nothing is known, or a caveat, in words ("No Codex session on this host yet").
    pub note: Option<String>,
}

/// One rate-limit window.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageWindow {
    /// Short name: `5h`, `weekly`, `weekly Opus`.
    pub name: String,
    /// The window's length in minutes (300, 10080), 0 when the tool does not say.
    pub minutes: u32,
    /// How much of it is used, in tenths of a percent (625 = 62.5 %). May exceed 1000.
    pub used_permille: u16,
    /// When the window resets.
    pub resets_at: Option<UnixMillis>,
    /// The tool says requests are being refused until the reset.
    pub limited: bool,
}

/// Where usage numbers come from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum UsageSource {
    /// Nothing known.
    Unknown,
    /// A log the tool writes on the host (Codex session rollouts).
    LocalLog,
    /// Claude Code's status-line input, from a session the daemon launched.
    StatusLine,
    /// The tool's own documented command: `claude -p /usage` (stream-json `usage_report`),
    /// `codex app-server` (`account/rateLimits/read`).
    Cli,
    /// Unused: kept for wire compatibility (older daemons' undocumented-endpoint fallback).
    Api,
}
