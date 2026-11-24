//! Chat's agent controls against a fake `claude` run through the real hook shim: a model or
//! mode change restarts Claude Code on the same conversation in the same pane (after the turn
//! when one runs), and questions and plans are answered from Chat into the held hook.

#[allow(dead_code)]
#[path = "../../daemon/tests/it/support.rs"]
mod support;

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::Duration;

use client_core::grants::GrantSpec;
use client_core::proto::{
    AgentConfigValues, AgentControls, AgentKind, AgentPrompt, ApprovalError, Axis, LayoutOp,
    OpOutcome, PaneId, PaneLaunch, QuestionAnswer, Roles, Scope, WsError,
};
use client_core::{ClientConfig, WorkspaceEvent, WorkspaceEventQueue};
use daemon::Daemon;
use support::{TIMEOUT, TestClient, start_with, ticket};
use tokio::sync::mpsc::UnboundedReceiver;

const HELP: &str = r#"Options:
  --effort <level>             Effort level for the current session
                               (low, high)
  --model <model>              Model for the current session (e.g.
                               'opus' or 'sonnet') or a model's full name.
  --permission-mode <mode>     Permission mode to use for the session
                               (choices: "default", "plan", "bypassPermissions")
"#;

/// A `claude` that prints its arguments, reports hooks for lines typed into it (`prompt`,
/// `stop`, `ask`, `plan`) and prints what a held hook answers.
fn fake_claude(hook: &str) -> String {
    format!(
        r#"#!/bin/sh
case "$1" in
  --help) cat <<'HELP'
{HELP}HELP
    exit 0 ;;
  --version) echo "2.1.331 (Claude Code)"; exit 0 ;;
esac
echo "AGENT-UP $*"
session=""
mode="default"
previous=""
for argument in "$@"; do
  case "$previous" in
    --session-id|--resume) session="$argument" ;;
    --permission-mode) mode="$argument" ;;
  esac
  previous="$argument"
done
hook() {{ printf '%s' "$2" | '{hook}' claude "$1"; }}
trap 'echo AGENT-TERM; exit 0' TERM
hook SessionStart '{{"session_id":"'"$session"'","hook_event_name":"SessionStart","source":"startup","permission_mode":"'"$mode"'"}}'
while IFS= read -r line; do
  case "$line" in
    prompt) hook UserPromptSubmit '{{"session_id":"'"$session"'","hook_event_name":"UserPromptSubmit","prompt":"go"}}'; echo TURN-START ;;
    stop) hook Stop '{{"session_id":"'"$session"'","hook_event_name":"Stop"}}'; echo TURN-END ;;
    ask) out=$(hook HeldPreToolUse '{{"session_id":"'"$session"'","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{{"questions":[{{"question":"Which framework?","header":"Framework","multiSelect":false,"options":[{{"label":"React","description":"Components"}}]}}]}}}}'); echo "HOOK-OUT:[$out]" ;;
    plan) out=$(hook HeldPreToolUse '{{"session_id":"'"$session"'","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{{"plan":"Step one"}}}}'); echo "HOOK-OUT:[$out]" ;;
  esac
done
"#
    )
}

struct Fixture {
    daemon: Daemon,
    owner: TestClient,
    pane: PaneId,
    events: UnboundedReceiver<WorkspaceEvent>,
}

async fn launch(dir: &Path) -> Fixture {
    let home = dir.join("home");
    let bin = dir.join("programs");
    std::fs::create_dir(&home).unwrap();
    std::fs::write(home.join(".profile"), "PS1='SHELL> '; export PS1\n").unwrap();
    std::fs::create_dir(&bin).unwrap();
    let program = bin.join("claude");
    std::fs::write(&program, fake_claude(env!("CARGO_BIN_EXE_gudo-hook"))).unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    let path = format!("{}:/usr/bin:/bin", bin.display());
    let daemon = start_with(&dir.join("state"), |config| {
        config.hook_bin = Some(env!("CARGO_BIN_EXE_gudo-hook").into());
        config.pane_env.extend([
            ("HOME".into(), home.to_string_lossy().into_owned()),
            ("PATH".into(), path),
            (
                "CLAUDE_CONFIG_DIR".into(),
                home.join(".claude").to_string_lossy().into_owned(),
            ),
        ]);
    })
    .await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let (listener, events) = WorkspaceEventQueue::channel();
    owner.client.set_workspace_listener(listener);
    let first = owner.attach_and_follow().await;
    let outcome = owner
        .op(LayoutOp::Split {
            pane_id: first,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Agent {
                agent: AgentKind::Claude,
                cwd: Some(home.to_string_lossy().into_owned()),
                resume: None,
            },
        })
        .await;
    let OpOutcome::PaneCreated { pane_id: pane } = outcome else {
        panic!("agent launch: {outcome:?}")
    };
    owner.follow(pane).await;
    owner.wait_flat(pane, "AGENT-UP").await;
    Fixture {
        daemon,
        owner,
        pane,
        events,
    }
}

impl Fixture {
    async fn watch(&mut self) -> AgentControls {
        self.owner
            .client
            .agent_controls_watch(self.pane)
            .await
            .unwrap()
    }

    /// The next controls push that `done` accepts.
    async fn controls(&mut self, done: impl Fn(&AgentControls) -> bool) -> AgentControls {
        let deadline = tokio::time::Instant::now() + TIMEOUT;
        loop {
            let event = tokio::time::timeout_at(deadline, self.events.recv())
                .await
                .expect("controls push")
                .expect("events");
            if let WorkspaceEvent::AgentControls { controls } = event
                && done(&controls)
            {
                return controls;
            }
        }
    }

    async fn turn(&mut self) {
        self.owner.type_line(self.pane, "prompt");
        self.owner.wait_flat(self.pane, "TURN-START").await;
        self.owner.type_line(self.pane, "stop");
        self.owner.wait_flat(self.pane, "TURN-END").await;
    }

    fn session(&self) -> String {
        let text = self.owner.flat_text(self.pane);
        let after = text.split("--session-id ").nth(1).expect("pinned session");
        after.split_whitespace().next().unwrap().to_owned()
    }
}

fn change(model: Option<&str>, mode: Option<&str>) -> AgentConfigValues {
    AgentConfigValues {
        model: model.map(str::to_owned),
        mode: mode.map(str::to_owned),
        effort: None,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_model_change_restarts_claude_on_the_same_conversation_in_the_same_pane() {
    let dir = tempfile::tempdir().unwrap();
    let mut fixture = launch(dir.path()).await;
    let controls = fixture.watch().await;
    let ids = |choices: &[client_core::proto::AgentChoice]| -> Vec<String> {
        choices.iter().map(|choice| choice.id.clone()).collect()
    };
    assert!(ids(&controls.config.models).contains(&"sonnet".to_owned()));
    let modes: Vec<_> = controls
        .config
        .modes
        .iter()
        .map(|mode| mode.choice.id.clone())
        .collect();
    assert_eq!(modes, ["default", "plan", "bypassPermissions"]);
    assert_eq!(ids(&controls.config.efforts), ["low", "high"]);
    assert_eq!(controls.config.current.mode.as_deref(), Some("default"));
    let session = fixture.session();
    fixture.turn().await;

    let changed = fixture
        .owner
        .client
        .set_agent_config(fixture.pane, change(Some("sonnet"), None))
        .await
        .unwrap();
    assert_eq!(changed.config.current.model.as_deref(), Some("sonnet"));
    let (owner, pane) = (&mut fixture.owner, fixture.pane);
    owner.wait_flat(pane, "AGENT-TERM").await;
    owner
        .wait_flat(pane, &format!("AGENT-UP --resume {session} --model sonnet"))
        .await;
    let leaves = support::leaves(&owner.layout.as_ref().unwrap().tabs[0].root);
    assert!(leaves.contains(&pane), "the pane stays: {leaves:?}");
    tokio::time::sleep(Duration::from_millis(800)).await;
    owner
        .until("agent stays", |client| {
            client
                .metas
                .get(&pane)
                .and_then(|meta| meta.agent.as_ref())
                .is_some_and(|agent| agent.kind == "claude")
        })
        .await;
    assert!(
        !owner.flat_text(pane).contains("SHELL>"),
        "never falls back to the shell: {}",
        owner.flat_text(pane)
    );
    fixture.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_change_during_a_turn_applies_when_the_turn_ends() {
    let dir = tempfile::tempdir().unwrap();
    let mut fixture = launch(dir.path()).await;
    fixture.watch().await;
    fixture.owner.type_line(fixture.pane, "prompt");
    fixture.owner.wait_flat(fixture.pane, "TURN-START").await;

    let waiting = fixture
        .owner
        .client
        .set_agent_config(fixture.pane, change(None, Some("plan")))
        .await
        .unwrap();
    assert_eq!(
        waiting
            .config
            .pending
            .and_then(|pending| pending.mode)
            .as_deref(),
        Some("plan")
    );
    tokio::time::sleep(Duration::from_secs(1)).await;
    fixture.owner.until("output", |_| true).await;
    assert!(
        !fixture.owner.flat_text(fixture.pane).contains("AGENT-TERM"),
        "a running turn is never cut short"
    );

    fixture.owner.type_line(fixture.pane, "stop");
    let (owner, pane) = (&mut fixture.owner, fixture.pane);
    owner.wait_flat(pane, "AGENT-TERM").await;
    owner.wait_flat(pane, "--permission-mode plan").await;
    let applied = fixture
        .controls(|controls| controls.config.pending.is_none())
        .await;
    assert_eq!(applied.config.current.mode.as_deref(), Some("plan"));
    fixture.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn questions_and_plans_are_answered_from_chat_into_the_held_hook() {
    let dir = tempfile::tempdir().unwrap();
    let mut fixture = launch(dir.path()).await;
    fixture.watch().await;

    fixture.owner.type_line(fixture.pane, "ask");
    let asked = fixture
        .controls(|controls| matches!(controls.prompt, Some(AgentPrompt::Questions(_))))
        .await;
    let Some(AgentPrompt::Questions(questions)) = asked.prompt else {
        unreachable!()
    };
    assert_eq!(questions.questions[0].question, "Which framework?");
    assert_eq!(questions.questions[0].options[0].label, "React");
    let plain = fixture
        .owner
        .client
        .refuse(questions.request_id, questions.answer, "no".into())
        .await;
    assert!(plain.is_err(), "the answer option needs answers: {plain:?}");
    fixture
        .owner
        .client
        .answer_question(
            questions.request_id,
            questions.answer,
            vec![QuestionAnswer {
                question: "Which framework?".into(),
                answer: "React".into(),
            }],
        )
        .await
        .unwrap();
    let (owner, pane) = (&mut fixture.owner, fixture.pane);
    owner.wait_flat(pane, r#""Which framework?":"React""#).await;
    owner
        .wait_flat(pane, r#""permissionDecision":"allow""#)
        .await;

    owner.type_line(pane, "plan");
    let planned = fixture
        .controls(|controls| matches!(controls.prompt, Some(AgentPrompt::Plan(_))))
        .await;
    let Some(AgentPrompt::Plan(plan)) = planned.prompt else {
        unreachable!()
    };
    assert_eq!(plan.plan, "Step one");
    fixture
        .owner
        .client
        .refuse(plan.request_id, plan.keep_planning, "add tests".into())
        .await
        .unwrap();
    fixture
        .owner
        .wait_flat(fixture.pane, "The user wants to keep planning: add tests")
        .await;

    fixture.owner.type_line(fixture.pane, "ask");
    fixture.controls(|controls| controls.prompt.is_some()).await;
    fixture.owner.type_line(fixture.pane, "x");
    fixture.controls(|controls| controls.prompt.is_none()).await;
    fixture.owner.wait_flat(fixture.pane, "HOOK-OUT:[]").await;
    fixture.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn guests_cannot_change_settings_and_viewers_cannot_answer() {
    let dir = tempfile::tempdir().unwrap();
    let mut fixture = launch(dir.path()).await;
    fixture.watch().await;
    let invite = |roles| {
        let client = &fixture.owner.client;
        async move {
            client
                .create_invite(GrantSpec::new(roles, Scope::Daemon), "fixture".into())
                .await
                .unwrap()
        }
    };
    let pair = invite(Roles::DRIVER | Roles::PROMPTER | Roles::APPROVER).await;
    let viewer = invite(Roles::VIEWER).await;
    let join = |invite: String| async move {
        let mut guest = TestClient::join(&invite, ClientConfig::generate_key());
        guest.client.attach(None);
        guest
            .until("guest layout", |client| client.layout.is_some())
            .await;
        guest
    };
    let pair = join(pair.to_string()).await;
    let viewer = join(viewer.to_string()).await;

    assert!(matches!(
        pair.client
            .set_agent_config(fixture.pane, change(Some("sonnet"), None))
            .await,
        Err(WsError::Denied(_))
    ));
    assert!(
        viewer
            .client
            .agent_controls_watch(fixture.pane)
            .await
            .is_ok()
    );
    fixture.owner.type_line(fixture.pane, "ask");
    let asked = fixture.controls(|controls| controls.prompt.is_some()).await;
    let Some(AgentPrompt::Questions(questions)) = asked.prompt else {
        panic!("{asked:?}")
    };
    let answers = vec![QuestionAnswer {
        question: "Which framework?".into(),
        answer: "React".into(),
    }];
    assert!(matches!(
        viewer
            .client
            .answer_question(questions.request_id, questions.answer, answers)
            .await,
        Err(ApprovalError::Forbidden(_))
    ));
    assert!(
        !fixture.owner.flat_text(fixture.pane).contains("HOOK-OUT"),
        "the hook still waits"
    );
    fixture.daemon.shutdown().await;
}
