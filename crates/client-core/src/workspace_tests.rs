use super::*;

#[test]
fn expired_disconnected_or_cancelled_requests_are_not_awaited() {
    let state = WsState::default();
    assert!(!state.awaits(1));
    let (sender, receiver) = oneshot::channel();
    lock(&state.pending).insert(1, sender);
    assert!(state.awaits(1));
    drop(receiver);
    assert!(!state.awaits(1));
    let (sender, _receiver) = oneshot::channel();
    lock(&state.pending).insert(1, sender);
    state.fail_pending();
    assert!(!state.awaits(1));
}

#[test]
fn a_request_the_daemon_cannot_read_is_answered_at_once() {
    let state = WsState::default();
    let (sender, mut receiver) = oneshot::channel();
    lock(&state.pending).insert(3, sender);
    state.refuse_unsupported(&proto::ClientCtl::Workspace {
        req_id: 3,
        req: WorkspaceRequest::ResolvePaths(proto::PathQuery {
            pane_id: PaneId(7),
            command_id: None,
            paths: vec!["src/main.rs".into()],
        }),
    });
    assert!(matches!(
        receiver.try_recv(),
        Ok(Err(WsError::Unavailable(_)))
    ));
    assert!(lock(&state.pending).is_empty());
    state.refuse_unsupported(&proto::ClientCtl::Ping { nonce: 1 });
}
