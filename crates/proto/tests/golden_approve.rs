//! Frozen wire bytes for the approval extras (`proto::approve`), kept apart from `golden.rs`
//! so the cases of parallel additions do not collide. Same rule: never edit an existing hex
//! string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_approve -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

const PANE: PaneId = PaneId(3);
const ACTOR: Actor = Actor {
    principal: PrincipalId([0xaa; 16]),
    device: DeviceId([0xbb; 32]),
};

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

fn rule() -> AutoApproveRule {
    AutoApproveRule {
        rule_id: RuleId([0x11; 16]),
        pane_id: PANE,
        request_id: Some(RequestId(7)),
        matcher: RuleMatch {
            tool: "Bash".into(),
            prefix: "ls".into(),
        },
        expires_at: UnixMillis(1000),
        max_turns: 2,
        actor: ACTOR,
        sig: vec![1, 2],
    }
}

#[test]
fn approval_messages_match_their_frozen_bytes() {
    let mut c = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };
    assert_eq!(Caps::APPROVALS.0, 1 << 9);

    let req = |req| ClientCtl::Approval { req_id: 5, req };
    c.check(
        "ClientCtl::Approval(ApproveEdited)",
        req(ApprovalRequest::ApproveEdited {
            decide: Decide {
                request_id: RequestId(7),
                option_id: OptionId(0),
                actor: ACTOR,
                sig: vec![9],
            },
            input: "ls".into(),
        }),
        "3b000000011b05000700aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0109026c73",
    );
    c.check(
        "ClientCtl::Approval(AddRule)",
        req(ApprovalRequest::AddRule(rule())),
        "55000000011b0501111111111111111111111111111111110301070442617368026c73e80702aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb020102",
    );
    c.check(
        "ClientCtl::Approval(RevokeRule)",
        req(ApprovalRequest::RevokeRule {
            rule_id: RuleId([0x11; 16]),
        }),
        "14000000011b050211111111111111111111111111111111",
    );

    let result = |result| ServerCtl::ApprovalResult { req_id: 5, result };
    c.check(
        "ServerCtl::ApprovalResult(Done)",
        result(Ok(ApprovalResponse::Done)),
        "05000000012c050000",
    );
    for (name, error, golden) in [
        ("NotFound", ApprovalError::NotFound, "05000000012c050100"),
        (
            "Forbidden",
            ApprovalError::Forbidden("x".into()),
            "07000000012c0501010178",
        ),
        (
            "NotEditable",
            ApprovalError::NotEditable,
            "05000000012c050102",
        ),
        (
            "Invalid",
            ApprovalError::Invalid("x".into()),
            "07000000012c0501030178",
        ),
        (
            "AlreadyDecided",
            ApprovalError::AlreadyDecided,
            "05000000012c050104",
        ),
        (
            "Disconnected",
            ApprovalError::Disconnected,
            "05000000012c050105",
        ),
    ] {
        c.check(
            &format!("ServerCtl::ApprovalResult({name})"),
            result(Err(error)),
            golden,
        );
    }

    c.check(
        "ServerCtl::Approval(Request)",
        ServerCtl::Approval(ApprovalPush::Request(ApprovalInfo {
            pane_id: PANE,
            request_id: RequestId(7),
            tool: "Bash".into(),
            input: Some("ls".into()),
            like: Some(RuleMatch {
                tool: "Bash".into(),
                prefix: "ls".into(),
            }),
        })),
        "17000000012d000307044261736801026c73010442617368026c73",
    );
    c.check(
        "ServerCtl::Approval(Rules)",
        ServerCtl::Approval(ApprovalPush::Rules {
            pane_id: PANE,
            rules: vec![ActiveRule {
                rule: rule(),
                turns_used: 1,
                uses: 2,
                granted_by: "Ana".into(),
            }],
        }),
        "5c000000012d010301111111111111111111111111111111110301070442617368026c73e80702aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb020102010203416e61",
    );

    assert!(c.failures.is_empty(), "{}", c.failures.join("\n"));
}
