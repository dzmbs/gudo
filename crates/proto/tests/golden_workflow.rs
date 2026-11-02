//! Frozen wire bytes for workflows (`proto::workflow`): the list and save requests, their
//! answers and the `WorkflowsChanged` push. Kept apart from `golden.rs` so parallel additions
//! do not collide. Same rule: never edit an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_workflow -- --nocapture`.

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

fn argument() -> WorkflowArgument {
    WorkflowArgument {
        name: "b".into(),
        description: Some("d".into()),
        default_value: Some("m".into()),
        raw: true,
    }
}

fn workflow() -> Workflow {
    Workflow {
        id: "/r/f.yaml".into(),
        name: "N".into(),
        command: "git co {{b}}".into(),
        description: Some("D".into()),
        tags: vec!["git".into()],
        arguments: vec![argument()],
        shells: vec!["zsh".into()],
        author: None,
        source_url: Some("u".into()),
        scope: WorkflowScope::Repo,
        path: "/r/f.yaml".into(),
    }
}

#[test]
fn workflow_messages_match_their_frozen_bytes() {
    let mut checker = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };
    checker.check("Caps::WORKFLOWS", Caps::WORKFLOWS, "03000000018020");
    checker.check(
        "ServerCtl::WorkflowsChanged",
        ServerCtl::WorkflowsChanged { rev: 9 },
        "03000000013209",
    );
    checker.check(
        "WorkflowScope::Global",
        WorkflowScope::Global,
        "020000000100",
    );
    let req = |req| ClientCtl::Workspace { req_id: 5, req };
    for (name, r, golden) in [
        (
            "WorkflowList",
            WorkspaceRequest::WorkflowList {
                pane_id: Some(PaneId(3)),
            },
            "06000000011505300103",
        ),
        (
            "WorkflowList (global)",
            WorkspaceRequest::WorkflowList { pane_id: None },
            "050000000115053000",
        ),
        (
            "WorkflowSave",
            WorkspaceRequest::WorkflowSave(WorkflowSave {
                scope: WorkflowScope::Repo,
                pane_id: Some(PaneId(3)),
                workflow: WorkflowDraft {
                    name: "N".into(),
                    command: "c {{b}}".into(),
                    description: None,
                    tags: vec![],
                    arguments: vec![argument()],
                    shells: vec![],
                },
            }),
            "1e00000001150531010103014e0763207b7b627d7d000001016201016401016d0100",
        ),
    ] {
        checker.check(name, req(r), golden);
    }
    let answer = |result| ServerCtl::WorkspaceResult { req_id: 5, result };
    for (name, r, golden) in [
        (
            "WorkspaceResponse::Workflows",
            Ok(WorkspaceResponse::Workflows(WorkflowList {
                rev: 4,
                repo: Some("/r".into()),
                repo_name: Some("r".into()),
                workflows: vec![workflow()],
                problems: vec![WorkflowProblem {
                    path: "/r/x.yaml".into(),
                    message: "bad".into(),
                }],
            })),
            "5c000000011805001b0401022f7201017201092f722f662e79616d6c014e0c67697420636f207b7b627d7d010144010367697401016201016401016d0101037a73680001017501092f722f662e79616d6c01092f722f782e79616d6c03626164",
        ),
        (
            "WorkspaceResponse::WorkflowSaved",
            Ok(WorkspaceResponse::WorkflowSaved(workflow())),
            "44000000011805001c092f722f662e79616d6c014e0c67697420636f207b7b627d7d010144010367697401016201016401016d0101037a73680001017501092f722f662e79616d6c",
        ),
    ] {
        checker.check(name, answer(r), golden);
    }
    assert!(
        checker.failures.is_empty(),
        "{}",
        checker.failures.join("\n")
    );
}
