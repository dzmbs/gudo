//! Paths printed in a pane, resolved where the command that printed them ran
//! (`WorkspaceRequest::ResolvePaths` and the links of earlier commands).

use std::path::{Path, PathBuf};
use std::time::Duration;

use client_core::proto::{CommandMark, PaneId, PathFound, PathQuery, ResolvedPath, WsError};
use client_core::{ClientConfig, ClientEvent};

use crate::support::{TestClient, start_with, ticket};

struct Folders {
    _home: tempfile::TempDir,
    home: PathBuf,
    first: PathBuf,
    second: PathBuf,
}

fn folders() -> Folders {
    let home_dir = tempfile::tempdir().unwrap();
    let home = home_dir.path().canonicalize().unwrap();
    let first = home.join("first");
    let second = home.join("second");
    std::fs::create_dir_all(first.join("sub")).unwrap();
    std::fs::create_dir_all(&second).unwrap();
    std::fs::write(first.join("notes.txt"), "hello").unwrap();
    Folders {
        _home: home_dir,
        home,
        first,
        second,
    }
}

fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// A zsh pane that printed `notes.txt` in `first`, then moved to `second`.
async fn printed_then_moved(
    state: &Path,
    folders: &Folders,
) -> Option<(daemon::Daemon, TestClient, PaneId, CommandMark)> {
    let zsh = PathBuf::from("/bin/zsh");
    if !zsh.exists() {
        return None;
    }
    let home = text(&folders.home);
    let allowed = folders.home.clone();
    let daemon = start_with(state, move |config| {
        config.shell = Some(zsh);
        config.pane_env = vec![
            ("HOME".into(), home.clone()),
            ("PS1".into(), "$ ".into()),
            ("ZDOTDIR".into(), home),
        ];
        config.fs_allow.push(allowed);
        config.long_command = Duration::from_secs(60);
    })
    .await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;
    client.type_line(pane, &format!("cd {}", folders.first.display()));
    client.type_line(pane, "printf 'see notes.txt\\n'");
    client.type_line(pane, &format!("cd {}", folders.second.display()));
    client
        .until("three finished commands", |client| {
            client
                .marks
                .iter()
                .filter(|mark| mark.finished.is_some())
                .count()
                >= 3
        })
        .await;
    let printed = client
        .marks
        .iter()
        .filter(|mark| mark.finished.is_some())
        .nth(1)
        .cloned()
        .unwrap();
    Some((daemon, client, pane, printed))
}

fn resolved(path: &Path, found: PathFound) -> ResolvedPath {
    ResolvedPath {
        path: text(path),
        found,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn printed_paths_resolve_in_the_printing_commands_directory() {
    let state = tempfile::tempdir().unwrap();
    let folders = folders();
    let Some((_daemon, client, pane, printed)) = printed_then_moved(state.path(), &folders).await
    else {
        return;
    };
    let notes = folders.first.join("notes.txt");
    let escape = format!("sub/{}etc/hosts", "../".repeat(40));

    let paths = client
        .client
        .resolve_paths(PathQuery {
            pane_id: pane,
            command_id: Some(printed.command_id),
            paths: vec![
                "notes.txt".into(),
                "./sub".into(),
                "../first/./notes.txt".into(),
                "~/first/notes.txt".into(),
                "missing.txt".into(),
                "/etc/hosts".into(),
                escape,
            ],
        })
        .await
        .unwrap();
    assert_eq!(
        paths,
        [
            resolved(&notes, PathFound::File { size: 5 }),
            resolved(&folders.first.join("sub"), PathFound::Dir),
            resolved(&notes, PathFound::File { size: 5 }),
            resolved(&notes, PathFound::File { size: 5 }),
            resolved(&folders.first.join("missing.txt"), PathFound::Missing),
            ResolvedPath {
                path: "/etc/hosts".into(),
                found: PathFound::Denied
            },
            ResolvedPath {
                path: "/etc/hosts".into(),
                found: PathFound::Denied
            },
        ]
    );

    let current = client
        .client
        .resolve_paths(PathQuery {
            pane_id: pane,
            command_id: None,
            paths: vec!["notes.txt".into()],
        })
        .await
        .unwrap();
    assert_eq!(
        current,
        [resolved(
            &folders.second.join("notes.txt"),
            PathFound::Missing
        )]
    );

    let too_many = client
        .client
        .resolve_paths(PathQuery {
            pane_id: pane,
            command_id: None,
            paths: vec!["a.txt".into(); PathQuery::MAX_PATHS + 1],
        })
        .await;
    assert!(matches!(too_many, Err(WsError::Invalid(_))), "{too_many:?}");

    let unknown = client
        .client
        .resolve_paths(PathQuery {
            pane_id: PaneId(9999),
            command_id: None,
            paths: vec!["notes.txt".into()],
        })
        .await;
    assert!(matches!(unknown, Err(WsError::NotFound(_))), "{unknown:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn links_of_earlier_commands_resolve_where_they_ran() {
    let state = tempfile::tempdir().unwrap();
    let folders = folders();
    let Some((_daemon, mut client, pane, _)) = printed_then_moved(state.path(), &folders).await
    else {
        return;
    };
    let id = client.client.links(pane, 3);
    let ClientEvent::Links { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    let links = result.unwrap();
    assert!(
        links
            .links
            .iter()
            .any(|link| link.target == text(&folders.first.join("notes.txt"))
                && link.exists == Some(true)),
        "{links:#?}"
    );
}
