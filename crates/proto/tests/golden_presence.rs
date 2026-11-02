//! Frozen wire bytes for live presence (`proto::peer`): drafts, viewports, following, peers.
//! Same rule as `golden.rs`: never edit an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_presence -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

const PANE: PaneId = PaneId(3);
const ACTOR: Actor = Actor {
    principal: PrincipalId([0x11; 16]),
    device: DeviceId([0x22; 32]),
};

struct Checker {
    print: bool,
    failures: Vec<String>,
}

impl Checker {
    fn check<T>(&mut self, name: &str, msg: T, golden: &str)
    where
        T: Serialize + DeserializeOwned + PartialEq + Debug,
    {
        let wire = frame::to_vec(&msg).unwrap();
        let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
        if self.print {
            println!("{name}: \"{hex}\"");
        }
        if hex != golden {
            self.failures
                .push(format!("{name}\n  want {golden}\n  got  {hex}"));
        }
        let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
        decoder.extend(&wire);
        let back: T = decoder.decode().unwrap().unwrap();
        assert_eq!(back, msg, "{name} did not round-trip");
        assert_eq!(decoder.buffered(), 0, "{name} left bytes behind");
    }
}

fn draft() -> Draft {
    Draft {
        pane_id: PANE,
        source: DraftSource::Composer,
        text: "fix it".into(),
        caret: 6,
    }
}

fn peer() -> Peer {
    Peer {
        peer: PeerId(4),
        rev: 9,
        actor: ACTOR,
        name: "Kim".into(),
        roles: Roles::DRIVER,
        device: DeviceClass::Tablet,
        since: UnixMillis(1),
        state: PresenceState::Idle,
        focus: Some(PANE),
        viewport: Some(PeerViewport {
            pane_id: PANE,
            from_bottom: 12,
            rows: 40,
        }),
        typing: Some(PANE),
        draft: Some(draft()),
        following: Some(PrincipalId([0x77; 16])),
    }
}

#[test]
fn presence_messages_match_their_frozen_bytes() {
    let mut checker = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };
    assert_eq!(Caps::PRESENCE.0, 1 << 14);
    assert_eq!(DaemonFeatures::PRESENCE.0, 1 << 10);

    let cases: Vec<(&str, ClientCtl, &str)> = vec![
        (
            "PeerUpdate::Device",
            ClientCtl::Peer(PeerUpdate::Device(DeviceClass::Desktop)),
            "04000000011d0003",
        ),
        (
            "PeerUpdate::State",
            ClientCtl::Peer(PeerUpdate::State(PresenceState::Away)),
            "04000000011d0102",
        ),
        (
            "PeerUpdate::Viewport",
            ClientCtl::Peer(PeerUpdate::Viewport(Some(PeerViewport {
                pane_id: PANE,
                from_bottom: 300,
                rows: 24,
            }))),
            "08000000011d020103ac0218",
        ),
        (
            "PeerUpdate::Draft",
            ClientCtl::Peer(PeerUpdate::Draft(Some(draft()))),
            "0e000000011d030103010666697820697406",
        ),
        (
            "PeerUpdate::Draft(clear)",
            ClientCtl::Peer(PeerUpdate::Draft(None)),
            "04000000011d0300",
        ),
        (
            "PeerUpdate::Follow",
            ClientCtl::Peer(PeerUpdate::Follow(Some(PrincipalId([0x77; 16])))),
            "14000000011d040177777777777777777777777777777777",
        ),
        (
            "PeerUpdate::Heartbeat",
            ClientCtl::Peer(PeerUpdate::Heartbeat),
            "03000000011d05",
        ),
    ];
    for (name, msg, golden) in cases {
        checker.check(name, msg, golden);
    }
    checker.check(
        "PeerPush::All",
        ServerCtl::Peers(PeerPush::All {
            you: PeerId(4),
            peers: vec![peer()],
        }),
        "6300000001340004010409111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222034b696d04020101010301030c28010301030106666978206974060177777777777777777777777777777777",
    );
    checker.check(
        "PeerPush::Changed",
        ServerCtl::Peers(PeerPush::Changed(Peer {
            viewport: None,
            draft: None,
            following: None,
            typing: None,
            ..peer()
        })),
        "430000000134010409111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222034b696d04020101010300000000",
    );
    assert!(
        checker.failures.is_empty(),
        "{}",
        checker.failures.join("\n")
    );
}
