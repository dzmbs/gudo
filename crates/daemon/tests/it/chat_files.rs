//! Files offered to a Chat `@` mention (`WorkspaceRequest::ChatFileSearch`): searched under the
//! agent pane's working directory, bounded, checked against the path policy, the owner's alone.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use client_core::grants::GrantSpec;
use client_core::proto::{
    CHAT_FILE_MATCHES_MAX, CHAT_FILE_QUERY_MAX_BYTES, FileMatches, PaneId, Roles, Scope,
    UnixMillis, WsError,
};
use client_core::{ClientConfig, now_millis};

use crate::support::{TIMEOUT, TestClient, start_with, ticket};

struct Project {
    _home: tempfile::TempDir,
    home: PathBuf,
    root: PathBuf,
}

fn project() -> Project {
    let home_dir = tempfile::tempdir().unwrap();
    let home = home_dir.path().canonicalize().unwrap();
    let root = home.join("project");
    std::fs::create_dir_all(root.join("src/components")).unwrap();
    std::fs::write(root.join("src/app.ts"), "app").unwrap();
    std::fs::write(root.join("src/components/button.tsx"), "button").unwrap();
    std::fs::write(root.join("README.md"), "readme").unwrap();
    for index in 0..80 {
        std::fs::write(root.join(format!("src/apple{index}.ts")), "").unwrap();
    }
    Project {
        _home: home_dir,
        home,
        root,
    }
}

async fn search(
    client: &TestClient,
    pane: PaneId,
    query: &str,
    limit: u16,
) -> Result<FileMatches, WsError> {
    tokio::time::timeout(
        TIMEOUT,
        client.client.chat_file_search(pane, query.into(), limit),
    )
    .await
    .expect("an answer")
}

/// A zsh pane that moved into `folder`, once the daemon knows it is there.
async fn pane_in(client: &mut TestClient, folder: &Path) -> PaneId {
    let pane = client.attach_and_follow().await;
    client.type_line(pane, &format!("cd {}", folder.display()));
    let deadline = Instant::now() + TIMEOUT;
    loop {
        if search(client, pane, "", 1).await.is_ok() {
            return pane;
        }
        assert!(
            Instant::now() < deadline,
            "the pane never reached {folder:?}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn chat_file_search_lists_the_panes_folder_within_bounds() {
    let zsh = PathBuf::from("/bin/zsh");
    if !zsh.exists() {
        return;
    }
    let project = project();
    let state = tempfile::Builder::new()
        .prefix("state")
        .tempdir_in(&project.root)
        .unwrap();
    std::fs::write(state.path().join("apple-secret.ts"), "").unwrap();
    let home = project.home.to_string_lossy().into_owned();
    let allowed = project.home.clone();
    let daemon = start_with(state.path(), move |config| {
        config.shell = Some(zsh);
        config.pane_env = vec![
            ("HOME".into(), home.clone()),
            ("PS1".into(), "$ ".into()),
            ("ZDOTDIR".into(), home),
        ];
        config.fs_allow.push(allowed);
    })
    .await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = pane_in(&mut owner, &project.root).await;

    let found = search(&owner, pane, "app", 5).await.unwrap();
    assert_eq!(found.root, project.root.to_string_lossy());
    assert_eq!(
        found.matches.first().map(|file| file.path.as_str()),
        Some("src/app.ts")
    );
    assert_eq!(found.matches.len(), 5);

    let button = search(&owner, pane, "btn", 5).await.unwrap();
    assert_eq!(
        button.matches.first().map(|file| file.path.as_str()),
        Some("src/components/button.tsx")
    );

    let capped = search(&owner, pane, "apple", u16::MAX).await.unwrap();
    assert_eq!(capped.matches.len(), usize::from(CHAT_FILE_MATCHES_MAX));

    let state_name = state
        .path()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let secret = search(&owner, pane, "secret", 50).await.unwrap();
    assert!(
        secret
            .matches
            .iter()
            .all(|file| !file.path.starts_with(&state_name)),
        "the daemon's state was offered: {:?}",
        secret.matches
    );

    let overlong = search(&owner, pane, &"a".repeat(CHAT_FILE_QUERY_MAX_BYTES + 1), 5).await;
    assert!(matches!(overlong, Err(WsError::Invalid(_))), "{overlong:?}");
    let unknown = search(&owner, PaneId(9_999), "app", 5).await;
    assert!(matches!(unknown, Err(WsError::NotFound(_))), "{unknown:?}");

    owner.type_line(pane, &format!("cd {}", project.home.display()));
    let deadline = Instant::now() + TIMEOUT;
    loop {
        match search(&owner, pane, "app", 5).await {
            Err(WsError::Unavailable(message)) => {
                assert!(message.contains("home folder"), "{message}");
                break;
            }
            other => {
                assert!(Instant::now() < deadline, "home was searched: {other:?}");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }

    // Even a guest whose grant names every role is not the owner.
    let mut spec = GrantSpec::new(
        Roles::VIEWER | Roles::PROMPTER | Roles::DRIVER | Roles::APPROVER | Roles::OWNER,
        Scope::Daemon,
    );
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "guest".into())
        .await
        .unwrap()
        .to_string();
    let mut guest = TestClient::join(&invite, ClientConfig::generate_key());
    guest.client.attach(None);
    guest
        .until("guest attached", |client| client.layout.is_some())
        .await;
    owner.type_line(pane, &format!("cd {}", project.root.display()));
    let refused = search(&guest, pane, "app", 5).await;
    assert!(matches!(refused, Err(WsError::Denied(_))), "{refused:?}");
    drop(guest);
    drop(owner);
    daemon.shutdown().await;
}
