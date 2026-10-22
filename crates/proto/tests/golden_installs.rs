//! Frozen wire bytes for agent install checks: `DaemonFeatures::AGENT_INSTALLS`,
//! `WorkspaceRequest::AgentInstalls` and its answer. Same rule as `golden.rs`: never edit an
//! existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_installs -- --nocapture`.

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
    let hex: String = wire.iter().map(|b| format!("{b:02x}")).collect();
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

#[test]
fn install_messages_match_their_frozen_bytes() {
    let mut failures = vec![];
    check(
        &mut failures,
        "DaemonFeatures::AGENT_INSTALLS",
        DaemonFeatures::AGENT_INSTALLS,
        "020000000140",
    );
    check(
        &mut failures,
        "WorkspaceRequest::AgentInstalls",
        ClientCtl::Workspace {
            req_id: 5,
            req: WorkspaceRequest::AgentInstalls,
        },
        "0400000001150532",
    );
    check(
        &mut failures,
        "WorkspaceResponse::AgentInstalls",
        ServerCtl::WorkspaceResult {
            req_id: 5,
            result: Ok(WorkspaceResponse::AgentInstalls(vec![
                AgentInstall {
                    agent: AgentKind::Claude,
                    program: "claude".into(),
                    state: InstallState::Installed {
                        path: "/b/claude".into(),
                    },
                },
                AgentInstall {
                    agent: AgentKind::Codex,
                    program: "codex".into(),
                    state: InstallState::NotOnPath {
                        path: "/h/codex".into(),
                    },
                },
                AgentInstall {
                    agent: AgentKind::Codex,
                    program: "codex".into(),
                    state: InstallState::Missing,
                },
            ])),
        },
        "32000000011805001d030006636c6175646500092f622f636c617564650105636f64657801082f682f636f6465780105636f64657802",
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
