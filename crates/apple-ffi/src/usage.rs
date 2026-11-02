//! windows, gathered by the daemon from what the tools wrote there. Watch with
//! [`DaemonClient::usage_watch`]; changes arrive as `WorkspaceEvent::AgentUsage`.

use client_core::proto;

use crate::client::DaemonClient;
use crate::types::AgentKind;
use crate::ws_types::WorkspaceError;

/// Where usage numbers come from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UsageSource {
    /// Nothing known.
    Unknown,
    /// A log the tool writes on the host (Codex session rollouts).
    LocalLog,
    /// Claude Code's status-line input, from a session the app launched.
    StatusLine,
    /// The tool's own command (`claude -p /usage`, `codex app-server`).
    Cli,
    /// The provider's usage endpoint with the host's sign-in (opt-in fallback).
    Api,
}

/// One rate-limit window.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UsageWindow {
    /// `5h`, `weekly`, `weekly Opus`.
    pub name: String,
    /// Length in minutes, 0 when unknown.
    pub minutes: u32,
    /// Used, in tenths of a percent (625 = 62.5 %).
    pub used_permille: u16,
    /// When it resets, Unix milliseconds.
    pub resets_at_ms: Option<u64>,
    /// Requests are refused until the reset.
    pub limited: bool,
}

/// One agent's plan and windows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentUsage {
    /// The agent.
    pub agent: AgentKind,
    /// The plan as the tool names it, if known.
    pub plan: Option<String>,
    /// Windows, shortest first; empty when unknown.
    pub windows: Vec<UsageWindow>,
    /// Where the numbers come from.
    pub source: UsageSource,
    /// When the tool reported them, Unix milliseconds.
    pub as_of_ms: Option<u64>,
    /// Why nothing is known, or a caveat.
    pub note: Option<String>,
}

/// Every agent the host has.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct AgentUsageReport {
    /// One per agent installed or used on the host.
    pub agents: Vec<AgentUsage>,
}

impl From<proto::AgentKind> for AgentKind {
    fn from(a: proto::AgentKind) -> Self {
        match a {
            proto::AgentKind::Claude => Self::Claude,
            proto::AgentKind::Codex => Self::Codex,
        }
    }
}

impl From<proto::UsageSource> for UsageSource {
    fn from(s: proto::UsageSource) -> Self {
        match s {
            proto::UsageSource::Unknown => Self::Unknown,
            proto::UsageSource::LocalLog => Self::LocalLog,
            proto::UsageSource::StatusLine => Self::StatusLine,
            proto::UsageSource::Cli => Self::Cli,
            proto::UsageSource::Api => Self::Api,
        }
    }
}

impl From<proto::AgentUsage> for AgentUsage {
    fn from(a: proto::AgentUsage) -> Self {
        Self {
            agent: a.agent.into(),
            plan: a.plan,
            windows: a
                .windows
                .into_iter()
                .map(|w| UsageWindow {
                    name: w.name,
                    minutes: w.minutes,
                    used_permille: w.used_permille,
                    resets_at_ms: w.resets_at.map(|t| t.0),
                    limited: w.limited,
                })
                .collect(),
            source: a.source.into(),
            as_of_ms: a.as_of.map(|t| t.0),
            note: a.note,
        }
    }
}

impl From<proto::AgentUsageReport> for AgentUsageReport {
    fn from(r: proto::AgentUsageReport) -> Self {
        Self {
            agents: r.agents.into_iter().map(Into::into).collect(),
        }
    }
}

#[uniffi::export]
impl DaemonClient {
    /// Agent plan usage on the host now; while watching, changes arrive as
    /// `WorkspaceEvent::AgentUsage`. Call again to refresh (the daemon reads at most once a
    /// minute). Only for daemons whose `DaemonInfo.agentUsage` is true.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`] (owners only).
    pub async fn usage_watch(&self) -> Result<AgentUsageReport, WorkspaceError> {
        self.ws_call(|c| async move { c.usage_watch().await }).await
    }

    /// Stops this connection's usage pushes.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn usage_unwatch(&self) -> Result<(), WorkspaceError> {
        self.ws_call(|c| async move { c.usage_unwatch().await })
            .await
    }

    /// Whether each agent's command is installed on the host, as a pane would find it.
    ///
    /// # Errors
    ///
    /// `Unavailable` from a daemon too old to check (nothing is sent to it); else the
    /// daemon's [`WorkspaceError`].
    pub async fn agent_installs(&self) -> Result<Vec<AgentInstall>, WorkspaceError> {
        let installs: Vec<proto::AgentInstall> = self
            .ws_call(|c| async move { c.agent_installs().await })
            .await?;
        Ok(installs.into_iter().map(Into::into).collect())
    }

    /// The commands that add the daemon's MCP server to each installed agent's user-wide
    /// configuration (`register`), or remove it, for the client to show and run.
    ///
    /// # Errors
    ///
    /// `Unavailable` from a daemon too old to build them; else the daemon's [`WorkspaceError`].
    pub async fn agent_mcp_commands(
        &self,
        register: bool,
    ) -> Result<Vec<AgentMcpCommand>, WorkspaceError> {
        let commands: Vec<proto::AgentMcpCommand> = self
            .ws_call(move |c| async move { c.agent_mcp_commands(register).await })
            .await?;
        Ok(commands
            .into_iter()
            .map(|c| AgentMcpCommand {
                agent: c.agent.into(),
                argv: c.argv,
            })
            .collect())
    }
}

/// A command that registers or removes the daemon's MCP server with an agent.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentMcpCommand {
    /// The agent.
    pub agent: AgentKind,
    /// The program and its arguments.
    pub argv: Vec<String>,
}

/// Whether an agent's command is on the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentInstall {
    /// The agent.
    pub agent: AgentKind,
    /// The command launching runs (`claude`, `codex`).
    pub program: String,
    /// What the host has.
    pub state: InstallState,
}

/// Where an agent's command was found.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum InstallState {
    /// On the login shell's `PATH`: launching works.
    Installed {
        /// The resolved executable.
        path: String,
    },
    /// In an installer's directory the login shell's `PATH` lacks: launching fails until
    /// `PATH` is fixed.
    NotOnPath {
        /// The executable found.
        path: String,
    },
    /// Not found.
    Missing,
}

impl From<proto::AgentInstall> for AgentInstall {
    fn from(i: proto::AgentInstall) -> Self {
        Self {
            agent: i.agent.into(),
            program: i.program,
            state: match i.state {
                proto::InstallState::Installed { path } => InstallState::Installed { path },
                proto::InstallState::NotOnPath { path } => InstallState::NotOnPath { path },
                proto::InstallState::Missing => InstallState::Missing,
            },
        }
    }
}
