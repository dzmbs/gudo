//! Agent accounts against a real daemon: an account's sign-in runs the agent's own login in
//! its own directory, agent panes under a named account run with every credential variable
//! removed (even one a startup file exports) while the system account keeps them, resume stays with the account that made the
//! session, sign-out runs the agent's logout before the directory goes, usage counts per
//! account, and guests neither see nor choose accounts. `claude` is a script that honours
//! `CLAUDE_CONFIG_DIR` the way Claude Code documents it; nothing signs in for real.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use client_core::grants::GrantSpec;
use client_core::proto::{
    AccountAdd, AccountStatus, AccountsReport, AgentAccount, AgentKind, LayoutOp, OpOutcome,
    PaneId, PaneLaunch, Roles, SYSTEM_ACCOUNT, Scope, UnixMillis, WorkspaceRequest,
    WorkspaceResponse, WsError,
};
use client_core::{ClientConfig, now_millis};

use crate::support::{TIMEOUT, TestClient, start_with, ticket};

/// Prints its environment, then: `auth login` signs the directory in (the user's part, done
/// here by the fake), `auth status --json` reports it, `auth logout` signs out and logs it.
const FAKE_CLAUDE: &str = r#"#!/bin/sh
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$1 $2" in
  "auth login") mkdir -p "$dir"; echo "work@example.com" > "$dir/.fake-login"; echo "login done"; exit 0 ;;
  "auth logout") echo "logout $dir" >> "$FAKE_LOG"; rm -f "$dir/.fake-login"; exit 0 ;;
  "auth status")
    if [ -f "$dir/.fake-login" ]; then
      printf '{"loggedIn":true,"authMethod":"claude.ai","email":"%s","subscriptionType":"max"}\n' "$(cat "$dir/.fake-login")"
      exit 0
    fi
    echo '{"loggedIn":false,"authMethod":"none"}'; exit 1 ;;
esac
echo "CFG=${CLAUDE_CONFIG_DIR:-unset}|"
echo "ACC=${UN_ACCOUNT:-unset}|"
echo "KEY=${ANTHROPIC_API_KEY:-none}|"
echo "TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-none}|"
echo "CODEX=${CODEX_HOME:-none}|"
echo "ARGS $*"
exec sleep 600
"#;

struct Host {
    _dir: tempfile::TempDir,
    home: PathBuf,
    log: PathBuf,
    env: Vec<(String, String)>,
}

impl Host {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        // A startup file that exports a key: it must still not reach an agent.
        std::fs::write(
            home.join(".profile"),
            "export ANTHROPIC_API_KEY=from-profile\nexport CLAUDE_CODE_OAUTH_TOKEN=from-profile\n",
        )
        .unwrap();
        let claude = bin.join("claude");
        std::fs::write(&claude, FAKE_CLAUDE).unwrap();
        std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
        let log = dir.path().join("log");
        let path = format!("{}:/usr/bin:/bin", bin.display());
        let env = vec![
            ("HOME".into(), home.display().to_string()),
            ("PATH".into(), path),
            ("FAKE_LOG".into(), log.display().to_string()),
            ("ANTHROPIC_API_KEY".into(), "from-daemon".into()),
            (
                "CODEX_HOME".into(),
                home.join(".codex").display().to_string(),
            ),
            (
                "CLAUDE_CONFIG_DIR".into(),
                home.join(".claude").display().to_string(),
            ),
        ];
        Self {
            _dir: dir,
            home,
            log,
            env,
        }
    }

    fn config(&self) -> impl FnOnce(&mut daemon::Config) + use<> {
        let env = self.env.clone();
        move |c: &mut daemon::Config| {
            c.pane_env.extend(env);
            c.usage.cli = false;
        }
    }
}

async fn ask(c: &TestClient, req: WorkspaceRequest) -> Result<WorkspaceResponse, WsError> {
    tokio::time::timeout(TIMEOUT, c.client.workspace(req))
        .await
        .expect("an answer")
}

async fn report(c: &TestClient) -> AccountsReport {
    match ask(c, WorkspaceRequest::Accounts).await {
        Ok(WorkspaceResponse::Accounts(r)) => r,
        other => panic!("accounts: {other:?}"),
    }
}

async fn add(c: &TestClient, label: &str) -> AgentAccount {
    match ask(
        c,
        WorkspaceRequest::AccountAdd(AccountAdd {
            agent: AgentKind::Claude,
            label: label.into(),
            color: 2,
        }),
    )
    .await
    {
        Ok(WorkspaceResponse::Account(a)) => a,
        other => panic!("add: {other:?}"),
    }
}

async fn new_tab(c: &mut TestClient, launch: PaneLaunch) -> OpOutcome {
    let session_id = c.layout.as_ref().unwrap().session_id;
    c.op(LayoutOp::NewTab {
        session_id,
        name: String::new(),
        launch,
    })
    .await
}

async fn agent_tab(c: &mut TestClient, account: Option<&str>, resume: Option<&str>) -> PaneId {
    let launch = PaneLaunch::AccountAgent {
        agent: AgentKind::Claude,
        account: account.map(str::to_owned),
        resume: resume.map(str::to_owned),
        cwd: None,
    };
    match new_tab(c, launch).await {
        OpOutcome::TabCreated { pane_id, .. } => {
            c.follow(pane_id).await;
            c.wait_flat(pane_id, "ARGS").await;
            pane_id
        }
        other => panic!("agent tab: {other:?}"),
    }
}

/// The value after `key=` in the fake's output (each ends with `|`: rows join unseparated).
fn field(text: &str, key: &str) -> String {
    let after = text.split(&format!("{key}=")).nth(1).unwrap_or_default();
    after.split('|').next().unwrap_or_default().to_owned()
}

/// Waits until `account` is signed in, asking the daemon as the app would.
async fn signed_in(c: &TestClient, account: &str) -> AgentAccount {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        let check = WorkspaceRequest::AccountCheck {
            agent: AgentKind::Claude,
            account: account.into(),
        };
        if let Ok(WorkspaceResponse::Account(a)) = ask(c, check).await
            && matches!(a.status, AccountStatus::SignedIn(_))
        {
            return a;
        }
        assert!(Instant::now() < deadline, "never signed in");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn dir_of(state: &Path, id: &str) -> PathBuf {
    state.join("accounts/claude").join(id)
}

#[tokio::test(flavor = "multi_thread")]
async fn accounts_sign_in_launch_resume_and_sign_out_in_their_own_directory() {
    let state = tempfile::tempdir().unwrap();
    let host = Host::new();
    let daemon = start_with(state.path(), host.config()).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;

    // Only the system accounts at first, unchanged.
    let first = report(&c).await;
    assert_eq!(first.accounts.len(), 2);
    assert!(first.accounts.iter().all(AgentAccount::is_system));

    let work = add(&c, "Work").await;
    let dir = dir_of(state.path(), &work.id);
    assert_eq!(
        std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
        0o700
    );

    // Sign-in: the agent's own login, in the account's directory only.
    let sign_in = PaneLaunch::AccountSignIn {
        agent: AgentKind::Claude,
        account: work.id.clone(),
        device_code: false,
    };
    let OpOutcome::TabCreated { pane_id: login, .. } = new_tab(&mut c, sign_in).await else {
        panic!("sign-in tab");
    };
    c.follow(login).await;
    c.wait_flat(login, "login done").await;
    let signed = signed_in(&c, &work.id).await;
    let AccountStatus::SignedIn(who) = &signed.status else {
        unreachable!()
    };
    assert_eq!(who.email.as_deref(), Some("work@example.com"));
    assert!(dir.join(".fake-login").exists());
    // The user's own directory was not touched.
    assert!(!host.home.join(".claude/.fake-login").exists());

    // An agent under Work: its directory, no credential, not even one the profile exports.
    let pane = agent_tab(&mut c, Some(&work.id), None).await;
    let text = c.flat_text(pane);
    assert_eq!(field(&text, "CFG"), dir.display().to_string(), "{text}");
    assert_eq!(field(&text, "ACC"), work.id);
    assert_eq!(field(&text, "KEY"), "none", "{text}");
    assert_eq!(field(&text, "TOKEN"), "none", "{text}");
    assert_eq!(field(&text, "CODEX"), "none", "{text}");
    let session = text
        .split("--session-id ")
        .nth(1)
        .and_then(|s| s.split_whitespace().next())
        .unwrap()
        .to_owned();
    let panes = report(&c).await.panes;
    assert!(
        panes
            .iter()
            .any(|p| p.pane_id == pane && p.account == work.id)
    );

    // The system account behaves as before accounts: the user's own directory and keys.
    let own = agent_tab(&mut c, None, None).await;
    let text = c.flat_text(own);
    assert_eq!(
        field(&text, "CFG"),
        host.home.join(".claude").display().to_string()
    );
    assert_eq!(field(&text, "ACC"), SYSTEM_ACCOUNT);
    assert_eq!(field(&text, "KEY"), "from-profile", "{text}");
    assert_eq!(field(&text, "TOKEN"), "from-profile", "{text}");

    // Removing an account in use is refused.
    let remove = WorkspaceRequest::AccountRemove {
        agent: AgentKind::Claude,
        account: work.id.clone(),
    };
    assert!(matches!(
        ask(&c, remove.clone()).await,
        Err(WsError::Conflict(_))
    ));

    // Resume runs under the account that made the session, whatever is asked.
    assert!(matches!(
        c.op(LayoutOp::ClosePane { pane_id: pane }).await,
        OpOutcome::Done
    ));
    let resumed = agent_tab(&mut c, Some(SYSTEM_ACCOUNT), Some(&session)).await;
    let text = c.flat_text(resumed);
    assert!(text.contains(&format!("--resume {session}")), "{text}");
    assert_eq!(field(&text, "CFG"), dir.display().to_string(), "{text}");
    assert!(matches!(
        c.op(LayoutOp::ClosePane { pane_id: resumed }).await,
        OpOutcome::Done
    ));

    // Sign-out: the agent's own logout first, then the directory goes.
    assert!(matches!(
        ask(&c, remove).await,
        Ok(WorkspaceResponse::Accounts(_))
    ));
    let log = std::fs::read_to_string(&host.log).unwrap();
    assert!(log.contains(&format!("logout {}", dir.display())), "{log}");
    assert!(!dir.exists());
    // Its session no longer resumes, under any account.
    let launch = PaneLaunch::AccountAgent {
        agent: AgentKind::Claude,
        account: None,
        resume: Some(session),
        cwd: None,
    };
    match new_tab(&mut c, launch).await {
        OpOutcome::Failed { message, .. } => assert!(message.contains("removed"), "{message}"),
        other => panic!("resumed under another account: {other:?}"),
    }
    // The system account cannot be removed.
    let system = WorkspaceRequest::AccountRemove {
        agent: AgentKind::Claude,
        account: SYSTEM_ACCOUNT.into(),
    };
    assert!(ask(&c, system).await.is_err());
    drop(c);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn defaults_choose_the_account_and_survive_a_restart() {
    let state = tempfile::tempdir().unwrap();
    let host = Host::new();
    let daemon = start_with(state.path(), host.config()).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let work = add(&c, "Work").await;
    let set = WorkspaceRequest::AccountSetDefault {
        agent: AgentKind::Claude,
        project: None,
        account: Some(work.id.clone()),
    };
    let Ok(WorkspaceResponse::Accounts(r)) = ask(&c, set).await else {
        panic!("set default");
    };
    assert_eq!(r.default_for(AgentKind::Claude, None), work.id);
    assert_eq!(r.default_for(AgentKind::Codex, None), SYSTEM_ACCOUNT);
    // A launch naming no account takes the host default; old clients' `Agent` too.
    let pane = agent_tab(&mut c, None, None).await;
    assert_eq!(field(&c.flat_text(pane), "ACC"), work.id);
    let old = PaneLaunch::Agent {
        agent: AgentKind::Claude,
        resume: None,
        cwd: None,
    };
    let OpOutcome::TabCreated { pane_id: old, .. } = new_tab(&mut c, old).await else {
        panic!("agent tab");
    };
    c.follow(old).await;
    c.wait_flat(old, "ARGS").await;
    assert_eq!(field(&c.flat_text(old), "ACC"), work.id);
    drop(c);
    daemon.shutdown().await;

    // After a restart the pane comes back under its account.
    let daemon = start_with(state.path(), host.config()).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.client.attach(None);
    c.until("layout", |c| c.layout.is_some()).await;
    c.follow(pane).await;
    c.wait_flat(pane, "--resume").await;
    assert_eq!(field(&c.flat_text(pane), "ACC"), work.id);
    let r = report(&c).await;
    assert_eq!(r.default_for(AgentKind::Claude, None), work.id);
    drop(c);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_neither_see_nor_choose_the_owners_accounts() {
    let state = tempfile::tempdir().unwrap();
    let host = Host::new();
    let daemon = start_with(state.path(), host.config()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let work = add(&owner, "Work").await;

    // Even a guest whose grant names every role is not the owner's device.
    let mut spec = GrantSpec::new(
        Roles::VIEWER | Roles::PROMPTER | Roles::DRIVER | Roles::APPROVER | Roles::OWNER,
        Scope::Daemon,
    );
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "owner".into())
        .await
        .unwrap()
        .to_string();
    let mut guest = TestClient::join(&invite, ClientConfig::generate_key());
    guest.client.attach(None);
    guest.until("guest attached", |c| c.layout.is_some()).await;

    assert!(matches!(
        ask(&guest, WorkspaceRequest::Accounts).await,
        Err(WsError::Denied(_))
    ));
    let check = WorkspaceRequest::AccountCheck {
        agent: AgentKind::Claude,
        account: work.id.clone(),
    };
    assert!(ask(&guest, check).await.is_err());
    for launch in [
        PaneLaunch::AccountAgent {
            agent: AgentKind::Claude,
            account: Some(work.id.clone()),
            resume: None,
            cwd: None,
        },
        PaneLaunch::AccountSignIn {
            agent: AgentKind::Claude,
            account: work.id.clone(),
            device_code: false,
        },
    ] {
        match new_tab(&mut guest, launch).await {
            OpOutcome::Failed { message, .. } => {
                assert!(message.contains("owner"), "{message}");
            }
            other => panic!("a guest chose an account: {other:?}"),
        }
    }
    drop(guest);
    drop(owner);
    daemon.shutdown().await;
}

const STATUS_LINE: &str = r#"{"session_id":"s1","workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":81.5,"resets_at":1792438800},"seven_day":{"used_percentage":40,"resets_at":1792760400}}}"#;

/// Sends a status-line input as `pane`'s hook shim would.
async fn status_line(state: &Path, socket: &Path, pane: PaneId) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let request = daemon::HookRequest {
        v: 1,
        token: std::fs::read_to_string(state.join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: daemon::STATUS_LINE_EVENT.into(),
        seq: 1,
        payload: serde_json::from_str(STATUS_LINE).unwrap(),
    };
    let mut stream = tokio::net::UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
}

/// A status line counts for the account of the pane that sent it, never for the system
/// account's meter.
#[tokio::test(flavor = "multi_thread")]
async fn usage_is_kept_per_account() {
    use client_core::{WorkspaceEvent, WorkspaceEventQueue};
    let state = tempfile::tempdir().unwrap();
    let host = Host::new();
    let daemon = start_with(state.path(), host.config()).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let work = add(&c, "Work").await;
    let pane = agent_tab(&mut c, Some(&work.id), None).await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);
    let first = c.client.usage_watch().await.unwrap();
    assert!(
        first
            .agents
            .iter()
            .all(|a| a.windows.iter().all(|w| w.used_permille != 815))
    );

    status_line(state.path(), daemon.hook_socket(), pane).await;
    let deadline = Instant::now() + TIMEOUT;
    let (accounts, system) = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let event = tokio::time::timeout(left, events.recv())
            .await
            .expect("an account usage push")
            .expect("events open");
        if let WorkspaceEvent::AccountUsage { report } = event
            && report
                .accounts
                .iter()
                .any(|a| a.account == work.id && !a.usage.windows.is_empty())
        {
            break (report, first);
        }
    };
    let entry = accounts
        .accounts
        .iter()
        .find(|a| a.account == work.id)
        .unwrap();
    assert_eq!(entry.usage.agent, AgentKind::Claude);
    assert_eq!(entry.usage.windows[0].used_permille, 815);
    let own = accounts
        .accounts
        .iter()
        .find(|a| a.account == SYSTEM_ACCOUNT && a.usage.agent == AgentKind::Claude);
    assert!(own.is_none_or(|o| o.usage.windows.iter().all(|w| w.used_permille != 815)));
    assert!(
        system
            .agents
            .iter()
            .all(|a| a.windows.iter().all(|w| w.used_permille != 815))
    );
    // Kept for the account across a restart, apart from the system account's snapshot.
    assert!(
        state
            .path()
            .join(format!("usage/claude-status-line-{}.json", work.id))
            .exists()
    );
    assert!(!state.path().join("usage/claude-status-line.json").exists());
    drop(c);
    daemon.shutdown().await;
}

const CODEX_ID: &str = "0199a213-81c0-7800-8aa1-bbab2a035a53";

/// Answers `account/read` from `$CODEX_HOME/.fake-login`, and otherwise writes a rollout under
/// `$CODEX_HOME` the way Codex does and keeps it open.
const FAKE_CODEX: &str = r#"#!/bin/sh
if [ "$1" = "app-server" ]; then
  while read -r line; do
    case "$line" in *'"id":2'*)
      if [ -f "$CODEX_HOME/.fake-login" ]; then
        echo '{"id":2,"result":{"account":{"type":"chatgpt","email":"me@codex.example","planType":"plus"},"requiresOpenaiAuth":true}}'
      else
        echo '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
      fi ;;
    esac
  done
  exit 0
fi
if [ "$1" = "login" ]; then touch "$CODEX_HOME/.fake-login"; echo "login $2 done"; exit 0; fi
echo "HOME=${CODEX_HOME:-unset}|"
echo "KEY=${OPENAI_API_KEY:-none}|"
echo "ARGS $*"
dir="$CODEX_HOME/sessions/2026/10/18"
mkdir -p "$dir"
f="$dir/rollout-2026-10-18T12-00-00-__ID__.jsonl"
if [ ! -e "$f" ]; then
  printf '{"type":"session_meta","payload":{"id":"__ID__","cwd":"%s"}}\n' "$PWD" > "$f"
fi
exec 3>>"$f"
exec sleep 600
"#;

#[tokio::test(flavor = "multi_thread")]
async fn codex_accounts_sign_in_and_resume_in_their_own_home() {
    let state = tempfile::tempdir().unwrap();
    let mut host = Host::new();
    let bin = host._dir.path().join("bin");
    let codex = bin.join("codex");
    std::fs::write(&codex, FAKE_CODEX.replace("__ID__", CODEX_ID)).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    host.env
        .push(("OPENAI_API_KEY".into(), "from-daemon".into()));
    let daemon = start_with(state.path(), host.config()).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let Ok(WorkspaceResponse::Account(work)) = ask(
        &c,
        WorkspaceRequest::AccountAdd(AccountAdd {
            agent: AgentKind::Codex,
            label: "Work".into(),
            color: 1,
        }),
    )
    .await
    else {
        panic!("add");
    };
    let home = state.path().join("accounts/codex").join(&work.id);

    // A remote host signs in with a device code, in the account's home only.
    let sign_in = PaneLaunch::AccountSignIn {
        agent: AgentKind::Codex,
        account: work.id.clone(),
        device_code: true,
    };
    let OpOutcome::TabCreated { pane_id: login, .. } = new_tab(&mut c, sign_in).await else {
        panic!("sign-in tab");
    };
    c.follow(login).await;
    c.wait_flat(login, "login --device-auth done").await;
    assert!(home.join(".fake-login").exists());
    let check = WorkspaceRequest::AccountCheck {
        agent: AgentKind::Codex,
        account: work.id.clone(),
    };
    let Ok(WorkspaceResponse::Account(checked)) = ask(&c, check).await else {
        panic!("check");
    };
    let AccountStatus::SignedIn(who) = checked.status else {
        panic!("not signed in: {checked:?}");
    };
    assert_eq!(who.email.as_deref(), Some("me@codex.example"));

    // The agent runs in the account's home; its rollout is found there.
    let launch = |resume: Option<&str>| PaneLaunch::AccountAgent {
        agent: AgentKind::Codex,
        account: resume.is_none().then(|| work.id.clone()),
        resume: resume.map(str::to_owned),
        cwd: None,
    };
    let OpOutcome::TabCreated { pane_id: pane, .. } = new_tab(&mut c, launch(None)).await else {
        panic!("codex tab");
    };
    c.follow(pane).await;
    c.wait_flat(pane, "ARGS").await;
    let text = c.flat_text(pane);
    assert_eq!(field(&text, "HOME"), home.display().to_string(), "{text}");
    assert_eq!(field(&text, "KEY"), "none", "{text}");
    let layout = state.path().join("layout.json");
    let deadline = Instant::now() + TIMEOUT;
    while !std::fs::read_to_string(&layout).is_ok_and(|s| s.contains(CODEX_ID)) {
        assert!(Instant::now() < deadline, "session id never found");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(matches!(
        c.op(LayoutOp::ClosePane { pane_id: pane }).await,
        OpOutcome::Done
    ));
    // Resuming by id alone goes back to the account that made it.
    let OpOutcome::TabCreated { pane_id: again, .. } =
        new_tab(&mut c, launch(Some(CODEX_ID))).await
    else {
        panic!("resume tab");
    };
    c.follow(again).await;
    c.wait_flat(again, &format!("resume {CODEX_ID}")).await;
    assert_eq!(
        field(&c.flat_text(again), "HOME"),
        home.display().to_string()
    );
    drop(c);
    daemon.shutdown().await;
}
