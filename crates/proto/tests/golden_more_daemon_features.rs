use proto::{Caps, MoreDaemonFeatures, ServerCtl};

#[test]
fn more_daemon_features_keep_their_wire_bytes() {
    assert_eq!(
        postcard::to_allocvec(&Caps::MORE_DAEMON_FEATURES).unwrap(),
        vec![128, 128, 128, 128, 4]
    );
    assert_eq!(
        postcard::to_allocvec(&ServerCtl::MoreDaemonFeatures(MoreDaemonFeatures::EMPTY)).unwrap(),
        vec![65, 0]
    );
}

#[test]
fn repo_root_keeps_its_bit() {
    assert_eq!(
        postcard::to_allocvec(&MoreDaemonFeatures::REPO_ROOT).unwrap(),
        vec![1]
    );
}
