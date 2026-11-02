//! Frozen wire bytes for agent accounts: `Caps::ACCOUNTS`, `DaemonFeatures::ACCOUNTS`, the
//! `Account*` workspace requests and answers, `PaneLaunch::AccountAgent` / `AccountSignIn`,
//! `ServerCtl::Accounts` and `ServerCtl::AccountUsage`. Same rule as `golden.rs`: never edit an
//! existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_accounts -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

fn check<T>(failures: &mut Vec<String>, name: &str, msg: T, golden: &str)
where
    T: Serialize + DeserializeOwned + PartialEq + Debug,
{
    let wire = frame::to_vec(&msg).unwrap();
    let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
    if std::env::var_os("PROTO_PRINT_GOLDEN").is_some() {
        println!("GOLDEN {name}: \"{hex}\"");
    }
    if hex != golden {
        failures.push(format!("{name}\n  want {golden}\n  got  {hex}"));
    }
    let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
    decoder.extend(&wire);
    let back: T = decoder.decode().unwrap().unwrap();
    assert_eq!(back, msg, "{name} did not round-trip");
}

fn work() -> AgentAccount {
    AgentAccount {
        id: "a1b2c3d4".into(),
        agent: AgentKind::Claude,
        label: "Work".into(),
        color: 2,
        status: AccountStatus::SignedIn(AccountIdentity {
            email: Some("me@work.example".into()),
            plan: Some("max".into()),
            organization: None,
            method: Some("claude.ai".into()),
        }),
    }
}

#[test]
fn account_messages_match_their_frozen_bytes() {
    let mut failures = vec![];
    check(
        &mut failures,
        "Caps::ACCOUNTS",
        Caps::ACCOUNTS,
        "050000000180808004",
    );
    check(
        &mut failures,
        "DaemonFeatures::ACCOUNTS",
        DaemonFeatures::ACCOUNTS,
        "0400000001808010",
    );
    check(
        &mut failures,
        "WorkspaceRequest::Accounts",
        ClientCtl::Workspace {
            req_id: 7,
            req: WorkspaceRequest::Accounts,
        },
        "0400000001150736",
    );
    check(
        &mut failures,
        "WorkspaceRequest::AccountAdd",
        ClientCtl::Workspace {
            req_id: 7,
            req: WorkspaceRequest::AccountAdd(AccountAdd {
                agent: AgentKind::Codex,
                label: "Work".into(),
                color: 3,
            }),
        },
        "0b000000011507370104576f726b03",
    );
    check(
        &mut failures,
        "WorkspaceRequest::AccountSetDefault",
        ClientCtl::Workspace {
            req_id: 7,
            req: WorkspaceRequest::AccountSetDefault {
                agent: AgentKind::Claude,
                project: Some("app".into()),
                account: Some("a1b2c3d4".into()),
            },
        },
        "140000000115073b00010361707001086131623263336434",
    );
    check(
        &mut failures,
        "WorkspaceRequest::AccountRemove",
        ClientCtl::Workspace {
            req_id: 7,
            req: WorkspaceRequest::AccountRemove {
                agent: AgentKind::Claude,
                account: "a1b2c3d4".into(),
            },
        },
        "0e0000000115073900086131623263336434",
    );
    check(
        &mut failures,
        "WorkspaceResponse::Account",
        ServerCtl::WorkspaceResult {
            req_id: 7,
            result: Ok(WorkspaceResponse::Account(work())),
        },
        "3800000001180700210861316232633364340004576f726b0202010f6d6540776f726b2e6578616d706c6501036d6178000109636c617564652e6169",
    );
    check(
        &mut failures,
        "PaneLaunch::AccountAgent",
        ClientCtl::Op {
            op_id: 9,
            op: LayoutOp::NewTab {
                session_id: SessionId(1),
                name: String::new(),
                launch: PaneLaunch::AccountAgent {
                    agent: AgentKind::Claude,
                    account: Some("a1b2c3d4".into()),
                    resume: None,
                    cwd: Some("~/src".into()),
                },
            },
        },
        "1a000000010f090601000500010861316232633364340001057e2f737263",
    );
    check(
        &mut failures,
        "PaneLaunch::AccountSignIn",
        ClientCtl::Op {
            op_id: 9,
            op: LayoutOp::NewTab {
                session_id: SessionId(1),
                name: String::new(),
                launch: PaneLaunch::AccountSignIn {
                    agent: AgentKind::Codex,
                    account: "a1b2c3d4".into(),
                    device_code: true,
                },
            },
        },
        "12000000010f09060100060108613162326333643401",
    );
    check(
        &mut failures,
        "ServerCtl::Accounts",
        ServerCtl::Accounts(AccountsReport {
            accounts: vec![work()],
            defaults: vec![AccountDefault {
                agent: AgentKind::Claude,
                project: None,
                account: "a1b2c3d4".into(),
            }],
            panes: vec![PaneAccount {
                pane_id: PaneId(3),
                agent: AgentKind::Claude,
                account: "a1b2c3d4".into(),
            }],
        }),
        "4e000000013a010861316232633364340004576f726b0202010f6d6540776f726b2e6578616d706c6501036d6178000109636c617564652e6169010000086131623263336434010300086131623263336434",
    );
    check(
        &mut failures,
        "ServerCtl::AccountUsage",
        ServerCtl::AccountUsage(AccountUsageReport {
            accounts: vec![AccountUsage {
                account: "a1b2c3d4".into(),
                usage: AgentUsage {
                    agent: AgentKind::Claude,
                    plan: Some("max".into()),
                    windows: vec![UsageWindow {
                        name: "5h".into(),
                        minutes: 300,
                        used_permille: 815,
                        resets_at: Some(UnixMillis(1_792_438_800_000)),
                        limited: false,
                    }],
                    source: UsageSource::StatusLine,
                    as_of: Some(UnixMillis(1_792_430_000_000)),
                    note: None,
                },
            }],
        }),
        "2b000000013b010861316232633364340001036d617801023568ac02af0601809db6ad9534000201808f9da9953400",
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
