//! Frozen wire bytes for projects: `Caps::PROJECTS`, `DaemonFeatures::PROJECTS`,
//! `LayoutOp::SetTabProject` / `PutProject` / `RemoveProject` (appended after `MergeTab`) and
//! `ServerCtl::Projects`. Same rule as `golden.rs`: never edit an existing hex string; add a case
//! instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_projects -- --nocapture`.

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

fn project() -> Project {
    Project {
        id: "p1".into(),
        name: "Web".into(),
        color: 3,
        order: -1,
        updated: UnixMillis(1000),
    }
}

#[test]
fn project_messages_match_their_frozen_bytes() {
    let mut failures = vec![];
    check(
        &mut failures,
        "Caps::PROJECTS",
        Caps::PROJECTS,
        "0400000001808010",
    );
    check(
        &mut failures,
        "DaemonFeatures::PROJECTS",
        DaemonFeatures::PROJECTS,
        "03000000018040",
    );
    let ops = [
        (
            "LayoutOp::SetTabProject",
            LayoutOp::SetTabProject {
                tab_id: TabId(2),
                project: Some("p1".into()),
                rank: 5,
            },
            "0a000000010f4d1102010270310a",
        ),
        (
            "LayoutOp::SetTabProject (leave)",
            LayoutOp::SetTabProject {
                tab_id: TabId(2),
                project: None,
                rank: 0,
            },
            "07000000010f4d11020000",
        ),
        (
            "LayoutOp::PutProject",
            LayoutOp::PutProject {
                session_id: SessionId(1),
                project: project(),
            },
            "10000000010f4d1201027031035765620301e807",
        ),
        (
            "LayoutOp::RemoveProject",
            LayoutOp::RemoveProject {
                session_id: SessionId(1),
                project: "p1".into(),
            },
            "08000000010f4d1301027031",
        ),
    ];
    for (name, op, golden) in ops {
        check(&mut failures, name, ClientCtl::Op { op_id: 77, op }, golden);
    }
    check(
        &mut failures,
        "ServerCtl::Projects",
        ServerCtl::Projects(SessionProjects {
            session_id: SessionId(1),
            revision: 9,
            projects: vec![project()],
            tabs: vec![TabProject {
                tab_id: TabId(2),
                project: "p1".into(),
                rank: 5,
            }],
        }),
        "160000000138010901027031035765620301e80701020270310a",
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
