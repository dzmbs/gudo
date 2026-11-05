use proto::{DaemonFeatures, PowerPolicy, PowerStatus, WorkspaceRequest, WorkspaceResponse};

#[test]
fn power_messages_keep_their_wire_bytes() {
    assert_eq!(
        postcard::to_allocvec(&DaemonFeatures::POWER_SETTINGS).unwrap(),
        vec![128, 128, 128, 4]
    );
    assert_eq!(
        postcard::to_allocvec(&WorkspaceRequest::PowerSettings(Some(PowerPolicy::Always))).unwrap(),
        vec![61, 1, 0]
    );
    assert_eq!(
        postcard::to_allocvec(&WorkspaceResponse::PowerStatus(PowerStatus {
            policy: PowerPolicy::WhenPluggedIn,
            keeping_awake: true
        }))
        .unwrap(),
        vec![34, 1, 1]
    );
}
