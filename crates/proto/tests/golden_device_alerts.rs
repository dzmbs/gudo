//! Frozen wire bytes for owner alerts (`ServerCtl::DevicePaired`, `ServerCtl::HostAlert`).
//! Same rule as `golden.rs`: never edit an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_device_alerts -- --nocapture`.

use proto::frame::{self, FrameDecoder};
use proto::*;

#[test]
fn device_paired_matches_its_frozen_bytes() {
    assert_eq!(Caps::DEVICE_ALERTS.0, 1 << 16);
    let msg = ServerCtl::DevicePaired(DeviceInfo {
        device: DeviceId([2; 32]),
        principal: PrincipalId([3; 16]),
        kind: DeviceKind::Owner,
        name: "owner".into(),
        first_seen: UnixMillis(1_700_000_000_000),
        grant_id: None,
        revoked: false,
        connected: 1,
    });
    let wire = frame::to_vec(&msg).unwrap();
    let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
    if std::env::var_os("PROTO_PRINT_GOLDEN").is_some() {
        println!("DevicePaired: \"{hex}\"");
    }
    let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
    decoder.extend(&wire);
    let back: ServerCtl = decoder.decode().unwrap().unwrap();
    assert_eq!(back, msg);
    assert_eq!(
        hex,
        "42000000013602020202020202020202020202020202020202020202020202020202020202020303030303030303030303030303030300056f776e657280d095ffbc31000001"
    );
}

#[test]
fn host_alert_matches_its_frozen_bytes() {
    assert_eq!(Caps::HOST_ALERTS.0, 1 << 17);
    let msg = ServerCtl::HostAlert(HostAlert {
        kind: HostAlertKind::GrantStoreReset,
        at: UnixMillis(1_700_000_000_000),
        title: "t".into(),
        body: "b".into(),
    });
    let wire = frame::to_vec(&msg).unwrap();
    let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
    if std::env::var_os("PROTO_PRINT_GOLDEN").is_some() {
        println!("HostAlert: \"{hex}\"");
    }
    let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
    decoder.extend(&wire);
    let back: ServerCtl = decoder.decode().unwrap().unwrap();
    assert_eq!(back, msg);
    assert_eq!(hex, "0d00000001370080d095ffbc3101740162");
}
