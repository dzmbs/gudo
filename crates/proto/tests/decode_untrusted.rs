//! Everything a peer can send before or after authenticating is decoded from untrusted
//! bytes: none of it may panic or allocate past what arrived, however it is mangled.

use proptest::prelude::*;
use proto::frame::{self, FrameDecoder};
use proto::*;

/// Decodes `body` as every message type a daemon or client reads off the wire.
fn decode_all(body: &[u8]) {
    let _ = frame::decode_body::<ClientCtl>(body);
    let _ = frame::decode_body::<ServerCtl>(body);
    let _ = frame::decode_body::<StreamHeader>(body);
    let _ = frame::decode_body::<ClientInput>(body);
    let _ = frame::decode_body::<PaneOutput>(body);
    let _ = frame::decode_body::<Bulk>(body);
    let _ = GrantChain::from_token(body);
}

/// A body with the current wire version, so the bytes reach the message decoders.
fn versioned(rest: &[u8]) -> Vec<u8> {
    let mut body = postcard::to_stdvec(&WIRE_VERSION).unwrap();
    body.extend_from_slice(rest);
    body
}

fn hello() -> Vec<u8> {
    let msg = ClientCtl::Hello(Hello {
        device_id: DeviceId([4; 32]),
        principal_id: PrincipalId([5; 16]),
        grant: SignedGrant {
            v: SignedGrant::PAIRING,
            grant_id: GrantId([6; 16]),
            token: vec![7; 16],
        },
        snapshot_format: 1,
        resume: Vec::new(),
        caps: Caps::DAEMON_INFO,
        link: LinkClass::Normal,
        resume_token: None,
    });
    frame::to_vec(&msg).unwrap()[frame::LEN_PREFIX..].to_vec()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2000))]

    #[test]
    fn random_bodies_never_panic(rest in proptest::collection::vec(any::<u8>(), 0..512)) {
        decode_all(&rest);
        decode_all(&versioned(&rest));
    }

    #[test]
    fn mangled_hellos_never_panic(
        flips in proptest::collection::vec((any::<usize>(), any::<u8>()), 1..8),
        cut in any::<usize>(),
    ) {
        let mut body = hello();
        for (at, xor) in flips {
            let i = at % body.len();
            body[i] ^= xor;
        }
        body.truncate(cut % (body.len() + 1));
        decode_all(&body);
    }

    #[test]
    fn ticket_and_invite_text_never_panics(text in "\\PC{0,300}") {
        let _ = text.parse::<Ticket>();
        let _ = Ticket::parse_with_extras(&text);
        let _ = text.parse::<Invite>();
        let _ = Invite::parse_with_terms(&text);
        let prefixed = format!("gudo://pair/{text}");
        let _ = prefixed.parse::<Ticket>();
    }
}

/// A length prefix claiming far more than arrived is refused before anything is allocated.
#[test]
fn oversized_lengths_are_refused() {
    let mut huge = (u32::MAX).to_le_bytes().to_vec();
    huge.extend_from_slice(&[0; 8]);
    let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
    decoder.extend(&huge);
    assert!(decoder.decode::<ClientCtl>().is_err());

    // A collection whose element count runs past the body is an error, not an allocation.
    let mut body = hello();
    let mut claim = Vec::new();
    let mut n: u64 = u64::from(u32::MAX);
    while n >= 0x80 {
        claim.push((n as u8) | 0x80);
        n >>= 7;
    }
    claim.push(n as u8);
    body.extend_from_slice(&claim);
    assert!(frame::decode_body::<ClientCtl>(&body).is_err());
    let mut chain = claim.clone();
    chain.extend_from_slice(&[1, 2, 3]);
    assert!(GrantChain::from_token(&chain).is_err());
}
