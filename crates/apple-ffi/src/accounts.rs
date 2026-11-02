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
    pub email: Option<String>,
    /// Plan (`max`, `pro`, `plus`, `team`).
    pub plan: Option<String>,
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
    SignedIn {
        identity: AccountIdentity,
    },
    /// Asking failed.
    Failed {
        message: String,
    },
}

/// One sign-in of one agent on the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentAccount {
    /// `system_account_id()` or a daemon-minted id.
    pub id: String,
    pub agent: AgentKind,
    /// "Personal", "Work"; "System" for the host user's own.
    pub label: String,
    /// Palette index 0…7.
    pub color: u8,
    pub status: AccountStatus,
}

/// A host or project default.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountDefault {
    pub agent: AgentKind,
    /// The project id; `nil` is the host's default.
    pub project: Option<String>,
    pub account: String,
}

/// The account a daemon-launched agent pane runs under.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PaneAccount {
    pub pane_id: u64,
    pub agent: AgentKind,
    pub account: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct AccountsReport {
    /// Every account; each agent's system account leads its own.
    pub accounts: Vec<AgentAccount>,
    /// Host and project defaults.
    pub defaults: Vec<AccountDefault>,
    /// Agent panes and their accounts.
    pub panes: Vec<PaneAccount>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountUsage {
    pub account: String,
    /// Its usage (`usage.agent` is the account's agent).
    pub usage: AgentUsage,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct AccountUsageReport {
    /// One entry per account.
    pub accounts: Vec<AccountUsage>,
}

impl From<proto::AccountIdentity> for AccountIdentity {
    fn from(account_identity: proto::AccountIdentity) -> Self {
        Self {
            email: account_identity.email,
            plan: account_identity.plan,
            organization: account_identity.organization,
            method: account_identity.method,
        }
    }
}

impl From<proto::AccountStatus> for AccountStatus {
    fn from(account_status: proto::AccountStatus) -> Self {
        match account_status {
            proto::AccountStatus::Unknown => Self::Unknown,
            proto::AccountStatus::SignedOut => Self::SignedOut,
            proto::AccountStatus::SignedIn(identity) => Self::SignedIn {
                identity: identity.into(),
            },
            proto::AccountStatus::Failed(message) => Self::Failed { message },
        }
    }
}

impl From<proto::AgentAccount> for AgentAccount {
    fn from(agent_account: proto::AgentAccount) -> Self {
        Self {
            id: agent_account.id,
            agent: agent_account.agent.into(),
            label: agent_account.label,
            color: agent_account.color,
            status: agent_account.status.into(),
        }
    }
}

impl From<proto::AccountsReport> for AccountsReport {
    fn from(accounts_report: proto::AccountsReport) -> Self {
        Self {
            accounts: accounts_report
                .accounts
                .into_iter()
                .map(Into::into)
                .collect(),
            defaults: accounts_report
                .defaults
                .into_iter()
                .map(|default| AccountDefault {
                    agent: default.agent.into(),
                    project: default.project,
                    account: default.account,
                })
                .collect(),
            panes: accounts_report
                .panes
                .into_iter()
                .map(|pane| PaneAccount {
                    pane_id: pane.pane_id.0,
                    agent: pane.agent.into(),
                    account: pane.account,
                })
                .collect(),
        }
    }
}

impl From<proto::AccountUsageReport> for AccountUsageReport {
    fn from(account_usage_report: proto::AccountUsageReport) -> Self {
        Self {
            accounts: account_usage_report
                .accounts
                .into_iter()
                .map(|usage| AccountUsage {
                    account: usage.account,
                    usage: usage.usage.into(),
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
        let report: proto::AccountsReport = self
            .ws_call(|client| async move { client.accounts().await })
            .await?;
        Ok(report.into())
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
        let account: proto::AgentAccount = self
            .ws_call(move |client| async move { client.account_add(add).await })
            .await?;
        Ok(account.into())
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
        let report: proto::AccountsReport = self
            .ws_call(move |client| async move {
                client.account_edit(agent, account, label, color).await
            })
            .await?;
        Ok(report.into())
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
        let report: proto::AccountsReport = self
            .ws_call(move |client| async move { client.account_remove(agent, account).await })
            .await?;
        Ok(report.into())
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
        let checked: proto::AgentAccount = self
            .ws_call(move |client| async move { client.account_check(agent, account).await })
            .await?;
        Ok(checked.into())
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
        let report: proto::AccountsReport = self
            .ws_call(move |client| async move {
                client.account_set_default(agent, project, account).await
            })
            .await?;
        Ok(report.into())
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
