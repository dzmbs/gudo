//! A daemon that starts again after it was killed brings every pane back, but resumes its
//! agents one after another, those on screen first, so a restart never starts every agent at
//! once and loads the whole machine.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{AgentKind, Axis, LayoutOp, OpOutcome, PaneLaunch};

use crate::support::{TIMEOUT, TestClient, start_with, ticket};

/// Notes when and where it started, then keeps running as `claude`.
const FAKE_CLAUDE: &str = r#"#!/bin/bash
perl -MTime::HiRes=time -e 'printf "%.3f %s %s\n", time, $ARGV[0], $ARGV[1]' "$(basename "$(pwd -P)")" "$*" >> "$AGENT_STARTS"
echo "fake claude $*"
exec -a claude /bin/sleep 600
"#;

const AGENTS_OFF_SCREEN: usize = 4;

fn agent_in(dir: &Path) -> PaneLaunch {
    PaneLaunch::Agent {
        agent: AgentKind::Claude,
        resume: None,
        cwd: Some(dir.display().to_string()),
    }
}

struct Start {
    at: f64,
    dir: String,
    resumed: bool,
}

fn starts(log: &Path) -> Vec<Start> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let mut fields = line.splitn(3, ' ');
            Some(Start {
                at: fields.next()?.parse().ok()?,
                dir: fields.next()?.to_owned(),
                resumed: fields.next()?.contains("--resume"),
            })
        })
        .collect()
}

fn wait_for_resumes(log: &Path, count: usize) -> Vec<Start> {
    let deadline = Instant::now() + TIMEOUT * 2;
    loop {
        let resumed: Vec<Start> = starts(log)
            .into_iter()
            .filter(|start| start.resumed)
            .collect();
        if resumed.len() >= count {
            return resumed;
        }
        assert!(
            Instant::now() < deadline,
            "only {} of {count} agents resumed",
            resumed.len()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn wait_persisted(state: &Path, sessions: usize) {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        let text = std::fs::read_to_string(state.join("layout.json")).unwrap_or_default();
        if text.matches("\"session_id\"").count() >= sessions {
            return;
        }
        assert!(Instant::now() < deadline, "agents never persisted:\n{text}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn agents_resume_one_after_another_those_on_screen_first() {
    let state = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let bin = tools.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let claude = bin.join("claude");
    std::fs::write(&claude, FAKE_CLAUDE).unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
    let dir = |name: &str| -> PathBuf {
        let dir = tools.path().join(name);
        std::fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    };
    let log = tools.path().join("starts.log");
    let env = vec![
        (
            "PATH".to_owned(),
            format!(
                "{}:{}",
                bin.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        ),
        ("AGENT_STARTS".to_owned(), log.display().to_string()),
        (
            "CLAUDE_CONFIG_DIR".to_owned(),
            tools.path().join("claude-config").display().to_string(),
        ),
    ];
    let configure =
        |env: Vec<(String, String)>| move |config: &mut daemon::Config| config.pane_env.extend(env);

    let daemon = start_with(state.path(), configure(env.clone())).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let first = owner.attach_and_follow().await;
    for index in 0..AGENTS_OFF_SCREEN {
        let OpOutcome::PaneCreated { pane_id } = owner
            .op(LayoutOp::Split {
                pane_id: first,
                axis: Axis::Horizontal,
                launch: agent_in(&dir(&format!("hidden-{index}"))),
            })
            .await
        else {
            panic!("split failed");
        };
        owner.follow(pane_id).await;
        owner.wait_flat(pane_id, "fake claude").await;
    }
    let session_id = owner.layout.as_ref().unwrap().session_id;
    let OpOutcome::TabCreated { pane_id: shown, .. } = owner
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch: agent_in(&dir("shown")),
        })
        .await
    else {
        panic!("new tab failed");
    };
    owner.follow(shown).await;
    owner.wait_flat(shown, "fake claude").await;
    wait_persisted(state.path(), AGENTS_OFF_SCREEN + 1);
    drop(owner);
    daemon.shutdown().await;
    std::fs::remove_file(&log).unwrap();

    let daemon = start_with(state.path(), configure(env)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.client.attach(None);
    owner.until("layout", |owner| owner.layout.is_some()).await;
    let resumed = wait_for_resumes(&log, AGENTS_OFF_SCREEN + 1);
    assert_eq!(resumed[0].dir, "shown", "the agent on screen resumes first");
    let first_at = resumed[0].at;
    let last_at = resumed
        .iter()
        .map(|start| start.at)
        .fold(first_at, f64::max);
    assert!(
        last_at - first_at >= 2.0,
        "{} agents resumed within {:.2} s of each other",
        resumed.len(),
        last_at - first_at
    );
    drop(owner);
    daemon.shutdown().await;
}
