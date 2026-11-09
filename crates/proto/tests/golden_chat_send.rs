use proto::{ChatSendStatus, DaemonFeatures, PaneId, WorkspaceRequest, WorkspaceResponse};

#[test]
fn chat_send_variants_are_appended_without_changing_old_indices() {
    assert_eq!(
        postcard::to_stdvec(&WorkspaceRequest::ChatPrepare { pane_id: PaneId(7) }).unwrap(),
        [68, 7]
    );
    assert_eq!(
        postcard::to_stdvec(&WorkspaceRequest::ChatSend {
            pane_id: PaneId(7),
            ticket: 1,
            text: "x".into(),
            confirmed_revision: Some(2),
        })
        .unwrap(),
        [69, 7, 1, 1, 120, 1, 2]
    );
    assert_eq!(
        postcard::to_stdvec(&WorkspaceResponse::ChatSend(ChatSendStatus::Confirmed)).unwrap(),
        [38, 2]
    );
    assert_eq!(
        postcard::to_stdvec(&DaemonFeatures::CHAT_SEND).unwrap(),
        [128, 128, 128, 128, 2]
    );
    assert_eq!(
        serde_json::to_string(&ChatSendStatus::Prepared {
            ticket: 7,
            revision: 3,
            needs_confirmation: true,
        })
        .unwrap(),
        r#"{"Prepared":{"ticket":7,"revision":3,"needs_confirmation":true}}"#
    );
}

#[test]
fn chat_send_statuses_keep_their_wire_indices() {
    assert_eq!(
        postcard::to_stdvec(&ChatSendStatus::Prepared {
            ticket: 7,
            revision: 3,
            needs_confirmation: true,
        })
        .unwrap(),
        [0, 7, 3, 1]
    );
    assert_eq!(
        postcard::to_stdvec(&ChatSendStatus::ConfirmationRequired { revision: 3 }).unwrap(),
        [1, 3]
    );
    assert_eq!(
        postcard::to_stdvec(&ChatSendStatus::Confirmed).unwrap(),
        [2]
    );
    assert_eq!(
        postcard::to_stdvec(&ChatSendStatus::NotConfirmed).unwrap(),
        [3]
    );
    assert_eq!(
        postcard::to_stdvec(&ChatSendStatus::SentNotConfirmed).unwrap(),
        [4]
    );
}
