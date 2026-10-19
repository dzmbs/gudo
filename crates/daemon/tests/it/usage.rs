//! reach a watching client, the tools' own commands answer when there is no local data, and the
//! providers' endpoints are asked only when the client opted in. Everything runs against a
//! scratch `$HOME`, fake `claude` / `codex` programs and a local HTTP server.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use client_core::proto::{AgentKind, AgentUsage, AgentUsageReport, UsageSource};
use client_core::{ClientConfig, WorkspaceEvent, WorkspaceEventQueue};
use daemon::{HookRequest, HookResponse};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, UnixStream};
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TIMEOUT, TestClient, start_with, ticket};

const ROLLOUT: &str = r#"{"timestamp":"2026-10-19T09:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/tmp"}}
{"timestamp":"2026-10-19T09:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":62.0,"window_minutes":300,"resets_at":1792410000},"secondary":{"used_percent":18.0,"window_minutes":10080,"resets_at":1792900000},"credits":null,"plan_type":"plus"}}}
"#;

const STATUS_LINE: &str = r#"{"session_id":"s1","model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":81.5,"resets_at":1792438800},"seven_day":{"used_percentage":40,"resets_at":1792760400}}}"#;

/// A scratch host: `$HOME` with the tools' directories, an empty `bin` on `PATH`.
struct Host {
    _dir: tempfile::TempDir,
    home: PathBuf,
    bin: PathBuf,
}

impl Host {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        Self {
            _dir: dir,
            home,
            bin,
        }
    }

    fn env(&self) -> Vec<(String, String)> {
        vec![
            ("HOME".into(), self.home.display().to_string()),
            ("PATH".into(), self.bin.display().to_string()),
            (
                "CODEX_HOME".into(),
                self.home.join(".codex").display().to_string(),
            ),
            (
                "CLAUDE_CONFIG_DIR".into(),
                self.home.join(".claude").display().to_string(),
            ),
        ]
    }

    fn rollout(&self) {
        let day = self.home.join(".codex/sessions/2026/10/19");
        std::fs::create_dir_all(&day).unwrap();
        std::fs::write(
            day.join("rollout-2026-10-19T09-00-00-0199a213-81c0-7800-8aa1-bbab2a035a53.jsonl"),
            ROLLOUT,
        )
        .unwrap();
    }

    fn program(&self, name: &str, script: &str) {
        let path = self.bin.join(name);
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
}

fn config(host: &Host, cli: bool) -> impl FnOnce(&mut daemon::Config) {
    let env = host.env();
    move |c: &mut daemon::Config| {
        c.pane_env.extend(env);
        c.usage.cli = cli;
    }
}

fn agent(report: &AgentUsageReport, kind: AgentKind) -> &AgentUsage {
    report
        .agents
        .iter()
        .find(|a| a.agent == kind)
        .unwrap_or_else(|| panic!("{kind:?} missing from {report:?}"))
}

async fn status_line(state_dir: &Path, socket: &Path, payload: &str) {
    let request = HookRequest {
        v: 1,
        token: std::fs::read_to_string(state_dir.join("hook.token")).unwrap(),
        pane: "0".into(),
        agent: "claude".into(),
        event: daemon::STATUS_LINE_EVENT.into(),
        seq: 1,
        payload: serde_json::from_str(payload).unwrap(),
    };
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    let answer: HookResponse = serde_json::from_str(&answer).unwrap();
    assert!(
        answer.stdout.is_none(),
        "the shim prints the user's line itself"
    );
}

/// The next usage push that satisfies `want`.
async fn next_usage(
    events: &mut UnboundedReceiver<WorkspaceEvent>,
    want: impl Fn(&AgentUsageReport) -> bool,
) -> AgentUsageReport {
    loop {
        let event = tokio::time::timeout(TIMEOUT, events.recv())
            .await
            .expect("a usage push")
            .expect("events open");
        if let WorkspaceEvent::AgentUsage { report } = event
            && want(&report)
        {
            return report;
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn codex_rollouts_and_claude_status_line_reach_a_watching_client() {
    let state = tempfile::tempdir().unwrap();
    let host = Host::new();
    host.rollout();
    let daemon = start_with(state.path(), config(&host, true)).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let info = c.infos.last().cloned().flatten().expect("daemon info");
    assert!(
        info.features
            .contains(client_core::proto::DaemonFeatures::AGENT_USAGE)
    );
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);

    let report = c.client.usage_watch(false).await.unwrap();
    let codex = agent(&report, AgentKind::Codex);
    assert_eq!(codex.source, UsageSource::LocalLog);
    assert_eq!(codex.plan.as_deref(), Some("plus"));
    assert_eq!(codex.windows[0].name, "5h");
    assert_eq!(codex.windows[0].used_permille, 620);
    assert_eq!(codex.windows[1].name, "weekly");
    // Claude has said nothing yet and `claude` is not on the PATH: listed, with the reason
    // once the daemon has looked.
    assert_eq!(
        agent(&report, AgentKind::Claude).note.as_deref(),
        Some("Checking…")
    );
    let report = next_usage(&mut events, |r| {
        r.agents
            .iter()
            .any(|a| a.note.as_deref().is_some_and(|n| n.contains("PATH")))
    })
    .await;
    assert_eq!(
        agent(&report, AgentKind::Codex).windows[0].used_permille,
        620
    );
    let claude = agent(&report, AgentKind::Claude);
    assert_eq!(claude.source, UsageSource::Unknown);
    assert!(claude.windows.is_empty());
    let note = claude.note.as_deref().unwrap();
    assert!(note.contains("not on the PATH"), "{note}");
    assert!(note.contains("Settings › Agents"), "{note}");

    // A Claude session's status line arrives: pushed at once.
    status_line(state.path(), daemon.hook_socket(), STATUS_LINE).await;
    let pushed = next_usage(&mut events, |r| {
        r.agents
            .iter()
            .any(|a| a.agent == AgentKind::Claude && a.source == UsageSource::StatusLine)
    })
    .await;
    let claude = agent(&pushed, AgentKind::Claude);
    assert_eq!(claude.source, UsageSource::StatusLine);
    assert_eq!(claude.windows[0].used_permille, 815);
    assert_eq!(claude.windows[1].name, "weekly");
    assert_eq!(
        agent(&pushed, AgentKind::Codex).windows[0].used_permille,
        620
    );

    // The same numbers again are not news.
    status_line(state.path(), daemon.hook_socket(), STATUS_LINE).await;
    // After unwatching, changes are not pushed.
    c.client.usage_unwatch().await.unwrap();
    status_line(
        state.path(),
        daemon.hook_socket(),
        &STATUS_LINE.replace("81.5", "90"),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(event, WorkspaceEvent::AgentUsage { .. }),
            "pushed after unwatch: {event:?}"
        );
    }
    drop(c);
    daemon.shutdown().await;

    // The last status line survives a restart.
    let daemon = start_with(state.path(), config(&host, true)).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let report = c.client.usage_watch(false).await.unwrap();
    let claude = agent(&report, AgentKind::Claude);
    assert_eq!(claude.source, UsageSource::StatusLine);
    assert_eq!(claude.windows[0].used_permille, 900);
    drop(c);
    daemon.shutdown().await;
}

const FAKE_CLAUDE: &str = r#"#!/bin/sh
if [ "$1" = "auth" ]; then
  echo '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'
  exit 0
fi
if [ "$1" = "-p" ] && [ "$2" = "/usage" ]; then
  echo '{"type":"system","subtype":"init"}'
  echo '{"type":"assistant","message":{"model":"<synthetic>","usage_report":{"session":{},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":17,"resets_at":"2026-10-19T19:40:00.280888+00:00","scope":null,"severity":"normal"},{"kind":"weekly_all","group":"weekly","percent":58,"resets_at":"2026-10-23T13:00:00+00:00","scope":null,"severity":"normal"},{"kind":"weekly_scoped","group":"weekly","percent":3,"resets_at":"2026-10-23T13:00:00+00:00","scope":{"model":{"display_name":"Opus"}},"severity":"normal"}]}}}}'
  echo '{"type":"result","subtype":"success","result":"Current session: 17% used"}'
  exit 0
fi
exit 1
"#;

const FAKE_CODEX: &str = r#"#!/bin/sh
[ "$1" = "app-server" ] || exit 1
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) echo '{"id":1,"result":{"userAgent":"codex"}}' ;;
    *'account/rateLimits/read'*)
      echo '{"method":"account/rateLimits/updated","params":{}}'
      echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":91,"windowDurationMins":300,"resetsAt":1792410000},"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1792900000},"planType":"pro"}}}' ;;
  esac
done
"#;

#[tokio::test(flavor = "multi_thread")]
async fn the_tools_commands_answer_when_there_is_no_local_data() {
    let state = tempfile::tempdir().unwrap();
    let host = Host::new();
    host.program("claude", FAKE_CLAUDE);
    host.program("codex", FAKE_CODEX);
    let daemon = start_with(state.path(), config(&host, true)).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);

    // The answer comes at once (the commands take seconds); their results are pushed.
    let first = c.client.usage_watch(false).await.unwrap();
    assert_eq!(
        agent(&first, AgentKind::Claude).note.as_deref(),
        Some("Checking…")
    );
    let report = next_usage(&mut events, |r| {
        r.agents.iter().all(|a| a.source == UsageSource::Cli)
    })
    .await;
    let claude = agent(&report, AgentKind::Claude);
    assert_eq!(claude.source, UsageSource::Cli);
    assert_eq!(claude.plan.as_deref(), Some("max"));
    let names: Vec<_> = claude.windows.iter().map(|w| w.name.as_str()).collect();
    assert_eq!(names, ["5h", "weekly", "weekly Opus"]);
    assert_eq!(claude.windows[1].used_permille, 580);
    let codex = agent(&report, AgentKind::Codex);
    assert_eq!(codex.source, UsageSource::Cli);
    assert_eq!(codex.plan.as_deref(), Some("pro"));
    assert_eq!(codex.windows[0].used_permille, 910);
    drop(c);
    daemon.shutdown().await;
}

/// A one-request-per-connection HTTP server answering `body` and recording request heads.
async fn serve(body: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/usage", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut buf = vec![0; 8192];
            let n = stream.read(&mut buf).await.unwrap_or(0);
            log.lock()
                .unwrap()
                .push(String::from_utf8_lossy(&buf[..n]).to_lowercase());
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes()).await;
        }
    });
    (url, seen)
}

#[tokio::test(flavor = "multi_thread")]
async fn the_endpoints_are_asked_only_after_opting_in() {
    let state = tempfile::tempdir().unwrap();
    let host = Host::new();
    std::fs::write(
        host.home.join(".claude/.credentials.json"),
        r#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-secret","subscriptionType":"pro"}}"#,
    )
    .unwrap();
    std::fs::write(
        host.home.join(".codex/auth.json"),
        r#"{"tokens":{"access_token":"codex-secret","account_id":"acct-1"}}"#,
    )
    .unwrap();
    let (claude_url, claude_seen) = serve(
        r#"{"five_hour":{"utilization":44.0,"resets_at":"2026-10-19T19:40:00Z"},"seven_day":{"utilization":12.0,"resets_at":"2026-10-23T13:00:00Z"},"seven_day_opus":null}"#,
    )
    .await;
    let (codex_url, codex_seen) = serve(
        r#"{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_after_seconds":60,"reset_at":1792410000},"secondary_window":{"used_percent":2,"limit_window_seconds":604800,"reset_after_seconds":60,"reset_at":1792900000}}}"#,
    )
    .await;
    let env = host.env();
    let daemon = start_with(state.path(), move |c| {
        c.pane_env.extend(env);
        c.usage.cli = false;
        c.usage.claude_url = claude_url;
        c.usage.codex_url = codex_url;
    })
    .await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);

    // Off by default: nothing asked.
    let report = c.client.usage_watch(false).await.unwrap();
    assert_eq!(
        agent(&report, AgentKind::Claude).source,
        UsageSource::Unknown
    );
    assert_eq!(
        agent(&report, AgentKind::Codex).source,
        UsageSource::Unknown
    );
    assert!(claude_seen.lock().unwrap().is_empty());
    assert!(codex_seen.lock().unwrap().is_empty());

    // Opted in.
    c.client.usage_watch(true).await.unwrap();
    let report = next_usage(&mut events, |r| {
        r.agents.iter().all(|a| a.source == UsageSource::Api)
    })
    .await;
    let claude = agent(&report, AgentKind::Claude);
    assert_eq!(claude.source, UsageSource::Api);
    assert_eq!(claude.plan.as_deref(), Some("pro"));
    assert_eq!(claude.windows[0].used_permille, 440);
    let codex = agent(&report, AgentKind::Codex);
    assert_eq!(codex.source, UsageSource::Api);
    assert_eq!(codex.plan.as_deref(), Some("plus"));
    assert_eq!(codex.windows[1].name, "weekly");

    let claude_req = claude_seen.lock().unwrap().join("\n");
    assert!(claude_req.contains("authorization: bearer sk-ant-oat-secret"));
    assert!(claude_req.contains("anthropic-beta: oauth-2025-04-20"));
    let codex_req = codex_seen.lock().unwrap().join("\n");
    assert!(codex_req.contains("authorization: bearer codex-secret"));
    assert!(codex_req.contains("chatgpt-account-id: acct-1"));
    // The sign-in never reaches the client.
    let wire = format!("{report:?}");
    assert!(!wire.contains("secret"), "{wire}");

    // Cached: asking again within the interval does not call the endpoints.
    c.client.usage_watch(true).await.unwrap();
    assert_eq!(claude_seen.lock().unwrap().len(), 1);
    assert_eq!(codex_seen.lock().unwrap().len(), 1);
    drop(c);
    daemon.shutdown().await;
}
