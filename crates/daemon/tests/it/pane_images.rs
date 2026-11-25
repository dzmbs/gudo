//! Pictures pasted or dropped on an agent pane (`WorkspaceRequest::PasteImage`): kept without
//! their metadata in the pane's owner-only, bounded store, and pasted into each agent's input
//! the way it takes an image, without Enter. Guests need input on the pane.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::drawing;
use client_core::proto::{
    AgentKind, Axis, LayoutOp, OpOutcome, PaneId, PaneLaunch, PastedImage, PngSource, Roles, Scope,
    WorkspaceRequest, WorkspaceResponse, WsError,
};

use crate::artifacts::{LOCATION, guest_spec, holds, make_agent, photo_with_location};
use crate::support::{TIMEOUT, TestClient, start_with, ticket};

/// Turns on bracketed paste, as the agents do, and shows every byte it reads.
const FAKE_AGENT: &str =
    "#!/bin/sh\nstty -echo -icanon\nprintf '\\033[?2004hAGENT-READY\\n'\nexec cat -v\n";

fn fake_agents(bin: &Path) -> Vec<(String, String)> {
    std::fs::create_dir_all(bin).unwrap();
    for name in ["claude", "codex", "pi"] {
        let path = bin.join(name);
        std::fs::write(&path, FAKE_AGENT).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    vec![(
        "PATH".to_owned(),
        format!(
            "{}:{}",
            bin.display(),
            std::env::var("PATH").unwrap_or_default()
        ),
    )]
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// A solid square PNG; each `shade` is a different file of about the same size.
fn square(shade: u8) -> Vec<u8> {
    drawing::encode_png(&drawing::Rgba {
        width: 16,
        height: 16,
        data: [shade, 255 - shade, shade / 2, 255].repeat(256),
    })
}

/// A PNG that does not compress.
fn noise(side: u32) -> Vec<u8> {
    let mut state = 0x2545_f491_u32;
    let data = (0..side * side * 4)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state.to_le_bytes()[0]
        })
        .collect();
    drawing::encode_png(&drawing::Rgba {
        width: side,
        height: side,
        data,
    })
}

async fn paste(client: &TestClient, pane: PaneId, image: Vec<u8>) -> Result<PastedImage, WsError> {
    tokio::time::timeout(TIMEOUT, client.client.paste_image(pane, image))
        .await
        .expect("an answer")
}

async fn split(owner: &mut TestClient, from: PaneId, launch: PaneLaunch) -> PaneId {
    let OpOutcome::PaneCreated { pane_id } = owner
        .op(LayoutOp::Split {
            pane_id: from,
            axis: Axis::Horizontal,
            launch,
        })
        .await
    else {
        panic!("split failed")
    };
    owner.follow(pane_id).await;
    owner.wait_text(pane_id, "AGENT-READY").await;
    pane_id
}

fn fake_agent_command() -> PaneLaunch {
    PaneLaunch::Command {
        argv: vec![
            "sh".into(),
            "-c".into(),
            "stty -echo -icanon; printf '\\033[?2004hAGENT-READY\\n'; exec cat -v".into(),
        ],
        cwd: None,
    }
}

fn store(state: &Path) -> PathBuf {
    state.canonicalize().unwrap().join("pane-images")
}

fn files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|entries| entries.map(|entry| entry.unwrap().path()).collect())
        .unwrap_or_default();
    files.sort();
    files
}

async fn wait_gone(path: &Path) {
    let deadline = Instant::now() + TIMEOUT;
    while path.exists() {
        assert!(Instant::now() < deadline, "{path:?} stayed");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Exactly `typed` behind bracketed paste, and no Enter after it.
async fn assert_pasted(owner: &mut TestClient, pane: PaneId, typed: &str) {
    let expect = format!("^[[200~{typed}^[[201~");
    owner.wait_flat(pane, &expect).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let flat = owner.flat_text(pane);
    let after = &flat[flat.rfind(&expect).unwrap() + expect.len()..];
    assert!(!after.contains("^M") && !after.contains("^J"), "{after:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pasted_image_reaches_each_agent_as_a_path_in_its_input() {
    // A state directory with a space, like macOS's "Application Support".
    let tmp = tempfile::tempdir().unwrap();
    let state = tmp.path().join("Application Support");
    std::fs::create_dir_all(&state).unwrap();
    let env = fake_agents(&tmp.path().join("bin"));
    let daemon = start_with(&state, |config| config.pane_env.extend(env)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = owner.attach_and_follow().await;
    let store = store(&state);
    let mut panes = Vec::new();

    // Claude Code and Codex attach a pasted path escaped as a shell word; pi takes the path as
    // text its model reads.
    for (agent, escaped) in [
        (AgentKind::Claude, true),
        (AgentKind::Codex, true),
        (AgentKind::Pi, false),
    ] {
        let pane = split(
            &mut owner,
            shell,
            PaneLaunch::Agent {
                agent,
                resume: None,
                cwd: None,
            },
        )
        .await;
        let pasted = paste(&owner, pane, photo_with_location()).await.unwrap();
        assert_eq!(pasted.agent, agent);
        let path = Path::new(&pasted.path);
        assert_eq!(path.parent().unwrap(), store.join(pane.0.to_string()));
        assert_eq!(path.extension().unwrap(), "jpg");
        let copy = std::fs::read(path).unwrap();
        assert!(!holds(&copy, LOCATION), "the location stays on the device");
        assert!(holds(&copy, b"Exif\0\0MM\0*"), "the orientation stays");
        assert_eq!(mode(path), 0o600);
        assert_eq!(mode(path.parent().unwrap()), 0o700);
        assert_eq!(mode(&store), 0o700);
        let typed = if escaped {
            pasted.path.replace(' ', r"\ ")
        } else {
            pasted.path.clone()
        };
        assert_pasted(&mut owner, pane, &typed).await;
        panes.push(pane);
    }

    // An older app sends the photo as it is; the host strips it.
    let codex = panes[1];
    let WorkspaceResponse::ImagePasted(old_app) = owner
        .client
        .workspace(WorkspaceRequest::PasteImage {
            pane_id: codex,
            image: PngSource::Inline(photo_with_location()),
        })
        .await
        .unwrap()
    else {
        panic!("not pasted")
    };
    assert!(!holds(&std::fs::read(&old_app.path).unwrap(), LOCATION));

    // A shell gets nothing, and nothing is written for it.
    let refused = paste(&owner, shell, square(1)).await;
    assert!(
        matches!(refused, Err(WsError::Unavailable(_))),
        "{refused:?}"
    );
    assert!(!store.join(shell.0.to_string()).exists());
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_store_is_bounded_and_goes_with_its_pane() {
    let dir = tempfile::tempdir().unwrap();
    let size = square(0).len() as u64;
    let daemon = start_with(dir.path(), |config| {
        config.pane_images = daemon::PaneImageLimits {
            image_max: 64 << 10,
            per_pane: 3,
            pane_total_max: u64::MAX,
            total_max: 4 * size + size / 2,
        };
    })
    .await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = owner.attach_and_follow().await;
    let first = split(&mut owner, shell, fake_agent_command()).await;
    let second = split(&mut owner, shell, fake_agent_command()).await;
    make_agent(&daemon, dir.path(), first).await;
    make_agent(&daemon, dir.path(), second).await;
    let store = store(dir.path());
    let orphan = store.join("999999");
    std::fs::create_dir_all(&orphan).unwrap();
    std::fs::write(orphan.join("left.png"), square(9)).unwrap();

    // One image over the limit, and anything but PNG or JPEG, are refused.
    let refused = paste(&owner, first, noise(256)).await;
    assert!(matches!(refused, Err(WsError::Invalid(_))), "{refused:?}");
    let refused = paste(&owner, first, b"GIF89a not an image".to_vec()).await;
    assert!(matches!(refused, Err(WsError::Invalid(_))), "{refused:?}");

    // A pane keeps its newest three; the oldest goes first.
    let mut kept = Vec::new();
    for shade in 1..=4 {
        let pasted = paste(&owner, first, square(shade)).await.unwrap();
        kept.push(PathBuf::from(pasted.path));
        // Ages are told apart by the file times.
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(!kept[0].exists());
    assert_eq!(files(&store.join(first.0.to_string())), {
        let mut newest = kept[1..].to_vec();
        newest.sort();
        newest
    });
    assert!(!orphan.exists(), "a closed pane's images are swept");

    // Past the store's total, the oldest of any pane goes.
    let mut others = Vec::new();
    for shade in 11..=12 {
        let pasted = paste(&owner, second, square(shade)).await.unwrap();
        others.push(PathBuf::from(pasted.path));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(!kept[1].exists());
    assert!(kept[2].exists() && kept[3].exists());
    assert!(others.iter().all(|path| path.exists()));

    // Closing a pane deletes its images; the daemon stopping keeps the others.
    owner.op(LayoutOp::ClosePane { pane_id: first }).await;
    wait_gone(&store.join(first.0.to_string())).await;
    drop(owner);
    daemon.shutdown().await;
    assert!(others.iter().all(|path| path.exists()));
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_paste_only_into_panes_they_may_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |_| {}).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = owner.attach_and_follow().await;
    let agent = split(&mut owner, shell, fake_agent_command()).await;
    make_agent(&daemon, dir.path(), agent).await;
    let store = store(dir.path());

    let mut refused_guests = Vec::new();
    for (roles, scope, label) in [
        (Roles::VIEWER, Scope::Daemon, "vic"),
        (Roles::APPROVER, Scope::Pane(agent), "amy"),
        (Roles::PROMPTER, Scope::Pane(shell), "pat"),
    ] {
        let invite = owner
            .client
            .create_invite(guest_spec(roles, scope, label), "owner".into())
            .await
            .unwrap();
        let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
        guest.client.attach(None);
        guest
            .until("guest layout", |client| client.layout.is_some())
            .await;
        let refused = paste(&guest, agent, square(3)).await;
        assert!(
            matches!(refused, Err(WsError::Denied(_))),
            "{label}: {refused:?}"
        );
        refused_guests.push(guest);
    }
    assert!(!store.join(agent.0.to_string()).exists());

    let invite = owner
        .client
        .create_invite(
            guest_spec(Roles::PROMPTER, Scope::Pane(agent), "pia"),
            "owner".into(),
        )
        .await
        .unwrap();
    let mut prompter = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    prompter.client.attach(None);
    prompter
        .until("prompter layout", |client| client.layout.is_some())
        .await;
    let pasted = paste(&prompter, agent, square(4)).await.unwrap();
    assert!(Path::new(&pasted.path).starts_with(store.join(agent.0.to_string())));
    assert_pasted(&mut owner, agent, &pasted.path).await;
    drop((owner, prompter, refused_guests));
    daemon.shutdown().await;
}
