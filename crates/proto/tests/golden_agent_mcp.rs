//! Frozen wire bytes for agent MCP registration: `DaemonFeatures::AGENT_MCP`,
//! `WorkspaceRequest::AgentMcpCommands` and its answer. Same rule as `golden.rs`: never edit an
//! existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_agent_mcp -- --nocapture`.

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
fn agent_mcp_messages_match_their_frozen_bytes() {
    let mut failures = vec![];
    check(
        &mut failures,
        "DaemonFeatures::AGENT_MCP",
        DaemonFeatures::AGENT_MCP,
        "03000000018004",
    );
    check(
        &mut failures,
        "WorkspaceRequest::AgentMcpCommands",
        ClientCtl::Workspace {
            req_id: 5,
            req: WorkspaceRequest::AgentMcpCommands { register: true },
        },
        "050000000115053301",
    );
    check(
        &mut failures,
        "WorkspaceResponse::AgentMcpCommands",
        ServerCtl::WorkspaceResult {
            req_id: 5,
            result: Ok(WorkspaceResponse::AgentMcpCommands(vec![AgentMcpCommand {
                agent: AgentKind::Codex,
                argv: vec!["codex".into(), "mcp".into()],
            }])),
        },
        "12000000011805001e01010205636f646578036d6370",
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
