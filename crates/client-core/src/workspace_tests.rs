use super::*;

#[test]
fn expired_disconnected_or_cancelled_chat_controls_never_leave_the_queue() {
    for req in [
        WorkspaceRequest::ChatPrepare { pane_id: PaneId(7) },
        WorkspaceRequest::ChatSend {
            pane_id: PaneId(7),
            ticket: 1,
            text: "hello".into(),
            confirmed_revision: None,
        },
        WorkspaceRequest::ChatInterruptPrepare { pane_id: PaneId(7) },
        WorkspaceRequest::ChatInterrupt {
            pane_id: PaneId(7),
            ticket: 1,
            confirmed_revision: None,
        },
    ] {
        let state = WsState::default();
        let control = proto::ClientCtl::Workspace { req_id: 1, req };
        assert!(!state.control_is_live(&control));
        let (sender, receiver) = oneshot::channel();
        lock(&state.pending).insert(1, sender);
        assert!(state.control_is_live(&control));
        drop(receiver);
        assert!(!state.control_is_live(&control));
        let (sender, _receiver) = oneshot::channel();
        lock(&state.pending).insert(1, sender);
        state.fail_pending();
        assert!(!state.control_is_live(&control));
    }
    assert!(WsState::default().control_is_live(&proto::ClientCtl::Ping { nonce: 1 }));
}
