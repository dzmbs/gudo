use proto::{ChatSendStatus, DaemonFeatures, PaneId, WorkspaceRequest, WorkspaceResponse};

#[test]
fn interrupts_append_to_the_existing_workspace_and_receipt_schema() {
    assert_eq!(
        postcard::to_stdvec(&WorkspaceRequest::ChatInterruptPrepare { pane_id: PaneId(7) })
            .unwrap(),
        [70, 7]
    );
    assert_eq!(
        postcard::to_stdvec(&WorkspaceRequest::ChatInterrupt {
            pane_id: PaneId(7),
            ticket: 1,
            confirmed_revision: Some(2),
        })
        .unwrap(),
        [71, 7, 1, 1, 2]
    );
    assert_eq!(
        postcard::to_stdvec(&WorkspaceResponse::ChatSend(
            ChatSendStatus::InterruptRequested
        ))
        .unwrap(),
        [38, 5]
    );
    assert_eq!(
        postcard::to_stdvec(&DaemonFeatures::CHAT_INTERRUPT).unwrap(),
        [128, 128, 128, 128, 4]
    );
    assert_eq!(
        serde_json::to_string(&ChatSendStatus::InterruptRequested).unwrap(),
        r#""InterruptRequested""#
    );
}
