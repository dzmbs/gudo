use proto::{MoreDaemonFeatures, PaneId, PngSource, WorkspaceRequest};

#[test]
fn chat_images_are_appended_after_repo_root() {
    assert_eq!(
        postcard::to_stdvec(&WorkspaceRequest::ChatSendImages {
            pane_id: PaneId(7),
            ticket: 1,
            text: "x".into(),
            confirmed_revision: Some(2),
            images: vec![PngSource::Inline(vec![9])],
        })
        .unwrap(),
        [75, 7, 1, 1, 120, 1, 2, 1, 0, 1, 9]
    );
    assert_eq!(
        postcard::to_stdvec(&MoreDaemonFeatures::CHAT_IMAGES).unwrap(),
        [32]
    );
}
