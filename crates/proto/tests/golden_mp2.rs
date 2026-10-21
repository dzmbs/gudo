//! policies), kept apart from `golden.rs` so the cases of parallel additions do not collide.
//! Same rule: never edit an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_mp2 -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

const PANE: PaneId = PaneId(3);
const SESSION: SessionId = SessionId(2);
const ACTOR: Actor = Actor {
    principal: PrincipalId([0x11; 16]),
    device: DeviceId([0x22; 32]),
};
const GRANT: GrantId = GrantId([0x33; 16]);
const KNOCK: KnockId = KnockId(7);

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

fn grant() -> Grant {
    Grant {
        v: Grant::VERSION,
        grant_id: GRANT,
        daemon_id: DaemonId([0x44; 32]),
        issuer: DeviceId([0x55; 32]),
        roles: Roles::DRIVER,
        scope: Scope::Session(SESSION),
        issued_at: UnixMillis(1),
        expires: Some(UnixMillis(2)),
        max_uses: Some(1),
        bind: None,
        delegate: false,
        label: "bo".into(),
    }
}

fn chain() -> GrantChain {
    GrantChain {
        links: vec![GrantLink {
            grant: grant(),
            sig: vec![9, 9],
        }],
    }
}

fn knock() -> Knock {
    Knock {
        knock_id: KNOCK,
        actor: ACTOR,
        name: "bo".into(),
        grant_id: GRANT,
        roles: Roles::VIEWER,
        scope: Scope::Pane(PANE),
        at: UnixMillis(5),
    }
}

fn vote() -> ApprovalVote {
    ApprovalVote {
        actor: ACTOR,
        name: "al".into(),
        at: UnixMillis(6),
    }
}

fn status() -> ApprovalStatus {
    ApprovalStatus {
        pane_id: PANE,
        request_id: RequestId(4),
        risk: Risk::Any,
        mode: ApprovalMode::TwoPerson,
        approvals: vec![vote()],
        needed: 2,
        claimed_by: None,
    }
}

const POLICY: ApprovalPolicy = ApprovalPolicy {
    mode: ApprovalMode::Claim,
    max_risk: Risk::Edits,
};

#[test]
fn mp2_messages_match_their_frozen_bytes() {
    let mut c = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };
    assert_eq!(Caps::KNOCK.0, 1 << 9);
    assert_eq!(Caps::APPROVAL_POLICY.0, 1 << 10);
    assert_eq!(DaemonFeatures::MP2.0, 1 << 3);

    let req = |req| ClientCtl::Multiplayer { req_id: 5, req };
    c.check(
        "MpRequest::RegisterInvite",
        req(MpRequest::RegisterInvite {
            chain: chain(),
            terms: InviteTerms {
                knock: true,
                history: History::SinceJoin,
            },
        }),
        "680000000116050e010133333333333333333333333333333333444444444444444444444444444444444444444444444444444444444444444455555555555555555555555555555555555555555555555555555555555555550401020101020101000002626f0209090101",
    );
    c.check(
        "MpRequest::Knocks",
        req(MpRequest::Knocks),
        "040000000116050f",
    );
    c.check(
        "MpRequest::AnswerKnock(admit)",
        req(MpRequest::AnswerKnock {
            knock_id: KNOCK,
            admit: Some(Admit {
                roles: Roles::DRIVER | Roles::APPROVER,
                history: History::Full,
                expires: Some(UnixMillis(9)),
            }),
        }),
        "0a0000000116051007010c000109",
    );
    c.check(
        "MpRequest::AnswerKnock(deny)",
        req(MpRequest::AnswerKnock {
            knock_id: KNOCK,
            admit: None,
        }),
        "06000000011605100700",
    );
    c.check(
        "MpRequest::GetApprovalPolicy",
        req(MpRequest::GetApprovalPolicy {
            session_id: SESSION,
        }),
        "050000000116051102",
    );
    c.check(
        "MpRequest::SetApprovalPolicy",
        req(MpRequest::SetApprovalPolicy {
            session_id: SESSION,
            policy: POLICY,
        }),
        "0700000001160512020301",
    );
    c.check(
        "MpRequest::Claim",
        req(MpRequest::Claim {
            request_id: RequestId(4),
            claim: true,
        }),
        "06000000011605130401",
    );

    let answer = |result| ServerCtl::MultiplayerResult { req_id: 5, result };
    c.check(
        "MpResponse::Knocks",
        answer(Ok(MpResponse::Knocks(vec![knock()]))),
        "4e000000011d05000b010711111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222202626f3333333333333333333333333333333301030305",
    );
    c.check(
        "MpResponse::Admitted",
        answer(Ok(MpResponse::Admitted(GrantInfo {
            grant: grant(),
            parent: None,
            bound: vec![ACTOR.device],
            revoked: false,
        }))),
        "86000000011d05000c0133333333333333333333333333333333444444444444444444444444444444444444444444444444444444444444444455555555555555555555555555555555555555555555555555555555555555550401020101020101000002626f0001222222222222222222222222222222222222222222222222222222222222222200",
    );
    c.check(
        "MpResponse::ApprovalPolicy",
        answer(Ok(MpResponse::ApprovalPolicy(POLICY))),
        "07000000011d05000d0301",
    );
    c.check(
        "MpResponse::Approval",
        answer(Ok(MpResponse::Approval(ApprovalStatus {
            claimed_by: Some(vote()),
            ..status()
        }))),
        "74000000011d05000e030402020111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222202616c06020111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222202616c06",
    );

    c.check(
        "ServerCtl::Knock(Added)",
        ServerCtl::Knock(KnockUpdate::Added(knock())),
        "4b000000012c000711111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222202626f3333333333333333333333333333333301030305",
    );
    for (name, outcome, golden) in [
        (
            "Admitted",
            KnockOutcome::Admitted {
                roles: Roles::VIEWER,
            },
            "37000000012c0107000101111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222",
        ),
        (
            "Denied",
            KnockOutcome::Denied,
            "36000000012c01070101111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222",
        ),
        (
            "Withdrawn",
            KnockOutcome::Withdrawn,
            "36000000012c01070201111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222",
        ),
    ] {
        c.check(
            &format!("ServerCtl::Knock(Gone {name})"),
            ServerCtl::Knock(KnockUpdate::Gone {
                knock_id: KNOCK,
                outcome,
                by: Some(ACTOR),
            }),
            golden,
        );
    }
    c.check(
        "ServerCtl::KnockAnswer(Waiting)",
        ServerCtl::KnockAnswer(KnockAnswer::Waiting { knock_id: KNOCK }),
        "04000000012d0007",
    );
    c.check(
        "ServerCtl::KnockAnswer(Admitted)",
        ServerCtl::KnockAnswer(KnockAnswer::Admitted(chain())),
        "65000000012d01010133333333333333333333333333333333444444444444444444444444444444444444444444444444444444444444444455555555555555555555555555555555555555555555555555555555555555550401020101020101000002626f020909",
    );
    c.check(
        "ServerCtl::KnockAnswer(Denied)",
        ServerCtl::KnockAnswer(KnockAnswer::Denied),
        "03000000012d02",
    );
    c.check(
        "ServerCtl::ApprovalPolicy",
        ServerCtl::ApprovalPolicy {
            session_id: SESSION,
            policy: POLICY,
        },
        "05000000012e020301",
    );
    c.check("ServerCtl::ApprovalStatus", ServerCtl::ApprovalStatus(status()), "3d000000012f030402020111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222202616c060200");

    for (name, kind, golden) in [
        ("Knock", AuditKind::Knock, "02000000010a"),
        ("KnockAnswered", AuditKind::KnockAnswered, "02000000010b"),
        ("Policy", AuditKind::Policy, "02000000010c"),
        ("Claim", AuditKind::Claim, "02000000010d"),
    ] {
        c.check(&format!("AuditKind::{name}"), kind, golden);
    }
    for (name, mode, golden) in [
        ("AnyApprover", ApprovalMode::AnyApprover, "020000000100"),
        ("OwnerOnly", ApprovalMode::OwnerOnly, "020000000101"),
        ("TwoPerson", ApprovalMode::TwoPerson, "020000000102"),
        ("Claim", ApprovalMode::Claim, "020000000103"),
    ] {
        c.check(&format!("ApprovalMode::{name}"), mode, golden);
    }
    for (name, risk, golden) in [
        ("ReadOnly", Risk::ReadOnly, "020000000100"),
        ("Edits", Risk::Edits, "020000000101"),
        ("Any", Risk::Any, "020000000102"),
    ] {
        c.check(&format!("Risk::{name}"), risk, golden);
    }
    assert!(c.failures.is_empty(), "{}", c.failures.join("\n"));
}

#[test]
fn invite_terms_ride_after_the_invite() {
    let invite = Invite {
        v: Invite::VERSION,
        daemon_id: DaemonId([7; 32]),
        addrs: vec!["127.0.0.1:4433".parse().unwrap()],
        relay_url: None,
        inviter: "alice".into(),
        chain: chain(),
    };
    let terms = InviteTerms {
        knock: true,
        history: History::SinceJoin,
    };
    let text = invite.to_string_with_terms(terms);
    // Frozen: the terms are a marker byte and `(version, terms)` after the invite.
    let plain = invite.to_string();
    assert!(text.len() > plain.len());
    assert_eq!(
        Invite::parse_with_terms(&text).unwrap(),
        (invite.clone(), terms)
    );
    assert_eq!(
        text.parse::<Invite>().unwrap(),
        invite,
        "old readers ignore terms"
    );
    assert_eq!(
        Invite::parse_with_terms(&plain).unwrap(),
        (invite.clone(), InviteTerms::default())
    );
    // Default terms add nothing, so plain invites stay byte-identical.
    assert_eq!(invite.to_string_with_terms(InviteTerms::default()), plain);
    // The fragment form and upper case (QR codes) carry the terms too.
    let qr = text.to_ascii_uppercase().replacen("/JOIN/", "/JOIN#", 1);
    assert_eq!(Invite::parse_with_terms(&qr).unwrap().1, terms);
}

#[test]
fn terms_only_get_stricter() {
    let open = InviteTerms::default();
    let knock = InviteTerms {
        knock: true,
        history: History::Full,
    };
    let since = InviteTerms {
        knock: false,
        history: History::SinceJoin,
    };
    assert_eq!(open.strictest(open), open);
    assert_eq!(
        knock.strictest(since),
        InviteTerms {
            knock: true,
            history: History::SinceJoin
        }
    );
    assert_eq!(since.strictest(open), since);
}

#[test]
fn tools_have_a_risk_class() {
    for tool in [
        "Read",
        "Grep",
        "Glob",
        "LS",
        "WebFetch",
        "WebSearch",
        "TodoWrite",
    ] {
        assert_eq!(Risk::of_tool(Some(tool)), Risk::ReadOnly, "{tool}");
    }
    for tool in ["Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch"] {
        assert_eq!(Risk::of_tool(Some(tool)), Risk::Edits, "{tool}");
    }
    for tool in ["Bash", "Task", "mcp__github__merge", "", "exec_command"] {
        assert_eq!(Risk::of_tool(Some(tool)), Risk::Any, "{tool}");
    }
    assert!(Risk::ReadOnly < Risk::Edits && Risk::Edits < Risk::Any);
}
