//! Frozen wire bytes for program status (`proto::program`).
//! Same rule as `golden.rs`: never edit an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_program -- --nocapture`.

use proto::frame::{self, FrameDecoder};
use proto::*;

fn check(print: bool, name: &str, msg: ServerCtl, golden: &str) -> Option<String> {
    let wire = frame::to_vec(&msg).unwrap();
    let hex: String = wire.iter().map(|b| format!("{b:02x}")).collect();
    if print {
        println!("{name}: \"{hex}\"");
    }
    let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
    decoder.extend(&wire);
    let back: ServerCtl = decoder.decode().unwrap().unwrap();
    assert_eq!(back, msg, "{name} did not round-trip");
    (hex != golden).then(|| format!("{name}\n  want {golden}\n  got  {hex}"))
}

#[test]
fn program_status_messages_match_their_frozen_bytes() {
    let print = std::env::var_os("PROTO_PRINT_GOLDEN").is_some();
    assert_eq!(Caps::PROGRAM_STATUS.0, 1 << 15);
    assert_eq!(DaemonFeatures::PROGRAM_STATUS.0, 1 << 12);

    let cases = [
        (
            "ProgramStatus::Blocked",
            ServerCtl::ProgramStatus {
                pane_id: PaneId(3),
                status: Some(ProgramReport {
                    state: ProgramState::Blocked,
                    kind: Some(ProgramKind::Question),
                    app: Some("pi".into()),
                    message: Some("Which?".into()),
                    progress: Some(40),
                }),
            },
            "150000000135030103010101027069010657686963683f0128",
        ),
        (
            "ProgramStatus::Working",
            ServerCtl::ProgramStatus {
                pane_id: PaneId(3),
                status: Some(ProgramReport {
                    state: ProgramState::Working,
                    kind: None,
                    app: None,
                    message: None,
                    progress: None,
                }),
            },
            "09000000013503010100000000",
        ),
        (
            "ProgramStatus::None",
            ServerCtl::ProgramStatus {
                pane_id: PaneId(3),
                status: None,
            },
            "0400000001350300",
        ),
    ];
    let failures: Vec<String> = cases
        .into_iter()
        .filter_map(|(name, msg, golden)| check(print, name, msg, golden))
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
