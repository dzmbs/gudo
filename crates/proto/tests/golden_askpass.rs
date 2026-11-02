//! Frozen wire bytes for the native password prompt messages (`proto::askpass`), kept apart
//! from `golden.rs` so the cases of parallel additions do not collide. Same rule: never edit
//! an existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_askpass -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

const PANE: PaneId = PaneId(3);
const ID: AskpassId = AskpassId(9);
const ANA: PrincipalId = PrincipalId([0xaa; 16]);

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

#[test]
fn askpass_messages_match_their_frozen_bytes() {
    let mut checker = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };
    assert_eq!(Caps::ASKPASS.0, 1 << 7);

    let req = |req| ClientCtl::Askpass { req_id: 5, req };
    checker.check(
        "ClientCtl::Askpass(Answer)",
        req(AskpassRequest::Answer {
            id: ID,
            secret: Secret::new(b"pw".to_vec()),
        }),
        "08000000011a050009027077",
    );
    checker.check(
        "ClientCtl::Askpass(Cancel)",
        req(AskpassRequest::Cancel { id: ID }),
        "05000000011a050109",
    );
    checker.check(
        "ClientCtl::Askpass(TypeSecret)",
        req(AskpassRequest::TypeSecret {
            pane_id: PANE,
            secret: Secret::new(b"pw".to_vec()),
        }),
        "08000000011a050203027077",
    );

    let result = |result| ServerCtl::AskpassResult { req_id: 5, result };
    checker.check(
        "ServerCtl::AskpassResult(Ok)",
        result(Ok(())),
        "0400000001280500",
    );
    for (name, error, golden) in [
        ("Gone", AskpassError::Gone, "050000000128050100"),
        (
            "Denied",
            AskpassError::Denied("driver".into()),
            "0c000000012805010106647269766572",
        ),
        (
            "UnknownPane",
            AskpassError::UnknownPane,
            "050000000128050102",
        ),
        ("NotHidden", AskpassError::NotHidden, "050000000128050103"),
        (
            "Failed",
            AskpassError::Failed("x".into()),
            "0700000001280501040178",
        ),
        (
            "Disconnected",
            AskpassError::Disconnected,
            "050000000128050105",
        ),
    ] {
        checker.check(
            &format!("ServerCtl::AskpassResult({name})"),
            result(Err(error)),
            golden,
        );
    }

    checker.check(
        "ServerCtl::Askpass(Prompt)",
        ServerCtl::Askpass(AskpassPush::Prompt(SecretPrompt {
            id: ID,
            pane_id: PANE,
            source: SecretSource::Sudo,
            prompt: "Password:".into(),
            program: "sudo ls".into(),
            echo: false,
            retry: true,
            expires_at: UnixMillis(1000),
        })),
        "1c0000000129000903000950617373776f72643a077375646f206c730001e807",
    );
    for (name, reason, golden) in [
        (
            "Answered",
            CloseReason::Answered { by: ANA },
            "16000000012901090300aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
        (
            "Cancelled",
            CloseReason::Cancelled { by: Some(ANA) },
            "1700000001290109030101aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
        (
            "CancelledByDaemon",
            CloseReason::Cancelled { by: None },
            "0700000001290109030100",
        ),
        ("TimedOut", CloseReason::TimedOut, "06000000012901090302"),
        ("Abandoned", CloseReason::Abandoned, "06000000012901090303"),
        (
            "MovedToTerminal",
            CloseReason::MovedToTerminal,
            "06000000012901090304",
        ),
    ] {
        checker.check(
            &format!("ServerCtl::Askpass(Closed {name})"),
            ServerCtl::Askpass(AskpassPush::Closed {
                id: ID,
                pane_id: PANE,
                reason,
            }),
            golden,
        );
    }
    checker.check(
        "ServerCtl::Askpass(Detected)",
        ServerCtl::Askpass(AskpassPush::Detected(DetectedPrompt {
            pane_id: PANE,
            prompt: "Password:".into(),
            at_seq: Seq(300),
        })),
        "10000000012902030950617373776f72643aac02",
    );
    checker.check(
        "ServerCtl::Askpass(DetectedGone)",
        ServerCtl::Askpass(AskpassPush::DetectedGone { pane_id: PANE }),
        "0400000001290303",
    );
    for (name, source, golden) in [
        ("Sudo", SecretSource::Sudo, "020000000100"),
        ("Ssh", SecretSource::Ssh, "020000000101"),
        ("Git", SecretSource::Git, "020000000102"),
        ("Gpg", SecretSource::Gpg, "020000000103"),
        ("Other", SecretSource::Other, "020000000104"),
    ] {
        checker.check(&format!("SecretSource::{name}"), source, golden);
    }
    assert!(
        checker.failures.is_empty(),
        "{}",
        checker.failures.join("\n")
    );
}
