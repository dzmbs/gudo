//! Shared Rust/Swift test vectors (`tests/vectors/push-v1.json`).
//!
//! The Swift `PushCrypto` package (apple/Packages/PushCrypto) keeps a byte-identical copy and
//! decrypts every payload in it. Regenerate both after an intentional format change with
//! `UPDATE_PUSH_VECTORS=1 cargo test -p push --test vectors`.

use std::path::PathBuf;

use proto::{DaemonId, DeviceId, OptionId, PaneId, RequestId, UnixMillis};
use push::{
    ActionOffer, ActionToken, ActivityState, Decision, Kind, Notification, b64, ed25519_public,
    hex, hpke,
};
use serde_json::{Value, json};

const DEVICE_SECRET: [u8; 32] = [0x11; 32];
const DAEMON_SEED: [u8; 32] = [0x22; 32];
const DEVICE_SEED: [u8; 32] = [0x33; 32];

fn eph(n: u8) -> [u8; 32] {
    [0x40 + n; 32]
}

fn notification(kind: Kind, action: Option<ActionOffer>) -> Notification {
    Notification {
        v: Notification::VERSION,
        daemon: hex(&ed25519_public(&DAEMON_SEED)),
        host: "studio-mac".into(),
        kind,
        item: 42,
        pane: 7,
        session: Some(1),
        title: match kind {
            Kind::Approval | Kind::Blocked => "claude needs you".into(),
            Kind::Done => "claude finished".into(),
            Kind::Failed => "claude failed".into(),
            Kind::Command => "cargo test succeeded".into(),
        },
        body: "Bash: git push --force — «ünïcödé» ✓".into(),
        at: 1_760_000_000_000,
        action,
    }
}

fn vectors() -> Value {
    let device_public = hpke::public_key(&DEVICE_SECRET);
    let daemon_public = ed25519_public(&DAEMON_SEED);
    let token = ActionToken {
        v: ActionToken::VERSION,
        daemon: DaemonId(daemon_public),
        device: DeviceId(ed25519_public(&DEVICE_SEED)),
        pane: PaneId(7),
        request: RequestId(9),
        approve: Some(OptionId(0)),
        deny: Some(OptionId(2)),
        item: 42,
        expires: UnixMillis(1_760_000_600_000),
    };
    let token_bytes = push::issue_token(&DAEMON_SEED, &token);
    let offer = ActionOffer {
        token: b64(&token_bytes),
        approve: "Yes".into(),
        deny: "No".into(),
        expires: token.expires.0,
    };

    let mut payloads = Vec::new();
    for (i, (name, note)) in [
        (
            "approval",
            notification(Kind::Approval, Some(offer.clone())),
        ),
        ("done", notification(Kind::Done, None)),
        ("command", notification(Kind::Command, None)),
    ]
    .into_iter()
    .enumerate()
    {
        let json = serde_json::to_vec(&note).unwrap();
        let sealed =
            push::seal_with_ephemeral(&device_public, &DAEMON_SEED, &json, &eph(i as u8)).unwrap();
        // Rust reads back what it wrote.
        let opened = push::open(&DEVICE_SECRET, &sealed).unwrap();
        assert_eq!(opened.notification().unwrap(), note);
        payloads.push(json!({
            "name": name,
            "sealed": sealed,
            "json": String::from_utf8(json).unwrap(),
            "category": note.kind.category().apns_category(),
        }));
    }

    let activity = ActivityState {
        v: Notification::VERSION,
        daemon: hex(&daemon_public),
        host: "studio-mac".into(),
        running: 2,
        blocked: 1,
        done: 3,
        headline: "claude: approve git push?".into(),
        at: 1_760_000_000_000,
    };
    let activity_json = serde_json::to_vec(&activity).unwrap();
    let activity_sealed =
        push::seal_with_ephemeral(&device_public, &DAEMON_SEED, &activity_json, &eph(9)).unwrap();
    assert_eq!(
        push::open(&DEVICE_SECRET, &activity_sealed)
            .unwrap()
            .activity()
            .unwrap(),
        activity
    );

    // Payloads the NSE must reject: sealed to another key, bit-flipped, and validly sealed but
    // signed by a daemon other than the one the JSON names.
    let other_device = hpke::public_key(&[0x55; 32]);
    let done_json = serde_json::to_vec(&notification(Kind::Done, None)).unwrap();
    let wrong_key =
        push::seal_with_ephemeral(&other_device, &DAEMON_SEED, &done_json, &eph(10)).unwrap();
    let mut flipped = push::unb64(payloads[1]["sealed"].as_str().unwrap()).unwrap();
    let last = flipped.len() - 1;
    flipped[last] ^= 0x01;
    let wrong_signer =
        push::seal_with_ephemeral(&device_public, &[0x66; 32], &done_json, &eph(11)).unwrap();

    let mut decisions = Vec::new();
    for decision in [Decision::Approve, Decision::Deny] {
        let sig = push::sign_decision(&DEVICE_SEED, &token_bytes, decision);
        decisions.push(json!({
            "decision": format!("{decision:?}").to_lowercase(),
            "message": hex(&[push::DECISION_DOMAIN, &push::decision_message(&token_bytes, decision)].concat()),
            "signature": b64(&sig),
        }));
    }

    // A relay request as the daemon signs it (the Worker's tests verify it).
    let request = push::RelayRequest {
        v: push::RelayRequest::VERSION,
        daemon: hex(&daemon_public),
        cap: "v1.opaque-capability".into(),
        push_type: push::PushType::Alert,
        category: Some(push::Category::Approval),
        collapse: Some(push::collapse_id(
            &DAEMON_SEED,
            PaneId(7),
            push::Category::Approval,
        )),
        sealed: payloads[0]["sealed"].as_str().unwrap().to_owned(),
        ts: 1_760_000_000_000,
        nonce: "00112233445566778899aabbccddeeff".into(),
        event: None,
        stale: None,
        dismiss: None,
        urgent: false,
    };
    let request_body = serde_json::to_string(&request).unwrap();
    let request_sig = push::sign_request(&DAEMON_SEED, request_body.as_bytes());
    assert_eq!(
        push::verify_request(request_body.as_bytes(), &request_sig).unwrap(),
        request
    );

    json!({
        "comment": "Generated by crates/push/tests/vectors.rs; do not edit by hand.",
        "relay_request": {
            "body": request_body,
            "signature": request_sig,
        },
        "info": String::from_utf8(push::SEAL_INFO.to_vec()).unwrap(),
        "payload_domain": hex(push::PAYLOAD_DOMAIN),
        "device_secret": b64(&DEVICE_SECRET),
        "device_public": b64(&device_public),
        "daemon_public": hex(&daemon_public),
        "payloads": payloads,
        "activity": {
            "sealed": activity_sealed,
            "json": String::from_utf8(activity_json).unwrap(),
        },
        "rejects": [
            {"name": "wrong_device_key", "sealed": wrong_key, "error": "open"},
            {"name": "bit_flip", "sealed": b64(&flipped), "error": "open"},
            {"name": "wrong_signer", "sealed": wrong_signer, "error": "signature"},
        ],
        "action": {
            "device_seed": b64(&DEVICE_SEED),
            "device_public": b64(&ed25519_public(&DEVICE_SEED)),
            "token": b64(&token_bytes),
            "decisions": decisions,
        },
        "rfc9180_a21": {
            "info": "4f6465206f6e2061204772656369616e2055726e",
            "skRm": "8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb",
            "enc": "1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a",
            "aad": "436f756e742d30",
            "ct": "1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db21993c62ce81883d2dd1b51a28",
            "pt": "4265617574792069732074727574682c20747275746820626561757479",
        },
    })
}

fn paths() -> [PathBuf; 2] {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    [
        root.join("tests/vectors/push-v1.json"),
        root.join("../../apple/Packages/PushCrypto/Tests/PushCryptoTests/Resources/push-v1.json"),
    ]
}

#[test]
fn vectors_match_the_committed_files() {
    let text = serde_json::to_string_pretty(&vectors()).unwrap() + "\n";
    for path in paths() {
        if std::env::var_os("UPDATE_PUSH_VECTORS").is_some() {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, &text).unwrap();
        }
        let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            panic!(
                "{}: {e}; run with UPDATE_PUSH_VECTORS=1 to create it",
                path.display()
            )
        });
        assert_eq!(
            committed,
            text,
            "{} is stale; regenerate with UPDATE_PUSH_VECTORS=1 (and check why the format changed)",
            path.display()
        );
    }
}

#[test]
fn rejects_are_rejected() {
    let v = vectors();
    for case in v["rejects"].as_array().unwrap() {
        let sealed = case["sealed"].as_str().unwrap();
        let result = push::open(&DEVICE_SECRET, sealed).and_then(|o| o.notification());
        match case["error"].as_str().unwrap() {
            "open" => assert!(
                matches!(result, Err(push::PushError::Open(_))),
                "{case}: {result:?}"
            ),
            _ => assert!(
                matches!(result, Err(push::PushError::Signature)),
                "{case}: {result:?}"
            ),
        }
    }
}
