use proto::{ClientCtl, MoreDaemonFeatures, PaneId, RunAgainOffer, ServerCtl};

#[test]
fn run_again_keeps_its_wire_bytes() {
    assert_eq!(
        postcard::to_allocvec(&MoreDaemonFeatures::RUN_AGAIN).unwrap(),
        vec![4]
    );
    assert_eq!(
        postcard::to_allocvec(&ClientCtl::WatchRunAgain).unwrap(),
        vec![33]
    );
    let offers = ServerCtl::RunAgainOffers(vec![RunAgainOffer {
        pane_id: PaneId(3),
        command: "npm run dev".into(),
    }]);
    assert_eq!(
        postcard::to_allocvec(&offers).unwrap(),
        [&[66, 1, 3, 11][..], b"npm run dev"].concat()
    );
}
