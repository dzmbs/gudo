use proto::{DaemonFeatures, PaneId, TimelineVersion, WorkspaceRequest};

#[test]
fn watch_negotiates_the_highest_mutually_supported_version() {
    assert!(TimelineVersion::negotiate(0).is_err());
    for maximum in [1, 2, u16::MAX] {
        assert_eq!(TimelineVersion::negotiate(maximum), Ok(TimelineVersion::V1));
    }
    assert!(
        TimelineVersion::SUPPORTED
            .windows(2)
            .all(|versions| { versions[0].as_u16() < versions[1].as_u16() })
    );
}

#[test]
fn older_helpers_only_receive_the_frozen_legacy_request() {
    let request = TimelineVersion::CURRENT.watch_request(PaneId(7), DaemonFeatures::AGENT_TIMELINE);
    assert_eq!(
        request,
        WorkspaceRequest::TimelineWatch { pane_id: PaneId(7) }
    );
    assert_eq!(postcard::to_allocvec(&request).unwrap(), [62, 7]);
}

#[test]
fn versioned_watch_has_an_append_only_tag_and_feature_bit() {
    let request = TimelineVersion::CURRENT.watch_request(
        PaneId(7),
        DaemonFeatures::AGENT_TIMELINE | DaemonFeatures::VERSIONED_TIMELINE,
    );
    assert_eq!(
        request,
        WorkspaceRequest::TimelineWatchVersioned {
            pane_id: PaneId(7),
            version: 1
        }
    );
    assert_eq!(postcard::to_allocvec(&request).unwrap(), [66, 7, 1]);
    assert_eq!(
        postcard::to_allocvec(&DaemonFeatures::VERSIONED_TIMELINE).unwrap(),
        [128, 128, 128, 64]
    );
}
