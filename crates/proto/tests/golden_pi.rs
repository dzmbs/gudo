//! Frozen wire bytes for pi as an agent: `AgentKind::Pi` (appended after `Codex`),
//! `MoreDaemonFeatures::PI_AGENT` and timeline schema 3, the first that may name pi. Same rule as
//! `golden.rs`: never edit an existing hex string; add a case instead.

use proto::{
    AgentKind, DaemonFeatures, LayoutOp, MoreDaemonFeatures, PaneId, PaneLaunch,
    TimelineCursor, TimelineOp, TimelineSession, TimelineSnapshot, TimelineVersion,
    WorkspaceRequest,
};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[test]
fn pi_is_appended_after_the_agents_before_it() {
    assert_eq!(postcard::to_allocvec(&AgentKind::Claude).unwrap(), [0]);
    assert_eq!(postcard::to_allocvec(&AgentKind::Codex).unwrap(), [1]);
    assert_eq!(postcard::to_allocvec(&AgentKind::Pi).unwrap(), [2]);
}

#[test]
fn pi_agent_keeps_its_bit() {
    assert_eq!(
        postcard::to_allocvec(&MoreDaemonFeatures::PI_AGENT).unwrap(),
        [16]
    );
}

#[test]
fn launching_pi_keeps_its_wire_bytes() {
    let op = LayoutOp::Split {
        pane_id: PaneId(4),
        axis: proto::Axis::Horizontal,
        launch: PaneLaunch::Agent {
            agent: AgentKind::Pi,
            resume: None,
            cwd: Some("/w".into()),
        },
    };
    let encoded = postcard::to_allocvec(&op).unwrap();
    assert_eq!(hex(&encoded), "00040002020001022f77");
    assert_eq!(postcard::from_bytes::<LayoutOp>(&encoded).unwrap(), op);
    assert_eq!(
        op.launch().and_then(PaneLaunch::agent),
        Some(AgentKind::Pi)
    );
}

#[test]
fn schema_three_is_the_first_that_names_pi() {
    assert_eq!(TimelineVersion::negotiate(3), Ok(TimelineVersion::V3));
    assert_eq!(TimelineVersion::negotiate(2), Ok(TimelineVersion::V2));
    let request = TimelineVersion::V3.watch_request(
        PaneId(7),
        DaemonFeatures::AGENT_TIMELINE | DaemonFeatures::VERSIONED_TIMELINE,
    );
    assert_eq!(
        request,
        WorkspaceRequest::TimelineWatchVersioned {
            pane_id: PaneId(7),
            version: 3
        }
    );
    assert_eq!(postcard::to_allocvec(&request).unwrap(), [66, 7, 3]);
}

fn pi_snapshot() -> TimelineSnapshot {
    TimelineSnapshot {
        cursor: TimelineCursor {
            epoch: 1,
            sequence: 2,
        },
        session: TimelineSession {
            agent: AgentKind::Pi,
            native_session: "s".into(),
            title: None,
            model: None,
            permission_mode: None,
            commands: Vec::new(),
        },
        items: Vec::new(),
        before: None,
    }
}

#[test]
fn older_schemas_never_carry_pi() {
    for version in [TimelineVersion::V1, TimelineVersion::V2] {
        assert!(!version.names(AgentKind::Pi));
        assert!(version.names(AgentKind::Codex));
        let operations = version.operations(vec![
            TimelineOp::Snapshot(pi_snapshot()),
            TimelineOp::Session {
                cursor: TimelineCursor::default(),
                session: pi_snapshot().session,
            },
        ]);
        assert!(
            operations
                .iter()
                .all(|operation| matches!(operation, TimelineOp::Unavailable { .. })),
            "{operations:?}"
        );
    }
    assert!(TimelineVersion::V3.names(AgentKind::Pi));
    let operations = TimelineVersion::V3.operations(vec![TimelineOp::Snapshot(pi_snapshot())]);
    assert_eq!(operations, [TimelineOp::Snapshot(pi_snapshot())]);
}
