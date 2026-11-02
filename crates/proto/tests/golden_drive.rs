//! Frozen wire bytes for drive requests (`proto::drive`) and the JSON of the script event
//! stream (`proto::script`). Same rule as `golden.rs`: never edit an existing case; add one.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_drive -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

struct Checker {
    print: bool,
    failures: Vec<String>,
}

impl Checker {
    fn check<T>(&mut self, name: &str, msg: T, golden: &str)
    where
        T: Serialize + DeserializeOwned + PartialEq + Debug,
    {
        let wire = frame::to_vec(&msg).unwrap();
        let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
        if self.print {
            println!("{name}: \"{hex}\"");
        }
        if hex != golden {
            self.failures
                .push(format!("{name}\n  want {golden}\n  got  {hex}"));
        }
        let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
        decoder.extend(&wire);
        let back: T = decoder.decode().unwrap().unwrap();
        assert_eq!(back, msg, "{name} did not round-trip");
    }

    fn json<T>(&mut self, name: &str, value: T, golden: &str)
    where
        T: Serialize + DeserializeOwned + PartialEq + Debug,
    {
        let text = serde_json::to_string(&value).unwrap();
        if self.print {
            println!("{name}: {text}");
        }
        if text != golden {
            self.failures
                .push(format!("{name}\n  want {golden}\n  got  {text}"));
        }
        let back: T = serde_json::from_str(&text).unwrap();
        assert_eq!(back, value, "{name} did not round-trip");
    }
}

fn ask(action: DriveAction) -> DriveAsk {
    DriveAsk {
        request_id: RequestId(7),
        pane_id: PaneId(3),
        target: PaneId(4),
        agent: "Claude".into(),
        target_label: "~/api · zsh".into(),
        action,
        expires_at: UnixMillis(1000),
    }
}

#[test]
fn drive_requests_are_frozen() {
    let mut checker = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: Vec::new(),
    };
    assert_eq!(Caps::DRIVE_ASKS.0, 1 << 22);
    assert_eq!(DaemonFeatures::DRIVE_ASKS.0, 1 << 17);
    checker.check(
        "ServerCtl::Approval(Drive(Open(Type)))",
        ServerCtl::Approval(ApprovalPush::Drive(DrivePush::Open(ask(DriveAction::Type {
            text: Some("ls".into()),
            keys: vec!["enter".into()],
            submit: true,
        })))),
        "2a0000000131020007030406436c617564650c7e2f61706920c2b7207a73680001026c730105656e74657201e807",
    );
    checker.check(
        "ServerCtl::Approval(Drive(Open(Run)))",
        ServerCtl::Approval(ApprovalPush::Drive(DrivePush::Open(ask(
            DriveAction::Run {
                command: "npm test".into(),
            },
        )))),
        "270000000131020007030406436c617564650c7e2f61706920c2b7207a736801086e706d2074657374e807",
    );
    checker.check(
        "ServerCtl::Approval(Drive(Open(Prompt)))",
        ServerCtl::Approval(ApprovalPush::Drive(DrivePush::Open(ask(
            DriveAction::Prompt { text: "go".into() },
        )))),
        "210000000131020007030406436c617564650c7e2f61706920c2b7207a73680202676fe807",
    );
    checker.check(
        "ServerCtl::Approval(Drive(Open(Close)))",
        ServerCtl::Approval(ApprovalPush::Drive(DrivePush::Open(ask(
            DriveAction::Close,
        )))),
        "1e0000000131020007030406436c617564650c7e2f61706920c2b7207a736803e807",
    );
    checker.check(
        "ServerCtl::Approval(Drive(Closed))",
        ServerCtl::Approval(ApprovalPush::Drive(DrivePush::Closed {
            request_id: RequestId(7),
        })),
        "050000000131020107",
    );
    assert!(
        checker.failures.is_empty(),
        "{}",
        checker.failures.join("\n")
    );
}

#[test]
fn script_events_keep_their_json() {
    let mut checker = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: Vec::new(),
    };
    let event = |pane: Option<&str>, kind| ScriptEvent {
        v: SCRIPT_EVENTS_VERSION,
        seq: 12,
        at: 1_700_000_000_000,
        session: Some("s1".into()),
        pane: pane.map(str::to_owned),
        kind,
    };
    checker.json(
        "pane.opened",
        event(Some("p4"), ScriptEventKind::PaneOpened { tab: Some("t2".into()) }),
        r#"{"v":1,"seq":12,"at":1700000000000,"session":"s1","pane":"p4","type":"pane.opened","tab":"t2"}"#,
    );
    checker.json(
        "pane.closed",
        event(Some("p4"), ScriptEventKind::PaneClosed),
        r#"{"v":1,"seq":12,"at":1700000000000,"session":"s1","pane":"p4","type":"pane.closed"}"#,
    );
    checker.json(
        "command.started",
        event(
            Some("p4"),
            ScriptEventKind::CommandStarted {
                id: 3,
                command: Some("cargo test".into()),
                cwd: Some("/src".into()),
            },
        ),
        r#"{"v":1,"seq":12,"at":1700000000000,"session":"s1","pane":"p4","type":"command.started","id":3,"command":"cargo test","cwd":"/src"}"#,
    );
    checker.json(
        "command.finished",
        event(
            Some("p4"),
            ScriptEventKind::CommandFinished {
                id: 3,
                command: Some("cargo test".into()),
                exit_code: Some(101),
                duration_ms: 2500,
            },
        ),
        r#"{"v":1,"seq":12,"at":1700000000000,"session":"s1","pane":"p4","type":"command.finished","id":3,"command":"cargo test","exitCode":101,"durationMs":2500}"#,
    );
    checker.json(
        "agent.state",
        event(
            Some("p5"),
            ScriptEventKind::AgentState {
                state: "blocked".into(),
                kind: Some("permission".into()),
                app: Some("claude".into()),
            },
        ),
        r#"{"v":1,"seq":12,"at":1700000000000,"session":"s1","pane":"p5","type":"agent.state","state":"blocked","kind":"permission","app":"claude"}"#,
    );
    checker.json(
        "layout.changed",
        event(None, ScriptEventKind::LayoutChanged),
        r#"{"v":1,"seq":12,"at":1700000000000,"session":"s1","type":"layout.changed"}"#,
    );
    checker.json(
        "events.lost",
        ScriptEvent {
            session: None,
            ..event(None, ScriptEventKind::Lost { missed: 40 })
        },
        r#"{"v":1,"seq":12,"at":1700000000000,"type":"events.lost","missed":40}"#,
    );
    assert!(
        checker.failures.is_empty(),
        "{}",
        checker.failures.join("\n")
    );
}

#[test]
fn drive_wording_shows_everything_typed() {
    let typed = DriveAction::Type {
        text: Some("rm -rf build\n\x1b[2K".into()),
        keys: vec!["ctrl+c".into()],
        submit: true,
    };
    assert_eq!(
        typed.describe(),
        "Type “rm -rf build⏎^[[2K”, keys ctrl+c, then Return"
    );
    let reversed = DriveAction::Run {
        command: "echo safe\u{202e}fr- mr".into(),
    };
    assert_eq!(reversed.describe(), "Run $ echo safe<U+202E>fr- mr");
    assert_eq!(
        ask(DriveAction::Close).title(),
        "Claude wants to close ~/api · zsh"
    );
}
