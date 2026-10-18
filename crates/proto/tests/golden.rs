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
    multiplayer_messages(&mut c);

    assert!(
        c.failures.is_empty(),
        "wire format changed:\n{}",
        c.failures.join("\n")
    );
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
