//! Frozen wire bytes for setting a divider: `MoreDaemonFeatures::SPLIT_RATIOS` and
//! `LayoutOp::SetRatio` (appended after `MovePaneToEdge`). Same rule as `golden.rs`: never edit
//! an existing hex string; add a case instead.

use proto::frame::{self, FrameDecoder};
use proto::{Axis, ClientCtl, LayoutOp, MAX_FRAME_LEN, MoreDaemonFeatures, PaneId};

#[test]
fn split_ratios_keep_their_bit() {
    assert_eq!(
        postcard::to_allocvec(&MoreDaemonFeatures::SPLIT_RATIOS).unwrap(),
        vec![8]
    );
}

#[test]
fn set_ratio_keeps_its_wire_bytes() {
    let message = ClientCtl::Op {
        op_id: 77,
        op: LayoutOp::SetRatio {
            pane_id: PaneId(3),
            axis: Axis::Horizontal,
            ratio: 0.25,
        },
    };
    let wire = frame::to_vec(&message).unwrap();
    let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
    assert_eq!(hex, "0a000000010f4d1903000000803e");
    let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
    decoder.extend(&wire);
    let decoded: ClientCtl = decoder.decode().unwrap().unwrap();
    assert_eq!(decoded, message);
}
