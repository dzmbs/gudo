use proto::{
    AgentKind, BlobHash, MoreDaemonFeatures, PaneId, PastedImage, PngSource, WorkspaceRequest,
    WorkspaceResponse,
};

#[test]
fn paste_image_is_appended_after_chat_file_search() {
    assert_eq!(
        postcard::to_stdvec(&WorkspaceRequest::PasteImage {
            pane_id: PaneId(7),
            image: PngSource::Inline(vec![9]),
        })
        .unwrap(),
        [80, 7, 0, 1, 9]
    );
    assert_eq!(
        postcard::to_stdvec(&WorkspaceRequest::PasteImage {
            pane_id: PaneId(7),
            image: PngSource::Blob(BlobHash([1; 32])),
        })
        .unwrap()[..3],
        [80, 7, 1]
    );
}

#[test]
fn image_pasted_is_appended_after_chat_files() {
    assert_eq!(
        postcard::to_stdvec(&WorkspaceResponse::ImagePasted(PastedImage {
            path: "/p".into(),
            agent: AgentKind::Pi,
        }))
        .unwrap(),
        [44, 2, 47, 112, 2]
    );
}

#[test]
fn pane_images_keeps_its_bit() {
    assert_eq!(
        postcard::to_stdvec(&MoreDaemonFeatures::PANE_IMAGES).unwrap(),
        [128, 2]
    );
}
