//! Workflows end to end: a pane in a repository lists the repository's workflow files and the
//! global ones, a pane outside lists only the global ones, editing a file pushes
//! `WorkflowsChanged`, saving writes a new file (never replacing one) that the next list
//! shows.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use client_core::proto::{
    LayoutOp, OpOutcome, PaneId, PaneLaunch, WorkflowArgument, WorkflowDraft, WorkflowList,
    WorkflowSave, WorkflowScope, WsError,
};
use client_core::{ClientConfig, RelayMode, WorkspaceEvent, WorkspaceEventQueue};
use daemon::Daemon;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TestClient, start_with, ticket};

fn canonical_tempdir() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().canonicalize().unwrap();
    (dir, path)
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn workflow_dir(root: &Path) -> PathBuf {
    root.join(format!(".{}", brand::DIR_NAME)).join("workflows")
}

fn global_dir(home: &Path) -> PathBuf {
    home.join(".config").join(brand::DIR_NAME).join("workflows")
}

async fn start(state: &Path, home: &Path) -> Daemon {
    let home = home.to_owned();
    start_with(state, move |config| {
        config.pane_env.push(("HOME".into(), path_string(&home)));
        config
            .pane_env
            .retain(|(name, _)| name != "XDG_CONFIG_HOME");
        config
            .pane_env
            .push(("XDG_CONFIG_HOME".into(), String::new()));
        config.fs_allow.push(home.clone());
    })
    .await
}

async fn client(daemon: &Daemon) -> (TestClient, UnboundedReceiver<WorkspaceEvent>) {
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    let mut client = TestClient::connect_with(
        &ticket(daemon),
        config,
        client_core::ConnectOptions::default(),
    );
    let (listener, events) = WorkspaceEventQueue::channel();
    client.client.set_workspace_listener(listener);
    client
        .until("connected", |client| client.connected > 0)
        .await;
    client.attach_and_follow().await;
    (client, events)
}

async fn tab_in(client: &mut TestClient, dir: &Path) -> PaneId {
    let session = client.layout.as_ref().unwrap().session_id;
    match client
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Shell {
                cwd: Some(path_string(dir)),
            },
        })
        .await
    {
        OpOutcome::TabCreated { pane_id, .. } => pane_id,
        other => panic!("{other:?}"),
    }
}

async fn changed(events: &mut UnboundedReceiver<WorkspaceEvent>, after: u64) -> u64 {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if let WorkspaceEvent::WorkflowsChanged { rev } = events.recv().await.unwrap()
                && rev > after
            {
                return rev;
            }
        }
    })
    .await
    .expect("a WorkflowsChanged push")
}

fn names(list: &WorkflowList) -> Vec<(&str, WorkflowScope)> {
    list.workflows
        .iter()
        .map(|workflow| (workflow.name.as_str(), workflow.scope))
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn lists_watches_and_saves_workflows() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = home.join("proj");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    let git = Command::new("git")
        .args(["init", "-q"])
        .current_dir(&repo)
        .status()
        .unwrap();
    assert!(git.success());
    std::fs::create_dir_all(workflow_dir(&repo)).unwrap();
    std::fs::write(
        workflow_dir(&repo).join("checkout.yaml"),
        "---\nname: Check out\ncommand: git checkout {{branch}}\ndescription: Switch\narguments:\n  - name: branch\n    default_value: main\ntags: [git]\nshells: []\n",
    )
    .unwrap();
    std::fs::write(workflow_dir(&repo).join("broken.yaml"), "name: [\n").unwrap();
    std::fs::create_dir_all(global_dir(&home)).unwrap();
    std::fs::write(
        global_dir(&home).join("disk.yml"),
        "name: Disk usage\ncommand: du -sh {{path}}\n",
    )
    .unwrap();
    let outside = home.join("elsewhere");
    std::fs::create_dir_all(&outside).unwrap();

    let daemon = start(&state, &home).await;
    let (mut client, mut events) = client(&daemon).await;
    let in_repo = tab_in(&mut client, &repo.join("src")).await;
    let not_in_repo = tab_in(&mut client, &outside).await;

    let list = client.client.workflow_list(Some(in_repo)).await.unwrap();
    assert_eq!(
        names(&list),
        [
            ("Check out", WorkflowScope::Repo),
            ("Disk usage", WorkflowScope::Global)
        ]
    );
    assert_eq!(list.repo.as_deref(), Some(path_string(&repo).as_str()));
    assert_eq!(list.repo_name.as_deref(), Some("proj"));
    assert_eq!(list.problems.len(), 1, "{:?}", list.problems);
    assert!(list.problems[0].path.ends_with("broken.yaml"));
    let checkout = &list.workflows[0];
    assert_eq!(checkout.arguments[0].default_value.as_deref(), Some("main"));
    // A placeholder without an `arguments` entry still gets one.
    assert_eq!(list.workflows[1].arguments[0].name, "path");

    let list = client
        .client
        .workflow_list(Some(not_in_repo))
        .await
        .unwrap();
    assert_eq!(names(&list), [("Disk usage", WorkflowScope::Global)]);
    assert_eq!(list.repo, None);
    let global_only = client.client.workflow_list(None).await.unwrap();
    assert_eq!(names(&global_only), [("Disk usage", WorkflowScope::Global)]);

    // Editing a listed file pushes a change, and the next list has it.
    let rev = global_only.rev;
    tokio::time::sleep(Duration::from_millis(300)).await;
    std::fs::write(
        workflow_dir(&repo).join("checkout.yaml"),
        "name: Switch branch\ncommand: git switch {{branch}}\n",
    )
    .unwrap();
    let rev = changed(&mut events, rev).await;
    let list = client.client.workflow_list(Some(in_repo)).await.unwrap();
    assert!(list.rev >= rev);
    assert_eq!(list.workflows[0].name, "Switch branch");

    // A new global directory file is noticed too.
    std::fs::write(
        global_dir(&home).join("ports.yaml"),
        "name: Ports\ncommand: lsof -i :{{port}}\n",
    )
    .unwrap();
    let rev = changed(&mut events, rev).await;

    // Saving: a new file in the repository, never replacing one.
    let draft = WorkflowDraft {
        name: "Run tests".into(),
        command: "cargo test -p {{crate}} -- {{filter}}".into(),
        description: Some("From the last command".into()),
        tags: vec![],
        arguments: vec![WorkflowArgument {
            name: "crate".into(),
            description: None,
            default_value: Some("daemon".into()),
            raw: false,
        }],
        shells: vec![],
    };
    let save = |scope| WorkflowSave {
        scope,
        pane_id: Some(in_repo),
        workflow: draft.clone(),
    };
    let saved = client
        .client
        .workflow_save(save(WorkflowScope::Repo))
        .await
        .unwrap();
    assert_eq!(
        Path::new(&saved.path),
        workflow_dir(&repo).join("run-tests.yaml")
    );
    assert_eq!(
        saved.arguments.len(),
        2,
        "crate, then filter from the command"
    );
    let again = client
        .client
        .workflow_save(save(WorkflowScope::Repo))
        .await
        .unwrap();
    assert_eq!(
        Path::new(&again.path),
        workflow_dir(&repo).join("run-tests-2.yaml")
    );
    changed(&mut events, rev).await;
    let list = client.client.workflow_list(Some(in_repo)).await.unwrap();
    assert_eq!(
        list.workflows
            .iter()
            .filter(|workflow| workflow.name == "Run tests")
            .count(),
        2
    );

    let global = client
        .client
        .workflow_save(save(WorkflowScope::Global))
        .await
        .unwrap();
    assert!(Path::new(&global.path).starts_with(global_dir(&home)));

    // A pane outside a repository cannot save a repository workflow.
    let refused = client
        .client
        .workflow_save(WorkflowSave {
            scope: WorkflowScope::Repo,
            pane_id: Some(not_in_repo),
            workflow: draft.clone(),
        })
        .await;
    assert!(matches!(refused, Err(WsError::NotFound(_))), "{refused:?}");
    let empty = client
        .client
        .workflow_save(WorkflowSave {
            scope: WorkflowScope::Global,
            pane_id: None,
            workflow: WorkflowDraft {
                command: " ".into(),
                ..draft
            },
        })
        .await;
    assert!(matches!(empty, Err(WsError::Invalid(_))), "{empty:?}");
}

/// The repository's workflow directory created after the first list is picked up (the
/// watch sits on the repository until it exists).
#[tokio::test(flavor = "multi_thread")]
async fn notices_a_new_workflow_directory() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = home.join("proj");
    std::fs::create_dir_all(&repo).unwrap();
    assert!(
        Command::new("git")
            .args(["init", "-q"])
            .current_dir(&repo)
            .status()
            .unwrap()
            .success()
    );
    let daemon = start(&state, &home).await;
    let (mut client, mut events) = client(&daemon).await;
    let pane = tab_in(&mut client, &repo).await;
    let list = client.client.workflow_list(Some(pane)).await.unwrap();
    assert!(list.workflows.is_empty());
    tokio::time::sleep(Duration::from_millis(300)).await;
    std::fs::create_dir_all(workflow_dir(&repo)).unwrap();
    let rev = changed(&mut events, list.rev).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    std::fs::write(
        workflow_dir(&repo).join("hello.yaml"),
        "name: Hello\ncommand: echo hello\n",
    )
    .unwrap();
    changed(&mut events, rev).await;
    let list = client.client.workflow_list(Some(pane)).await.unwrap();
    assert_eq!(names(&list), [("Hello", WorkflowScope::Repo)]);
}
