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
    id.len() == 8
        && id
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
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
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        // Never trust an id from disk with a path.
        state.accounts.retain(|account| is_minted(&account.id));
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
        if let Err(error) = crate::fsutil::write_atomic(&self.file, &bytes) {
            tracing::warn!("saving accounts: {error}");
        }
    }

    /// The directory of account `id` (not the system account's).
    pub fn dir(&self, agent: AgentKind, id: &str) -> PathBuf {
        self.root.join(agent_dir_name(agent)).join(id)
    }

    pub fn exists(&self, agent: AgentKind, id: &str) -> bool {
        id == SYSTEM_ACCOUNT
            || lock(&self.state)
                .accounts
                .iter()
                .any(|account| account.agent == agent && account.id == id)
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
        let state = lock(&self.state);
        if let Some(session) = resume
            && let Some(pin) = state
                .sessions
                .iter()
                .rev()
                .find(|pin| pin.agent == agent && pin.session_id == session)
        {
            let pinned = pin.account.clone();
            drop(state);
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
                    defaults: state.defaults.clone(),
                    panes: Vec::new(),
                };
                report.default_for(agent, project).to_owned()
            }
        };
        drop(state);
        match self.context(agent, &id) {
            Some(context) => Ok(context),
            // A default whose account went: the user's own setup, as before accounts.
            None if asked.is_none() => Ok(AccountContext::system()),
            None => Err(format!("no such {} account", agent_dir_name(agent))),
        }
    }

    /// Remembers that `account` created `agent`'s session `session_id`.
    pub fn pin(&self, agent: AgentKind, session_id: &str, account: &str) {
        let mut state = lock(&self.state);
        if state
            .sessions
            .iter()
            .any(|pin| pin.agent == agent && pin.session_id == session_id && pin.account == account)
        {
            return;
        }
        state
            .sessions
            .retain(|pin| !(pin.agent == agent && pin.session_id == session_id));
        state.sessions.push(SessionPin {
            agent,
            session_id: session_id.to_owned(),
            account: account.to_owned(),
        });
        let excess = state.sessions.len().saturating_sub(SESSION_PINS);
        state.sessions.drain(..excess);
        self.save(&state);
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
        let mut accounts = Vec::new();
        for agent in [AgentKind::Claude, AgentKind::Codex] {
            accounts.push(AgentAccount {
                id: SYSTEM_ACCOUNT.into(),
                agent,
                label: "System".into(),
                color: 0,
                status: self.status_of(agent, SYSTEM_ACCOUNT),
            });
            accounts.extend(stored.iter().filter(|account| account.agent == agent).map(
                |account| AgentAccount {
                    id: account.id.clone(),
                    agent,
                    label: account.label.clone(),
                    color: account.color,
                    status: self.status_of(agent, &account.id),
                },
            ));
        }
        accounts
    }

    pub fn get(&self, agent: AgentKind, id: &str) -> Option<AgentAccount> {
        self.list()
            .into_iter()
            .find(|account| account.agent == agent && account.id == id)
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
        let mut state = lock(&self.state);
        let count = state
            .accounts
            .iter()
            .filter(|account| account.agent == add.agent)
            .count();
        if count + 1 >= proto::MAX_ACCOUNTS_PER_AGENT {
            return Err("this host has as many accounts for that agent as it keeps".into());
        }
        let id = loop {
            let id = crate::fsutil::hex(&crate::fsutil::random::<4>());
            if !state.accounts.iter().any(|account| account.id == id) {
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
        if let Err(error) = made {
            let _ = std::fs::remove_dir_all(&dir);
            return Err(format!("could not make the account's directory: {error}"));
        }
        state.accounts.push(Stored {
            id: id.clone(),
            agent: add.agent,
            label: add.label.trim().to_owned(),
            color: add.color,
        });
        self.save(&state);
        drop(state);
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
        let mut state = lock(&self.state);
        let account = state
            .accounts
            .iter_mut()
            .find(|account| account.agent == agent && account.id == id)
            .ok_or("no such account (the system account cannot be renamed)")?;
        account.label = label.trim().to_owned();
        account.color = color;
        self.save(&state);
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
        if project
            .as_deref()
            .is_some_and(|project| !proto::is_valid_id(project))
        {
            return Err("invalid project".into());
        }
        if let Some(account) = &account
            && !self.exists(agent, account)
        {
            return Err("no such account".into());
        }
        let mut state = lock(&self.state);
        state
            .defaults
            .retain(|default| !(default.agent == agent && default.project == project));
        if let Some(account) = account {
            state.defaults.push(AccountDefault {
                agent,
                project,
                account,
            });
        }
        self.save(&state);
        Ok(())
    }

    /// Forgets account `id` and its defaults; its directory goes too. Its session pins stay,
    /// so those sessions say why they cannot resume.
    pub fn forget(&self, agent: AgentKind, id: &str) {
        let mut state = lock(&self.state);
        state
            .accounts
            .retain(|account| !(account.agent == agent && account.id == id));
        state
            .defaults
            .retain(|default| !(default.agent == agent && default.account == id));
        self.save(&state);
        drop(state);
        lock(&self.status).remove(&(agent, id.to_owned()));
        let _ = std::fs::remove_dir_all(self.dir(agent, id));
    }

    /// Records what the agent said about an account; whether it changed.
    pub fn set_status(&self, agent: AgentKind, id: &str, status: AccountStatus) -> bool {
        lock(&self.status).insert((agent, id.to_owned()), status.clone()) != Some(status)
    }

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
    let status: serde_json::Value = serde_json::from_str(json.trim()).unwrap_or_default();
    let text = |key: &str| {
        status
            .get(key)
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    let method = text("authMethod");
    let logged_in = status
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
            .filter(|value| !value.is_empty())
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
    pub fn new(config: &crate::config::Config) -> Self {
        Self {
            home: config.home(),
            path: config.pane_var("PATH"),
            vars: config.pane_env.clone(),
        }
    }

    /// The agent's program on the panes' `PATH`, else where its installer puts it.
    pub fn which(&self, program: &str) -> Option<PathBuf> {
        let path = self.path.iter().flat_map(std::env::split_paths);
        let installers = crate::ws::installs::INSTALLER_DIRS
            .iter()
            .map(|dir| self.home.join(dir));
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
                .map(|(name, value)| (name, value.to_string_lossy().into_owned())),
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
            Err(error) => AccountStatus::Failed(error),
            Ok(env) => match agent {
                AgentKind::Claude => match env.run(agents::ClaudeCode::STATUS).await {
                    Ok((succeeded, output)) => claude_identity(succeeded, &output)
                        .map_or(AccountStatus::SignedOut, AccountStatus::SignedIn),
                    Err(error) => AccountStatus::Failed(error),
                },
                AgentKind::Codex => {
                    let params = serde_json::json!({"refreshToken": false});
                    match crate::usage::cli::app_server(&env, "account/read", params).await {
                        Ok(result) => codex_identity(&result)
                            .map_or(AccountStatus::SignedOut, AccountStatus::SignedIn),
                        Err(error) => AccountStatus::Failed(error),
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
                if let Err(error) = env.run(args).await
                    && !signed_out
                {
                    return Err(format!("could not sign out first: {error}"));
                }
            }
            Err(error) if !signed_out => {
                return Err(format!("could not sign out first: {error}"));
            }
            Err(_) => {}
        }
        self.forget(agent, id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn add(accounts: &Accounts, agent: AgentKind, label: &str) -> AgentAccount {
        accounts
            .add(&proto::AccountAdd {
                agent,
                label: label.into(),
                color: 1,
            })
            .unwrap()
    }

    #[test]
    fn an_account_is_a_private_directory_of_its_own() {
        let state = tempfile::tempdir().unwrap();
        let accounts = Accounts::load(state.path());
        let work = add(&accounts, AgentKind::Codex, "Work");
        assert!(is_minted(&work.id));
        assert_eq!(work.status, AccountStatus::SignedOut);
        let dir = accounts.dir(AgentKind::Codex, &work.id);
        for path in [
            state.path().join("accounts"),
            dir.parent().unwrap().into(),
            dir.clone(),
        ] {
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "{}", path.display());
        }
        // MCP OAuth logins stay per account.
        let config = std::fs::read_to_string(dir.join("config.toml")).unwrap();
        assert!(config.contains("mcp_oauth_credentials_store = \"file\""));
        let again = Accounts::load(state.path());
        assert_eq!(again.get(AgentKind::Codex, &work.id).unwrap().label, "Work");
        let ids: Vec<_> = again
            .list()
            .into_iter()
            .map(|account| (account.agent, account.id))
            .collect();
        assert_eq!(ids[0], (AgentKind::Claude, SYSTEM_ACCOUNT.to_owned()));
        assert_eq!(ids[1], (AgentKind::Codex, SYSTEM_ACCOUNT.to_owned()));
        assert_eq!(ids[2], (AgentKind::Codex, work.id));
    }

    /// An id read from disk is a path component: anything but a minted id is dropped.
    #[test]
    fn ids_from_disk_never_escape_the_accounts_directory() {
        let state = tempfile::tempdir().unwrap();
        std::fs::write(
            state.path().join("accounts.json"),
            r#"{"accounts":[{"id":"../../etc","agent":"Claude","label":"x","color":0}]}"#,
        )
        .unwrap();
        let accounts = Accounts::load(state.path());
        assert!(!accounts.exists(AgentKind::Claude, "../../etc"));
        assert_eq!(accounts.list().len(), 2);
    }

    #[test]
    fn launches_resolve_resume_first_then_asked_then_defaults() {
        let state = tempfile::tempdir().unwrap();
        let accounts = Accounts::load(state.path());
        let work = add(&accounts, AgentKind::Claude, "Work");
        let personal = add(&accounts, AgentKind::Claude, "Personal");
        let id = |resolved: Result<AccountContext, String>| resolved.unwrap().id;
        // Nothing set: the user's own setup, with no directory.
        let system = accounts
            .resolve(AgentKind::Claude, None, None, None)
            .unwrap();
        assert_eq!(system, AccountContext::system());
        // Host default, then a project's.
        accounts
            .set_default(AgentKind::Claude, None, Some(personal.id.clone()))
            .unwrap();
        accounts
            .set_default(AgentKind::Claude, Some("app".into()), Some(work.id.clone()))
            .unwrap();
        assert_eq!(
            id(accounts.resolve(AgentKind::Claude, None, None, None)),
            personal.id
        );
        assert_eq!(
            id(accounts.resolve(AgentKind::Claude, None, None, Some("app"))),
            work.id
        );
        // Codex defaults are its own.
        assert_eq!(
            id(accounts.resolve(AgentKind::Codex, None, None, Some("app"))),
            SYSTEM_ACCOUNT
        );
        // An explicit pick wins over defaults; an unknown one is refused.
        assert_eq!(
            id(accounts.resolve(AgentKind::Claude, Some(SYSTEM_ACCOUNT), None, Some("app"))),
            SYSTEM_ACCOUNT
        );
        assert!(
            accounts
                .resolve(AgentKind::Claude, Some("ffffffff"), None, None)
                .is_err()
        );
        let context = accounts
            .resolve(AgentKind::Claude, Some(&work.id), None, None)
            .unwrap();
        assert_eq!(context.dir, Some(accounts.dir(AgentKind::Claude, &work.id)));
    }

    /// Transcripts live in the account's directory, so a session resumes only under the account
    /// that created it, and never under another once that account is gone.
    #[test]
    fn resume_is_pinned_to_the_account_that_made_the_session() {
        let state = tempfile::tempdir().unwrap();
        let accounts = Accounts::load(state.path());
        let work = add(&accounts, AgentKind::Claude, "Work");
        accounts.pin(AgentKind::Claude, "s-work", &work.id);
        accounts.pin(AgentKind::Claude, "s-own", SYSTEM_ACCOUNT);
        let resume = |asked: Option<&str>, session: &str| {
            accounts.resolve(AgentKind::Claude, asked, Some(session), None)
        };
        assert_eq!(resume(None, "s-work").unwrap().id, work.id);
        assert_eq!(resume(Some(SYSTEM_ACCOUNT), "s-work").unwrap().id, work.id);
        assert_eq!(resume(Some(&work.id), "s-own").unwrap().id, SYSTEM_ACCOUNT);
        // Same id, other agent: not pinned.
        assert_eq!(
            accounts
                .resolve(AgentKind::Codex, None, Some("s-work"), None)
                .unwrap()
                .id,
            SYSTEM_ACCOUNT
        );
        let again = Accounts::load(state.path());
        assert_eq!(
            again
                .resolve(AgentKind::Claude, None, Some("s-work"), None)
                .unwrap()
                .id,
            work.id
        );
        accounts.forget(AgentKind::Claude, &work.id);
        let err = resume(None, "s-work").unwrap_err();
        assert!(err.contains("removed"), "{err}");
        assert!(!accounts.dir(AgentKind::Claude, &work.id).exists());
    }

    #[test]
    fn labels_colours_and_limits_are_checked() {
        let state = tempfile::tempdir().unwrap();
        let accounts = Accounts::load(state.path());
        let bad = |label: &str, color| {
            accounts
                .add(&proto::AccountAdd {
                    agent: AgentKind::Claude,
                    label: label.into(),
                    color,
                })
                .is_err()
        };
        assert!(bad("", 0));
        assert!(bad("  ", 0));
        assert!(bad("a\nb", 0));
        assert!(bad("Work", 8));
        assert!(
            accounts
                .edit(AgentKind::Claude, SYSTEM_ACCOUNT, "Mine", 0)
                .is_err()
        );
        for i in 1..proto::MAX_ACCOUNTS_PER_AGENT {
            add(&accounts, AgentKind::Claude, &format!("A{i}"));
        }
        assert!(bad("One more", 0));
    }

    #[test]
    fn reads_who_is_signed_in() {
        let json = r#"{"loggedIn":true,"authMethod":"claude.ai","email":"me@work.example","orgName":"Acme","subscriptionType":"max"}"#;
        let identity = claude_identity(true, json).unwrap();
        assert_eq!(identity.email.as_deref(), Some("me@work.example"));
        assert_eq!(identity.plan.as_deref(), Some("max"));
        assert_eq!(identity.organization.as_deref(), Some("Acme"));
        assert_eq!(claude_identity(false, json), None);
        assert_eq!(
            claude_identity(true, r#"{"loggedIn":false,"authMethod":"none"}"#),
            None
        );
        let codex = serde_json::json!({"account": {"type": "chatgpt", "email": "me@x", "planType": "plus"}, "requiresOpenaiAuth": true});
        let identity = codex_identity(&codex).unwrap();
        assert_eq!(
            (
                identity.email.as_deref(),
                identity.plan.as_deref(),
                identity.method.as_deref()
            ),
            (Some("me@x"), Some("plus"), Some("chatgpt"))
        );
        assert_eq!(codex_identity(&serde_json::json!({"account": null})), None);
    }
}
