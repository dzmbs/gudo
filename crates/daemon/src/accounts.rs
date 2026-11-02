//! Agent accounts: several Claude Code / Codex sign-ins on one host (docs/DAEMON.md "Agent
//! accounts", `proto::account`).
//!
//! An account is a directory `<state>/accounts/<agent>/<id>/` (0700) passed to the agent as
//! `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. The system account is the user's own setup, launched
//! with neither set. The daemon keeps names, colours, defaults and which account created each
//! session in `<state>/accounts.json`; never a credential. Sign-in and sign-out are the
//! agents' own commands.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use agents::AccountContext;
use proto::{
    AccountDefault, AccountIdentity, AccountStatus, AgentAccount, AgentKind, SYSTEM_ACCOUNT,
};
use serde::{Deserialize, Serialize};

use crate::core::lock;

/// Most sessions whose account is remembered, oldest dropped first.
const SESSION_PINS: usize = 2048;

/// An account as `accounts.json` keeps it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Stored {
    id: String,
    agent: AgentKind,
    label: String,
    color: u8,
}

/// Which account created a session: resume must run under it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct SessionPin {
    agent: AgentKind,
    session_id: String,
    account: String,
}

/// `accounts.json`.
#[derive(Debug, Default, Serialize, Deserialize)]
struct File {
    #[serde(default)]
    accounts: Vec<Stored>,
    #[serde(default)]
    defaults: Vec<AccountDefault>,
    #[serde(default)]
    sessions: Vec<SessionPin>,
}

/// The daemon's accounts.
pub(crate) struct Accounts {
    root: PathBuf,
    file: PathBuf,
    state: Mutex<File>,
    /// What each agent last said about each account, by (agent, id).
    status: Mutex<HashMap<(AgentKind, String), AccountStatus>>,
    /// Sign-in panes and the account each signs in.
    sign_ins: Mutex<HashMap<proto::PaneId, (AgentKind, String)>>,
}

/// Whether `id` is one the daemon mints: 8 lowercase hex digits, so it is safe in a path.
fn is_minted(id: &str) -> bool {
    id.len() == 8 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn agent_dir_name(agent: AgentKind) -> &'static str {
    match agent {
        AgentKind::Claude => "claude",
        AgentKind::Codex => "codex",
    }
}

impl Accounts {
    /// Loads `<state_dir>/accounts.json`; a missing or unreadable file is no accounts.
    pub fn load(state_dir: &Path) -> Self {
        let file = state_dir.join("accounts.json");
        let mut state: File = std::fs::read(&file)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        // Never trust an id from disk with a path.
        state.accounts.retain(|a| is_minted(&a.id));
        Self {
            root: state_dir.join("accounts"),
            file,
            state: Mutex::new(state),
            status: Mutex::default(),
            sign_ins: Mutex::default(),
        }
    }

    fn save(&self, state: &File) {
        let bytes = serde_json::to_vec_pretty(state).expect("accounts serialize");
        if let Err(e) = crate::fsutil::write_atomic(&self.file, &bytes) {
            tracing::warn!("saving accounts: {e}");
        }
    }

    /// The directory of account `id` (not the system account's).
    pub fn dir(&self, agent: AgentKind, id: &str) -> PathBuf {
        self.root.join(agent_dir_name(agent)).join(id)
    }

    /// Whether `agent` has account `id`.
    pub fn exists(&self, agent: AgentKind, id: &str) -> bool {
        id == SYSTEM_ACCOUNT
            || lock(&self.state)
                .accounts
                .iter()
                .any(|a| a.agent == agent && a.id == id)
    }

    /// The launch context of an existing account.
    pub fn context(&self, agent: AgentKind, id: &str) -> Option<AccountContext> {
        if id == SYSTEM_ACCOUNT {
            return Some(AccountContext::system());
        }
        self.exists(agent, id).then(|| AccountContext {
            id: id.to_owned(),
            dir: Some(self.dir(agent, id)),
        })
    }

    /// The account a launch of `agent` runs under. A resumed session runs under the account
    /// that created it, whatever was asked; else the asked account; else the project's
    /// default, the host's, the system account.
    ///
    /// # Errors
    ///
    /// The asked account does not exist, or the session's account was removed.
    pub fn resolve(
        &self,
        agent: AgentKind,
        asked: Option<&str>,
        resume: Option<&str>,
        project: Option<&str>,
    ) -> Result<AccountContext, String> {
        let st = lock(&self.state);
        if let Some(session) = resume
            && let Some(pin) = st
                .sessions
                .iter()
                .rev()
                .find(|p| p.agent == agent && p.session_id == session)
        {
            let pinned = pin.account.clone();
            drop(st);
            return self.context(agent, &pinned).ok_or_else(|| {
                "this session belongs to an account that was removed, so it cannot resume"
                    .to_owned()
            });
        }
        let id = match asked {
            Some(id) => id.to_owned(),
            None => {
                let report = proto::AccountsReport {
                    accounts: Vec::new(),
                    defaults: st.defaults.clone(),
                    panes: Vec::new(),
                };
                report.default_for(agent, project).to_owned()
            }
        };
        drop(st);
        match self.context(agent, &id) {
            Some(ctx) => Ok(ctx),
            // A default whose account went: the user's own setup, as before accounts.
            None if asked.is_none() => Ok(AccountContext::system()),
            None => Err(format!("no such {} account", agent_dir_name(agent))),
        }
    }

    /// Remembers that `account` created `agent`'s session `session_id`.
    pub fn pin(&self, agent: AgentKind, session_id: &str, account: &str) {
        let mut st = lock(&self.state);
        if st
            .sessions
            .iter()
            .any(|p| p.agent == agent && p.session_id == session_id && p.account == account)
        {
            return;
        }
        st.sessions
            .retain(|p| !(p.agent == agent && p.session_id == session_id));
        st.sessions.push(SessionPin {
            agent,
            session_id: session_id.to_owned(),
            account: account.to_owned(),
        });
        let excess = st.sessions.len().saturating_sub(SESSION_PINS);
        st.sessions.drain(..excess);
        self.save(&st);
    }
}

impl Accounts {
    fn status_of(&self, agent: AgentKind, id: &str) -> AccountStatus {
        lock(&self.status)
            .get(&(agent, id.to_owned()))
            .cloned()
            .unwrap_or(AccountStatus::Unknown)
    }

    /// Every account, each agent's system account first.
    pub fn list(&self) -> Vec<AgentAccount> {
        let stored = lock(&self.state).accounts.clone();
        let mut out = Vec::new();
        for agent in [AgentKind::Claude, AgentKind::Codex] {
            out.push(AgentAccount {
                id: SYSTEM_ACCOUNT.into(),
                agent,
                label: "System".into(),
                color: 0,
                status: self.status_of(agent, SYSTEM_ACCOUNT),
            });
            out.extend(stored.iter().filter(|a| a.agent == agent).map(|a| AgentAccount {
                id: a.id.clone(),
                agent,
                label: a.label.clone(),
                color: a.color,
                status: self.status_of(agent, &a.id),
            }));
        }
        out
    }

    /// One account.
    pub fn get(&self, agent: AgentKind, id: &str) -> Option<AgentAccount> {
        self.list()
            .into_iter()
            .find(|a| a.agent == agent && a.id == id)
    }

    /// The report clients see, with the panes' accounts from the core.
    pub fn report(&self, panes: Vec<proto::PaneAccount>) -> proto::AccountsReport {
        proto::AccountsReport {
            accounts: self.list(),
            defaults: lock(&self.state).defaults.clone(),
            panes,
        }
    }

    /// Makes an account: its private directory (and, for Codex, its `config.toml`), signed out.
    ///
    /// # Errors
    ///
    /// An invalid label or colour, too many accounts, or the directory cannot be made.
    pub fn add(&self, add: &proto::AccountAdd) -> Result<AgentAccount, String> {
        if !proto::is_valid_account_label(&add.label) || add.color > proto::MAX_ACCOUNT_COLOR {
            return Err("an account needs a name of up to 64 bytes and a palette colour".into());
        }
        let mut st = lock(&self.state);
        let count = st.accounts.iter().filter(|a| a.agent == add.agent).count();
        if count + 1 >= proto::MAX_ACCOUNTS_PER_AGENT {
            return Err("this host has as many accounts for that agent as it keeps".into());
        }
        let id = loop {
            let id = crate::fsutil::hex(&crate::fsutil::random::<4>());
            if !st.accounts.iter().any(|a| a.id == id) {
                break id;
            }
        };
        let dir = self.dir(add.agent, &id);
        let made = crate::fsutil::create_private_dir(&self.root)
            .and_then(|()| crate::fsutil::create_private_dir(dir.parent().expect("has a parent")))
            .and_then(|()| crate::fsutil::create_private_dir(&dir))
            .and_then(|()| match add.agent {
                AgentKind::Codex => {
                    std::fs::write(dir.join("config.toml"), agents::Codex::ACCOUNT_CONFIG)
                }
                AgentKind::Claude => Ok(()),
            });
        if let Err(e) = made {
            let _ = std::fs::remove_dir_all(&dir);
            return Err(format!("could not make the account's directory: {e}"));
        }
        st.accounts.push(Stored {
            id: id.clone(),
            agent: add.agent,
            label: add.label.trim().to_owned(),
            color: add.color,
        });
        self.save(&st);
        drop(st);
        lock(&self.status).insert((add.agent, id.clone()), AccountStatus::SignedOut);
        Ok(self.get(add.agent, &id).expect("just added"))
    }

    /// Renames or recolours an account. The system account keeps its name.
    ///
    /// # Errors
    ///
    /// No such account, the system account, or an invalid label or colour.
    pub fn edit(&self, agent: AgentKind, id: &str, label: &str, color: u8) -> Result<(), String> {
        if !proto::is_valid_account_label(label) || color > proto::MAX_ACCOUNT_COLOR {
            return Err("an account needs a name of up to 64 bytes and a palette colour".into());
        }
        let mut st = lock(&self.state);
        let account = st
            .accounts
            .iter_mut()
            .find(|a| a.agent == agent && a.id == id)
            .ok_or("no such account (the system account cannot be renamed)")?;
        account.label = label.trim().to_owned();
        account.color = color;
        self.save(&st);
        Ok(())
    }

    /// Sets or clears a host or project default.
    ///
    /// # Errors
    ///
    /// No such account, or an invalid project id.
    pub fn set_default(
        &self,
        agent: AgentKind,
        project: Option<String>,
        account: Option<String>,
    ) -> Result<(), String> {
        if project.as_deref().is_some_and(|p| !proto::is_valid_id(p)) {
            return Err("invalid project".into());
        }
        if let Some(account) = &account
            && !self.exists(agent, account)
        {
            return Err("no such account".into());
        }
        let mut st = lock(&self.state);
        st.defaults
            .retain(|d| !(d.agent == agent && d.project == project));
        if let Some(account) = account {
            st.defaults.push(AccountDefault {
                agent,
                project,
                account,
            });
        }
        self.save(&st);
        Ok(())
    }

    /// Forgets account `id` and its defaults; its directory goes too. Its session pins stay,
    /// so those sessions say why they cannot resume.
    pub fn forget(&self, agent: AgentKind, id: &str) {
        let mut st = lock(&self.state);
        st.accounts.retain(|a| !(a.agent == agent && a.id == id));
        st.defaults
            .retain(|d| !(d.agent == agent && d.account == id));
        self.save(&st);
        drop(st);
        lock(&self.status).remove(&(agent, id.to_owned()));
        let _ = std::fs::remove_dir_all(self.dir(agent, id));
    }

    /// Records what the agent said about an account; whether it changed.
    pub fn set_status(&self, agent: AgentKind, id: &str, status: AccountStatus) -> bool {
        lock(&self.status).insert((agent, id.to_owned()), status.clone()) != Some(status)
    }

    /// Notes that `pane` signs in account `id`.
    pub fn signing_in(&self, pane: proto::PaneId, agent: AgentKind, id: &str) {
        lock(&self.sign_ins).insert(pane, (agent, id.to_owned()));
    }

    /// The account `pane` signs in, if it is a sign-in pane.
    pub fn sign_in_of(&self, pane: proto::PaneId) -> Option<(AgentKind, String)> {
        lock(&self.sign_ins).get(&pane).cloned()
    }

    /// Forgets a closed sign-in pane, returning its account.
    pub fn sign_in_closed(&self, pane: proto::PaneId) -> Option<(AgentKind, String)> {
        lock(&self.sign_ins).remove(&pane)
    }
}

/// Who `claude auth status --json` says is signed in: `None` when signed out.
pub(crate) fn claude_identity(succeeded: bool, json: &str) -> Option<AccountIdentity> {
    let v: serde_json::Value = serde_json::from_str(json.trim()).unwrap_or_default();
    let text = |key: &str| {
        v.get(key)
            .and_then(serde_json::Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    let method = text("authMethod");
    let logged_in = v
        .get("loggedIn")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(succeeded);
    if !succeeded || !logged_in || method.as_deref() == Some("none") {
        return None;
    }
    Some(AccountIdentity {
        email: text("email"),
        plan: text("subscriptionType"),
        organization: text("orgName"),
        method,
    })
}

/// Who Codex's `account/read` says is signed in: `None` when signed out.
pub(crate) fn codex_identity(result: &serde_json::Value) -> Option<AccountIdentity> {
    let account = result.get("account").unwrap_or(result);
    if account.is_null() {
        return None;
    }
    let text = |key: &str| {
        account
            .get(key)
            .and_then(serde_json::Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    Some(AccountIdentity {
        email: text("email"),
        plan: text("planType"),
        organization: text("workspaceName"),
        method: text("type"),
    })
}

/// How the daemon runs the agents' own commands for an account.
#[derive(Debug, Clone)]
pub(crate) struct Tools {
    home: PathBuf,
    path: Option<std::ffi::OsString>,
    vars: Vec<(String, String)>,
}

impl Tools {
    pub fn new(cfg: &crate::config::Config) -> Self {
        Self {
            home: cfg.home(),
            path: cfg.pane_var("PATH"),
            vars: cfg.pane_env.clone(),
        }
    }

    /// The agent's program on the panes' `PATH`, else where its installer puts it.
    pub fn which(&self, program: &str) -> Option<PathBuf> {
        let path = self.path.iter().flat_map(std::env::split_paths);
        let installers = crate::ws::installs::INSTALLER_DIRS
            .iter()
            .map(|d| self.home.join(d));
        crate::ws::installs::find(path.chain(installers), program)
    }

    /// The environment to run `agent`'s commands under `account`: the panes' variables, the
    /// account's directory, and no credential that would outrank its sign-in.
    pub fn env(
        &self,
        agent: AgentKind,
        account: &AccountContext,
    ) -> Result<crate::usage::cli::Env, String> {
        let program = crate::agent::program(agent);
        let own = match agent {
            AgentKind::Claude => agents::CLAUDE_DIR_VAR,
            AgentKind::Codex => agents::CODEX_DIR_VAR,
        };
        let (remove, set) = agents::account_env(account, own);
        let mut vars = self.vars.clone();
        vars.extend(
            set.into_iter()
                .map(|(k, v)| (k, v.to_string_lossy().into_owned())),
        );
        Ok(crate::usage::cli::Env {
            program: self
                .which(program)
                .ok_or_else(|| format!("{program} is not on the PATH"))?,
            cwd: self.home.clone(),
            vars,
            remove,
        })
    }
}

impl Accounts {
    /// Asks the agent whether account `id` is signed in, and as whom; records and returns it.
    ///
    /// # Errors
    ///
    /// No such account.
    pub async fn check(
        &self,
        tools: &Tools,
        agent: AgentKind,
        id: &str,
    ) -> Result<(AgentAccount, bool), String> {
        let account = self.context(agent, id).ok_or("no such account")?;
        let status = match tools.env(agent, &account) {
            Err(e) => AccountStatus::Failed(e),
            Ok(env) => match agent {
                AgentKind::Claude => match env.run(agents::ClaudeCode::STATUS).await {
                    Ok((ok, out)) => claude_identity(ok, &out)
                        .map_or(AccountStatus::SignedOut, AccountStatus::SignedIn),
                    Err(e) => AccountStatus::Failed(e),
                },
                AgentKind::Codex => {
                    let params = serde_json::json!({"refreshToken": false});
                    match crate::usage::cli::app_server(&env, "account/read", params).await {
                        Ok(result) => codex_identity(&result)
                            .map_or(AccountStatus::SignedOut, AccountStatus::SignedIn),
                        Err(e) => AccountStatus::Failed(e),
                    }
                }
            },
        };
        let changed = self.set_status(agent, id, status);
        Ok((self.get(agent, id).ok_or("no such account")?, changed))
    }

    /// Signs account `id` out with the agent's own logout, which clears the agent's own store
    /// (the macOS Keychain item too), then forgets it and deletes its directory.
    ///
    /// # Errors
    ///
    /// The system account, no such account, or the logout could not run: the account is
    /// kept, since deleting the directory alone would orphan a Keychain item.
    pub async fn remove(&self, tools: &Tools, agent: AgentKind, id: &str) -> Result<(), String> {
        if id == SYSTEM_ACCOUNT {
            return Err("the system account is the host's own setup and cannot be removed".into());
        }
        let account = self.context(agent, id).ok_or("no such account")?;
        let args = match agent {
            AgentKind::Claude => agents::ClaudeCode::SIGN_OUT,
            AgentKind::Codex => agents::Codex::SIGN_OUT,
        };
        let signed_out = matches!(self.status_of(agent, id), AccountStatus::SignedOut);
        match tools.env(agent, &account) {
            // A failed logout of an account that is not signed in has nothing to clear.
            Ok(env) => {
                if let Err(e) = env.run(args).await
                    && !signed_out
                {
                    return Err(format!("could not sign out first: {e}"));
                }
            }
            Err(e) if !signed_out => return Err(format!("could not sign out first: {e}")),
            Err(_) => {}
        }
        self.forget(agent, id);
        Ok(())
    }
}
