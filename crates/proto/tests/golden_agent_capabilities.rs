use proto::{
    AgentCapabilities, AgentKind, AgentTimelineSnapshot, DaemonFeatures, PaneId, TimelineCursor,
    TimelineSession, TimelineSnapshot, WorkspaceRequest, WorkspaceResponse,
};

#[test]
fn capability_watch_appends_without_changing_legacy_snapshots() {
    let request = WorkspaceRequest::TimelineWatchCapabilities {
        pane_id: PaneId(7),
        version: 1,
    };
    assert_eq!(postcard::to_stdvec(&request).unwrap(), [72, 7, 1]);
    assert_eq!(
        postcard::from_bytes::<WorkspaceRequest>(&[72, 7, 1]).unwrap(),
        request
    );
    let snapshot = TimelineSnapshot {
        cursor: TimelineCursor {
            epoch: 1,
            sequence: 2,
        },
        session: TimelineSession {
            agent: AgentKind::Claude,
            native_session: "n".into(),
            title: None,
            model: None,
            permission_mode: None,
            commands: vec![],
        },
        items: vec![],
        before: None,
    };
    let response = WorkspaceResponse::AgentTimeline(AgentTimelineSnapshot {
        snapshot: snapshot.clone(),
        capabilities: AgentCapabilities::READ | AgentCapabilities::STOP,
    });
    let bytes = [39, 1, 2, 0, 1, 110, 0, 0, 0, 0, 0, 0, 9];
    assert_eq!(postcard::to_stdvec(&response).unwrap(), bytes);
    assert_eq!(
        postcard::from_bytes::<WorkspaceResponse>(&bytes).unwrap(),
        response
    );
    assert_eq!(
        postcard::to_stdvec(&WorkspaceResponse::Timeline(snapshot)).unwrap(),
        [35, 1, 2, 0, 1, 110, 0, 0, 0, 0, 0, 0]
    );
    assert_eq!(
        postcard::to_stdvec(&DaemonFeatures::AGENT_CAPABILITIES).unwrap(),
        [128, 128, 128, 128, 8]
    );
}

#[test]
fn unknown_agent_capability_bits_are_preserved_not_authority() {
    let capabilities = AgentCapabilities(0x8001);
    assert_eq!(serde_json::to_string(&capabilities).unwrap(), "32769");
    let restored: AgentCapabilities =
        postcard::from_bytes(&postcard::to_stdvec(&capabilities).unwrap()).unwrap();
    assert_eq!(restored, capabilities);
    assert!(restored.contains(AgentCapabilities::READ));
    assert!(!restored.contains(AgentCapabilities::SEND));
}
