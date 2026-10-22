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
    terminal_completeness(&mut c);
    workspace_messages(&mut c);
    attach_results(&mut c);
    daemon_info_messages(&mut c);
    agent_usage_messages(&mut c);
    multiplayer_messages(&mut c);
    artifact_messages(&mut c);
    artifact_messages_2(&mut c);
    artifact_history_messages(&mut c);
    live_activity_messages(&mut c);
    browser_messages(&mut c);

    assert!(
        c.failures.is_empty(),
        "wire format changed:\n{}",
        c.failures.join("\n")
    );
}

/// `ServerCtl::AttachResult` (appended after `Assist`, variant 0x26), for clients with
/// `Caps::ATTACH_RESULT`.
fn attach_results(c: &mut Checker) {
    c.check(
        "ServerCtl::AttachResult(Requested)",
        ServerCtl::AttachResult(Ok(Attachment {
            session_id: SESSION,
            via: AttachVia::Requested,
            missing: None,
        })),
        "06000000012600010000",
    );
    c.check(
        "ServerCtl::AttachResult(MostRecent, missing)",
        ServerCtl::AttachResult(Ok(Attachment {
            session_id: SESSION,
            via: AttachVia::MostRecent,
            missing: Some(SessionId(7)),
        })),
        "0700000001260001010107",
    );
    c.check(
        "ServerCtl::AttachResult(Err)",
        ServerCtl::AttachResult(Err(AttachFailure {
            code: OpError::NotFound,
            message: "gone".into(),
        })),
        "090000000126010004676f6e65",
    );
}

fn usage_report() -> AgentUsageReport {
    AgentUsageReport {
        agents: vec![
            AgentUsage {
                agent: AgentKind::Claude,
                plan: Some("max".into()),
                windows: vec![
                    UsageWindow {
                        name: "5h".into(),
                        minutes: 300,
                        used_permille: 625,
                        resets_at: Some(UnixMillis(1_792_438_800_000)),
                        limited: false,
                    },
                    UsageWindow {
                        name: "weekly".into(),
                        minutes: 10_080,
                        used_permille: 1000,
                        resets_at: None,
                        limited: true,
                    },
                ],
                source: UsageSource::StatusLine,
                as_of: Some(UnixMillis(1_792_402_200_000)),
                note: None,
            },
            AgentUsage {
                agent: AgentKind::Codex,
                plan: None,
                windows: vec![],
                source: UsageSource::Unknown,
                as_of: None,
                note: Some("why".into()),
            },
        ],
    }
}

/// Agent plan usage: `Caps::AGENT_USAGE` (bit 6), `DaemonFeatures::AGENT_USAGE` (bit 1),
/// `WorkspaceRequest::UsageWatch` / `UsageUnwatch` (appended after `PushAction`, 0x22/0x23),
/// `WorkspaceResponse::AgentUsage` (appended after `PushDecided`, 0x15) and
/// `ServerCtl::AgentUsage` (appended after `DaemonInfo`, 0x28).
fn agent_usage_messages(c: &mut Checker) {
    c.check("Caps::AGENT_USAGE", Caps::AGENT_USAGE, "020000000140");
    c.check(
        "DaemonFeatures::AGENT_USAGE",
        DaemonFeatures::AGENT_USAGE,
        "020000000102",
    );
    c.check(
        "ClientCtl::Workspace(UsageWatch)",
        ClientCtl::Workspace {
            req_id: 9,
            req: WorkspaceRequest::UsageWatch(UsageWatch { api_fallback: true }),
        },
        "050000000115092201",
    );
    c.check(
        "ClientCtl::Workspace(UsageUnwatch)",
        ClientCtl::Workspace {
            req_id: 9,
            req: WorkspaceRequest::UsageUnwatch,
        },
        "0400000001150923",
    );
    c.check(
        "ServerCtl::WorkspaceResult(AgentUsage)",
        ServerCtl::WorkspaceResult {
            req_id: 9,
            result: Ok(WorkspaceResponse::AgentUsage(usage_report())),
        },
        "3c0000000118090015020001036d617802023568ac02f10401809db6ad953400067765656b6c79e04ee80700010201c0abfc9b95340001000000000103776879",
    );
    c.check(
        "ServerCtl::AgentUsage",
        ServerCtl::AgentUsage(usage_report()),
        "39000000012a020001036d617802023568ac02f10401809db6ad953400067765656b6c79e04ee80700010201c0abfc9b95340001000000000103776879",
    );
    for (name, source, hex) in [
        ("UsageSource::Unknown", UsageSource::Unknown, "020000000100"),
        (
            "UsageSource::LocalLog",
            UsageSource::LocalLog,
            "020000000101",
        ),
        (
            "UsageSource::StatusLine",
            UsageSource::StatusLine,
            "020000000102",
        ),
        ("UsageSource::Cli", UsageSource::Cli, "020000000103"),
        ("UsageSource::Api", UsageSource::Api, "020000000104"),
    ] {
        c.check(name, source, hex);
    }
}

fn daemon_info() -> DaemonInfo {
    DaemonInfo {
        version: "0.1.0".into(),
        build: "3f2a9c1d7e4b".into(),
        built_unix: 1_792_000_000,
        protocol: 1,
        min_client_protocol: 0,
        features: DaemonFeatures::SELF_UPGRADE,
        hostname: "ubuntu-32gb-hel1-2".into(),
        os: "linux".into(),
        os_name: "Ubuntu 24.04.1 LTS".into(),
        arch: "x86_64".into(),
    }
}

/// `Caps::DAEMON_INFO` (bit 5), `ServerCtl::DaemonInfo` (appended after `AttachResult`,
/// variant 0x27), `StreamHeader::Upgrade` (appended after `Blob`, variant 7) and its replies.
fn daemon_info_messages(c: &mut Checker) {
    c.check("Caps::DAEMON_INFO", Caps::DAEMON_INFO, "020000000120");
    c.check(
        "DaemonFeatures::SELF_UPGRADE",
        DaemonFeatures::SELF_UPGRADE,
        "020000000101",
    );
    c.check("ServerCtl::DaemonInfo", ServerCtl::DaemonInfo(daemon_info()), "50000000012705302e312e300c3366326139633164376534628080bfd606010001127562756e74752d333267622d68656c312d32056c696e7578125562756e74752032342e30342e31204c5453067838365f3634");
    c.check(
        "StreamHeader::Upgrade",
        StreamHeader::Upgrade(UpgradeHeader {
            size: 7_000_000,
            encoding: UpgradeEncoding::Gzip,
            sha256: [0x44; 32],
            build: "3f2a9c1d7e4b".into(),
        }),
        "340000000108c09fab030144444444444444444444444444444444444444444444444444444444444444440c336632613963316437653462",
    );
    c.check("UpgradeReply::Ready", UpgradeReply::Ready, "020000000100");
    c.check(
        "UpgradeReply::Installed",
        UpgradeReply::Installed(daemon_info()),
        "50000000010105302e312e300c3366326139633164376534628080bfd606010001127562756e74752d333267622d68656c312d32056c696e7578125562756e74752032342e30342e31204c5453067838365f3634",
    );
    c.check(
        "UpgradeReply::Failed",
        UpgradeReply::Failed {
            code: UpgradeFailure::Forbidden,
            message: "owner only".into(),
        },
        "0e0000000102000a6f776e6572206f6e6c79",
    );
    for (name, code, hex) in [
        (
            "UpgradeFailure::Unsupported",
            UpgradeFailure::Unsupported,
            "020000000101",
        ),
        ("UpgradeFailure::Busy", UpgradeFailure::Busy, "020000000102"),
        (
            "UpgradeFailure::Corrupt",
            UpgradeFailure::Corrupt,
            "020000000103",
        ),
        (
            "UpgradeFailure::Rejected",
            UpgradeFailure::Rejected,
            "020000000104",
        ),
        ("UpgradeFailure::Io", UpgradeFailure::Io, "020000000105"),
    ] {
        c.check(name, code, hex);
    }
    c.check("UpgradeEncoding::Raw", UpgradeEncoding::Raw, "020000000100");
}

fn workspace_messages(c: &mut Checker) {
    let stat = || FileStat {
        path: "/h/f".into(),
        name: "f".into(),
        kind: FileKind::File,
        size: 5,
        modified: UnixMillis(1000),
        mode: 0o644,
        hidden: false,
        link_target: None,
        target_kind: None,
        version: "1-5-9".into(),
    };
    let target = WriteTarget {
        path: "~/f".into(),
        if_match: Some("1-5-9".into()),
        create_new: false,
        mkdirs: true,
        mode: Some(0o600),
    };
    c.check(
        "StreamHeader::Forward(Tcp)",
        StreamHeader::Forward {
            target: ForwardTarget::Tcp { port: 3000 },
        },
        "05000000010400b817",
    );
    c.check(
        "StreamHeader::Forward(Unix)",
        StreamHeader::Forward {
            target: ForwardTarget::Unix { path: "/s".into() },
        },
        "06000000010401022f73",
    );
    c.check(
        "StreamHeader::Upload",
        StreamHeader::Upload(UploadHeader {
            target: target.clone(),
            size: 70_000,
        }),
        "150000000105037e2f660105312d352d390001018003f0a204",
    );
    c.check(
        "StreamHeader::Download",
        StreamHeader::Download(DownloadHeader {
            path: "/h/f".into(),
            offset: 10,
            len: None,
        }),
        "090000000106042f682f660a00",
    );
    c.check(
        "TransferReply::Ready",
        TransferReply::Ready {
            stat: Some(stat()),
            len: 5,
        },
        "1a000000010001042f682f6601660005e807a40300000005312d352d3905",
    );
    c.check(
        "TransferReply::Done",
        TransferReply::Done(stat()),
        "180000000101042f682f6601660005e807a40300000005312d352d39",
    );
    c.check(
        "TransferReply::Failed",
        TransferReply::Failed(WsError::Conflict("x".into())),
        "050000000102020178",
    );

    let requests: Vec<(&str, WorkspaceRequest)> = vec![
        ("ListPorts", WorkspaceRequest::ListPorts),
        ("EditorStatus", WorkspaceRequest::EditorStatus),
        (
            "EditorLaunch",
            WorkspaceRequest::EditorLaunch(EditorLaunch {
                folder: "~/p".into(),
                choice: EditorChoice::Only(EditorKind::OpenVsCode),
                accept_vscode_license: true,
            }),
        ),
        (
            "EditorStop",
            WorkspaceRequest::EditorStop {
                folder: "~/p".into(),
            },
        ),
        (
            "EditorOpen",
            WorkspaceRequest::EditorOpen {
                folder: None,
                path: "~/p/a.rs".into(),
                line: Some(3),
                column: None,
            },
        ),
        (
            "GitStatus",
            WorkspaceRequest::GitStatus { path: "~/p".into() },
        ),
        (
            "GitDiff",
            WorkspaceRequest::GitDiff(GitDiffRequest {
                path: "~/p".into(),
                base: DiffBase::MergeBase("main".into()),
                files: vec!["a".into()],
                context: 3,
                hunks: true,
            }),
        ),
        ("ListTurns", WorkspaceRequest::ListTurns { pane_id: PANE }),
        (
            "TurnDiff",
            WorkspaceRequest::TurnDiff {
                pane_id: PANE,
                turn: Some(2),
                context: 3,
                hunks: false,
            },
        ),
        (
            "SendReview",
            WorkspaceRequest::SendReview(ReviewRequest {
                pane_id: PANE,
                preamble: None,
                notes: vec![ReviewNote {
                    path: "a".into(),
                    start_line: 1,
                    end_line: 2,
                    old_side: false,
                    quote: Some("q".into()),
                    note: "n".into(),
                }],
                submit: true,
            }),
        ),
        (
            "WorktreeCreate",
            WorkspaceRequest::WorktreeCreate(WorktreeCreate {
                repo: "~/p".into(),
                branch: Some("b".into()),
                base: None,
                path: None,
            }),
        ),
        (
            "WorktreeList",
            WorkspaceRequest::WorktreeList { repo: "~/p".into() },
        ),
        (
            "WorktreeRemove",
            WorkspaceRequest::WorktreeRemove {
                path: "~/w".into(),
                force: false,
                delete_branch: true,
            },
        ),
        (
            "WorktreeLaunch",
            WorkspaceRequest::WorktreeLaunch {
                path: "~/w".into(),
                split_from: PANE,
                axis: Axis::Vertical,
                agent: Some(AgentKind::Codex),
            },
        ),
        (
            "FsList",
            WorkspaceRequest::FsList {
                path: "~".into(),
                show_hidden: true,
            },
        ),
        ("FsStat", WorkspaceRequest::FsStat { path: "~".into() }),
        (
            "FsRead",
            WorkspaceRequest::FsRead {
                path: "~/f".into(),
                offset: 1,
                len: 4096,
            },
        ),
        (
            "FsMkdir",
            WorkspaceRequest::FsMkdir {
                path: "~/d".into(),
                parents: true,
            },
        ),
        (
            "FsRename",
            WorkspaceRequest::FsRename {
                from: "~/a".into(),
                to: "~/b".into(),
                overwrite: false,
            },
        ),
        (
            "FsDelete",
            WorkspaceRequest::FsDelete {
                path: "~/a".into(),
                mode: DeleteMode::Trash,
                recursive: true,
            },
        ),
        ("FsWatch", WorkspaceRequest::FsWatch { path: "~".into() }),
        ("FsUnwatch", WorkspaceRequest::FsUnwatch { watch_id: 7 }),
        ("AttentionList", WorkspaceRequest::AttentionList),
        (
            "AttentionSeen",
            WorkspaceRequest::AttentionSeen(AttentionSeen {
                ids: vec![4],
                up_to: Some(9),
                pane_id: Some(PANE),
            }),
        ),
        (
            "FsWrite",
            WorkspaceRequest::FsWrite {
                target: target.clone(),
                data: vec![0xab; 2],
            },
        ),
        ("VsCodeTunnelStatus", WorkspaceRequest::VsCodeTunnelStatus),
        (
            "VsCodeCliInstall",
            WorkspaceRequest::VsCodeCliInstall(VsCodeCliInstall {
                accept_license: true,
            }),
        ),
        (
            "VsCodeTunnelStart",
            WorkspaceRequest::VsCodeTunnelStart(VsCodeTunnelStart {
                accept_server_license: true,
                provider: TunnelProvider::Microsoft,
                name: Some("box".into()),
            }),
        ),
        ("VsCodeTunnelStop", WorkspaceRequest::VsCodeTunnelStop),
        (
            "VsCodeTunnelOpen",
            WorkspaceRequest::VsCodeTunnelOpen(VsCodeTunnelOpen {
                folder: None,
                path: "~/a.rs".into(),
                line: Some(3),
                column: None,
            }),
        ),
        (
            "PushRegister",
            WorkspaceRequest::PushRegister(PushRegistration {
                cap: "c".into(),
                seal_key: [0x66; 32],
                relay_url: Some("https://p".into()),
                prefs: PushPrefs {
                    done: false,
                    ..PushPrefs::default()
                },
                activity_cap: None,
            }),
        ),
        ("PushUnregister", WorkspaceRequest::PushUnregister),
        ("PushStatus", WorkspaceRequest::PushStatus),
        (
            "PushAction",
            WorkspaceRequest::PushAction(PushActionRequest {
                token: vec![1, 2],
                approve: true,
                sig: vec![3],
            }),
        ),
    ];
    for (name, req) in requests {
        let goldens = WORKSPACE_REQUEST_GOLDENS;
        let golden = goldens
            .iter()
            .find(|(n, _)| *n == name)
            .map_or("missing golden", |(_, g)| *g);
        c.check(
            &format!("ClientCtl::Workspace({name})"),
            ClientCtl::Workspace { req_id: 5, req },
            golden,
        );
    }

    let instance = EditorInstance {
        kind: EditorKind::VsCode,
        folder: "/p".into(),
        port: 40000,
        token: "t".into(),
        url_path: "/?tkn=t".into(),
        pid: 77,
        started_at: UnixMillis(1000),
    };
    let item = AttentionItem {
        id: 3,
        at: UnixMillis(1000),
        pane_id: PANE,
        session_id: Some(SessionId(1)),
        kind: AttentionKind::AgentBlocked {
            agent: "claude".into(),
            request_id: Some(RequestId(9)),
        },
        title: "t".into(),
        body: "b".into(),
        seen: false,
        while_viewed: false,
    };
    let responses: Vec<(&str, Result<WorkspaceResponse, WsError>)> = vec![
        ("Done", Ok(WorkspaceResponse::Done)),
        (
            "Ports",
            Ok(WorkspaceResponse::Ports(vec![PortInfo {
                port: 5173,
                loopback_only: true,
                pane_id: Some(PANE),
                pid: 42,
                process: "node".into(),
                kind: PortKind::Http,
                url: Some("http://localhost:5173/".into()),
            }])),
        ),
        (
            "Editors",
            Ok(WorkspaceResponse::Editors(EditorList {
                available: vec![EditorAvailability {
                    kind: EditorKind::OpenVsCode,
                    installed: false,
                    downloadable: true,
                    path: None,
                    version: Some("v1".into()),
                    note: None,
                }],
                running: vec![instance.clone()],
            })),
        ),
        (
            "EditorOpened",
            Ok(WorkspaceResponse::EditorOpened(EditorOpened {
                instance,
                in_window: false,
                url_path: "/?p".into(),
            })),
        ),
        (
            "GitStatus",
            Ok(WorkspaceResponse::GitStatus(GitStatus {
                root: "/r".into(),
                branch: Some("main".into()),
                head: Some("abc".into()),
                upstream: None,
                ahead: 1,
                behind: 0,
                files: vec![GitFileStatus {
                    path: "b".into(),
                    orig_path: Some("a".into()),
                    staged: FileChange::Renamed,
                    unstaged: FileChange::Untracked,
                }],
            })),
        ),
        (
            "GitDiff",
            Ok(WorkspaceResponse::GitDiff(GitDiff {
                root: "/r".into(),
                from: "t1".into(),
                to: "t2".into(),
                files: vec![FileDiff {
                    path: "a".into(),
                    old_path: None,
                    change: FileChange::Modified,
                    binary: false,
                    additions: 1,
                    deletions: 1,
                    hunks: vec![Hunk {
                        old_start: 1,
                        old_lines: 1,
                        new_start: 1,
                        new_lines: 1,
                        header: "fn".into(),
                        lines: vec![
                            DiffLine {
                                kind: LineKind::Removed,
                                text: "x".into(),
                            },
                            DiffLine {
                                kind: LineKind::Added,
                                text: "y".into(),
                            },
                        ],
                    }],
                    hunks_omitted: false,
                }],
                truncated: false,
            })),
        ),
        (
            "Turns",
            Ok(WorkspaceResponse::Turns(vec![TurnInfo {
                turn: 1,
                root: "/r".into(),
                started_at: UnixMillis(1),
                ended_at: None,
                start_tree: "t".into(),
                end_tree: None,
            }])),
        ),
        (
            "Worktrees",
            Ok(WorkspaceResponse::Worktrees(vec![WorktreeInfo {
                path: "/w".into(),
                branch: Some("b".into()),
                head: None,
                main: false,
                locked: false,
                prunable: false,
                port: Some(4100),
            }])),
        ),
        (
            "Dir",
            Ok(WorkspaceResponse::Dir(DirListing {
                path: "/h".into(),
                entries: vec![stat()],
                truncated: false,
            })),
        ),
        (
            "FileData",
            Ok(WorkspaceResponse::FileData(FileChunk {
                stat: stat(),
                offset: 0,
                data: b"hi".to_vec(),
                eof: true,
            })),
        ),
        (
            "Attention",
            Ok(WorkspaceResponse::Attention(AttentionList {
                items: vec![item.clone()],
                unseen: 1,
            })),
        ),
        ("Denied", Err(WsError::Denied("no".into()))),
        ("Disconnected", Err(WsError::Disconnected)),
        (
            "VsCodeTunnel",
            Ok(WorkspaceResponse::VsCodeTunnel(tunnel())),
        ),
        (
            "VsCodeTunnelOpened",
            Ok(WorkspaceResponse::VsCodeTunnelOpened(VsCodeTunnelOpened {
                name: "box".into(),
                folder: "/p".into(),
                web_url: "https://vscode.dev/tunnel/box/p".into(),
                desktop_uri: "vscode://vscode-remote/tunnel+box/p/a.rs:3".into(),
                in_window: true,
            })),
        ),
        (
            "Push",
            Ok(WorkspaceResponse::Push(PushStatus {
                enabled: true,
                relay_url: "https://p".into(),
                registered: Some(PushPrefs::default()),
                devices: 1,
                last_error: None,
            })),
        ),
        (
            "PushDecided",
            Ok(WorkspaceResponse::PushDecided(Decided {
                pane_id: PANE,
                request_id: RequestId(9),
                option_id: OptionId(0),
                decided_by: ACTOR,
                at: UnixMillis(1000),
            })),
        ),
    ];
    for (name, result) in responses {
        let golden = WORKSPACE_RESPONSE_GOLDENS
            .iter()
            .find(|(n, _)| *n == name)
            .map_or("missing golden", |(_, g)| *g);
        c.check(
            &format!("ServerCtl::WorkspaceResult({name})"),
            ServerCtl::WorkspaceResult { req_id: 5, result },
            golden,
        );
    }

    c.check(
        "ServerCtl::PortsChanged",
        ServerCtl::PortsChanged { ports: vec![] },
        "03000000011900",
    );
    c.check(
        "ServerCtl::FsChanged",
        ServerCtl::FsChanged(FsChange {
            watch_id: 2,
            paths: vec!["/h/x".into()],
            rescan: false,
        }),
        "0a000000011a0201042f682f7800",
    );
    c.check(
        "ServerCtl::Attention(Added)",
        ServerCtl::Attention(AttentionUpdate::Added { item, unseen: 1 }),
        "1a000000011b0003e8070301010006636c61756465010901740162000001",
    );
    c.check(
        "ServerCtl::Attention(Seen)",
        ServerCtl::Attention(AttentionUpdate::Seen {
            ids: vec![3],
            unseen: 0,
        }),
        "06000000011b01010300",
    );
    for (name, state, golden) in [
        (
            "Stopped",
            TunnelState::Stopped,
            "20000000011c01022f630107312e3134322e300104366436320104323636390101000100",
        ),
        (
            "Starting",
            TunnelState::Starting,
            "20000000011c01022f630107312e3134322e300104366436320104323636390101010100",
        ),
        (
            "NeedsLogin",
            TunnelState::NeedsLogin(DeviceLogin {
                provider: TunnelProvider::GitHub,
                verification_url: "https://github.com/login/device".into(),
                user_code: "ABCD-1234".into(),
                at: UnixMillis(1000),
            }),
            "4d000000011c01022f630107312e3134322e30010436643632010432363639010102001f68747470733a2f2f6769746875622e636f6d2f6c6f67696e2f64657669636509414243442d31323334e8070100",
        ),
        (
            "Running",
            TunnelState::Running {
                name: "box".into(),
                web_url: "https://vscode.dev/tunnel/box".into(),
                adopted: false,
            },
            "43000000011c01022f630107312e3134322e3001043664363201043236363901010303626f781d68747470733a2f2f7673636f64652e6465762f74756e6e656c2f626f78000100",
        ),
        (
            "Failed",
            TunnelState::Failed {
                message: "x".into(),
                retrying: true,
            },
            "23000000011c01022f630107312e3134322e300104366436320104323636390101040178010100",
        ),
    ] {
        let mut status = tunnel();
        status.state = state;
        c.check(
            &format!("ServerCtl::VsCodeTunnel({name})"),
            ServerCtl::VsCodeTunnel(status),
            golden,
        );
    }
}

fn tunnel() -> VsCodeTunnelStatus {
    VsCodeTunnelStatus {
        cli: Some(VsCodeCli {
            path: "/c".into(),
            version: Some("1.142.0".into()),
            commit: Some("6d62".into()),
            sha256: Some("2669".into()),
            managed: true,
        }),
        cli_downloadable: true,
        state: TunnelState::Stopped,
        provider: Some(TunnelProvider::GitHub),
    }
}

const WORKSPACE_REQUEST_GOLDENS: &[(&str, &str)] = &[
    ("ListPorts", "0400000001150500"),
    ("EditorStatus", "0400000001150501"),
    ("EditorLaunch", "0b00000001150502037e2f70010101"),
    ("EditorStop", "0800000001150503037e2f70"),
    ("EditorOpen", "110000000115050400087e2f702f612e7273010300"),
    ("GitStatus", "0800000001150505037e2f70"),
    ("GitDiff", "1300000001150506037e2f7004046d61696e0101610301"),
    ("ListTurns", "050000000115050703"),
    ("TurnDiff", "09000000011505080301020300"),
    ("SendReview", "12000000011505090300010161010200010171016e01"),
    ("WorktreeCreate", "0d0000000115050a037e2f700101620000"),
    ("WorktreeList", "080000000115050b037e2f70"),
    ("WorktreeRemove", "0a0000000115050c037e2f770001"),
    ("WorktreeLaunch", "0c0000000115050d037e2f7703010101"),
    ("FsList", "070000000115050e017e01"),
    ("FsStat", "060000000115050f017e"),
    ("FsRead", "0b00000001150510037e2f66018020"),
    ("FsMkdir", "0900000001150511037e2f6401"),
    ("FsRename", "0d00000001150512037e2f61037e2f6200"),
    ("FsDelete", "0a00000001150513037e2f610001"),
    ("FsWatch", "0600000001150514017e"),
    ("FsUnwatch", "050000000115051507"),
    ("AttentionList", "0400000001150516"),
    ("AttentionSeen", "0a00000001150517010401090103"),
    (
        "FsWrite",
        "1700000001150518037e2f660105312d352d39000101800302abab",
    ),
    ("VsCodeTunnelStatus", "0400000001150519"),
    ("VsCodeCliInstall", "050000000115051a01"),
    ("VsCodeTunnelStart", "0b0000000115051b01010103626f78"),
    ("VsCodeTunnelStop", "040000000115051c"),
    ("VsCodeTunnelOpen", "0f0000000115051d00067e2f612e7273010300"),
    (
        "PushRegister",
        "370000000115051e01636666666666666666666666666666666666666666666666666666666666666666010968747470733a2f2f70010100010100",
    ),
    ("PushUnregister", "040000000115051f"),
    ("PushStatus", "0400000001150520"),
    ("PushAction", "0a00000001150521020102010103"),
];
const WORKSPACE_RESPONSE_GOLDENS: &[(&str, &str)] = &[
    ("Done", "050000000118050000"),
    (
        "Ports",
        "2a000000011805000101b5280101032a046e6f6465000116687474703a2f2f6c6f63616c686f73743a353137332f",
    ),
    (
        "Editors",
        "240000000118050002010100010001027631000100022f70c0b8020174072f3f746b6e3d744de807",
    ),
    (
        "EditorOpened",
        "1e000000011805000400022f70c0b8020174072f3f746b6e3d744de80700032f3f70",
    ),
    (
        "GitStatus",
        "1e0000000118050005022f7201046d61696e01036162630001000101620101610408",
    ),
    (
        "GitDiff",
        "270000000118050006022f720274310274320101610001000101010101010102666e020201780101790000",
    ),
    ("Turns", "0f00000001180500070101022f720100017400"),
    (
        "Worktrees",
        "13000000011805000a01022f7701016200000000018420",
    ),
    (
        "Dir",
        "20000000011805000c022f6801042f682f6601660005e807a40300000005312d352d3900",
    ),
    (
        "FileData",
        "20000000011805000e042f682f6601660005e807a40300000005312d352d390002686901",
    ),
    (
        "Attention",
        "1d00000001180500100103e8070301010006636c61756465010901740162000001",
    ),
    ("Denied", "080000000118050100026e6f"),
    ("Disconnected", "050000000118050106"),
    (
        "VsCodeTunnel",
        "23000000011805001101022f630107312e3134322e300104366436320104323636390101000100",
    ),
    (
        "VsCodeTunnelOpened",
        "58000000011805001203626f78022f701f68747470733a2f2f7673636f64652e6465762f74756e6e656c2f626f782f702a7673636f64653a2f2f7673636f64652d72656d6f74652f74756e6e656c2b626f782f702f612e72733a3301",
    ),
    (
        "Push",
        "180000000118050013010968747470733a2f2f700101010101010100",
    ),
    (
        "PushDecided",
        "3a0000000118050014030900111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222e807",
    ),
];

fn mark(finished: bool) -> CommandMark {
    CommandMark {
        pane_id: PANE,
        command_id: 4,
        command: Some("make".into()),
        cwd: Some("/w".into()),
        started_at: UnixMillis(1000),
        at_seq: Seq(300),
        finished: finished.then_some(CommandEnd {
            exit: Some(2),
            duration_ms: 12_000,
        }),
    }
}

/// Messages added for key/mouse/paste, history paging, shell integration, search and links.
fn terminal_completeness(c: &mut Checker) {
    c.check(
        "InputPayload::KeyFull",
        ClientInput::Input(Input {
            pane_id: PANE,
            input_seq: InputSeq(9),
            principal: PRINCIPAL,
            payload: InputPayload::KeyFull(FullKeyEvent {
                key: 20,
                mods: 1,
                consumed_mods: 1,
                action: KeyAction::Repeat,
                text: Some("A".into()),
                unshifted_codepoint: Some(u32::from('a')),
                composing: false,
            }),
        }),
        "1f00000001000309111111111111111111111111111111110414010101010141016100",
    );
    c.check(
        "ClientCtl::FetchHistory",
        ClientCtl::FetchHistory {
            pane_id: PANE,
            snapshot_seq: Seq(300),
            offset: 5000,
            max_bytes: 1 << 20,
        },
        "0a000000011003ac028827808040",
    );
    c.check(
        "ClientCtl::Search",
        ClientCtl::Search {
            req_id: 7,
            pane_id: PANE,
            query: SearchQuery {
                pattern: "err".into(),
                mode: SearchMode::Regex,
                case: CaseMode::Smart,
            },
            cursor: 50,
            limit: 25,
        },
        "0c000000011107030365727201023219",
    );
    c.check(
        "ClientCtl::Links",
        ClientCtl::Links {
            req_id: 7,
            pane_id: PANE,
            commands: 3,
        },
        "050000000112070303",
    );
    c.check(
        "ClientCtl::Commands",
        ClientCtl::Commands {
            req_id: 7,
            pane_id: PANE,
        },
        "0400000001130703",
    );
    c.check(
        "ClientCtl::CommandOutput",
        ClientCtl::CommandOutput {
            req_id: 7,
            pane_id: PANE,
            command_id: Some(4),
        },
        "06000000011407030104",
    );
    c.check(
        "ServerCtl::CommandMark",
        ServerCtl::CommandMark(mark(false)),
        "130000000112030401046d616b6501022f77e807ac0200",
    );
    c.check(
        "ServerCtl::CommandFinishedUnseen",
        ServerCtl::CommandFinishedUnseen(mark(true)),
        "170000000113030401046d616b6501022f77e807ac02010104e05d",
    );
    c.check(
        "ServerCtl::SearchResult",
        ServerCtl::SearchResult {
            req_id: 7,
            pane_id: PANE,
            result: Ok(SearchPage {
                at_seq: Seq(300),
                total_rows: 1000,
                total: 2,
                matches: vec![SearchMatch {
                    row: 990,
                    col: 4,
                    end_row: 991,
                    end_col: 1,
                    line: "an error".into(),
                }],
                next: Some(1),
            }),
        },
        "1c0000000114070300ac02e8070201de0704df070108616e206572726f720101",
    );
    c.check(
        "ServerCtl::SearchResult(Err)",
        ServerCtl::SearchResult {
            req_id: 7,
            pane_id: PANE,
            result: Err(RpcError::BadRequest("(".into())),
        },
        "080000000114070301010128",
    );
    c.check(
        "ServerCtl::LinksResult",
        ServerCtl::LinksResult {
            req_id: 7,
            pane_id: PANE,
            result: Ok(Links {
                cwd: Some("/w".into()),
                links: vec![
                    Link {
                        kind: LinkKind::Path,
                        text: "src/a.rs:3:4".into(),
                        target: "/w/src/a.rs".into(),
                        line: Some(3),
                        column: Some(4),
                        exists: Some(true),
                        source: LinkSource::Command { command_id: 4 },
                    },
                    Link {
                        kind: LinkKind::Hyperlink,
                        text: "docs".into(),
                        target: "https://x.y".into(),
                        line: None,
                        column: None,
                        exists: None,
                        source: LinkSource::Screen,
                    },
                ],
            }),
        },
        "42000000011507030001022f7702020c7372632f612e72733a333a340b2f772f7372632f612e727301030104010101040004646f63730b68747470733a2f2f782e7900000000",
    );
    c.check(
        "ServerCtl::CommandsResult",
        ServerCtl::CommandsResult {
            req_id: 7,
            pane_id: PANE,
            result: Ok(CommandList {
                at_seq: Seq(300),
                total_rows: 1000,
                commands: vec![CommandInfo {
                    mark: mark(true),
                    rows: CommandRows {
                        prompt: Some(10),
                        output: Some(11),
                        end: None,
                    },
                }],
            }),
        },
        "240000000116070300ac02e80701030401046d616b6501022f77e807ac02010104e05d010a010b00",
    );
    c.check(
        "ServerCtl::CommandOutputResult",
        ServerCtl::CommandOutputResult {
            req_id: 7,
            pane_id: PANE,
            result: Ok(CommandOutput {
                mark: mark(true),
                text: "ok".into(),
                truncated: false,
            }),
        },
        "1e0000000117070300030401046d616b6501022f77e807ac02010104e05d026f6b00",
    );
    c.check(
        "ServerCtl::CommandOutputResult(Err)",
        ServerCtl::CommandOutputResult {
            req_id: 7,
            pane_id: PANE,
            result: Err(RpcError::NotFound),
        },
        "06000000011707030102",
    );
    c.check(
        "Bulk::HistoryPage",
        Bulk::HistoryPage {
            pane_id: PANE,
            snapshot_seq: Seq(300),
            offset: 5000,
            next_offset: 9000,
            total_len: 20_000,
            raw_len: 4000,
            pages: 2,
            done: false,
            data: vec![0xee; 3],
        },
        "14000000010103ac028827a846a09c01a01f020003eeeeee",
    );
    c.check(
        "Bulk::HistoryGone",
        Bulk::HistoryGone {
            pane_id: PANE,
            snapshot_seq: Seq(300),
        },
        "05000000010203ac02",
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
fn ticket_extras_carry_relays_and_stay_readable_by_old_parsers() {
    let ticket = Ticket {
        v: Ticket::VERSION,
        daemon_id: DaemonId([0x44; 32]),
        addrs: vec!["10.0.0.2:4433".parse().unwrap()],
        relay_url: Some("https://relay.example./".into()),
        principal: PRINCIPAL,
        secret: PairingSecret([0x55; 16]),
        expires: UnixMillis(1_760_000_000_000),
    };
    // Default relays: the plain ticket, byte for byte.
    assert_eq!(
        ticket.to_string_with(&TicketExtras::default()),
        ticket.to_string()
    );
    assert_eq!(
        Ticket::parse_with_extras(&ticket.to_string()).unwrap().1,
        TicketExtras::default()
    );
    for relays in [
        TicketRelays::Disabled,
        TicketRelays::Custom {
            urls: vec!["https://relay.example".into(), "https://r2.example".into()],
            auth_token: Some("tok".into()),
        },
    ] {
        let extras = TicketExtras {
            v: TicketExtras::VERSION,
            relays,
        };
        let text = ticket.to_string_with(&extras);
        assert_ne!(text, ticket.to_string());
        assert_eq!(
            Ticket::parse_with_extras(&text).unwrap(),
            (ticket.clone(), extras)
        );
        assert_eq!(text.parse::<Ticket>().unwrap(), ticket, "old readers");
        // Extras survive the QR's upper-casing.
        assert_eq!(
            Ticket::parse_with_extras(&text.to_ascii_uppercase())
                .unwrap()
                .0,
            ticket
        );
    }
    // Frozen: the extension's bytes after the ticket.
    let extras = TicketExtras {
        v: TicketExtras::VERSION,
        relays: TicketRelays::Disabled,
    };
    let text = ticket.to_string_with(&extras);
    let payload = text.rsplit('/').next().unwrap();
    let bytes = data_encoding::BASE32_NOPAD
        .decode(payload.as_bytes())
        .unwrap();
    let hex: String = bytes[bytes.len() - 3..]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    assert_eq!(hex, "e70102");
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

const DAEMON: DaemonId = DaemonId([0x44; 32]);
const LEASE: Lease = Lease {
    pane_id: PANE,
    holder: Some(PRINCIPAL),
    since: UnixMillis(1_760_000_000_000),
    mode: LeaseMode::Leased,
};

fn grant() -> Grant {
    Grant {
        v: Grant::VERSION,
        grant_id: GRANT,
        daemon_id: DAEMON,
        issuer: DEVICE,
        roles: Roles::DRIVER | Roles::APPROVER,
        scope: Scope::Session(SessionId(2)),
        issued_at: UnixMillis(1_760_000_000_000),
        expires: Some(UnixMillis(1_760_086_400_000)),
        max_uses: Some(1),
        bind: None,
        delegate: true,
        label: "bob".into(),
    }
}

fn chain() -> GrantChain {
    GrantChain {
        links: vec![GrantLink {
            grant: grant(),
            sig: vec![0x5a; 4],
        }],
    }
}

fn join_info() -> JoinInfo {
    JoinInfo {
        actor: ACTOR,
        name: "bob".into(),
        roles: Roles::VIEWER,
        scope: Scope::Pane(PANE),
        grant_id: Some(GRANT),
        expires: Some(UnixMillis(5)),
    }
}

fn participant() -> Participant {
    Participant {
        actor: ACTOR,
        name: "bob".into(),
        roles: Roles::DRIVER,
        scope: Scope::Daemon,
        grant_id: Some(GRANT),
        since: UnixMillis(7),
        state: PresenceState::Idle,
        focus: Some(PANE),
        typing: true,
        cursor: Some(CursorPos {
            pane_id: PANE,
            row: 1,
            col: 2,
        }),
    }
}

fn audit_record() -> AuditRecord {
    AuditRecord {
        seq: 3,
        at: UnixMillis(9),
        kind: AuditKind::Approval,
        actor: Some(ACTOR),
        grant_id: Some(GRANT),
        pane_id: Some(PANE),
        detail: "ok".into(),
        approval: Some(ApprovalAudit {
            request_id: RequestId(9),
            agent_request: "r1".into(),
            option_id: OptionId(0),
            option: "Yes".into(),
            tool: Some("Bash".into()),
            summary: "rm".into(),
            signed: vec![1, 2],
            sig: vec![3, 4],
        }),
        prev_hash: vec![0; 2],
        hash: vec![0xff; 2],
    }
}

fn multiplayer_messages(c: &mut Checker) {
    for (name, scope, golden) in [
        ("Scope::Daemon", Scope::Daemon, "020000000100"),
        (
            "Scope::Session",
            Scope::Session(SessionId(2)),
            "03000000010102",
        ),
        ("Scope::Tab", Scope::Tab(TabId(4)), "03000000010204"),
        ("Scope::Pane", Scope::Pane(PANE), "03000000010303"),
    ] {
        c.check(name, scope, golden);
    }
    c.check("GrantChain", chain(), "7000000001010133333333333333333333333333333333444444444444444444444444444444444444444444444444444444444444444422222222222222222222222222222222222222222222222222222222222222220c01028080b3c19c330180b8ccea9c330101000103626f62045a5a5a5a");
    c.check(
        "Invite",
        Invite {
            v: Invite::VERSION,
            daemon_id: DAEMON,
            addrs: vec!["127.0.0.1:4433".parse().unwrap()],
            relay_url: Some("https://r".into()),
            inviter: "alice".into(),
            chain: chain(),
        },
        "aa0000000101444444444444444444444444444444444444444444444444444444444444444401007f000001d122010968747470733a2f2f7205616c696365010133333333333333333333333333333333444444444444444444444444444444444444444444444444444444444444444422222222222222222222222222222222222222222222222222222222222222220c01028080b3c19c330180b8ccea9c330101000103626f62045a5a5a5a",
    );
    c.check(
        "Hello(CHAIN)",
        ClientCtl::Hello(Hello {
            device_id: DEVICE,
            principal_id: PRINCIPAL,
            grant: SignedGrant {
                v: SignedGrant::CHAIN,
                grant_id: GRANT,
                token: chain().to_token(),
            },
            snapshot_format: 1,
            resume: vec![],
            caps: Caps::EMPTY,
            link: LinkClass::Normal,
            resume_token: None,
        }),
        "b8000000010022222222222222222222222222222222222222222222222222222222222222221111111111111111111111111111111102333333333333333333333333333333336f010133333333333333333333333333333333444444444444444444444444444444444444444444444444444444444444444422222222222222222222222222222222222222222222222222222222222222220c01028080b3c19c330180b8ccea9c330101000103626f62045a5a5a5a0100000000",
    );

    let requests = [
        ("MpRequest::WhoAmI", MpRequest::WhoAmI, "0400000001160700"),
        (
            "MpRequest::Participants",
            MpRequest::Participants,
            "0400000001160701",
        ),
        (
            "MpRequest::RegisterGrant",
            MpRequest::RegisterGrant(chain()),
            "7300000001160702010133333333333333333333333333333333444444444444444444444444444444444444444444444444444444444444444422222222222222222222222222222222222222222222222222222222222222220c01028080b3c19c330180b8ccea9c330101000103626f62045a5a5a5a",
        ),
        (
            "MpRequest::ListGrants",
            MpRequest::ListGrants,
            "0400000001160703",
        ),
        (
            "MpRequest::ListDevices",
            MpRequest::ListDevices,
            "0400000001160704",
        ),
        (
            "MpRequest::Revoke(Grant)",
            MpRequest::Revoke(RevokeTarget::Grant(GRANT)),
            "15000000011607050033333333333333333333333333333333",
        ),
        (
            "MpRequest::Revoke(Device)",
            MpRequest::Revoke(RevokeTarget::Device(DEVICE)),
            "2500000001160705012222222222222222222222222222222222222222222222222222222222222222",
        ),
        (
            "MpRequest::Revoke(Principal)",
            MpRequest::Revoke(RevokeTarget::Principal(PRINCIPAL)),
            "15000000011607050211111111111111111111111111111111",
        ),
        (
            "MpRequest::TakeControl",
            MpRequest::TakeControl {
                pane_id: PANE,
                force: true,
            },
            "06000000011607060301",
        ),
        (
            "MpRequest::ReleaseControl",
            MpRequest::ReleaseControl { pane_id: PANE },
            "050000000116070703",
        ),
        (
            "MpRequest::AnswerControl",
            MpRequest::AnswerControl {
                pane_id: PANE,
                give: true,
            },
            "06000000011607080301",
        ),
        (
            "MpRequest::GiveControl",
            MpRequest::GiveControl {
                pane_id: PANE,
                to: PRINCIPAL,
            },
            "15000000011607090311111111111111111111111111111111",
        ),
        ("MpRequest::Leases", MpRequest::Leases, "040000000116070a"),
        (
            "MpRequest::Prompt",
            MpRequest::Prompt {
                pane_id: PANE,
                text: "fix it".into(),
                submit: true,
            },
            "0d0000000116070b030666697820697401",
        ),
        (
            "MpRequest::Audit",
            MpRequest::Audit(AuditQuery {
                after: Some(10),
                limit: 50,
            }),
            "070000000116070c010a32",
        ),
        (
            "MpRequest::SetName",
            MpRequest::SetName { name: "bo".into() },
            "070000000116070d02626f",
        ),
    ];
    for (name, req, golden) in requests {
        c.check(name, ClientCtl::Multiplayer { req_id: 7, req }, golden);
    }

    let device_info = DeviceInfo {
        device: DEVICE,
        principal: PRINCIPAL,
        kind: DeviceKind::Guest,
        name: "bob".into(),
        first_seen: UnixMillis(1),
        grant_id: Some(GRANT),
        revoked: false,
        connected: 2,
    };
    let answers: Vec<(&str, Result<MpResponse, MpError>, &str)> = vec![
        (
            "MpResponse::Done",
            Ok(MpResponse::Done),
            "05000000011d070000",
        ),
        (
            "MpResponse::Me",
            Ok(MpResponse::Me(join_info())),
            "4f000000011d07000111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222203626f6201030301333333333333333333333333333333330105",
        ),
        (
            "MpResponse::Participants",
            Ok(MpResponse::Participants(vec![participant()])),
            "56000000011d0700020111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222203626f6204000133333333333333333333333333333333070101030101030102",
        ),
        (
            "MpResponse::Grant",
            Ok(MpResponse::Grant(GrantInfo {
                grant: grant(),
                parent: Some(GrantId([0x34; 16])),
                bound: vec![DEVICE],
                revoked: true,
            })),
            "a1000000011d0700030133333333333333333333333333333333444444444444444444444444444444444444444444444444444444444444444422222222222222222222222222222222222222222222222222222222222222220c01028080b3c19c330180b8ccea9c330101000103626f62013434343434343434343434343434343401222222222222222222222222222222222222222222222222222222222222222201",
        ),
        (
            "MpResponse::Grants",
            Ok(MpResponse::Grants(vec![])),
            "06000000011d07000400",
        ),
        (
            "MpResponse::Devices",
            Ok(MpResponse::Devices(vec![
                device_info.clone(),
                DeviceInfo {
                    kind: DeviceKind::Owner,
                    grant_id: None,
                    ..device_info
                },
            ])),
            "88000000011d070005022222222222222222222222222222222222222222222222222222222222222222111111111111111111111111111111110103626f6201013333333333333333333333333333333300022222222222222222222222222222222222222222222222222222222222222222111111111111111111111111111111110003626f6201000002",
        ),
        (
            "MpResponse::Revoked",
            Ok(MpResponse::Revoked {
                grants: vec![GRANT],
                devices: vec![DEVICE],
                disconnected: 2,
            }),
            "38000000011d070006013333333333333333333333333333333301222222222222222222222222222222222222222222222222222222222222222202",
        ),
        (
            "MpResponse::Lease(Granted)",
            Ok(MpResponse::Lease(LeaseOutcome::Granted(LEASE))),
            "1f000000011d070007000301111111111111111111111111111111118080b3c19c3301",
        ),
        (
            "MpResponse::Lease(Pending)",
            Ok(MpResponse::Lease(LeaseOutcome::Pending {
                holder: PRINCIPAL,
            })),
            "16000000011d0700070111111111111111111111111111111111",
        ),
        (
            "MpResponse::Lease(Kept)",
            Ok(MpResponse::Lease(LeaseOutcome::Kept(LEASE))),
            "1f000000011d070007020301111111111111111111111111111111118080b3c19c3301",
        ),
        (
            "MpResponse::Leases",
            Ok(MpResponse::Leases(vec![LEASE])),
            "1f000000011d070008010301111111111111111111111111111111118080b3c19c3301",
        ),
        (
            "MpResponse::Prompted",
            Ok(MpResponse::Prompted { chars: 6 }),
            "06000000011d07000906",
        ),
        (
            "MpResponse::Audit",
            Ok(MpResponse::Audit(AuditPage {
                records: vec![audit_record()],
                total: 3,
                chain_ok: true,
            })),
            "71000000011d07000a010309080111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222201333333333333333333333333333333330103026f6b0109027231000359657301044261736802726d02010202030402000002ffff0301",
        ),
        (
            "MpError::Forbidden",
            Err(MpError::Forbidden("r".into())),
            "07000000011d0701000172",
        ),
        (
            "MpError::NotFound",
            Err(MpError::NotFound("p".into())),
            "07000000011d0701010170",
        ),
        (
            "MpError::Invalid",
            Err(MpError::Invalid("i".into())),
            "07000000011d0701020169",
        ),
        (
            "MpError::Conflict",
            Err(MpError::Conflict("c".into())),
            "07000000011d0701030163",
        ),
        (
            "MpError::Failed",
            Err(MpError::Failed("f".into())),
            "07000000011d0701040166",
        ),
        (
            "MpError::Disconnected",
            Err(MpError::Disconnected),
            "05000000011d070105",
        ),
    ];
    for (name, result, golden) in answers {
        c.check(
            name,
            ServerCtl::MultiplayerResult { req_id: 7, result },
            golden,
        );
    }

    c.check("ServerCtl::Joined", ServerCtl::Joined(join_info()), "4c000000011e11111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222203626f6201030301333333333333333333333333333333330105");
    c.check(
        "ServerCtl::Participants",
        ServerCtl::Participants {
            participants: vec![participant()],
        },
        "53000000011f0111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222203626f6204000133333333333333333333333333333333070101030101030102",
    );
    c.check(
        "ServerCtl::LeaseRequested",
        ServerCtl::LeaseRequested {
            pane_id: PANE,
            by: ACTOR,
            name: "bob".into(),
        },
        "3700000001200311111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222203626f62",
    );
    c.check(
        "ServerCtl::Forbidden",
        ServerCtl::Forbidden {
            what: "Input".into(),
            reason: "viewer".into(),
        },
        "0f000000012105496e70757406766965776572",
    );
    for (name, kind, golden) in [
        ("AuditKind::Join", AuditKind::Join, "020000000100"),
        ("AuditKind::Leave", AuditKind::Leave, "020000000101"),
        ("AuditKind::Paired", AuditKind::Paired, "020000000102"),
        (
            "AuditKind::GrantRegistered",
            AuditKind::GrantRegistered,
            "020000000103",
        ),
        (
            "AuditKind::GrantRedeemed",
            AuditKind::GrantRedeemed,
            "020000000104",
        ),
        ("AuditKind::Revoked", AuditKind::Revoked, "020000000105"),
        ("AuditKind::Lease", AuditKind::Lease, "020000000106"),
        ("AuditKind::Prompt", AuditKind::Prompt, "020000000107"),
        ("AuditKind::Approval", AuditKind::Approval, "020000000108"),
        ("AuditKind::Denied", AuditKind::Denied, "020000000109"),
    ] {
        c.check(name, kind, golden);
    }
}

#[test]
fn invite_round_trips_through_text() {
    let invite = Invite {
        v: Invite::VERSION,
        daemon_id: DAEMON,
        addrs: vec!["[::1]:9".parse().unwrap()],
        relay_url: None,
        inviter: "alice".into(),
        chain: chain(),
    };
    let text = invite.to_string();
    assert!(text.starts_with(&format!("{}://join/", brand::URL_SCHEME)));
    assert_eq!(text.parse::<Invite>().unwrap(), invite);
    // The fragment form and a lower-cased, wrapped payload parse too.
    let fragment = text.replacen("join/", "join#", 1);
    assert_eq!(fragment.parse::<Invite>().unwrap(), invite);
    let payload = text.rsplit('/').next().unwrap();
    let mangled = format!(" {}\n{} ", payload[..8].to_lowercase(), &payload[8..]);
    assert_eq!(mangled.parse::<Invite>().unwrap(), invite);
    // A pairing ticket is not an invite.
    assert!(
        format!("{}://pair/{payload}", brand::URL_SCHEME)
            .parse::<Invite>()
            .is_err()
    );
}

#[test]
fn grant_signing_bytes_are_domain_separated() {
    let g = grant();
    let bytes = g.signing_bytes();
    assert!(bytes.starts_with(Grant::SIGNING_CONTEXT));
    let mut other = g.clone();
    other.roles = Roles::OWNER;
    assert_ne!(other.signing_bytes(), bytes);
    let a = approval_signing_bytes(DAEMON, RequestId(1), OptionId(0), ACTOR);
    assert!(a.starts_with(b"approval-v1\0"));
    assert_ne!(
        a,
        approval_signing_bytes(DaemonId([0; 32]), RequestId(1), OptionId(0), ACTOR)
    );
}

#[test]
fn roles_parse_and_print() {
    let r: Roles = "driver+approver".parse().unwrap();
    assert_eq!(r, Roles::DRIVER | Roles::APPROVER);
    assert_eq!(r.names(), "approver+driver");
    assert!(Roles::OWNER.covers(r));
    assert!(!r.covers(Roles::OWNER));
    assert!("root".parse::<Roles>().is_err());
}

/// `EditorKind::Vscodium` (appended): a launch choosing it and its availability entry.
#[test]
fn vscodium_editor_messages_match_their_frozen_bytes() {
    let mut c = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: Vec::new(),
    };
    c.check(
        "ClientCtl::Workspace(EditorLaunch Vscodium)",
        ClientCtl::Workspace {
            req_id: 5,
            req: WorkspaceRequest::EditorLaunch(EditorLaunch {
                folder: "~/p".into(),
                choice: EditorChoice::Only(EditorKind::Vscodium),
                accept_vscode_license: false,
            }),
        },
        "0b00000001150502037e2f70010200",
    );
    c.check(
        "ServerCtl::WorkspaceResult(Editors Vscodium)",
        ServerCtl::WorkspaceResult {
            req_id: 5,
            result: Ok(WorkspaceResponse::Editors(EditorList {
                available: vec![EditorAvailability {
                    kind: EditorKind::Vscodium,
                    installed: false,
                    downloadable: true,
                    path: None,
                    version: Some("1.140.06880".into()),
                    note: None,
                }],
                running: vec![],
            })),
        },
        "1900000001180500020102000100010b312e3134302e30363838300000",
    );
    assert!(
        c.failures.is_empty(),
        "wire format changed:\n{}",
        c.failures.join("\n")
    );
}

// ---------------------------------------------------------------------------------------------
// ---------------------------------------------------------------------------------------------

const HASH: BlobHash = BlobHash([0x55; 32]);

fn image_ref() -> ImageRef {
    ImageRef {
        hash: HASH,
        media: MediaType::Png,
        size: 1000,
        width: 640,
        height: 480,
    }
}

fn element() -> Element {
    Element {
        id: ElementId(7),
        z: -1,
        style: Style {
            color: 0xff00_00ff,
            width: 2.5,
        },
        kind: ElementKind::Stroke(Stroke {
            tool: Tool::Pen,
            points: PackedPoints(vec![1, 2, 4, 128, 255, 0, 8]),
        }),
    }
}

fn row_anchor() -> RowAnchor {
    RowAnchor {
        pane_id: PANE,
        screen: AnchorScreen::Primary,
        at_seq: Seq(900),
        from_bottom: 12,
        command_id: Some(4),
        state: AnchorState::Live,
    }
}

fn artifact_info() -> ArtifactInfo {
    ArtifactInfo {
        artifact_id: ArtifactId(5),
        session_id: SessionId(2),
        kind: ArtifactKind::Drawing,
        title: "t".into(),
        space: CoordSpace::Cells,
        created_by: ACTOR,
        created_at: UnixMillis(10),
        updated_at: UnixMillis(20),
        version: 3,
        elements: 2,
        image: None,
        preview: Some(Preview {
            image: image_ref(),
            version: 3,
        }),
        anchor: Some(row_anchor()),
        canvas_panes: vec![PaneId(9)],
    }
}

fn op_batch() -> OpBatch {
    OpBatch {
        version: 3,
        actor: ACTOR,
        at: UnixMillis(20),
        ops: vec![
            DrawOp::Add(element()),
            DrawOp::Move {
                id: ElementId(7),
                dx: 1.0,
                dy: -1.0,
            },
            DrawOp::Delete { id: ElementId(8) },
        ],
    }
}

fn ink() -> InkLive {
    InkLive {
        artifact_id: ArtifactId(5),
        stroke_id: ElementId(99),
        actor: ACTOR,
        chunk: 2,
        tool: Tool::Highlighter,
        style: Style {
            color: 0xffff_0080,
            width: 8.0,
        },
        points: PackedPoints(vec![1, 0, 0, 255, 255, 0, 4]),
        done: false,
    }
}

fn artifact_messages(c: &mut Checker) {
    let req = |req: ArtifactRequest| ClientCtl::Artifact { req_id: 6, req };
    let anchor_req = AnchorRequest {
        pane_id: PANE,
        at_seq: Seq(800),
        from_bottom: 3,
    };
    for (name, msg, golden) in [
        (
            "ClientCtl::Artifact(List)",
            req(ArtifactRequest::List {
                session_id: SessionId(2),
            }),
            "050000000117060002",
        ),
        (
            "ClientCtl::Artifact(Create)",
            req(ArtifactRequest::Create(ArtifactCreate {
                session_id: SessionId(2),
                kind: ArtifactKind::Drawing,
                title: "t".into(),
                space: CoordSpace::Cells,
                anchor: Some(anchor_req),
                image: None,
                ops: vec![DrawOp::Add(element())],
            })),
            "260000000117060102000174010103a006030001000701ff8180f80f0000204000000701020480ff0008",
        ),
        (
            "ClientCtl::Artifact(Get)",
            req(ArtifactRequest::Get {
                artifact_id: ArtifactId(5),
                since: 2,
            }),
            "06000000011706020502",
        ),
        (
            "ClientCtl::Artifact(Apply)",
            req(ArtifactRequest::Apply {
                artifact_id: ArtifactId(5),
                base: 2,
                ops: vec![
                    DrawOp::Restyle {
                        id: ElementId(7),
                        style: Style {
                            color: 1,
                            width: 1.0,
                        },
                    },
                    DrawOp::SetZ {
                        id: ElementId(7),
                        z: 3,
                    },
                    DrawOp::Clear,
                    DrawOp::SetTitle("x".into()),
                ],
            }),
            "15000000011706030502040207010000803f03070605060178",
        ),
        (
            "ClientCtl::Artifact(Delete)",
            req(ArtifactRequest::Delete {
                artifact_id: ArtifactId(5),
            }),
            "050000000117060405",
        ),
        (
            "ClientCtl::Artifact(SetAnchor)",
            req(ArtifactRequest::SetAnchor {
                artifact_id: ArtifactId(5),
                anchor: Some(anchor_req),
            }),
            "0a00000001170605050103a00603",
        ),
        (
            "ClientCtl::Artifact(SetPreview)",
            req(ArtifactRequest::SetPreview {
                artifact_id: ArtifactId(5),
                version: 3,
                png: HASH,
            }),
            "260000000117060605035555555555555555555555555555555555555555555555555555555555555555",
        ),
        (
            "ClientCtl::Artifact(Export)",
            req(ArtifactRequest::Export {
                artifact_id: ArtifactId(5),
                version: Some(2),
                format: ExportFormat::Svg,
            }),
            "080000000117060705010201",
        ),
        (
            "ClientCtl::Artifact(Send)",
            req(ArtifactRequest::Send(ArtifactSend {
                pane_id: PANE,
                artifact_id: Some(ArtifactId(5)),
                version: None,
                png: PngSource::Inline(vec![0x89, 0x50]),
            })),
            "0c000000011706080301050000028950",
        ),
        (
            "ClientCtl::Artifact(Send blob)",
            req(ArtifactRequest::Send(ArtifactSend {
                pane_id: PANE,
                artifact_id: None,
                version: Some(1),
                png: PngSource::Blob(HASH),
            })),
            "290000000117060803000101015555555555555555555555555555555555555555555555555555555555555555",
        ),
        (
            "ClientCtl::Artifact(Send render)",
            req(ArtifactRequest::Send(ArtifactSend {
                pane_id: PANE,
                artifact_id: Some(ArtifactId(5)),
                version: None,
                png: PngSource::Artifact,
            })),
            "09000000011706080301050002",
        ),
        (
            "ClientCtl::InkLive",
            ClientCtl::InkLive(ink()),
            "480000000118056311111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222202018081fcff0f0000004107010000ffff000400",
        ),
    ] {
        c.check(name, msg, golden);
    }

    let res = |result: Result<ArtifactResponse, ArtifactError>| ServerCtl::ArtifactResult {
        req_id: 6,
        result,
    };
    for (name, msg, golden) in [
        (
            "ServerCtl::ArtifactResult(List)",
            res(Ok(ArtifactResponse::List(vec![artifact_info()]))),
            "750000000122060000010502000174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c0104000109",
        ),
        (
            "ServerCtl::ArtifactResult(Created)",
            res(Ok(ArtifactResponse::Created(artifact_info()))),
            "7400000001220600010502000174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c0104000109",
        ),
        (
            "ServerCtl::ArtifactResult(Scene)",
            res(Ok(ArtifactResponse::Scene(ArtifactScene {
                info: artifact_info(),
                elements: Some(vec![element()]),
                batches: vec![op_batch()],
            }))),
            "e100000001220600020502000174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c010400010901010701ff8180f80f0000204000000701020480ff000801031111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222221403000701ff8180f80f0000204000000701020480ff000801070000803f000080bf0408",
        ),
        (
            "ServerCtl::ArtifactResult(Applied)",
            res(Ok(ArtifactResponse::Applied {
                artifact_id: ArtifactId(5),
                version: 4,
            })),
            "0700000001220600030504",
        ),
        (
            "ServerCtl::ArtifactResult(Info)",
            res(Ok(ArtifactResponse::Info(artifact_info()))),
            "7400000001220600040502000174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c0104000109",
        ),
        (
            "ServerCtl::ArtifactResult(Exported)",
            res(Ok(ArtifactResponse::Exported(Exported {
                format: ExportFormat::Png,
                version: 3,
                data: vec![],
                blob: Some(HASH),
            }))),
            "290000000122060005000300015555555555555555555555555555555555555555555555555555555555555555",
        ),
        (
            "ServerCtl::ArtifactResult(Sent)",
            res(Ok(ArtifactResponse::Sent(Sent {
                artifact_id: ArtifactId(5),
                version: 3,
                path: "/a b/5@3.png".into(),
                pasted: "/a\\ b/5@3.png".into(),
                bracketed: true,
            }))),
            "23000000012206000605030c2f6120622f3540332e706e670d2f615c20622f3540332e706e6701",
        ),
        (
            "ServerCtl::ArtifactResult(Done)",
            res(Ok(ArtifactResponse::Done)),
            "050000000122060007",
        ),
        (
            "ArtifactError::NotFound",
            res(Err(ArtifactError::NotFound("x".into()))),
            "0700000001220601000178",
        ),
        (
            "ArtifactError::Forbidden",
            res(Err(ArtifactError::Forbidden("x".into()))),
            "0700000001220601010178",
        ),
        (
            "ArtifactError::TooLarge",
            res(Err(ArtifactError::TooLarge("x".into()))),
            "0700000001220601020178",
        ),
        (
            "ArtifactError::Invalid",
            res(Err(ArtifactError::Invalid("x".into()))),
            "0700000001220601030178",
        ),
        (
            "ArtifactError::NotAgentPane",
            res(Err(ArtifactError::NotAgentPane)),
            "050000000122060104",
        ),
        (
            "ArtifactError::Failed",
            res(Err(ArtifactError::Failed("x".into()))),
            "0700000001220601050178",
        ),
        (
            "ArtifactError::Disconnected",
            res(Err(ArtifactError::Disconnected)),
            "050000000122060106",
        ),
        (
            "ServerCtl::Artifact(Created)",
            ServerCtl::Artifact(ArtifactEvent::Created(artifact_info())),
            "720000000123000502000174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c0104000109",
        ),
        (
            "ServerCtl::Artifact(Changed)",
            ServerCtl::Artifact(ArtifactEvent::Changed {
                info: artifact_info(),
                batch: op_batch(),
            }),
            "c70000000123010502000174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c0104000109031111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222221403000701ff8180f80f0000204000000701020480ff000801070000803f000080bf0408",
        ),
        (
            "ServerCtl::Artifact(Info)",
            ServerCtl::Artifact(ArtifactEvent::Info(artifact_info())),
            "720000000123020502000174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c0104000109",
        ),
        (
            "ServerCtl::Artifact(Deleted)",
            ServerCtl::Artifact(ArtifactEvent::Deleted {
                session_id: SessionId(2),
                artifact_id: ArtifactId(5),
            }),
            "050000000123030205",
        ),
        (
            "ServerCtl::Artifact(Ink)",
            ServerCtl::Artifact(ArtifactEvent::Ink(ink())),
            "49000000012304056311111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222202018081fcff0f0000004107010000ffff000400",
        ),
        (
            "ServerCtl::Artifact(Canvases)",
            ServerCtl::Artifact(ArtifactEvent::Canvases {
                session_id: SessionId(2),
                canvases: vec![CanvasPane {
                    pane_id: PaneId(9),
                    artifact_id: ArtifactId(5),
                }],
            }),
            "0700000001230502010905",
        ),
    ] {
        c.check(name, msg, golden);
    }

    for (name, msg, golden) in [
        (
            "StreamHeader::Blob(Put)",
            StreamHeader::Blob(BlobHeader::Put {
                session_id: SessionId(2),
                size: 300,
                media: MediaType::Jpeg,
            }),
            "0700000001070002ac0201",
        ),
        (
            "StreamHeader::Blob(Get)",
            StreamHeader::Blob(BlobHeader::Get { hash: HASH }),
            "230000000107015555555555555555555555555555555555555555555555555555555555555555",
        ),
    ] {
        c.check(name, msg, golden);
    }
    for (name, msg, golden) in [
        ("BlobReply::Ready", BlobReply::Ready, "020000000100"),
        (
            "BlobReply::Stored",
            BlobReply::Stored(image_ref()),
            "290000000101555555555555555555555555555555555555555555555555555555555555555500e8078005e003",
        ),
        (
            "BlobReply::Found",
            BlobReply::Found(image_ref()),
            "290000000102555555555555555555555555555555555555555555555555555555555555555500e8078005e003",
        ),
        (
            "BlobReply::Failed",
            BlobReply::Failed(ArtifactError::TooLarge("big".into())),
            "0700000001030203626967",
        ),
    ] {
        c.check(name, msg, golden);
    }
    let shapes = vec![
        ElementKind::Shape {
            shape: ShapeKind::Rect,
            from: Pt { x: 0.0, y: 0.0 },
            to: Pt { x: 1.0, y: 1.0 },
            filled: true,
        },
        ElementKind::Shape {
            shape: ShapeKind::Ellipse,
            from: Pt { x: 0.0, y: 0.0 },
            to: Pt { x: 1.0, y: 1.0 },
            filled: false,
        },
        ElementKind::Shape {
            shape: ShapeKind::Line,
            from: Pt { x: 0.0, y: 0.0 },
            to: Pt { x: 1.0, y: 1.0 },
            filled: false,
        },
        ElementKind::Shape {
            shape: ShapeKind::Arrow,
            from: Pt { x: 0.0, y: 0.0 },
            to: Pt { x: 1.0, y: 1.0 },
            filled: false,
        },
        ElementKind::Text {
            at: Pt { x: 1.0, y: 2.0 },
            text: "hi".into(),
            size: 12.0,
        },
        ElementKind::Image {
            image: image_ref(),
            from: Pt { x: 0.0, y: 0.0 },
            to: Pt { x: 4.0, y: 3.0 },
        },
        ElementKind::Stroke(Stroke {
            tool: Tool::Marker,
            points: PackedPoints(vec![]),
        }),
    ];
    let goldens = [
        "1400000001010000000000000000000000803f0000803f01",
        "1400000001010100000000000000000000803f0000803f00",
        "1400000001010200000000000000000000803f0000803f00",
        "1400000001010300000000000000000000803f0000803f00",
        "1100000001020000803f0000004002686900004041",
        "390000000103555555555555555555555555555555555555555555555555555555555555555500e8078005e00300000000000000000000804000004040",
        "0400000001000200",
    ];
    for (i, (kind, golden)) in shapes.into_iter().zip(goldens).enumerate() {
        c.check(&format!("ElementKind#{i}"), kind, golden);
    }
    for (name, msg, golden) in [
        (
            "RowAnchor(Detached)",
            RowAnchor {
                screen: AnchorScreen::Alternate,
                state: AnchorState::Detached(DetachReason::AltScreenExited),
                ..row_anchor()
            },
            "0a00000001030184070c01040101",
        ),
        (
            "RowAnchor(RowGone)",
            RowAnchor {
                state: AnchorState::Detached(DetachReason::RowGone),
                ..row_anchor()
            },
            "0a00000001030084070c01040100",
        ),
        (
            "RowAnchor(PaneClosed)",
            RowAnchor {
                state: AnchorState::Detached(DetachReason::PaneClosed),
                ..row_anchor()
            },
            "0a00000001030084070c01040102",
        ),
        (
            "RowAnchor(DaemonRestart)",
            RowAnchor {
                state: AnchorState::Detached(DetachReason::DaemonRestart),
                ..row_anchor()
            },
            "0a00000001030084070c01040103",
        ),
    ] {
        c.check(name, msg, golden);
    }
    c.check(
        "ArtifactInfo(Image)",
        ArtifactInfo {
            kind: ArtifactKind::Image,
            space: CoordSpace::Canvas,
            image: Some(image_ref()),
            preview: None,
            anchor: None,
            canvas_panes: vec![],
            ..artifact_info()
        },
        "66000000010502010174001111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a14030201555555555555555555555555555555555555555555555555555555555555555500e8078005e003000000",
    );
    c.check(
        "LayoutOp::Split(Canvas)",
        LayoutOp::Split {
            pane_id: PANE,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Canvas {
                artifact_id: Some(ArtifactId(5)),
            },
        },
        "0700000001000300030105",
    );
    c.check(
        "PaneLaunch::Canvas(None)",
        PaneLaunch::Canvas { artifact_id: None },
        "03000000010300",
    );
    c.check("Caps::ARTIFACTS", Caps::ARTIFACTS, "020000000108");
}


fn ex_element() -> ExElement {
    ExElement {
        id: "r1".into(),
        version: 4,
        version_nonce: 77,
        deleted: false,
        json: r#"{"id":"r1"}"#.into(),
    }
}

fn ex_file() -> ExFile {
    ExFile {
        file_id: "f1".into(),
        image: image_ref(),
    }
}

fn placement() -> Placement {
    Placement {
        placement_id: 8,
        pane_id: PANE,
        artifact_id: ArtifactId(5),
        version: 3,
        image: image_ref(),
        anchor: row_anchor(),
        col: 2,
        cols: 40,
        rows: 12,
        source: PlacementSource::User,
        at: UnixMillis(30),
    }
}

fn artifact_messages_2(c: &mut Checker) {
    let req = |req: ArtifactRequest| ClientCtl::Artifact { req_id: 6, req };
    let res = |result: Result<ArtifactResponse, ArtifactError>| ServerCtl::ArtifactResult {
        req_id: 6,
        result,
    };
    for (name, msg, golden) in [
        (
            "ClientCtl::Artifact(Export Ascii)",
            req(ArtifactRequest::Export {
                artifact_id: ArtifactId(5),
                version: None,
                format: ExportFormat::Ascii,
            }),
            "0700000001170607050002",
        ),
        (
            "ClientCtl::Artifact(ExcalidrawGet)",
            req(ArtifactRequest::ExcalidrawGet {
                artifact_id: ArtifactId(5),
                since: 9,
            }),
            "06000000011706090509",
        ),
        (
            "ClientCtl::Artifact(ExcalidrawPut)",
            req(ArtifactRequest::ExcalidrawPut(ExcalidrawPut {
                artifact_id: ArtifactId(5),
                base: 9,
                elements: vec![ex_element()],
                app_state: Some("{}".into()),
                files: vec![ex_file()],
            })),
            "480000000117060a050901027231044d000b7b226964223a227231227d01027b7d01026631555555555555555555555555555555555555555555555555555555555555555500e8078005e003",
        ),
        (
            "ClientCtl::Artifact(Place)",
            req(ArtifactRequest::Place(PlaceRequest {
                pane_id: PANE,
                artifact_id: ArtifactId(5),
                version: Some(3),
                anchor: Some(AnchorRequest {
                    pane_id: PANE,
                    at_seq: Seq(800),
                    from_bottom: 3,
                }),
                col: 2,
                cols: 0,
                rows: 0,
                png: Some(HASH),
                replace: Some(7),
            })),
            "330000000117060b030501030103a006030200000155555555555555555555555555555555555555555555555555555555555555550107",
        ),
        (
            "ClientCtl::Artifact(Unplace)",
            req(ArtifactRequest::Unplace { placement_id: 8 }),
            "050000000117060c08",
        ),
        (
            "ClientCtl::Artifact(Placements)",
            req(ArtifactRequest::Placements { pane_id: PANE }),
            "050000000117060d03",
        ),
        (
            "ClientCtl::Artifact(Import)",
            req(ArtifactRequest::Import(ImportRequest {
                pane_id: PANE,
                name: "a.excalidraw".into(),
                data: b"{}".to_vec(),
                blob: None,
            })),
            "160000000117060e030c612e657863616c6964726177027b7d00",
        ),
    ] {
        c.check(name, msg, golden);
    }
    for (name, msg, golden) in [
        (
            "ServerCtl::ArtifactResult(Excalidraw)",
            res(Ok(ArtifactResponse::Excalidraw(ExcalidrawScene {
                info: ArtifactInfo {
                    kind: ArtifactKind::Excalidraw,
                    ..artifact_info()
                },
                elements: vec![ex_element()],
                app_state: None,
                files: vec![ex_file()],
            }))),
            "b300000001220600080502020174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c010400010901027231044d000b7b226964223a227231227d0001026631555555555555555555555555555555555555555555555555555555555555555500e8078005e003",
        ),
        (
            "ServerCtl::ArtifactResult(ExcalidrawApplied)",
            res(Ok(ArtifactResponse::ExcalidrawApplied {
                artifact_id: ArtifactId(5),
                version: 10,
                rejected: vec![ex_element()],
            })),
            "1a0000000122060009050a01027231044d000b7b226964223a227231227d",
        ),
        (
            "ServerCtl::ArtifactResult(Placed)",
            res(Ok(ArtifactResponse::Placed(placement()))),
            "3d000000012206000a08030503555555555555555555555555555555555555555555555555555555555555555500e8078005e003030084070c01040002280c001e",
        ),
        (
            "ServerCtl::ArtifactResult(Placements)",
            res(Ok(ArtifactResponse::Placements(vec![Placement {
                source: PlacementSource::Kitty,
                ..placement()
            }]))),
            "3e000000012206000b0108030503555555555555555555555555555555555555555555555555555555555555555500e8078005e003030084070c01040002280c011e",
        ),
        (
            "ServerCtl::Artifact(Excalidraw)",
            ServerCtl::Artifact(ArtifactEvent::Excalidraw {
                artifact_id: ArtifactId(5),
                version: 10,
                elements: vec![ex_element()],
                app_state: Some("{}".into()),
                files: vec![],
            }),
            "1d000000012306050a01027231044d000b7b226964223a227231227d01027b7d00",
        ),
        (
            "ServerCtl::Artifact(Placed)",
            ServerCtl::Artifact(ArtifactEvent::Placed(placement())),
            "3b00000001230708030503555555555555555555555555555555555555555555555555555555555555555500e8078005e003030084070c01040002280c001e",
        ),
        (
            "ServerCtl::Artifact(Unplaced)",
            ServerCtl::Artifact(ArtifactEvent::Unplaced {
                pane_id: PANE,
                placement_id: 8,
            }),
            "050000000123080308",
        ),
    ] {
        c.check(name, msg, golden);
    }
}

/// Drawing history: `DaemonFeatures::ARTIFACT_HISTORY` (bit 2), `ArtifactRequest::History` /
/// `Restore` (appended after `Import`, 0x0f/0x10) and `ArtifactResponse::History` /
/// `Restored` (appended after `Placements`, 0x0c/0x0d).
fn artifact_history_messages(c: &mut Checker) {
    let req = |req: ArtifactRequest| ClientCtl::Artifact { req_id: 6, req };
    let res = |result: Result<ArtifactResponse, ArtifactError>| ServerCtl::ArtifactResult {
        req_id: 6,
        result,
    };
    let version = ArtifactVersion {
        version: 7,
        at: UnixMillis(1000),
        by: ACTOR,
        image: Some(image_ref()),
        elements: 3,
        restored_from: Some(4),
    };
    c.check(
        "DaemonFeatures::ARTIFACT_HISTORY",
        DaemonFeatures::ARTIFACT_HISTORY,
        "020000000104",
    );
    c.check(
        "ClientCtl::Artifact(History)",
        req(ArtifactRequest::History {
            artifact_id: ArtifactId(5),
        }),
        "050000000117060f05",
    );
    c.check(
        "ClientCtl::Artifact(Restore)",
        req(ArtifactRequest::Restore {
            artifact_id: ArtifactId(5),
            version: 4,
        }),
        "06000000011706100504",
    );
    c.check(
        "ServerCtl::ArtifactResult(History)",
        res(Ok(ArtifactResponse::History(vec![
            version.clone(),
            ArtifactVersion {
                version: 4,
                image: None,
                restored_from: None,
                ..version.clone()
            },
        ]))),
        "9a000000012206000c0207e80711111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222201555555555555555555555555555555555555555555555555555555555555555500e8078005e00303010404e807111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222000300",
    );
    c.check(
        "ServerCtl::ArtifactResult(Restored)",
        res(Ok(ArtifactResponse::Restored {
            info: artifact_info(),
            version,
        })),
        "d2000000012206000d0502000174011111111111111111111111111111111122222222222222222222222222222222222222222222222222222222222222220a1403020001555555555555555555555555555555555555555555555555555555555555555500e8078005e0030301030084070c010400010907e80711111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222201555555555555555555555555555555555555555555555555555555555555555500e8078005e003030104",
    );
}

/// Live Activity pushes: `DaemonFeatures::LIVE_ACTIVITY` (bit 4) and
/// `WorkspaceRequest::PushActivity` (appended after `ScriptRun`, 0x2f).
fn live_activity_messages(c: &mut Checker) {
    c.check(
        "DaemonFeatures::LIVE_ACTIVITY",
        DaemonFeatures::LIVE_ACTIVITY,
        "020000000110",
    );
    c.check(
        "ClientCtl::Workspace(PushActivity(Some))",
        ClientCtl::Workspace {
            req_id: 9,
            req: WorkspaceRequest::PushActivity(PushActivityToken {
                cap: Some("u".into()),
            }),
        },
        "070000000115092f010175",
    );
    c.check(
        "ClientCtl::Workspace(PushActivity(None))",
        ClientCtl::Workspace {
            req_id: 9,
            req: WorkspaceRequest::PushActivity(PushActivityToken { cap: None }),
        },
        "050000000115092f00",
    );
}

fn browser_messages(c: &mut Checker) {
    c.check("Caps::BROWSER", Caps::BROWSER, "03000000018040");
    c.check(
        "DaemonFeatures::BROWSER",
        DaemonFeatures::BROWSER,
        "03000000018002",
    );
    c.check(
        "ServerCtl::Browser(Open)",
        ServerCtl::Browser(BrowserPush::Open {
            pane_id: PANE,
            url: "http://x".into(),
        }),
        "0d0000000133000308687474703a2f2f78",
    );
    c.check(
        "ServerCtl::Browser(Call)",
        ServerCtl::Browser(BrowserPush::Call {
            id: 7,
            pane_id: PANE,
            tool: "browser_snapshot".into(),
            args: "{}".into(),
        }),
        "1900000001330107031062726f777365725f736e617073686f74027b7d",
    );
    c.check(
        "ServerCtl::Browser(CallClosed)",
        ServerCtl::Browser(BrowserPush::CallClosed { id: 7 }),
        "0400000001330207",
    );
    c.check(
        "ClientCtl::BrowserResult(Ok)",
        ClientCtl::BrowserResult {
            id: 7,
            result: Ok("{}".into()),
        },
        "07000000011c0700027b7d",
    );
    c.check(
        "ClientCtl::BrowserResult(Err)",
        ClientCtl::BrowserResult {
            id: 7,
            result: Err("no".into()),
        },
        "07000000011c0701026e6f",
    );
}
