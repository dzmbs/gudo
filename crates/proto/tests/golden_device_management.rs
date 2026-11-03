//! Frozen wire bytes for device management from an owner device (`MpRequest::PairingTicket`,
//! `MpRequest::RenameDevice`). Same rule as `golden.rs`: never edit an existing hex string; add
//! a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_device_management -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

fn check<T>(name: &str, msg: T, golden: &str)
where
    T: Serialize + DeserializeOwned + PartialEq + Debug,
{
    let wire = frame::to_vec(&msg).unwrap();
    let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
    if std::env::var_os("PROTO_PRINT_GOLDEN").is_some() {
        println!("{name}: \"{hex}\"");
    }
    let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
    decoder.extend(&wire);
    let back: T = decoder.decode().unwrap().unwrap();
    assert_eq!(back, msg, "{name} did not round-trip");
    if std::env::var_os("PROTO_PRINT_GOLDEN").is_none() {
        assert_eq!(hex, golden, "{name}");
    }
}

#[test]
fn device_management_matches_its_frozen_bytes() {
    assert_eq!(DaemonFeatures::DEVICE_MANAGEMENT.0, 1 << 20);
    check(
        "PairingTicket",
        ClientCtl::Multiplayer {
            req_id: 5,
            req: MpRequest::PairingTicket,
        },
        "0400000001160515",
    );
    check(
        "RenameDevice",
        ClientCtl::Multiplayer {
            req_id: 6,
            req: MpRequest::RenameDevice {
                device: DeviceId([2; 32]),
                name: "Work iPad".into(),
            },
        },
        "2e00000001160616020202020202020202020202020202020202020202020202020202020202020209576f726b2069506164",
    );
    check(
        "PairingTicketResult",
        ServerCtl::MultiplayerResult {
            req_id: 5,
            result: Ok(MpResponse::PairingTicket {
                ticket: "gudo://pair/abc".into(),
                expires: UnixMillis(1_700_000_000_000),
            }),
        },
        "1b000000011d0500100f6775646f3a2f2f706169722f61626380d095ffbc31",
    );
}
