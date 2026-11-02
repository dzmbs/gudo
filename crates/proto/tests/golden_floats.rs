//! Frozen wire bytes for floating panes: `Caps::FLOATS`, `DaemonFeatures::FLOATS`,
//! `LayoutOp::NewFloat` / `FloatPane` / `SetFloat` / `DockPane` / `MovePaneToEdge` (appended
//! after `RemoveProject`) and `ServerCtl::Floats` (after `AccountUsage`). Same rule as `golden.rs`: never
//! edit an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_floats -- --nocapture`.

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

const FRAME: FloatFrame = FloatFrame {
    x: 0.5,
    y: 0.25,
    w: 0.5,
    h: 0.5,
};

#[test]
fn float_messages_match_their_frozen_bytes() {
    let mut failures = vec![];
    check(
        &mut failures,
        "Caps::FLOATS",
        Caps::FLOATS,
        "050000000180808001",
    );
    check(
        &mut failures,
        "DaemonFeatures::FLOATS",
        DaemonFeatures::FLOATS,
        "0400000001808004",
    );
    let ops = [
        (
            "LayoutOp::NewFloat",
            LayoutOp::NewFloat {
                pane_id: PaneId(3),
                launch: PaneLaunch::Shell { cwd: None },
                frame: Some(FRAME),
                focus: false,
                close: CloseWhen::Done,
            },
            "1a000000010f4d14030000010000003f0000803e0000003f0000003f0001",
        ),
        (
            "LayoutOp::FloatPane",
            LayoutOp::FloatPane {
                pane_id: PaneId(3),
                frame: None,
            },
            "06000000010f4d150300",
        ),
        (
            "LayoutOp::SetFloat",
            LayoutOp::SetFloat {
                pane_id: PaneId(3),
                frame: Some(FRAME),
                minimized: Some(true),
                pinned: None,
            },
            "19000000010f4d1603010000003f0000803e0000003f0000003f010100",
        ),
        (
            "LayoutOp::DockPane",
            LayoutOp::DockPane {
                pane_id: PaneId(3),
                beside: Some(DockTarget {
                    pane_id: PaneId(1),
                    side: Direction::Down,
                }),
            },
            "08000000010f4d1703010103",
        ),
        (
            "LayoutOp::MovePaneToEdge",
            LayoutOp::MovePaneToEdge {
                pane_id: PaneId(3),
                tab_id: TabId(2),
                side: Direction::Left,
            },
            "07000000010f4d18030200",
        ),
        (
            "LayoutOp::DockPane (in place)",
            LayoutOp::DockPane {
                pane_id: PaneId(3),
                beside: None,
            },
            "06000000010f4d170300",
        ),
    ];
    for (name, op, golden) in ops {
        check(&mut failures, name, ClientCtl::Op { op_id: 77, op }, golden);
    }
    check(
        &mut failures,
        "ServerCtl::Floats",
        ServerCtl::Floats(SessionFloats {
            session_id: SessionId(1),
            revision: 9,
            floats: vec![FloatWindow {
                id: FloatId(4),
                panes: vec![PaneId(3), PaneId(5)],
                frame: FRAME,
                z: 2,
                minimized: false,
                pinned: true,
                close: CloseWhen::Never,
            }],
        }),
        "1d000000013c010901040203050000003f0000803e0000003f0000003f02000100",
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
