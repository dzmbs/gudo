//! Frozen wire bytes for agents reaching other hosts (`proto::cross_host`). Same rule as
//! `golden.rs`: never edit an existing case; add one.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_cross_host -- --nocapture`.

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
        assert_eq!(decoder.buffered(), 0, "{name} left bytes behind");
    }
}

fn request() -> CrossHostRequest {
    CrossHostRequest {
        id: RequestId(7),
        pane_id: PaneId(3),
        agent_key: 9,
        agent: "Claude".into(),
        host: "ops".into(),
        tool: "cmd_run".into(),
        args: r#"{"command":"ls"}"#.into(),
        guest_driving: Some("bob".into()),
        expires_at: UnixMillis(1000),
    }
}

fn agent() -> RemoteAgent {
    RemoteAgent {
        host: DaemonId([0x44; 32]),
        host_name: "mac".into(),
        pane_id: PaneId(3),
        agent_key: 9,
        agent: "Claude".into(),
    }
}

fn decide() -> Decide {
    Decide {
        request_id: RequestId(7),
        option_id: CrossHostRequest::ALLOW_AGENT,
        actor: Actor {
            principal: PrincipalId([0x11; 16]),
            device: DeviceId([0x22; 32]),
        },
        sig: vec![0xaa; 4],
    }
}

#[test]
fn cross_host_messages_are_frozen() {
    let mut checker = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: Vec::new(),
    };
    assert_eq!(Caps::CROSS_HOST.0, 1 << 31);
    assert_eq!(MoreDaemonFeatures::CROSS_HOST.0, 1 << 9);
    checker.check("AuditKind::CrossHost", AuditKind::CrossHost, "02000000010e");
    checker.check(
        "ServerCtl::CrossHost(Request)",
        ServerCtl::CrossHost(CrossHostPush::Request(request())),
        "3100000001440007030906436c61756465036f707307636d645f72756e107b22636f6d6d616e64223a226c73227d0103626f62e807",
    );
    checker.check(
        "ServerCtl::CrossHost(Closed)",
        ServerCtl::CrossHost(CrossHostPush::Closed { id: RequestId(7) }),
        "0400000001440107",
    );
    checker.check(
        "ServerCtl::CrossHost(Claimed)",
        ServerCtl::CrossHost(CrossHostPush::Claimed {
            id: RequestId(7),
            won: true,
        }),
        "050000000144020701",
    );
    checker.check(
        "ServerCtl::CrossHost(AgentGone)",
        ServerCtl::CrossHost(CrossHostPush::AgentGone {
            pane_id: PaneId(3),
            agent_key: 9,
        }),
        "050000000144030309",
    );
    checker.check(
        "ServerCtl::CrossHost(CallResult)",
        ServerCtl::CrossHost(CrossHostPush::CallResult {
            req_id: 5,
            reply: r#"{"ok":{}}"#.into(),
        }),
        "0e00000001440405097b226f6b223a7b7d7d",
    );
    checker.check(
        "ClientCtl::CrossHost(Directory)",
        ClientCtl::CrossHost(CrossHostMsg::Directory(vec![
            HostEntry {
                id: "ab".into(),
                name: "ops".into(),
                state: PairState::Enabled,
            },
            HostEntry {
                id: "cd".into(),
                name: "pi".into(),
                state: PairState::NoHelper,
            },
        ])),
        "1300000001220002026162036f70730002636402706904",
    );
    checker.check(
        "ClientCtl::CrossHost(Claim)",
        ClientCtl::CrossHost(CrossHostMsg::Claim(decide())),
        "3a000000012201070111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222204aaaaaaaa",
    );
    checker.check(
        "ClientCtl::CrossHost(Refuse)",
        ClientCtl::CrossHost(CrossHostMsg::Refuse {
            id: RequestId(7),
            refusal: CrossHostRefusal::NotEnabled { host: "ops".into() },
        }),
        "090000000122020701036f7073",
    );
    checker.check(
        "ClientCtl::CrossHost(Result(Ok))",
        ClientCtl::CrossHost(CrossHostMsg::Result {
            id: RequestId(7),
            outcome: Ok(r#"{"ok":{}}"#.into()),
        }),
        "0f0000000122030700097b226f6b223a7b7d7d",
    );
    checker.check(
        "ClientCtl::CrossHost(Result(Err))",
        ClientCtl::CrossHost(CrossHostMsg::Result {
            id: RequestId(7),
            outcome: Err("ops went away".into()),
        }),
        "1300000001220307010d6f70732077656e742061776179",
    );
    checker.check(
        "ClientCtl::CrossHost(Call)",
        ClientCtl::CrossHost(CrossHostMsg::Call {
            req_id: 5,
            call: RemoteCall {
                on_behalf_of: agent(),
                consent: Consent::Agent,
                session: Some(SessionId(1)),
                tool: "pane_list".into(),
                args: "{}".into(),
            },
        }),
        "41000000012204054444444444444444444444444444444444444444444444444444444444444444036d6163030906436c617564650101010970616e655f6c697374027b7d",
    );
    checker.check(
        "ClientCtl::CrossHost(AgentGone)",
        ClientCtl::CrossHost(CrossHostMsg::AgentGone {
            host: DaemonId([0x44; 32]),
            pane_id: PaneId(3),
            agent_key: 9,
        }),
        "2500000001220544444444444444444444444444444444444444444444444444444444444444440309",
    );
    for (name, refusal, golden) in [
        (
            "UnknownHost",
            CrossHostRefusal::UnknownHost { host: "x".into() },
            "0400000001000178",
        ),
        (
            "Guest",
            CrossHostRefusal::Guest { host: "x".into() },
            "0400000001020178",
        ),
        (
            "NoHelper",
            CrossHostRefusal::NoHelper { host: "x".into() },
            "0400000001030178",
        ),
        (
            "OldHelper",
            CrossHostRefusal::OldHelper { host: "x".into() },
            "0400000001040178",
        ),
        (
            "Offline",
            CrossHostRefusal::Offline { host: "x".into() },
            "0400000001050178",
        ),
        ("SameHost", CrossHostRefusal::SameHost, "020000000106"),
    ] {
        checker.check(&format!("CrossHostRefusal::{name}"), refusal, golden);
    }
    for (name, state, golden) in [
        ("Off", PairState::Off, "020000000101"),
        ("Offline", PairState::Offline, "020000000102"),
        ("Guest", PairState::Guest, "020000000103"),
        ("OldHelper", PairState::OldHelper, "020000000105"),
    ] {
        checker.check(&format!("PairState::{name}"), state, golden);
    }
    for (name, consent, golden) in [
        ("Once", Consent::Once, "020000000100"),
        ("Reads", Consent::Reads, "020000000102"),
    ] {
        checker.check(&format!("Consent::{name}"), consent, golden);
    }
    assert!(
        checker.failures.is_empty(),
        "{}",
        checker.failures.join("\n")
    );
}

#[test]
fn relayed_calls_are_worded_from_their_arguments() {
    assert_eq!(
        describe_cross_host("cmd_run", r#"{"command":"rm -rf /\n","pane":"p4"}"#),
        "run $ rm -rf /⏎ in p4"
    );
    assert_eq!(
        describe_cross_host("pane_send", r#"{"pane":"p4","keys":["ctrl+c"]}"#),
        "type keys ctrl+c into p4"
    );
    assert_eq!(
        describe_cross_host("agent_spawn", r#"{"kind":"codex","prompt":"fix it"}"#),
        "start codex and prompt it “fix it”"
    );
    assert_eq!(
        describe_cross_host("tab_new", r#"{"command":"htop"}"#),
        "open a tab running $ htop"
    );
    assert_eq!(
        describe_cross_host("pane_close", r#"{"pane":"p9"}"#),
        "close p9"
    );
    assert_eq!(
        describe_cross_host("pane_list", "not json"),
        "list the tabs and panes"
    );
    assert_eq!(
        describe_cross_host("cmd_run", "{\"command\":\"echo safe\u{202e}fr- mr\"}"),
        "run $ echo safe<U+202E>fr- mr"
    );
}
