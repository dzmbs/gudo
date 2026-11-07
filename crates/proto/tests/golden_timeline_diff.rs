use proto::{DaemonFeatures, PaneId, WorkspaceRequest, WorkspaceResponse};

#[test]
fn recorded_tool_diff_requests_append_to_the_workspace_protocol() {
    let request = WorkspaceRequest::TimelineToolDiff {
        pane_id: PaneId(7),
        handle: "x".into(),
    };
    let bytes = [67, 7, 1, 120];
    assert_eq!(postcard::to_allocvec(&request).unwrap(), bytes);
    assert_eq!(
        postcard::from_bytes::<WorkspaceRequest>(&bytes).unwrap(),
        request
    );
}

#[test]
fn recorded_tool_diff_replies_append_to_the_workspace_protocol() {
    let response = WorkspaceResponse::TimelineDiff(Vec::new());
    let bytes = [37, 0];
    assert_eq!(postcard::to_allocvec(&response).unwrap(), bytes);
    assert_eq!(
        postcard::from_bytes::<WorkspaceResponse>(&bytes).unwrap(),
        response
    );
}

#[test]
fn recorded_tool_diff_is_a_separate_daemon_capability() {
    assert_eq!(
        postcard::to_allocvec(&DaemonFeatures::TIMELINE_TOOL_DIFF).unwrap(),
        [128, 128, 128, 128, 1]
    );
}
