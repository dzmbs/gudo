//! Agent accounts: several Claude Code and Codex sign-ins on one host, such as Personal and
//! Work (docs/DAEMON.md "Agent accounts").
//!
//! Each account is a configuration directory the daemon owns, passed to the agent as
//! `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, the vendors' documented mechanism. The user's own
//! `~/.claude` and `~/.codex` are the [`SYSTEM_ACCOUNT`], launched with no such variable, so
//! nothing changes for a host without accounts. Sign-in runs the vendor's own login in a pane
//! ([`PaneLaunch::AccountSignIn`](crate::PaneLaunch::AccountSignIn)); credentials never leave
//! the host and are never on the wire.
//!
//! - Daemons offering [`DaemonFeatures::ACCOUNTS`](crate::DaemonFeatures::ACCOUNTS) answer the
//!   `Account*` [`WorkspaceRequest`](crate::WorkspaceRequest)s (owner only) and launch
//!   [`PaneLaunch::AccountAgent`](crate::PaneLaunch::AccountAgent).
//! - Owner clients with [`Caps::ACCOUNTS`](crate::Caps::ACCOUNTS) get
//!   [`ServerCtl::Accounts`](crate::ServerCtl::Accounts) on every change, and, while they
//!   watch usage, [`ServerCtl::AccountUsage`](crate::ServerCtl::AccountUsage).
//!
//! Same compatibility rules as the rest of the crate: append only.

use serde::{Deserialize, Serialize};

use crate::ids::PaneId;
use crate::layout::AgentKind;
use crate::usage::AgentUsage;

/// The id of the account every agent has: the user's own configuration directory.
pub const SYSTEM_ACCOUNT: &str = "system";
/// Longest [`AgentAccount::label`] in bytes.
pub const MAX_ACCOUNT_LABEL_LEN: usize = 64;
/// Highest [`AgentAccount::color`] (a palette index, as for projects).
pub const MAX_ACCOUNT_COLOR: u8 = 7;
/// Most accounts per agent on one host, the system account included.
pub const MAX_ACCOUNTS_PER_AGENT: usize = 16;

/// One sign-in of one agent on the host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentAccount {
    /// [`SYSTEM_ACCOUNT`] (each agent has one), or an id the daemon minted, unique on the
    /// host. Requests name an account by agent and id.
    pub id: String,
    /// The agent.
    pub agent: AgentKind,
    /// The user's name for it ("Personal", "Work"); "System" for the system account.
    pub label: String,
    /// Palette index, `0..=`[`MAX_ACCOUNT_COLOR`].
    pub color: u8,
    /// Whether it is signed in, as the agent last said.
    pub status: AccountStatus,
}

impl AgentAccount {
    /// Whether this is the user's own configuration directory.
    pub fn is_system(&self) -> bool {
        self.id == SYSTEM_ACCOUNT
    }
}

/// What the agent says about an account's sign-in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AccountStatus {
    /// Not asked yet, or being asked.
    Unknown,
    /// No sign-in.
    SignedOut,
    /// Signed in.
    SignedIn(AccountIdentity),
    /// Asking failed, in words ("claude is not on the PATH").
    Failed(String),
}

/// Who an account is signed in as: display facts the agent reports, never a credential.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountIdentity {
    /// The account's email address.
    pub email: Option<String>,
    /// The plan as the agent names it (`max`, `pro`, `plus`, `team`).
    pub plan: Option<String>,
    /// The organization or workspace.
    pub organization: Option<String>,
    /// How it signed in, as the agent names it (`claude.ai`, `api_key`, `chatgpt`, `apiKey`).
    pub method: Option<String>,
}

/// Which account an agent uses when a launch names none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountDefault {
    /// The agent.
    pub agent: AgentKind,
    /// The project ([`Project::id`](crate::Project::id)) this default is for; `None` is the
    /// host's default.
    pub project: Option<String>,
    /// The account.
    pub account: String,
}

/// Which account a daemon-launched agent pane runs under.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneAccount {
    /// The pane.
    pub pane_id: PaneId,
    /// The pane's agent.
    pub agent: AgentKind,
    /// The account.
    pub account: String,
}

/// The host's accounts, in [`WorkspaceResponse::Accounts`](crate::WorkspaceResponse::Accounts)
/// and [`ServerCtl::Accounts`](crate::ServerCtl::Accounts).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountsReport {
    /// Every account, Claude's first; each agent's system account leads its own.
    pub accounts: Vec<AgentAccount>,
    /// Host and project defaults. An agent with no host default uses its system account.
    pub defaults: Vec<AccountDefault>,
    /// The account of every agent pane the daemon launched.
    pub panes: Vec<PaneAccount>,
}

impl AccountsReport {
    /// The account a launch of `agent` uses with nothing else said: the project's default,
    /// else the host's, else [`SYSTEM_ACCOUNT`].
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::{AccountDefault, AccountsReport, AgentKind, SYSTEM_ACCOUNT};
    ///
    /// let mut report = AccountsReport::default();
    /// assert_eq!(report.default_for(AgentKind::Claude, None), SYSTEM_ACCOUNT);
    /// report.defaults.push(AccountDefault {
    ///     agent: AgentKind::Claude,
    ///     project: Some("app".into()),
    ///     account: "work".into(),
    /// });
    /// assert_eq!(report.default_for(AgentKind::Claude, Some("app")), "work");
    /// assert_eq!(report.default_for(AgentKind::Claude, Some("blog")), SYSTEM_ACCOUNT);
    /// ```
    pub fn default_for(&self, agent: AgentKind, project: Option<&str>) -> &str {
        let find = |project: Option<&str>| {
            self.defaults
                .iter()
                .find(|d| d.agent == agent && d.project.as_deref() == project)
                .map(|d| d.account.as_str())
        };
        project
            .and_then(|p| find(Some(p)))
            .or_else(|| find(None))
            .unwrap_or(SYSTEM_ACCOUNT)
    }
}

/// A new account ([`WorkspaceRequest::AccountAdd`](crate::WorkspaceRequest::AccountAdd)).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountAdd {
    /// The agent.
    pub agent: AgentKind,
    /// Its name, 1..=[`MAX_ACCOUNT_LABEL_LEN`] bytes.
    pub label: String,
    /// Palette index.
    pub color: u8,
}

/// One account's plan usage, in [`AccountUsageReport`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountUsage {
    /// The account ([`AgentAccount::id`]).
    pub account: String,
    /// Its usage; `usage.agent` is the account's agent.
    pub usage: AgentUsage,
}

/// Plan usage per account, in [`ServerCtl::AccountUsage`](crate::ServerCtl::AccountUsage).
/// [`AgentUsageReport`](crate::AgentUsageReport) keeps reporting the system accounts.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountUsageReport {
    /// One entry per account the daemon knows anything about.
    pub accounts: Vec<AccountUsage>,
}

/// Whether `label` is a valid [`AgentAccount::label`].
pub fn is_valid_account_label(label: &str) -> bool {
    let trimmed = label.trim();
    !trimmed.is_empty()
        && label.len() <= MAX_ACCOUNT_LABEL_LEN
        && !label.chars().any(char::is_control)
}
