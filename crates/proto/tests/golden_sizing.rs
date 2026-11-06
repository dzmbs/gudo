use proto::{Caps, ClientCtl, DaemonFeatures, PaneActivity, PaneId, SizePolicy};

#[test]
fn sizing_policy_tags_and_activity_are_append_only() {
    assert_eq!(Caps::ACTIVE_SIZING.0, 1 << 28);
    assert_eq!(DaemonFeatures::ACTIVE_SIZING.0, 1 << 26);
    assert_eq!(
        postcard::to_allocvec(&SizePolicy::LastActive.for_client(Caps::default())).unwrap(),
        [1]
    );
    assert_eq!(
        postcard::to_allocvec(&SizePolicy::LastActive.for_client(Caps::ACTIVE_SIZING)).unwrap(),
        [4]
    );
    for (policy, golden) in [
        (SizePolicy::FollowLease, vec![0]),
        (SizePolicy::LastInput, vec![1]),
        (SizePolicy::Fixed { cols: 80, rows: 24 }, vec![2, 80, 24]),
        (SizePolicy::Smallest, vec![3]),
        (SizePolicy::LastActive, vec![4]),
    ] {
        assert_eq!(postcard::to_allocvec(&policy).unwrap(), golden);
        assert_eq!(postcard::from_bytes::<SizePolicy>(&golden).unwrap(), policy);
    }
    let claim = ClientCtl::ClaimSize { pane_id: PaneId(1) };
    assert_eq!(postcard::to_allocvec(&claim).unwrap(), [32, 1]);
    assert_eq!(postcard::from_bytes::<ClientCtl>(&[32, 1]).unwrap(), claim);
    for (activity, golden) in [
        (PaneActivity::Active, [31, 1, 0]),
        (PaneActivity::Inactive, [31, 1, 1]),
    ] {
        let message = ClientCtl::PaneActivity {
            pane_id: PaneId(1),
            activity,
        };
        assert_eq!(postcard::to_allocvec(&message).unwrap(), golden);
        assert_eq!(postcard::from_bytes::<ClientCtl>(&golden).unwrap(), message);
    }
}
