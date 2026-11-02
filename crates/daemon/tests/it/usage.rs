//! Agent plan usage: Codex rollouts and Claude's status-line input on the host
//! reach a watching client, the tools' own commands answer when there is no local data, and the
//! host's sign-ins are never used. Everything runs against a scratch `$HOME` and fake `claude` /
//! `codex` programs.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use client_core::proto::{
    AgentKind, AgentUsage, AgentUsageReport, UsageSource, UsageWatch, WorkspaceRequest,
    WorkspaceResponse,
};
use client_core::{ClientConfig, WorkspaceEvent, WorkspaceEventQueue};
use daemon::{HookRequest, HookResponse};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
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
    move |config: &mut daemon::Config| {
        config.pane_env.extend(env);
        config.usage.cli = cli;
    }
}

fn agent(report: &AgentUsageReport, kind: AgentKind) -> &AgentUsage {
    report
        .agents
        .iter()
        .find(|usage| usage.agent == kind)
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
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    client.attach_and_follow().await;
    let info = client.infos.last().cloned().flatten().expect("daemon info");
    assert!(
        info.features
            .contains(client_core::proto::DaemonFeatures::AGENT_USAGE)
    );
    let (listener, mut events) = WorkspaceEventQueue::channel();
    client.client.set_workspace_listener(listener);

    let report = client.client.usage_watch().await.unwrap();
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
    let report = next_usage(&mut events, |report| {
        report.agents.iter().any(|usage| {
            usage
                .note
                .as_deref()
                .is_some_and(|note| note.contains("PATH"))
        })
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
    assert!(
        !note.contains("Settings"),
        "no sign-in fallback to point to: {note}"
    );

    // A Claude session's status line arrives: pushed at once.
    status_line(state.path(), daemon.hook_socket(), STATUS_LINE).await;
    let pushed = next_usage(&mut events, |report| {
        report.agents.iter().any(|usage| {
            usage.agent == AgentKind::Claude && usage.source == UsageSource::StatusLine
        })
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
    client.client.usage_unwatch().await.unwrap();
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
    drop(client);
    daemon.shutdown().await;

    // The last status line survives a restart.
    let daemon = start_with(state.path(), config(&host, true)).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    client.attach_and_follow().await;
    let report = client.client.usage_watch().await.unwrap();
    let claude = agent(&report, AgentKind::Claude);
    assert_eq!(claude.source, UsageSource::StatusLine);
    assert_eq!(claude.windows[0].used_permille, 900);
    drop(client);
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
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    client.attach_and_follow().await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    client.client.set_workspace_listener(listener);

    // The answer comes at once (the commands take seconds); their results are pushed.
    let first = client.client.usage_watch().await.unwrap();
    assert_eq!(
        agent(&first, AgentKind::Claude).note.as_deref(),
        Some("Checking…")
    );
    let report = next_usage(&mut events, |report| {
        report
            .agents
            .iter()
            .all(|usage| usage.source == UsageSource::Cli)
    })
    .await;
    let claude = agent(&report, AgentKind::Claude);
    assert_eq!(claude.source, UsageSource::Cli);
    assert_eq!(claude.plan.as_deref(), Some("max"));
    let names: Vec<_> = claude
        .windows
        .iter()
        .map(|window| window.name.as_str())
        .collect();
    assert_eq!(names, ["5h", "weekly", "weekly Opus"]);
    assert_eq!(claude.windows[1].used_permille, 580);
    let codex = agent(&report, AgentKind::Codex);
    assert_eq!(codex.source, UsageSource::Cli);
    assert_eq!(codex.plan.as_deref(), Some("pro"));
    assert_eq!(codex.windows[0].used_permille, 910);
    drop(client);
    daemon.shutdown().await;
}

/// A client that still sends `api_fallback` (older apps) gets the documented sources only: the
/// host's Claude and Codex sign-ins are not used and no usage endpoint is asked.
#[tokio::test(flavor = "multi_thread")]
async fn the_sign_in_is_never_used_even_when_a_client_asks() {
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
    let env = host.env();
    let daemon = start_with(state.path(), move |config| {
        config.pane_env.extend(env);
        config.usage.cli = false;
    })
    .await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    client.attach_and_follow().await;

    // What an older app sends when its "check usage with your sign-in" switch was on.
    let watch = || async {
        let request = WorkspaceRequest::UsageWatch(UsageWatch { api_fallback: true });
        match client.client.workspace(request).await.unwrap() {
            WorkspaceResponse::AgentUsage(report) => report,
            other => panic!("{other:?}"),
        }
    };
    watch().await;
    // Anything asked in the background would have answered by now.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let report = watch().await;
    for kind in [AgentKind::Claude, AgentKind::Codex] {
        let usage = agent(&report, kind);
        assert_eq!(usage.source, UsageSource::Unknown, "{kind:?}");
        let note = usage.note.as_deref().unwrap_or_default().to_lowercase();
        // Neither a sign-in's answer nor a pointer to a sign-in fallback.
        assert!(
            !note.contains("sign-in") && !note.contains("checking"),
            "{note}"
        );
    }
    assert!(!format!("{report:?}").contains("secret"));
    drop(client);
    daemon.shutdown().await;
}
