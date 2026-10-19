//! Frozen wire bytes for the git-native workspace (`proto::repo`): the `Repos` push, its
//! requests and answers. Kept apart from `golden.rs` so parallel additions do not collide.
//! Same rule: never edit an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_repo -- --nocapture`.

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
        let hex: String = wire.iter().map(|b| format!("{b:02x}")).collect();
        if self.print {
            println!("GOLDEN {name}: \"{hex}\"");
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

fn pr() -> PullRequest {
    PullRequest {
        number: 42,
        title: "Fix".into(),
        state: PrState::Open,
        draft: false,
        url: "u".into(),
        head_ref: "b".into(),
        additions: 10,
        deletions: 2,
        merge_state: MergeState::Unstable,
        checks: vec![
            PrCheck {
                name: "ci".into(),
                status: CheckStatus::Failure,
                url: Some("c".into()),
                workflow: Some("w".into()),
            },
            PrCheck {
                name: "lint".into(),
                status: CheckStatus::Pending,
                url: None,
                workflow: None,
            },
        ],
        fetched_at: UnixMillis(5),
    }
}

fn worktree() -> WorktreeState {
    WorktreeState {
        path: "/r/w".into(),
        repo: "/r".into(),
        repo_name: "r".into(),
        name: "w".into(),
        main: false,
        branch: Some("b".into()),
        head: Some("h".into()),
        upstream: Some("origin/b".into()),
        ahead: 1,
        behind: 2,
        added: 3,
        removed: 4,
        changed_files: 5,
        dirty: true,
        pr: Some(pr()),
        scripts: vec![RepoScript {
            name: "Dev".into(),
            command: "npm run dev".into(),
            icon: Some("play".into()),
            tint: Some("green".into()),
            default: true,
        }],
        hooks: RepoHooks {
            setup: Some("npm i".into()),
            teardown: None,
        },
        managed: true,
        merged_at: None,
        updated_at: UnixMillis(9),
    }
}

fn snapshot() -> RepoSnapshot {
    RepoSnapshot {
        rev: 7,
        panes: vec![PaneRepo {
            pane_id: PaneId(3),
            worktree: "/r/w".into(),
        }],
        worktrees: vec![worktree()],
        gh: GhStatus::Ready {
            account: Some("me".into()),
        },
    }
}

#[test]
fn repo_messages_match_their_frozen_bytes() {
    let mut c = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };
    c.check("Caps::REPO_STATUS", Caps::REPO_STATUS, "03000000018002");
    c.check("ServerCtl::Repos", ServerCtl::Repos(snapshot()), "80000000012a070103042f722f7701042f722f77022f72017201770001016201016801086f726967696e2f62010203040501012a034669780000017501620a02010202636902010163010177046c696e740000000501034465760b6e706d2072756e206465760104706c61790105677265656e0101056e706d2069000100090101026d65");
    for (name, gh, golden) in [
        ("GhStatus::Unknown", GhStatus::Unknown, "020000000100"),
        ("GhStatus::Missing", GhStatus::Missing, "020000000102"),
        (
            "GhStatus::NotAuthenticated",
            GhStatus::NotAuthenticated {
                message: "x".into(),
            },
            "0400000001030178",
        ),
    ] {
        c.check(name, gh, golden);
    }
    for (name, s, golden) in [
        ("MergeState::Clean", MergeState::Clean, "020000000100"),
        ("MergeState::Unknown", MergeState::Unknown, "020000000107"),
    ] {
        c.check(name, s, golden);
    }
    for (name, s, golden) in [
        ("CheckStatus::Success", CheckStatus::Success, "020000000101"),
        (
            "CheckStatus::Cancelled",
            CheckStatus::Cancelled,
            "020000000105",
        ),
    ] {
        c.check(name, s, golden);
    }
    c.check("PrState::Merged", PrState::Merged, "020000000102");
    let req = |req| ClientCtl::Workspace { req_id: 5, req };
    for (name, r, golden) in [
        (
            "RepoRefresh",
            WorkspaceRequest::RepoRefresh {
                path: Some("/r/w".into()),
            },
            "0a0000000115052201042f722f77",
        ),
        (
            "PrMerge",
            WorkspaceRequest::PrMerge(PrMerge {
                path: "/r/w".into(),
                number: 42,
                strategy: MergeStrategy::Squash,
            }),
            "0b00000001150523042f722f772a01",
        ),
        (
            "PrRerunFailed",
            WorkspaceRequest::PrRerunFailed {
                path: "/r/w".into(),
            },
            "0900000001150524042f722f77",
        ),
        (
            "PrCreate",
            WorkspaceRequest::PrCreate(PrCreate {
                path: "/r/w".into(),
                draft: true,
                base: None,
            }),
            "0b00000001150525042f722f770100",
        ),
        (
            "PrCheckout",
            WorkspaceRequest::PrCheckout(PrCheckout {
                repo: "/r".into(),
                number: 42,
            }),
            "0800000001150526022f722a",
        ),
        (
            "WorktreeArchive",
            WorkspaceRequest::WorktreeArchive {
                path: "/r/w".into(),
                force: false,
            },
            "0a00000001150527042f722f7700",
        ),
        (
            "WorktreeArchived",
            WorkspaceRequest::WorktreeArchived { repo: None },
            "050000000115052800",
        ),
        (
            "WorktreeRestore",
            WorkspaceRequest::WorktreeRestore { id: 3 },
            "050000000115052903",
        ),
        (
            "WorktreeSettings",
            WorkspaceRequest::WorktreeSettings(Some(WorktreeSettings {
                auto_delete_merged_days: 7,
            })),
            "060000000115052a0107",
        ),
        (
            "TaskCreate",
            WorkspaceRequest::TaskCreate(TaskCreate {
                repo: "/r".into(),
                session_id: SessionId(1),
                name: "quiet-otter".into(),
                branch: None,
                base: None,
                agent: Some(AgentKind::Claude),
            }),
            "180000000115052b022f72010b71756965742d6f7474657200000100",
        ),
        (
            "ScriptRun",
            WorkspaceRequest::ScriptRun(ScriptRun {
                cwd: "/r/w".into(),
                session_id: SessionId(1),
                name: "Dev".into(),
                command: "npm run dev".into(),
            }),
            "1a0000000115052c042f722f7701034465760b6e706d2072756e20646576",
        ),
    ] {
        c.check(name, req(r), golden);
    }
    let answer = |result| ServerCtl::WorkspaceResult { req_id: 5, result };
    let wt = WorktreeInfo {
        path: "/r/w".into(),
        branch: Some("b".into()),
        head: None,
        main: false,
        locked: false,
        prunable: false,
        port: Some(4100),
    };
    for (name, r, golden) in [
        (
            "WorkspaceResponse::Repos",
            Ok(WorkspaceResponse::Repos(RepoSnapshot {
                rev: 1,
                panes: vec![],
                worktrees: vec![],
                gh: GhStatus::Missing,
            })),
            "09000000011805001501000002",
        ),
        (
            "WorkspaceResponse::Pr",
            Ok(WorkspaceResponse::Pr(Some(pr()))),
            "280000000118050016012a034669780000017501620a02010202636902010163010177046c696e7400000005",
        ),
        (
            "WorkspaceResponse::Pr(None)",
            Ok(WorkspaceResponse::Pr(None)),
            "06000000011805001600",
        ),
        (
            "WorkspaceResponse::Archived",
            Ok(WorkspaceResponse::Archived(vec![ArchivedWorktree {
                id: 3,
                repo: "/r".into(),
                repo_name: "r".into(),
                path: "/r/w".into(),
                branch: Some("b".into()),
                head: Some("h".into()),
                saved_changes: true,
                archived_at: UnixMillis(8),
            }])),
            "1900000001180500170103022f720172042f722f770101620101680108",
        ),
        (
            "WorkspaceResponse::WorktreeSettings",
            Ok(WorkspaceResponse::WorktreeSettings(WorktreeSettings {
                auto_delete_merged_days: 0,
            })),
            "06000000011805001800",
        ),
        (
            "WorkspaceResponse::TaskCreated",
            Ok(WorkspaceResponse::TaskCreated(TaskCreated {
                worktree: wt,
                tab_id: TabId(2),
                pane_id: PaneId(3),
                setup: Some("npm i".into()),
            })),
            "1d0000000118050019042f722f7701016200000000018420020301056e706d2069",
        ),
    ] {
        c.check(name, answer(r), golden);
    }
    assert!(c.failures.is_empty(), "{}", c.failures.join("\n"));
}
