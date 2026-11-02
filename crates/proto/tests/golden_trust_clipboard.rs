//! Frozen wire bytes for repository hook trust, clipboard writes (OSC 52) and password prompts
//! asked while a guest drives. Same rule as `golden.rs`: never edit an existing hex string; add
//! a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_trust_clipboard -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

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
    }
}

#[test]
fn trust_clipboard_and_driver_messages_match_their_frozen_bytes() {
    assert_eq!(Caps::CLIPBOARD.0, 1 << 19);
    assert_eq!(Caps::ASKPASS_DRIVER.0, 1 << 20);
    assert_eq!(DaemonFeatures::REPO_TRUST.0, 1 << 14);
    let mut checker = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };
    checker.check(
        "ServerCtl::Clipboard",
        ServerCtl::Clipboard {
            pane_id: PaneId(3),
            text: "hi".into(),
        },
        "06000000013903026869",
    );
    checker.check(
        "ServerCtl::Askpass(PromptWhileGuestDrives)",
        ServerCtl::Askpass(AskpassPush::PromptWhileGuestDrives {
            prompt: SecretPrompt {
                id: AskpassId(9),
                pane_id: PaneId(3),
                source: SecretSource::Sudo,
                prompt: "Password:".into(),
                program: "sudo ls".into(),
                echo: false,
                retry: false,
                expires_at: UnixMillis(1000),
            },
            guest: "bob".into(),
        }),
        "200000000129040903000950617373776f72643a077375646f206c730000e80703626f62",
    );
    let req = |req| ClientCtl::Workspace { req_id: 5, req };
    checker.check(
        "WorkspaceRequest::RepoHooks(NewTask)",
        req(WorkspaceRequest::RepoHooks(RepoHooksFor::NewTask {
            repo: "/r".into(),
            base: Some("main".into()),
        })),
        "0e0000000115053400022f7201046d61696e",
    );
    checker.check(
        "WorkspaceRequest::RepoHooks(Worktree)",
        req(WorkspaceRequest::RepoHooks(RepoHooksFor::Worktree {
            path: "/w".into(),
        })),
        "080000000115053401022f77",
    );
    checker.check(
        "WorkspaceRequest::RepoTrust",
        req(WorkspaceRequest::RepoTrust {
            repo: "/r".into(),
            hash: "ab".into(),
        }),
        "0a00000001150535022f72026162",
    );
    checker.check(
        "WorkspaceResponse::RepoHooks",
        ServerCtl::WorkspaceResult {
            req_id: 5,
            result: Ok(WorkspaceResponse::RepoHooks(RepoHooksTrust {
                repo: "/r".into(),
                hooks: RepoHooks {
                    setup: Some("make".into()),
                    teardown: None,
                },
                hash: "ab".into(),
                trusted: false,
            })),
        },
        "13000000011805001f022f7201046d616b650002616200",
    );
    assert!(
        checker.failures.is_empty(),
        "{}",
        checker.failures.join("\n")
    );
}

/// Invite links and editor tokens are bearer secrets: logging a value must not leak them.
#[test]
fn debug_output_leaves_bearer_secrets_out() {
    let invite = Invite {
        v: Invite::VERSION,
        daemon_id: DaemonId([7; 32]),
        addrs: vec![],
        relay_url: None,
        inviter: "alice".into(),
        chain: GrantChain {
            links: vec![GrantLink {
                grant: Grant {
                    v: Grant::VERSION,
                    grant_id: GrantId([1; 16]),
                    daemon_id: DaemonId([7; 32]),
                    issuer: DeviceId([2; 32]),
                    roles: Roles::DRIVER,
                    scope: Scope::Daemon,
                    issued_at: UnixMillis(0),
                    expires: None,
                    max_uses: None,
                    bind: None,
                    delegate: false,
                    label: "bob".into(),
                },
                sig: vec![0x5a; 64],
            }],
        },
    };
    let shown = format!("{invite:?}");
    assert!(shown.contains("alice"), "{shown}");
    for leak in ["sig", "links", "90, 90", &invite.to_string()] {
        assert!(!shown.contains(leak), "{leak:?} in {shown}");
    }

    let editor = EditorInstance {
        kind: EditorKind::VsCode,
        folder: "/w".into(),
        port: 8000,
        token: "tok-secret".into(),
        url_path: "/?tkn=tok-secret&folder=/w".into(),
        pid: 1,
        started_at: UnixMillis(0),
    };
    let shown = format!("{editor:?}");
    assert!(shown.contains("8000"), "{shown}");
    assert!(!shown.contains("tok-secret"), "{shown}");
}
