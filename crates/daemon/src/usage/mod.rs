//! fresh only while a client watches.
//!
//! Sources, in order of preference:
//!
//! 1. **Local data the tool wrote** (stable, no process started). Codex: the `token_count`
//!    events in its session rollouts ([`codex`]). Claude Code: the `rate_limits` of its
//!    status-line input, which sessions the daemon launches send to the hook socket
//!    ([`claude`]). Used while younger than [`LOCAL_FRESH`].
//! 2. **The tools' documented commands** ([`cli`]): `claude -p /usage`, `codex app-server`.
//!    At most once per [`UsageConfig::cli_refresh`] per agent.
//!
//! Usage is kept per account (`proto::account`): each account's commands run in its own
//! directory, its rollouts are read from its own `CODEX_HOME`, and a status line counts for the
//! account of the pane that sent it. `AgentUsageReport` carries the system accounts.
//!
//! The daemon never reads the tools' sign-in tokens and never calls the providers' undocumented
//! usage endpoints. When every source fails the last local data stays (with its age), else the
//! agent is listed with the reason and no windows.

pub(crate) mod claude;
pub(crate) mod cli;
pub(crate) mod codex;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use proto::{
    AccountStatus, AccountUsage, AccountUsageReport, AgentKind, AgentUsage, AgentUsageReport, Caps,
    SYSTEM_ACCOUNT, ServerCtl, UsageSource, UsageWatch,
};
use tokio::sync::mpsc;

use crate::accounts::{Accounts, Tools};
use crate::config::Config;
use crate::core::lock;
use crate::ws::installs::{self, INSTALLER_DIRS};

/// Local data younger than this is used as is; older, the tool is asked.
pub(crate) const LOCAL_FRESH: Duration = Duration::from_secs(10 * 60);

/// Usage settings (not in `config.toml`; tests change these).
#[derive(Debug, Clone)]
pub struct UsageConfig {
    /// Shortest time between two refreshes of the report.
    pub refresh: Duration,
    /// Shortest time between two runs of one tool's usage command.
    pub cli_refresh: Duration,
    /// Run the tools' usage commands at all.
    pub cli: bool,
}

impl Default for UsageConfig {
    fn default() -> Self {
        Self {
            refresh: Duration::from_secs(60),
            cli_refresh: Duration::from_secs(5 * 60),
            cli: true,
        }
    }
}

/// Where the tools keep their files, from the panes' environment.
#[derive(Debug, Clone)]
struct Paths {
    home: PathBuf,
    codex_home: PathBuf,
    claude_dir: PathBuf,
    /// `PATH` to look for the tools on.
    path: Option<std::ffi::OsString>,
    /// Where the last status-line snapshot is kept across restarts.
    state: PathBuf,
}

impl Paths {
    fn new(cfg: &Config) -> Self {
        let home = cfg.home();
        Self {
            codex_home: cfg
                .pane_var("CODEX_HOME")
                .map_or_else(|| home.join(".codex"), PathBuf::from),
            claude_dir: cfg
                .pane_var("CLAUDE_CONFIG_DIR")
                .map_or_else(|| home.join(".claude"), PathBuf::from),
            path: cfg.pane_var("PATH"),
            state: cfg.state_dir.join("usage"),
            home,
        }
    }

    fn which(&self, program: &str) -> Option<PathBuf> {
        let path = self.path.iter().flat_map(std::env::split_paths);
        // Where the installers put them, for daemons started without a login PATH.
        let installers = INSTALLER_DIRS.iter().map(|d| self.home.join(d));
        installs::find(path.chain(installers), program)
    }

    fn has(&self, agent: AgentKind) -> bool {
        let dir = match agent {
            AgentKind::Claude => &self.claude_dir,
            AgentKind::Codex => &self.codex_home,
        };
        dir.is_dir() || self.which(crate::agent::program(agent)).is_some()
    }
}

struct Watcher {
    ctl: mpsc::UnboundedSender<ServerCtl>,
    push: bool,
    /// Takes per-account pushes (`Caps::ACCOUNTS`).
    accounts: bool,
}

/// One account of one agent: what usage is kept and asked for.
type Key = (AgentKind, String);

#[derive(Default)]
struct State {
    watchers: Vec<Watcher>,
    /// The system accounts, for clients without `Caps::ACCOUNTS`.
    report: AgentUsageReport,
    /// Every account.
    accounts: AccountUsageReport,
    refreshed: Option<Instant>,
    /// What was last pushed, to send only changes.
    pushed: Option<AgentUsageReport>,
    pushed_accounts: Option<AccountUsageReport>,
    pushed_at: Option<Instant>,
    ticking: bool,
    /// Commands are being run in the background.
    asking: bool,
    /// Where refreshes send what is due to be asked.
    asker: Option<mpsc::UnboundedSender<Vec<Key>>>,
    /// The last status-line snapshot of each Claude account.
    claude_lines: HashMap<String, AgentUsage>,
    /// The last answer of each account's command, and when it came.
    asked: HashMap<Key, (Instant, Result<AgentUsage, String>)>,
}

/// The usage hub: one per daemon.
pub(crate) struct Usage {
    cfg: UsageConfig,
    paths: Paths,
    accounts: Arc<Accounts>,
    tools: Tools,
    state: Mutex<State>,
    /// One refresh at a time.
    refreshing: tokio::sync::Mutex<()>,
}

impl Usage {
    pub fn new(cfg: &Config, accounts: Arc<Accounts>) -> Self {
        let paths = Paths::new(cfg);
        let mut claude_lines = HashMap::new();
        let ids = std::iter::once(SYSTEM_ACCOUNT.to_owned()).chain(
            accounts
                .list()
                .into_iter()
                .filter(|a| a.agent == AgentKind::Claude && !a.is_system())
                .map(|a| a.id),
        );
        for id in ids {
            if let Some(line) = claude::load(&paths.state, &id) {
                claude_lines.insert(id, line);
            }
        }
        Self {
            cfg: cfg.usage.clone(),
            paths,
            accounts,
            tools: Tools::new(cfg),
            state: Mutex::new(State {
                claude_lines,
                ..State::default()
            }),
            refreshing: tokio::sync::Mutex::new(()),
        }
    }

    /// Starts (or updates) a connection's watch and answers with the report, refreshed when
    /// older than the refresh interval. `UsageWatch::api_fallback` is ignored: it stays on the
    /// wire for compatibility only. A client with `Caps::ACCOUNTS` also gets every account's
    /// usage pushed at once.
    pub async fn watch(
        self: &Arc<Self>,
        ctl: &mpsc::UnboundedSender<ServerCtl>,
        caps: Caps,
        _opts: UsageWatch,
    ) -> AgentUsageReport {
        let accounts = caps.contains(Caps::ACCOUNTS);
        let start_ticker = {
            let mut st = lock(&self.state);
            st.watchers
                .retain(|w| !w.ctl.is_closed() && !w.ctl.same_channel(ctl));
            st.watchers.push(Watcher {
                ctl: ctl.clone(),
                push: caps.contains(Caps::AGENT_USAGE),
                accounts,
            });
            if st.asker.is_none() {
                st.asker = Some(self.spawn_asker());
            }
            !std::mem::replace(&mut st.ticking, true)
        };
        if start_ticker {
            self.spawn_ticker();
        }
        self.refresh(false).await;
        let st = lock(&self.state);
        if accounts {
            let _ = ctl.send(ServerCtl::AccountUsage(st.accounts.clone()));
        }
        st.report.clone()
    }

    /// Ends a connection's watch.
    pub fn unwatch(&self, ctl: &mpsc::UnboundedSender<ServerCtl>) {
        lock(&self.state)
            .watchers
            .retain(|w| !w.ctl.is_closed() && !w.ctl.same_channel(ctl));
    }

    /// A Claude Code status-line input from a session the daemon launched under `account`.
    pub fn status_line(&self, account: &str, payload: &serde_json::Value) {
        let Some(mut usage) = claude::from_status_line(payload, crate::identity::now_millis())
        else {
            return;
        };
        let (report, accounts) = {
            let mut st = lock(&self.state);
            if let Some(old) = st.claude_lines.get(account) {
                // The status line runs after every message: same numbers within a minute say
                // nothing new.
                let recent = old
                    .as_of
                    .zip(usage.as_of)
                    .is_some_and(|(o, n)| n.0 < o.0 + 60_000);
                if old.windows == usage.windows && recent {
                    return;
                }
            }
            // The plan is not in the status line; keep what a command said.
            usage.plan = st
                .accounts
                .accounts
                .iter()
                .find(|a| a.usage.agent == AgentKind::Claude && a.account == account)
                .and_then(|a| a.usage.plan.clone());
            st.claude_lines.insert(account.to_owned(), usage.clone());
            let entry = AccountUsage {
                account: account.to_owned(),
                usage: usage.clone(),
            };
            match st
                .accounts
                .accounts
                .iter_mut()
                .find(|a| a.usage.agent == AgentKind::Claude && a.account == account)
            {
                Some(old) => *old = entry,
                None => st.accounts.accounts.push(entry),
            }
            if account == SYSTEM_ACCOUNT {
                match st
                    .report
                    .agents
                    .iter_mut()
                    .find(|a| a.agent == AgentKind::Claude)
                {
                    Some(old) => *old = usage.clone(),
                    None => {
                        st.report.agents.push(usage.clone());
                        st.report.agents.sort_by_key(|a| agent_order(a.agent));
                    }
                }
            }
            (st.report.clone(), st.accounts.clone())
        };
        claude::save(&self.paths.state, account, &usage);
        self.publish(report, accounts);
    }

    fn spawn_ticker(self: &Arc<Self>) {
        let hub = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(hub.cfg.refresh).await;
                {
                    let mut st = lock(&hub.state);
                    st.watchers.retain(|w| !w.ctl.is_closed());
                    if st.watchers.is_empty() {
                        st.ticking = false;
                        return;
                    }
                }
                hub.refresh(true).await;
            }
        });
    }

    /// Re-reads the sources when the report is older than the refresh interval (or always,
    /// with `due`), then pushes a changed report.
    ///
    /// The files are read at once; the tools' commands (seconds) answer from their last
    /// result, and when that is due they run in the background, which refreshes and pushes
    /// again when they are done.
    async fn refresh(&self, due: bool) {
        let _one = self.refreshing.lock().await;
        let claude_lines = {
            let st = lock(&self.state);
            let fresh = st.refreshed.is_some_and(|t| {
                t.elapsed() < self.cfg.refresh.saturating_sub(Duration::from_millis(500))
            });
            if fresh && !due {
                return;
            }
            st.claude_lines.clone()
        };
        let accounts = self.accounts.list();
        let paths = self.paths.clone();
        let dirs: Vec<(Key, Option<PathBuf>, AccountStatus)> = accounts
            .iter()
            .map(|a| {
                let dir = (!a.is_system()).then(|| self.accounts.dir(a.agent, &a.id));
                ((a.agent, a.id.clone()), dir, a.status.clone())
            })
            .collect();
        let tools = self.tools.clone();
        let local = {
            let dirs = dirs.clone();
            tokio::task::spawn_blocking(move || Local::read(&paths, &tools, &dirs))
                .await
                .unwrap_or_default()
        };
        let now = crate::identity::now_millis();
        let mut entries = Vec::new();
        let mut asks = Vec::new();
        for ((agent, id), _, status) in dirs {
            let key = (agent, id.clone());
            let system = id == SYSTEM_ACCOUNT;
            let installed = local.installed.get(&key).copied().unwrap_or(false);
            let local_usage = match agent {
                AgentKind::Claude => claude_lines.get(&id).cloned(),
                AgentKind::Codex => local.codex.get(&key).cloned().flatten(),
            };
            if system && !installed && local_usage.is_none() {
                continue;
            }
            let signed_out = matches!(status, AccountStatus::SignedOut);
            let fresh = local_usage.as_ref().is_some_and(|u| {
                u.as_of
                    .is_some_and(|t| now.saturating_sub(t.0) < LOCAL_FRESH.as_millis() as u64)
            });
            let mut errors = Vec::new();
            let mut pending = false;
            let mut chosen = None;
            if fresh {
                chosen = local_usage.clone();
            }
            if chosen.is_none() && self.cfg.cli && installed && !signed_out {
                let (last, due) = self.cached(&key);
                if due {
                    asks.push(key.clone());
                    pending |= last.is_none();
                }
                match last {
                    Some(Ok(u)) => chosen = Some(u),
                    Some(Err(e)) => errors.push(e),
                    None => {}
                }
            }
            let mut usage = match (chosen, local_usage) {
                (Some(c), Some(l)) if is_newer(&l, &c) => l,
                (Some(c), _) => c,
                (None, Some(l)) => l,
                (None, None) if signed_out => not_signed_in(agent),
                (None, None) => unknown(agent, &errors, pending),
            };
            if usage.plan.is_none() {
                // A plan named by an earlier answer still holds.
                usage.plan = lock(&self.state)
                    .asked
                    .get(&key)
                    .and_then(|(_, r)| r.as_ref().ok()?.plan.clone());
            }
            entries.push(AccountUsage { account: id, usage });
        }
        let report = AgentUsageReport {
            agents: entries
                .iter()
                .filter(|e| e.account == SYSTEM_ACCOUNT)
                .map(|e| e.usage.clone())
                .collect(),
        };
        let accounts = AccountUsageReport { accounts: entries };
        {
            let mut st = lock(&self.state);
            st.report = report.clone();
            st.accounts = accounts.clone();
            st.refreshed = Some(Instant::now());
        }
        self.publish(report, accounts);
        let mut st = lock(&self.state);
        if !asks.is_empty()
            && !st.asking
            && let Some(tx) = &st.asker
            && tx.send(asks).is_ok()
        {
            st.asking = true;
        }
    }

    /// The background task that runs the commands a refresh found due, one batch at a time,
    /// then refreshes with their answers.
    fn spawn_asker(self: &Arc<Self>) -> mpsc::UnboundedSender<Vec<Key>> {
        let (tx, mut rx) = mpsc::unbounded_channel::<Vec<Key>>();
        let hub = Arc::downgrade(self);
        tokio::spawn(async move {
            while let Some(batch) = rx.recv().await {
                let Some(hub) = hub.upgrade() else { return };
                for key in batch {
                    hub.ask(&key).await;
                }
                lock(&hub.state).asking = false;
                hub.refresh(true).await;
            }
        });
        tx
    }

    /// The last answer of an account's command, and whether it is due to be asked again.
    fn cached(&self, key: &Key) -> (Option<Result<AgentUsage, String>>, bool) {
        match lock(&self.state).asked.get(key) {
            Some((at, result)) => (Some(result.clone()), at.elapsed() >= self.cfg.cli_refresh),
            None => (None, true),
        }
    }

    /// Runs the tool's usage command for one account, in that account's environment, and
    /// keeps the answer.
    async fn ask(&self, key: &Key) {
        let (agent, id) = key;
        let result = match self.accounts.context(*agent, id) {
            None => Err("the account was removed".to_owned()),
            Some(account) => match self.tools.env(*agent, &account) {
                Err(e) => Err(e),
                Ok(env) => match agent {
                    AgentKind::Claude => cli::claude(&env).await,
                    AgentKind::Codex => cli::codex(&env).await,
                },
            },
        };
        if let Err(e) = &result {
            tracing::debug!(?agent, account = %id, "usage: {e}");
        }
        lock(&self.state)
            .asked
            .insert(key.clone(), (Instant::now(), result));
    }

    /// Sends the reports to the watchers that take pushes, when they differ from the last ones
    /// pushed (only times moving is pushed at most once per refresh interval).
    fn publish(&self, report: AgentUsageReport, accounts: AccountUsageReport) {
        let mut st = lock(&self.state);
        st.watchers.retain(|w| !w.ctl.is_closed());
        let same = st.pushed.as_ref().is_some_and(|p| same_numbers(p, &report))
            && st
                .pushed_accounts
                .as_ref()
                .is_some_and(|p| same_account_numbers(p, &accounts));
        let recent = st.pushed_at.is_some_and(|t| t.elapsed() < self.cfg.refresh);
        let unchanged =
            st.pushed.as_ref() == Some(&report) && st.pushed_accounts.as_ref() == Some(&accounts);
        if unchanged || (same && recent) {
            return;
        }
        let system_changed = st.pushed.as_ref() != Some(&report);
        st.pushed = Some(report.clone());
        st.pushed_accounts = Some(accounts.clone());
        st.pushed_at = Some(Instant::now());
        for w in st.watchers.iter().filter(|w| w.push) {
            if system_changed {
                let _ = w.ctl.send(ServerCtl::AgentUsage(report.clone()));
            }
            if w.accounts {
                let _ = w.ctl.send(ServerCtl::AccountUsage(accounts.clone()));
            }
        }
    }
}

/// What the files on the host say (read on the blocking pool).
#[derive(Default)]
struct Local {
    /// Whether each account's agent can run here.
    installed: HashMap<Key, bool>,
    /// Each Codex account's newest rollout limits.
    codex: HashMap<Key, Option<AgentUsage>>,
}

impl Local {
    fn read(paths: &Paths, tools: &Tools, dirs: &[(Key, Option<PathBuf>, AccountStatus)]) -> Self {
        let mut local = Self::default();
        for ((agent, id), dir, _) in dirs {
            let key = (*agent, id.clone());
            let installed = match dir {
                None => paths.has(*agent),
                Some(_) => tools.which(crate::agent::program(*agent)).is_some(),
            };
            local.installed.insert(key.clone(), installed);
            if *agent == AgentKind::Codex {
                let home = dir.as_deref().unwrap_or(&paths.codex_home);
                local.codex.insert(key, codex::from_rollouts(home));
            }
        }
        local
    }
}

/// An account that is not signed in.
fn not_signed_in(agent: AgentKind) -> AgentUsage {
    AgentUsage {
        agent,
        plan: None,
        windows: Vec::new(),
        source: UsageSource::Unknown,
        as_of: None,
        note: Some("Not signed in.".into()),
    }
}

/// Equal but for the report times.
fn same_account_numbers(a: &AccountUsageReport, b: &AccountUsageReport) -> bool {
    a.accounts.len() == b.accounts.len()
        && a.accounts.iter().zip(&b.accounts).all(|(x, y)| {
            x.account == y.account
                && same_numbers(
                    &AgentUsageReport {
                        agents: vec![x.usage.clone()],
                    },
                    &AgentUsageReport {
                        agents: vec![y.usage.clone()],
                    },
                )
        })
}

/// An agent with nothing known, and why.
fn unknown(agent: AgentKind, errors: &[String], pending: bool) -> AgentUsage {
    if pending {
        return AgentUsage {
            agent,
            plan: None,
            windows: Vec::new(),
            source: UsageSource::Unknown,
            as_of: None,
            note: Some("Checking…".into()),
        };
    }
    let mut note = match agent {
        AgentKind::Claude => "Claude Code reports its limits for Pro and Max plans.".to_owned(),
        AgentKind::Codex => "Codex reports its limits when signed in with ChatGPT.".to_owned(),
    };
    for e in errors {
        note.push(' ');
        note.push_str(&capitalized(e));
        if !note.ends_with('.') {
            note.push('.');
        }
    }
    AgentUsage {
        agent,
        plan: None,
        windows: Vec::new(),
        source: UsageSource::Unknown,
        as_of: None,
        note: Some(note),
    }
}

fn capitalized(s: &str) -> String {
    let mut chars = s.chars();
    chars
        .next()
        .map_or_else(String::new, |c| c.to_uppercase().chain(chars).collect())
}

fn is_newer(a: &AgentUsage, b: &AgentUsage) -> bool {
    a.as_of.map_or(0, |t| t.0) > b.as_of.map_or(0, |t| t.0)
}

fn agent_order(agent: AgentKind) -> u8 {
    match agent {
        AgentKind::Claude => 0,
        AgentKind::Codex => 1,
    }
}

/// Equal but for the report times.
fn same_numbers(a: &AgentUsageReport, b: &AgentUsageReport) -> bool {
    a.agents.len() == b.agents.len()
        && a.agents.iter().zip(&b.agents).all(|(x, y)| {
            x.agent == y.agent
                && x.plan == y.plan
                && x.windows == y.windows
                && x.source == y.source
                && x.note == y.note
        })
}

/// A percentage as tenths of a percent, clamped to the wire's range.
pub(crate) fn permille(percent: f64) -> u16 {
    if percent.is_finite() {
        (percent * 10.0).round().clamp(0.0, f64::from(u16::MAX)) as u16
    } else {
        0
    }
}

/// A window's short name from its length: `5h`, `weekly`, `24h`, `30d`; `scope` is appended
/// (`weekly Opus`).
pub(crate) fn window_name(minutes: u32, scope: Option<&str>) -> String {
    let base = match minutes {
        0 => "window".to_owned(),
        10_080 => "weekly".to_owned(),
        m if m % 1440 == 0 => format!("{}d", m / 1440),
        m if m % 60 == 0 => format!("{}h", m / 60),
        m => format!("{m}m"),
    };
    match scope {
        Some(s) => format!("{base} {s}"),
        None => base,
    }
}

/// Milliseconds since the epoch of an RFC 3339 time (`2026-10-19T09:30:00.123Z`,
/// `…+02:00`).
pub(crate) fn rfc3339_millis(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || !matches!(b[10], b'T' | b't' | b' ') {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, se) = (num(11..13)?, num(14..16)?, num(17..19)?);
    let mut rest = &s[19..];
    let mut millis = 0i64;
    if let Some(frac) = rest.strip_prefix('.') {
        let digits = frac.bytes().take_while(u8::is_ascii_digit).count();
        let ms: String = frac[..digits]
            .chars()
            .chain("000".chars())
            .take(3)
            .collect();
        millis = ms.parse().ok()?;
        rest = &frac[digits..];
    }
    let offset = match rest {
        "Z" | "z" | "" => 0,
        o if o.len() == 6 && matches!(o.as_bytes()[0], b'+' | b'-') && o.as_bytes()[3] == b':' => {
            let sign = if o.starts_with('-') { -1 } else { 1 };
            sign * (o[1..3].parse::<i64>().ok()? * 3600 + o[4..6].parse::<i64>().ok()? * 60)
        }
        _ => return None,
    };
    // Days from the civil date (Howard Hinnant's algorithm).
    let y = if mo <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = days * 86_400 + h * 3600 + mi * 60 + se - offset;
    u64::try_from(secs * 1000 + millis).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rfc3339() {
        assert_eq!(rfc3339_millis("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            rfc3339_millis("2026-10-19T09:30:00.250Z"),
            Some(1_792_402_200_250)
        );
        assert_eq!(
            rfc3339_millis("2026-10-19T11:30:00+02:00"),
            Some(1_792_402_200_000)
        );
        assert_eq!(rfc3339_millis("yesterday"), None);
    }

    #[test]
    fn names_windows() {
        assert_eq!(window_name(300, None), "5h");
        assert_eq!(window_name(10_080, Some("Opus")), "weekly Opus");
        assert_eq!(window_name(1440, None), "1d");
        assert_eq!(window_name(0, None), "window");
    }

    #[test]
    fn permille_rounds_and_clamps() {
        assert_eq!(permille(62.04), 620);
        assert_eq!(permille(-3.0), 0);
        assert_eq!(permille(f64::NAN), 0);
    }

    #[test]
    fn unknown_says_why() {
        let u = unknown(AgentKind::Codex, &[], false);
        assert_eq!(u.source, UsageSource::Unknown);
        assert!(u.note.unwrap().contains("signed in with ChatGPT"));
        let u = unknown(AgentKind::Claude, &["claude exited with 1".into()], false);
        let note = u.note.unwrap();
        assert!(note.contains("Claude exited with 1."), "{note}");
        // No pointer to a sign-in fallback: there is none.
        assert!(!note.contains("Settings"), "{note}");
        assert_eq!(
            unknown(AgentKind::Claude, &[], true).note.as_deref(),
            Some("Checking…")
        );
    }
}
