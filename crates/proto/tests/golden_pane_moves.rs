//! Frozen wire bytes for moving panes between tabs: `DaemonFeatures::PANE_MOVES` and
//! `LayoutOp::BreakPane` / `MovePane` / `MergeTab` (appended after `CloseSession`). Same rule
//! as `golden.rs`: never edit an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_pane_moves -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

fn check<T>(failures: &mut Vec<String>, name: &str, msg: T, golden: &str)
where
    T: Serialize + DeserializeOwned + PartialEq + Debug,
{
    let wire = frame::to_vec(&msg).unwrap();
    let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
    if std::env::var_os("PROTO_PRINT_GOLDEN").is_some() {
        println!("GOLDEN {name}: \"{hex}\"");
    }
    if hex != golden {
        failures.push(format!("{name}\n  want {golden}\n  got  {hex}"));
    }
    let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
    decoder.extend(&wire);
    let back: T = decoder.decode().unwrap().unwrap();
    assert_eq!(back, msg, "{name} did not round-trip");
}

#[test]
fn pane_move_messages_match_their_frozen_bytes() {
    let mut failures = vec![];
    check(
        &mut failures,
        "DaemonFeatures::PANE_MOVES",
        DaemonFeatures::PANE_MOVES,
        "03000000018001",
    );
    let ops = [
        (
            "LayoutOp::BreakPane",
            LayoutOp::BreakPane { pane_id: PaneId(3) },
            "05000000010f4d0e03",
        ),
        (
            "LayoutOp::MovePane",
            LayoutOp::MovePane {
                pane_id: PaneId(3),
                target: PaneId(4),
                side: Direction::Left,
            },
            "07000000010f4d0f030400",
        ),
        (
            "LayoutOp::MergeTab",
            LayoutOp::MergeTab {
                tab_id: TabId(2),
                target: PaneId(4),
                side: Direction::Down,
            },
            "07000000010f4d10020403",
        ),
    ];
    for (name, op, golden) in ops {
        check(&mut failures, name, ClientCtl::Op { op_id: 77, op }, golden);
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
