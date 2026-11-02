//! Agent accounts on the host (`proto::account`): several Claude Code / Codex sign-ins, such
//! as Personal and Work. Each is a directory on the host the agent is launched with; signing in
//! is the agent's own login in a pane ([`DaemonClient::account_sign_in`]). Changes arrive as
//! `WorkspaceEvent::Accounts`, per-account usage as `WorkspaceEvent::AccountUsage`. Owners
//! only; for daemons whose `DaemonInfo.accounts` is true.

use client_core::proto;

use crate::client::DaemonClient;
use crate::types::AgentKind;
use crate::usage::AgentUsage;
use crate::ws_types::WorkspaceError;

/// The id of each agent's account that is the host user's own setup.
#[uniffi::export]
pub fn system_account_id() -> String {
    proto::SYSTEM_ACCOUNT.to_owned()
}

/// Who an account is signed in as (display facts, never a credential).
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct AccountIdentity {
    /// Email address.
    pub email: Option<String>,
    /// Plan (`max`, `pro`, `plus`, `team`).
    pub plan: Option<String>,
    /// Organization or workspace.
    pub organization: Option<String>,
    /// How it signed in (`claude.ai`, `api_key`, `chatgpt`, `apiKey`).
    pub method: Option<String>,
}

/// What the agent says about an account's sign-in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AccountStatus {
    /// Not asked yet, or being asked.
    Unknown,
    /// No sign-in.
    SignedOut,
    /// Signed in.
    SignedIn {
        /// As whom.
        identity: AccountIdentity,
    },
    /// Asking failed.
    Failed {
        /// Why, in words.
        message: String,
    },
}

/// One sign-in of one agent on the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentAccount {
    /// `system_account_id()` or a daemon-minted id.
    pub id: String,
    /// The agent.
    pub agent: AgentKind,
    /// "Personal", "Work"; "System" for the host user's own.
    pub label: String,
    /// Palette index 0…7.
    pub color: u8,
    /// Its sign-in.
    pub status: AccountStatus,
}

/// A host or project default.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountDefault {
    /// The agent.
    pub agent: AgentKind,
    /// The project id; `nil` is the host's default.
    pub project: Option<String>,
    /// The account.
    pub account: String,
}

/// The account a daemon-launched agent pane runs under.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PaneAccount {
    /// The pane.
    pub pane_id: u64,
    /// Its agent.
    pub agent: AgentKind,
    /// The account.
    pub account: String,
}

/// The host's accounts.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct AccountsReport {
    /// Every account; each agent's system account leads its own.
    pub accounts: Vec<AgentAccount>,
    /// Host and project defaults.
    pub defaults: Vec<AccountDefault>,
    /// Agent panes and their accounts.
    pub panes: Vec<PaneAccount>,
}

/// One account's usage.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountUsage {
    /// The account.
    pub account: String,
    /// Its usage (`usage.agent` is the account's agent).
    pub usage: AgentUsage,
}

/// Usage per account.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct AccountUsageReport {
    /// One entry per account.
    pub accounts: Vec<AccountUsage>,
}

impl From<proto::AccountIdentity> for AccountIdentity {
    fn from(i: proto::AccountIdentity) -> Self {
        Self {
            email: i.email,
            plan: i.plan,
            organization: i.organization,
            method: i.method,
        }
    }
}

impl From<proto::AccountStatus> for AccountStatus {
    fn from(s: proto::AccountStatus) -> Self {
        match s {
            proto::AccountStatus::Unknown => Self::Unknown,
            proto::AccountStatus::SignedOut => Self::SignedOut,
            proto::AccountStatus::SignedIn(i) => Self::SignedIn { identity: i.into() },
            proto::AccountStatus::Failed(message) => Self::Failed { message },
        }
    }
}

impl From<proto::AgentAccount> for AgentAccount {
    fn from(a: proto::AgentAccount) -> Self {
        Self {
            id: a.id,
            agent: a.agent.into(),
            label: a.label,
            color: a.color,
            status: a.status.into(),
        }
    }
}

impl From<proto::AccountsReport> for AccountsReport {
    fn from(r: proto::AccountsReport) -> Self {
        Self {
            accounts: r.accounts.into_iter().map(Into::into).collect(),
            defaults: r
                .defaults
                .into_iter()
                .map(|d| AccountDefault {
                    agent: d.agent.into(),
                    project: d.project,
                    account: d.account,
                })
                .collect(),
            panes: r
                .panes
                .into_iter()
                .map(|p| PaneAccount {
                    pane_id: p.pane_id.0,
                    agent: p.agent.into(),
                    account: p.account,
                })
                .collect(),
        }
    }
}

impl From<proto::AccountUsageReport> for AccountUsageReport {
    fn from(r: proto::AccountUsageReport) -> Self {
        Self {
            accounts: r
                .accounts
                .into_iter()
                .map(|a| AccountUsage {
                    account: a.account,
                    usage: a.usage.into(),
                })
                .collect(),
        }
    }
}

#[uniffi::export]
impl DaemonClient {
    /// The host's agent accounts. Accounts never asked about are checked in the background;
    /// the answer arrives as `WorkspaceEvent::Accounts`.
    ///
    /// # Errors
    ///
    /// `Unavailable` from a daemon without accounts (nothing is sent); else the daemon's
    /// [`WorkspaceError`] (owners only).
    pub async fn accounts(&self) -> Result<AccountsReport, WorkspaceError> {
        let r: proto::AccountsReport = self.ws_call(|c| async move { c.accounts().await }).await?;
        Ok(r.into())
    }

    /// Makes an account, signed out; then sign in with [`Self::account_sign_in`].
    ///
    /// # Errors
    ///
    /// As [`Self::accounts`]; `Invalid` for an empty or long name.
    pub async fn account_add(
        &self,
        agent: AgentKind,
        label: String,
        color: u8,
    ) -> Result<AgentAccount, WorkspaceError> {
        let add = proto::AccountAdd {
            agent: agent.into(),
            label,
            color,
        };
        let a: proto::AgentAccount = self
            .ws_call(move |c| async move { c.account_add(add).await })
            .await?;
        Ok(a.into())
    }

    /// Renames or recolours an account.
    ///
    /// # Errors
    ///
    /// As [`Self::accounts`].
    pub async fn account_edit(
        &self,
        agent: AgentKind,
        account: String,
        label: String,
        color: u8,
    ) -> Result<AccountsReport, WorkspaceError> {
        let agent = agent.into();
        let r: proto::AccountsReport = self
            .ws_call(move |c| async move { c.account_edit(agent, account, label, color).await })
            .await?;
        Ok(r.into())
    }

    /// Signs an account out with the agent's own logout on the host and deletes it.
    ///
    /// # Errors
    ///
    /// As [`Self::accounts`]; `Conflict` while agent panes run under it.
    pub async fn account_remove(
        &self,
        agent: AgentKind,
        account: String,
    ) -> Result<AccountsReport, WorkspaceError> {
        let agent = agent.into();
        let r: proto::AccountsReport = self
            .ws_call(move |c| async move { c.account_remove(agent, account).await })
            .await?;
        Ok(r.into())
    }

    /// Asks the agent on the host whether an account is signed in, and as whom.
    ///
    /// # Errors
    ///
    /// As [`Self::accounts`].
    pub async fn account_check(
        &self,
        agent: AgentKind,
        account: String,
    ) -> Result<AgentAccount, WorkspaceError> {
        let agent = agent.into();
        let a: proto::AgentAccount = self
            .ws_call(move |c| async move { c.account_check(agent, account).await })
            .await?;
        Ok(a.into())
    }

    /// Sets or clears an agent's default account on the host (`project` nil) or in a project.
    ///
    /// # Errors
    ///
    /// As [`Self::accounts`].
    pub async fn account_set_default(
        &self,
        agent: AgentKind,
        project: Option<String>,
        account: Option<String>,
    ) -> Result<AccountsReport, WorkspaceError> {
        let agent = agent.into();
        let r: proto::AccountsReport = self
            .ws_call(move |c| async move { c.account_set_default(agent, project, account).await })
            .await?;
        Ok(r.into())
    }

    /// Opens a new tab in `session` running the agent's own sign-in for `account` (`claude
    /// auth login`, `codex login`, with `device_code` `codex login --device-auth`), with only
    /// that account's directory in its environment. The user completes it in the pane; the
    /// daemon checks the account when it ends. Returns the pane.
    ///
    /// # Errors
    ///
    /// `Unavailable` from a daemon without accounts; `Denied` for a guest; `NotFound` for an
    /// unknown account.
    pub async fn account_sign_in(
        &self,
        session: u64,
        agent: AgentKind,
        account: String,
        device_code: bool,
    ) -> Result<u64, WorkspaceError> {
        let offered = self
            .inner
            .daemon_info()
            .is_some_and(|i| i.features.contains(proto::DaemonFeatures::ACCOUNTS));
        if !offered {
            return Err(WorkspaceError::Unavailable {
                message: "the host's helper predates agent accounts; update it".into(),
            });
        }
        let op = proto::LayoutOp::NewTab {
            session_id: proto::SessionId(session),
            name: String::new(),
            launch: proto::PaneLaunch::AccountSignIn {
                agent: agent.into(),
                account,
                device_code,
            },
        };
        crate::workspace::created_pane(self.await_op(op).await?)
    }
}
