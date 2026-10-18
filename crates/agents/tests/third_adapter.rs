//! Proves a new agent needs no changes to the crate: a pi adapter written against the public API
//! only, driven through the same arbiter as Claude and Codex.

use std::ffi::OsString;

use agents::{ActorId, NativeSessionId};
use agents::{
    AgentAdapter, AgentKind, AgentState, AnswerPath, ApprovalChoice, ApprovalOption, Arbiter,
    ArbiterConfig, BlockedReason, Blocker, Claim, Confidence, Decision, EventKind, HookCoverage,
    HookError, Lane, LaunchContext, LaunchMode, LaunchSpec, Manifest, Notify, PaneId, ScreenInput,
    ScreenVerdict, Seq, SessionInfo, Signal, Source, SupportFile, UnixMillis, pane_env,
};
use serde::Deserialize;

/// A stand-in for our pi extension's reports: one JSON object per pi event.
#[derive(Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum PiEvent {
    SessionStart {
        session_id: String,
        session_file: String,
    },
    AgentStart,
    ToolCall {
        tool: String,
        input: serde_json::Value,
    },
    AgentSettled,
}

struct Pi {
    manifest: Manifest,
}

impl Pi {
    fn new() -> Self {
        let manifest = Manifest::from_toml(
            r#"
            id = "pi"
            version = "2026.10.18.1"
            [[rules]]
            id = "working_border"
            state = "working"
            priority = 500
            region = "bottom_non_empty_lines(6)"
            visible_working = true
            contains = ["working…"]
            "#,
        )
        .expect("valid manifest");
        Self { manifest }
    }
}

impl AgentAdapter for Pi {
    fn kind(&self) -> AgentKind {
        AgentKind::Pi
    }

    fn program_status_app(&self) -> &str {
        "pi"
    }

    fn hook_coverage(&self) -> HookCoverage {
        HookCoverage::FullLifecycle
    }

    fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    fn launch(&self, ctx: &LaunchContext, mode: &LaunchMode) -> LaunchSpec {
        let extension = ctx.state_dir.join("pi/un-agent.ts");
        let mut args: Vec<OsString> = vec!["-e".into(), extension.clone().into()];
        match mode {
            LaunchMode::Fresh {
                session_id: Some(id),
            } => args.extend(["--session-id".into(), id.as_str().into()]),
            LaunchMode::Fresh { session_id: None } => {}
            LaunchMode::Resume { session_id } => {
                args.extend(["--session".into(), session_id.as_str().into()]);
            }
        }
        LaunchSpec {
            program: "pi".into(),
            args,
            env: pane_env(ctx),
            cwd: ctx.cwd.clone(),
            files: vec![SupportFile {
                path: extension,
                contents: "// un-agent extension".into(),
            }],
        }
    }

    fn parse_hook(&self, payload: &[u8], seq: Seq) -> Result<Option<Signal>, HookError> {
        let event: PiEvent = serde_json::from_slice(payload)?;
        let signal =
            |kind| Signal::new(Source::Hook, Confidence::Authoritative, kind).with_seq(seq);
        Ok(Some(match event {
            PiEvent::SessionStart {
                session_id,
                session_file,
            } => {
                let mut s = signal(EventKind::SessionStarted);
                s.session.native_id = Some(NativeSessionId::new(session_id));
                s.session.transcript = Some(session_file.into());
                s
            }
            PiEvent::AgentStart => signal(EventKind::TurnStarted).with_claim(Claim::Working),
            PiEvent::ToolCall { tool, input } => {
                let mut blocker = Blocker::new(BlockedReason::Permission);
                blocker.summary = input["command"].as_str().map(str::to_owned);
                blocker.tool = Some(tool);
                blocker.options = vec![
                    ApprovalOption::new(ApprovalChoice::AllowOnce, "Allow"),
                    ApprovalOption::new(ApprovalChoice::Deny, "Block"),
                ];
                blocker.answer_paths = vec![AnswerPath::HookDecision];
                signal(EventKind::Blocked).with_claim(Claim::Blocked(blocker))
            }
            PiEvent::AgentSettled => signal(EventKind::TurnEnded).with_claim(Claim::Idle),
        }))
    }
}

fn context() -> LaunchContext {
    LaunchContext {
        pane_id: PaneId::new("p7"),
        socket: "/run/un.sock".into(),
        token: "t".into(),
        endpoint_file: "/state/endpoint".into(),
        hook_bin: "/bin/un-hook".into(),
        state_dir: "/state".into(),
        cwd: "/src".into(),
    }
}

#[test]
fn a_third_agent_plugs_in_through_the_public_api() {
    let pi: Box<dyn AgentAdapter> = Box::new(Pi::new());

    let spec = pi.launch(
        &context(),
        &LaunchMode::Resume {
            session_id: NativeSessionId::new("/home/me/.pi/agent/sessions/s.jsonl"),
        },
    );
    assert_eq!(
        spec.display_argv(),
        [
            "pi",
            "-e",
            "/state/pi/un-agent.ts",
            "--session",
            "/home/me/.pi/agent/sessions/s.jsonl"
        ]
    );

    let mut arbiter = Arbiter::new(
        ArbiterConfig::new(pi.hook_coverage()),
        Some(PaneId::new("p7")),
        SessionInfo::new(pi.kind(), Lane::Pty),
        UnixMillis(0),
    );
    let feed = |arbiter: &mut Arbiter, line: &str, seq: u64, now: u64| {
        let signal = pi.parse_hook(line.as_bytes(), Seq(seq)).unwrap().unwrap();
        arbiter.apply(signal, UnixMillis(now))
    };

    let start = feed(
        &mut arbiter,
        r#"{"event":"session_start","session_id":"s1","session_file":"/s.jsonl"}"#,
        1,
        0,
    );
    assert_eq!(start.event.unwrap().session.agent, AgentKind::Pi);
    let _ = feed(&mut arbiter, r#"{"event":"agent_start"}"#, 2, 10);
    let blocked = feed(
        &mut arbiter,
        r#"{"event":"tool_call","tool":"bash","input":{"command":"rm -rf dist"}}"#,
        3,
        20,
    );
    let Some(Notify::Blocked { request_id }) = blocked.notify else {
        panic!("authoritative blocker notifies at once");
    };
    let decided = arbiter
        .decide(
            Decision {
                request_id,
                choice: ApprovalChoice::AllowOnce,
                actor: ActorId::new("owner"),
            },
            UnixMillis(30),
        )
        .unwrap();
    assert_eq!(decided.decided_by.as_str(), "owner");
    let _ = feed(&mut arbiter, r#"{"event":"agent_start"}"#, 4, 40);
    let settled = feed(&mut arbiter, r#"{"event":"agent_settled"}"#, 5, 50);
    assert_eq!(settled.event.unwrap().kind, EventKind::TurnEnded);
    assert_eq!(settled.notify, Some(Notify::Done));

    let verdict = pi.detect_screen(ScreenInput::screen("╭─\n│ Working…\n╰─"));
    let ScreenVerdict::State(m) = verdict else {
        panic!()
    };
    assert_eq!(m.state, AgentState::Working);

    // OSC 7501 reports from the pi extension use the adapter's app name with no extra code.
    let report = pi
        .parse_program_status("state=blocked:kind=question:app=pi")
        .unwrap();
    assert!(
        matches!(report.claim, Some(Claim::Blocked(ref b)) if b.reason == BlockedReason::Question)
    );
    assert_eq!(
        pi.parse_program_status("state=blocked:app=claude-code"),
        None
    );
    assert_eq!(pi.parse_osc9("anything"), None);
}
