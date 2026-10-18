//! Frozen wire bytes for every message.
//!
//! Each case encodes a representative value, compares the full frame (length prefix, version,
//! body) with a frozen hex string, and decodes it back. If a case fails, the wire format
//! changed. Do not edit an existing hex string to make it pass: add a variant or bump
//!
//! To print the current encodings when adding a case: `PROTO_PRINT_GOLDEN=1 cargo test -p proto
//! --test golden -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

const PANE: PaneId = PaneId(3);
const PRINCIPAL: PrincipalId = PrincipalId([0x11; 16]);
const DEVICE: DeviceId = DeviceId([0x22; 32]);
const ACTOR: Actor = Actor {
    principal: PRINCIPAL,
    device: DEVICE,
};
const GRANT: GrantId = GrantId([0x33; 16]);
const SIZE: PaneSize = PaneSize {
    cols: 120,
    rows: 40,
    width_px: 1440,
    height_px: 960,
};

fn pane_meta() -> PaneMeta {
    PaneMeta {
        pane_id: PANE,
        title: "zsh".into(),
        cwd: Some("/w".into()),
        exit: None,
        agent: Some(AgentStatus {
            kind: "claude".into(),
            state: AgentState::Blocked(Blocker {
                request_id: RequestId(9),
                summary: "rm".into(),
                options: vec![DecisionOption {
                    id: OptionId(1),
                    label: "ok".into(),
                }],
            }),
        }),
        size: SIZE,
        size_policy: SizePolicy::LastInput,
        sized_by: Some(PRINCIPAL),
    }
}

fn presence() -> Presence {
    Presence {
        actor: ACTOR,
        state: PresenceState::Active,
        focus: Some(PANE),
        typing: true,
        viewport: Some(Viewport {
            pane_id: PANE,
            top_row: 1000,
            rows: 40,
        }),
        cursor: Some(CursorPos {
            pane_id: PANE,
            row: 5,
            col: 7,
        }),
    }
}

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
        let hex: String = wire.iter().map(|b| format!("{b:02x}")).collect();
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

#[test]
fn every_message_matches_its_frozen_bytes() {
    let mut c = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };

    // Stream headers.
    c.check("StreamHeader::Input", StreamHeader::Input, "020000000100");
    c.check(
        "StreamHeader::Pane",
        StreamHeader::Pane { pane_id: PANE },
        "03000000010103",
    );
    c.check("StreamHeader::Bulk", StreamHeader::Bulk, "020000000102");

    // ctl, client → daemon.
    let hello = Hello {
        device_id: DEVICE,
        principal_id: PRINCIPAL,
        grant: SignedGrant {
            v: 1,
            grant_id: GRANT,
            token: vec![0xaa, 0xbb],
        },
        snapshot_format: 1,
        resume: vec![ResumePoint {
            pane_id: PANE,
            last_seq: Seq(300),
            snap_gen: SnapGen(2),
        }],
        caps: Caps::DATAGRAMS | Caps::ECHO_PREDICTION,
        link: LinkClass::Constrained,
        resume_token: Some(ResumeToken(vec![1, 2, 3])),
    };
    c.check("ClientCtl::Hello", ClientCtl::Hello(hello), "530000000100222222222222222222222222222222222222222222222222222222222222222211111111111111111111111111111111013333333333333333333333333333333302aabb010103ac020205010103010203");
    c.check(
        "ClientCtl::Subscribe",
        ClientCtl::Subscribe {
            pane_id: PANE,
            mode: SubscribeMode::Live,
            rows_hint: 40,
        },
        "050000000101030028",
    );
    c.check(
        "ClientCtl::Unsubscribe",
        ClientCtl::Unsubscribe { pane_id: PANE },
        "03000000010203",
    );
    c.check(
        "ClientCtl::Visible",
        ClientCtl::Visible {
            pane_ids: vec![PANE, PaneId(4)],
        },
        "050000000103020304",
    );
    c.check(
        "ClientCtl::Focus",
        ClientCtl::Focus {
            pane_id: Some(PANE),
        },
        "0400000001040103",
    );
    c.check(
        "ClientCtl::Resize",
        ClientCtl::Resize {
            pane_id: PANE,
            size: SIZE,
        },
        "090000000105037828a00bc007",
    );
    c.check(
        "ClientCtl::Ack",
        ClientCtl::Ack {
            pane_id: PANE,
            seq: Seq(65_536),
        },
        "06000000010603808004",
    );
    c.check(
        "ClientCtl::Decide",
        ClientCtl::Decide(Decide {
            request_id: RequestId(9),
            option_id: OptionId(1),
            actor: ACTOR,
            sig: vec![0x5a; 4],
        }),
        "3900000001070901111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222045a5a5a5a",
    );
    c.check(
        "ClientCtl::LeaseRequest",
        ClientCtl::LeaseRequest {
            pane_id: PANE,
            kind: LeaseRequestKind::Force,
        },
        "0400000001080301",
    );
    c.check(
        "ClientCtl::SetSizePolicy",
        ClientCtl::SetSizePolicy {
            pane_id: PANE,
            policy: SizePolicy::Fixed { cols: 80, rows: 24 },
        },
        "06000000010903025018",
    );
    c.check("ClientCtl::Presence", ClientCtl::Presence(presence()), "3f000000010a111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222000103010103e8072801030507");
    c.check(
        "ClientCtl::Ping",
        ClientCtl::Ping { nonce: 0xdead_beef },
        "07000000010beffdb6f50d",
    );
    c.check(
        "ClientCtl::Bye",
        ClientCtl::Bye {
            reason: ByeReason::Suspend,
        },
        "03000000010c00",
    );

    // ctl, daemon → client.
    let welcome = Welcome {
        daemon_id: DaemonId([0x44; 32]),
        session_epoch: SessionEpoch(7),
        roles: Roles::OWNER,
        snapshot_format: 1,
        panes: vec![pane_meta()],
        resume_token: ResumeToken(vec![9; 4]),
    };
    c.check("ServerCtl::Welcome", ServerCtl::Welcome(welcome), "5f000000010044444444444444444444444444444444444444444444444444444444444444440710010103037a736801022f77000106636c61756465020902726d0101026f6b7828a00bc0070101111111111111111111111111111111110409090909");
    c.check(
        "ServerCtl::Refused",
        ServerCtl::Refused {
            reason: RefuseReason::WireVersion { supported: 1 },
        },
        "0400000001010001",
    );
    c.check("ServerCtl::PaneMeta", ServerCtl::PaneMeta(pane_meta()), "36000000010203037a736801022f77000106636c61756465020902726d0101026f6b7828a00bc007010111111111111111111111111111111111");
    c.check(
        "ServerCtl::PaneClosed",
        ServerCtl::PaneClosed { pane_id: PANE },
        "03000000010303",
    );
    c.check(
        "ServerCtl::EchoHint",
        ServerCtl::EchoHint(EchoHint {
            pane_id: PANE,
            echo: true,
            icanon: true,
            alt_screen: false,
            at_prompt: true,
        }),
        "0700000001040301010001",
    );
    c.check(
        "ServerCtl::InputRejected",
        ServerCtl::InputRejected {
            pane_id: PANE,
            input_seq: InputSeq(12),
            reason: InputRejectReason::NoLease,
        },
        "050000000105030c00",
    );
    c.check(
        "ServerCtl::Lease",
        ServerCtl::Lease(Lease {
            pane_id: PANE,
            holder: Some(PRINCIPAL),
            since: UnixMillis(1_760_000_000_000),
            mode: LeaseMode::Free,
        }),
        "1b00000001060301111111111111111111111111111111118080b3c19c3300",
    );
    c.check(
        "ServerCtl::Decided",
        ServerCtl::Decided(Decided {
            pane_id: PANE,
            request_id: RequestId(9),
            option_id: OptionId(1),
            decided_by: ACTOR,
            at: UnixMillis(1_760_000_000_000),
        }),
        "3b00000001070309011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222228080b3c19c33",
    );
    c.check(
        "ServerCtl::AlreadyDecided",
        ServerCtl::AlreadyDecided { request_id: RequestId(9), by: ACTOR },
        "33000000010809111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222",
    );
    c.check("ServerCtl::Presence", ServerCtl::Presence(presence()), "3f0000000109111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222000103010103e8072801030507");
    c.check(
        "ServerCtl::Revoked",
        ServerCtl::Revoked { grant_id: GRANT },
        "12000000010a33333333333333333333333333333333",
    );
    c.check(
        "ServerCtl::Pong",
        ServerCtl::Pong { nonce: 0xdead_beef },
        "07000000010beffdb6f50d",
    );

    // input.
    let input = |payload| {
        ClientInput::Input(Input {
            pane_id: PANE,
            input_seq: InputSeq(12),
            principal: PRINCIPAL,
            payload,
        })
    };
    c.check(
        "ClientInput::Input/Bytes",
        input(InputPayload::Bytes(b"ls\r".to_vec())),
        "190000000100030c1111111111111111111111111111111100036c730d",
    );
    c.check(
        "ClientInput::Input/Key",
        input(InputPayload::Key(KeyEvent {
            key: 42,
            mods: 0b101,
            action: KeyAction::Press,
            text: Some("a".into()),
        })),
        "1b0000000100030c11111111111111111111111111111111012a0500010161",
    );
    c.check(
        "ClientInput::Input/Paste",
        input(InputPayload::Paste("hi".into())),
        "180000000100030c1111111111111111111111111111111102026869",
    );
    c.check(
        "ClientInput::Input/Mouse",
        input(InputPayload::Mouse(MouseEvent {
            action: MouseAction::Press,
            button: MouseButton::WheelDown,
            col: 10,
            row: 2,
            mods: 0,
        })),
        "1a0000000100030c111111111111111111111111111111110300050a0200",
    );

    // pane/<id>.
    c.check(
        "PaneOutput::Bytes",
        PaneOutput::Bytes {
            seq: Seq(300),
            data: b"$ ".to_vec(),
        },
        "070000000100ac02022420",
    );
    c.check(
        "PaneOutput::Snapshot",
        PaneOutput::Snapshot {
            seq: Seq(300),
            snap_gen: SnapGen(2),
            data: vec![0xee; 3],
        },
        "090000000101ac020203eeeeee",
    );
    c.check(
        "PaneOutput::InputAck",
        PaneOutput::InputAck {
            input_seq: InputSeq(12),
            at_seq: Seq(302),
        },
        "0500000001020cae02",
    );

    // bulk.
    c.check(
        "Bulk::History",
        Bulk::History {
            pane_id: PANE,
            snap_gen: SnapGen(2),
            data: vec![0xee; 3],
        },
        "080000000100030203eeeeee",
    );

    // Layout, sessions, port forwarding, compressed snapshots (appended variants).
    c.check(
        "StreamHeader::PortForward",
        StreamHeader::PortForward { port: 8080 },
        "040000000103903f",
    );
    c.check(
        "ForwardReply::Connected",
        ForwardReply::Connected,
        "020000000100",
    );
    c.check(
        "ForwardReply::Refused",
        ForwardReply::Refused {
            reason: "no".into(),
        },
        "050000000101026e6f",
    );
    c.check(
        "ClientCtl::ListSessions",
        ClientCtl::ListSessions,
        "02000000010d",
    );
    c.check(
        "ClientCtl::Attach",
        ClientCtl::Attach {
            session_id: Some(SESSION),
        },
        "04000000010e0101",
    );
    for (name, op, golden) in layout_ops() {
        c.check(name, ClientCtl::Op { op_id: 77, op }, golden);
    }
    c.check(
        "ServerCtl::Sessions",
        ServerCtl::Sessions {
            sessions: vec![SessionSummary {
                session_id: SESSION,
                name: "main".into(),
                tabs: 2,
                panes: 3,
                clients: 1,
            }],
        },
        "0c000000010c0101046d61696e020301",
    );
    c.check(
        "ServerCtl::Attached",
        ServerCtl::Attached {
            session_id: SESSION,
        },
        "03000000010d01",
    );
    c.check(
        "ServerCtl::LayoutChanged",
        ServerCtl::LayoutChanged(session_layout()),
        "1b000000010e01046d61696e0501020102017401000000003f000300040400",
    );
    let outcomes = [
        (
            "ServerCtl::OpResult/Done",
            OpOutcome::Done,
            "04000000010f4d00",
        ),
        (
            "ServerCtl::OpResult/PaneCreated",
            OpOutcome::PaneCreated { pane_id: PANE },
            "05000000010f4d0103",
        ),
        (
            "ServerCtl::OpResult/TabCreated",
            OpOutcome::TabCreated {
                tab_id: TAB,
                pane_id: PANE,
            },
            "06000000010f4d020203",
        ),
        (
            "ServerCtl::OpResult/SessionCreated",
            OpOutcome::SessionCreated {
                session_id: SESSION,
                tab_id: TAB,
                pane_id: PANE,
            },
            "07000000010f4d03010203",
        ),
        (
            "ServerCtl::OpResult/Failed",
            OpOutcome::Failed {
                code: OpError::NameTaken,
                message: "x".into(),
            },
            "07000000010f4d04010178",
        ),
    ];
    for (name, outcome, golden) in outcomes {
        c.check(name, ServerCtl::OpResult { op_id: 77, outcome }, golden);
    }
    c.check(
        "ServerCtl::AgentEvent",
        ServerCtl::AgentEvent {
            pane_id: PANE,
            json: "{}".into(),
        },
        "06000000011003027b7d",
    );
    c.check(
        "ServerCtl::EchoHintAt",
        ServerCtl::EchoHintAt(EchoHintAt {
            hint: EchoHint {
                pane_id: PANE,
                echo: false,
                icanon: false,
                alt_screen: false,
                at_prompt: true,
            },
            at_seq: Seq(300),
            prediction: Prediction::Allow,
        }),
        "0a00000001110300000001ac0200",
    );
    c.check(
        "PaneOutput::SnapshotZstd",
        PaneOutput::SnapshotZstd {
            seq: Seq(300),
            snap_gen: SnapGen(2),
            raw_len: 1000,
            data: vec![0xee; 3],
        },
        "0b0000000103ac0202e80703eeeeee",
    );
    c.check(
        "PaneOutput::Resized",
        PaneOutput::Resized {
            seq: Seq(300),
            size: SIZE,
        },
        "0a0000000104ac027828a00bc007",
    );

    assert!(
        c.failures.is_empty(),
        "wire format changed:\n{}",
        c.failures.join("\n")
    );
}

const SESSION: SessionId = SessionId(1);
const TAB: TabId = TabId(2);

fn session_layout() -> SessionLayout {
    SessionLayout {
        session_id: SESSION,
        name: "main".into(),
        revision: 5,
        active_tab: Some(TAB),
        tabs: vec![TabLayout {
            tab_id: TAB,
            name: "t".into(),
            root: LayoutNode::Split {
                axis: Axis::Horizontal,
                ratio: 0.5,
                first: Box::new(LayoutNode::Leaf(PANE)),
                second: Box::new(LayoutNode::Leaf(PaneId(4))),
            },
            focused: PaneId(4),
            zoomed: None,
        }],
    }
}

fn layout_ops() -> Vec<(&'static str, LayoutOp, &'static str)> {
    let shell = PaneLaunch::Shell {
        cwd: Some("/w".into()),
    };
    vec![
        (
            "LayoutOp::Split/Shell",
            LayoutOp::Split {
                pane_id: PANE,
                axis: Axis::Vertical,
                launch: shell.clone(),
            },
            "0b000000010f4d0003010001022f77",
        ),
        (
            "LayoutOp::Split/Command",
            LayoutOp::Split {
                pane_id: PANE,
                axis: Axis::Horizontal,
                launch: PaneLaunch::Command {
                    argv: vec!["top".into()],
                    cwd: None,
                },
            },
            "0d000000010f4d000300010103746f7000",
        ),
        (
            "LayoutOp::Split/Agent",
            LayoutOp::Split {
                pane_id: PANE,
                axis: Axis::Horizontal,
                launch: PaneLaunch::Agent {
                    agent: AgentKind::Codex,
                    resume: Some("abc".into()),
                    cwd: None,
                },
            },
            "0e000000010f4d0003000201010361626300",
        ),
        (
            "LayoutOp::ClosePane",
            LayoutOp::ClosePane { pane_id: PANE },
            "05000000010f4d0103",
        ),
        (
            "LayoutOp::Focus",
            LayoutOp::Focus { pane_id: PANE },
            "05000000010f4d0203",
        ),
        (
            "LayoutOp::FocusDirection",
            LayoutOp::FocusDirection {
                tab_id: TAB,
                direction: Direction::Down,
            },
            "06000000010f4d030203",
        ),
        (
            "LayoutOp::Resize",
            LayoutOp::Resize {
                pane_id: PANE,
                axis: Axis::Horizontal,
                delta: -0.25,
            },
            "0a000000010f4d040300000080be",
        ),
        (
            "LayoutOp::ToggleZoom",
            LayoutOp::ToggleZoom { pane_id: PANE },
            "05000000010f4d0503",
        ),
        (
            "LayoutOp::NewTab",
            LayoutOp::NewTab {
                session_id: SESSION,
                name: "t".into(),
                launch: shell.clone(),
            },
            "0c000000010f4d060101740001022f77",
        ),
        (
            "LayoutOp::CloseTab",
            LayoutOp::CloseTab { tab_id: TAB },
            "05000000010f4d0702",
        ),
        (
            "LayoutOp::MoveTab",
            LayoutOp::MoveTab {
                tab_id: TAB,
                index: 0,
            },
            "06000000010f4d080200",
        ),
        (
            "LayoutOp::SelectTab",
            LayoutOp::SelectTab { tab_id: TAB },
            "05000000010f4d0902",
        ),
        (
            "LayoutOp::RenameTab",
            LayoutOp::RenameTab {
                tab_id: TAB,
                name: "u".into(),
            },
            "07000000010f4d0a020175",
        ),
        (
            "LayoutOp::RenameSession",
            LayoutOp::RenameSession {
                session_id: SESSION,
                name: "w".into(),
            },
            "07000000010f4d0b010177",
        ),
        (
            "LayoutOp::CreateSession",
            LayoutOp::CreateSession {
                name: "w".into(),
                launch: shell,
            },
            "0b000000010f4d0c01770001022f77",
        ),
        (
            "LayoutOp::CloseSession",
            LayoutOp::CloseSession {
                session_id: SESSION,
            },
            "05000000010f4d0d01",
        ),
    ]
}

#[test]
fn ticket_round_trips_through_text() {
    let ticket = Ticket {
        v: Ticket::VERSION,
        daemon_id: DaemonId([0x44; 32]),
        addrs: vec![
            "127.0.0.1:4433".parse().unwrap(),
            "[::1]:9".parse().unwrap(),
        ],
        relay_url: Some("https://relay.example".into()),
        principal: PRINCIPAL,
        secret: PairingSecret([0x55; 16]),
        expires: UnixMillis(1_760_000_000_000),
    };
    let text = ticket.to_string();
    assert_eq!(text.parse::<Ticket>().unwrap(), ticket);
    // Case, whitespace and a missing scheme are tolerated.
    let payload = text.rsplit('/').next().unwrap();
    let mangled = format!("  {}\n{} ", payload[..10].to_lowercase(), &payload[10..]);
    assert_eq!(mangled.parse::<Ticket>().unwrap(), ticket);
    assert!("garbage!".parse::<Ticket>().is_err());
}

#[test]
fn prediction_rule_matches_spike_s6() {
    // (echo, icanon, alt, at_prompt) -> verdict
    let cases = [
        ((false, true, false, true), Prediction::HiddenInput),
        ((false, true, true, false), Prediction::HiddenInput),
        ((true, true, true, false), Prediction::AltScreen),
        ((true, true, false, false), Prediction::Allow),
        ((false, false, false, true), Prediction::Allow),
        ((false, false, false, false), Prediction::RawOutsidePrompt),
        ((true, false, false, false), Prediction::RawOutsidePrompt),
    ];
    for ((echo, icanon, alt, prompt), want) in cases {
        assert_eq!(Prediction::decide(echo, icanon, alt, prompt), want);
    }
}

#[test]
fn alpn_is_the_brand_alpn() {
    assert_eq!(ALPN, brand::ALPN);
}
