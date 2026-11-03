//! The git-native workspace end to end, on real temporary repositories with a fake `gh`
//! that answers from fixture JSON: the `Repos` push (panes → worktrees, branches,
//! ahead/behind, `+added −removed`, dirty, pull requests and checks), new tasks with setup
//! scripts, repository scripts, pull request actions, archive and restore, and auto-delete of
//! merged worktrees.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use client_core::proto::{
    CheckStatus, GhStatus, LayoutOp, MergeState, MergeStrategy, OpOutcome, PaneId, PaneLaunch,
    PrMerge, PrState, RepoHooksFor, RepoSnapshot, Roles, Scope, ScriptRun, TaskCreate, UnixMillis,
    WorktreeSettings, WsError,
};
use client_core::{ClientConfig, ConnectOptions, RelayMode, WorkspaceEvent, WorkspaceEventQueue};
use daemon::Daemon;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TestClient, start_with, ticket};

fn canonical_tempdir() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().canonicalize().unwrap();
    (dir, path)
}

fn text_of(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn run_git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .current_dir(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "init.defaultBranch=main",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// `home/repo` with two commits, pushed to `home/origin.git`, plus one local commit (ahead 1).
fn repo(home: &Path, config: Option<&str>) -> PathBuf {
    let origin = home.join("origin.git");
    run_git(home, &["init", "-q", "--bare", &text_of(&origin)]);
    let repo = home.join("repo");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    run_git(&repo, &["init", "-q"]);
    std::fs::write(repo.join("src/a.rs"), "fn a() {}\nfn b() {}\nfn c() {}\n").unwrap();
    if let Some(config) = config {
        std::fs::write(repo.join(".gudo.json"), config).unwrap();
    }
    run_git(&repo, &["add", "-A"]);
    run_git(&repo, &["commit", "-q", "-m", "init"]);
    run_git(&repo, &["remote", "add", "origin", &text_of(&origin)]);
    run_git(&repo, &["push", "-q", "-u", "origin", "main"]);
    std::fs::write(repo.join("src/b.rs"), "fn d() {}\n").unwrap();
    run_git(&repo, &["add", "-A"]);
    run_git(&repo, &["commit", "-q", "-m", "local"]);
    repo
}

/// A fake `gh`: `auth status` succeeds, `pr view <branch>` prints `fixtures/pr-<branch>.json`
/// (or "no pull requests found"), `pr merge` marks the fixture merged, everything is logged
/// to `fixtures/log`.
fn fake_gh(dir: &Path) -> PathBuf {
    let fixtures = dir.join("fixtures");
    std::fs::create_dir_all(&fixtures).unwrap();
    let gh = dir.join("gh");
    let script = format!(
        r#"#!/bin/sh
F='{fx}'
echo "$*" >> "$F/log"
case "$1 $2" in
  "auth status") echo "github.com"; echo "  ✓ Logged in to github.com account octo (keyring)"; exit 0 ;;
  "pr view")
    b=$(printf %s "$3" | tr / -)
    if [ -f "$F/pr-$b.json" ]; then cat "$F/pr-$b.json"; exit 0; fi
    echo "no pull requests found for branch \"$3\"" >&2; exit 1 ;;
  "pr merge")
    for f in "$F"/pr-*.json; do
      if grep -q "\"number\":$3," "$f"; then
        sed 's/"state":"OPEN"/"state":"MERGED"/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      fi
    done
    exit 0 ;;
  "run rerun") exit 0 ;;
  "pr checkout")
    if [ "$4" = "--branch" ]; then git checkout -q -b "$5"; else git checkout -q -b "pr-head-$3"; fi
    exit $? ;;
esac
echo "fake gh: unsupported $*" >&2
exit 2
"#,
        fx = fixtures.display()
    );
    std::fs::write(&gh, script).unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    gh
}

fn pr_fixture(dir: &Path, branch: &str, number: u32, state: &str, merge_state: &str) {
    let json = format!(
        r#"{{"number":{number},"title":"Task {branch}","state":"{state}","isDraft":false,"headRefName":"{branch}","additions":12,"deletions":3,"mergeStateStatus":"{merge_state}","url":"https://github.com/o/r/pull/{number}","statusCheckRollup":[{{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/776/job/1","workflowName":"CI"}},{{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/777/job/2","workflowName":"CI"}},{{"__typename":"StatusContext","context":"deploy","state":"PENDING","targetUrl":"https://x"}}]}}"#
    );
    std::fs::write(
        dir.join("fixtures")
            .join(format!("pr-{}.json", branch.replace('/', "-"))),
        json,
    )
    .unwrap();
}

fn gh_log(dir: &Path) -> String {
    std::fs::read_to_string(dir.join("fixtures/log")).unwrap_or_default()
}

async fn start(state: &Path, home: &Path, gh: Option<PathBuf>) -> Daemon {
    let home = home.to_owned();
    start_with(state, move |config| {
        config
            .pane_env
            .push(("HOME".into(), home.to_string_lossy().into_owned()));
        config.fs_allow.push(home.clone());
        config.worktree_root = Some(home.join("worktrees"));
        config.repos.gh = Some(gh.unwrap_or_else(|| home.join("no-such-gh")));
        config.repos.debounce = Duration::from_millis(100);
        config.repos.poll = Duration::from_millis(700);
        config.repos.pr_poll = Duration::from_millis(500);
    })
    .await
}

/// A client asking for the repository snapshot, with its workspace pushes.
async fn watcher(daemon: &Daemon) -> (TestClient, UnboundedReceiver<WorkspaceEvent>) {
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    config.repo_status = true;
    let mut client = TestClient::connect_with(&ticket(daemon), config, ConnectOptions::default());
    let (listener, events) = WorkspaceEventQueue::channel();
    client.client.set_workspace_listener(listener);
    client
        .until("connected", |client| client.connected > 0)
        .await;
    (client, events)
}

/// Opens a tab with a shell in `dir`; its pane.
async fn tab_in(client: &mut TestClient, dir: &Path) -> PaneId {
    let session = client.layout.as_ref().unwrap().session_id;
    match client
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Shell {
                cwd: Some(text_of(dir)),
            },
        })
        .await
    {
        OpOutcome::TabCreated { pane_id, .. } => pane_id,
        other => panic!("{other:?}"),
    }
}

/// Waits for a `Repos` push that satisfies `pick`.
async fn snapshot_where(
    events: &mut UnboundedReceiver<WorkspaceEvent>,
    what: &str,
    mut pick: impl FnMut(&RepoSnapshot) -> bool,
) -> RepoSnapshot {
    let mut last = None;
    let found = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if let WorkspaceEvent::Repos { snapshot } = events.recv().await.expect("listener") {
                if pick(&snapshot) {
                    return snapshot;
                }
                last = Some(snapshot);
            }
        }
    })
    .await;
    found.unwrap_or_else(|_| panic!("timed out waiting for {what}; last snapshot: {last:#?}"))
}

#[tokio::test(flavor = "multi_thread")]
async fn snapshot_follows_panes_branches_diffs_and_pull_requests() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let config = r#"{"setup":"echo setup-ran > .setup-done","scripts":[{"name":"Dev","command":"echo SCRIPT-RAN-$((40+2))","icon":"play","tint":"green","default":true}]}"#;
    let repo = repo(&home, Some(config));
    let gh = fake_gh(&home);
    pr_fixture(&home, "quiet-otter", 42, "OPEN", "UNSTABLE");
    let daemon = start(&state, &home, Some(gh)).await;
    let (mut client, mut events) = watcher(&daemon).await;
    client.attach_and_follow().await;
    let first = tab_in(&mut client, &repo).await;
    let snapshot = snapshot_where(&mut events, "the main worktree", |snapshot| {
        snapshot.panes.iter().any(|pane| pane.pane_id == first)
            && snapshot.worktrees.iter().any(|worktree| worktree.main)
            && snapshot.gh != GhStatus::Unknown
    })
    .await;
    let main = snapshot
        .worktrees
        .iter()
        .find(|worktree| worktree.main)
        .unwrap();
    assert_eq!(main.repo_name, "repo");
    assert_eq!(main.branch.as_deref(), Some("main"));
    assert_eq!(main.upstream.as_deref(), Some("origin/main"));
    assert_eq!((main.ahead, main.behind), (1, 0));
    assert!(!main.dirty);
    assert_eq!(
        snapshot.gh,
        GhStatus::Ready {
            account: Some("octo".into())
        }
    );

    // New task: worktree on a branch named after the task, setup first (the owner trusts
    // it), then a shell.
    let session = client.layout.as_ref().unwrap().session_id;
    trust_new_task(&client, &repo).await;
    let task = client
        .client
        .task_create(TaskCreate {
            repo: text_of(&repo),
            session_id: session,
            name: "quiet-otter".into(),
            branch: None,
            base: None,
            agent: None,
        })
        .await
        .unwrap();
    assert_eq!(task.worktree.branch.as_deref(), Some("quiet-otter"));
    assert_eq!(task.setup.as_deref(), Some("echo setup-ran > .setup-done"));
    let worktree_path = PathBuf::from(&task.worktree.path);
    assert!(
        worktree_path.starts_with(home.join("worktrees/repo")),
        "{worktree_path:?}"
    );
    let setup_done = worktree_path.join(".setup-done");
    tokio::time::timeout(Duration::from_secs(10), async {
        while !setup_done.exists() {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("setup ran in the new tab");

    // Changes: a new file (2 lines, plus the setup file's 1) and an edit (-1 +1).
    std::fs::write(worktree_path.join("new.txt"), "one\ntwo\n").unwrap();
    std::fs::write(
        worktree_path.join("src/a.rs"),
        "fn a() {}\nfn B() {}\nfn c() {}\n",
    )
    .unwrap();
    let snapshot = snapshot_where(
        &mut events,
        "the task's changes and pull request",
        |snapshot| {
            snapshot.worktrees.iter().any(|worktree| {
                worktree.path == task.worktree.path
                    && worktree.added == 4
                    && worktree.removed == 1
                    && worktree.pr.is_some()
            }) && snapshot
                .panes
                .iter()
                .any(|pane| pane.pane_id == task.pane_id)
        },
    )
    .await;
    let worktree = snapshot
        .worktrees
        .iter()
        .find(|worktree| worktree.path == task.worktree.path)
        .unwrap();
    assert!(worktree.dirty && worktree.managed && !worktree.main);
    assert_eq!(worktree.name, "quiet-otter");
    assert_eq!(worktree.changed_files, 3);
    assert_eq!(worktree.scripts.len(), 1);
    assert_eq!(
        worktree.hooks.setup.as_deref(),
        Some("echo setup-ran > .setup-done")
    );
    let pr = worktree.pr.as_ref().unwrap();
    assert_eq!(
        (pr.number, pr.state, pr.merge_state),
        (42, PrState::Open, MergeState::Unstable)
    );
    assert_eq!(
        pr.checks
            .iter()
            .map(|check| check.status)
            .collect::<Vec<_>>(),
        [
            CheckStatus::Failure,
            CheckStatus::Pending,
            CheckStatus::Success
        ]
    );
    // Both worktrees of the repository are listed, the main one first.
    let paths: Vec<bool> = snapshot
        .worktrees
        .iter()
        .filter(|worktree| worktree.repo == text_of(&repo))
        .map(|worktree| worktree.main)
        .collect();
    assert_eq!(paths, [true, false]);

    // A commit is seen through the git directory (no file left changed).
    run_git(&worktree_path, &["add", "-A"]);
    run_git(&worktree_path, &["commit", "-q", "-m", "work"]);
    snapshot_where(&mut events, "the commit", |snapshot| {
        snapshot.worktrees.iter().any(|worktree| {
            worktree.path == task.worktree.path && !worktree.dirty && worktree.added == 0
        })
    })
    .await;

    // Repository script in its own tab.
    let pane = client
        .client
        .script_run(ScriptRun {
            cwd: task.worktree.path.clone(),
            session_id: session,
            name: "Dev".into(),
            command: worktree.scripts[0].command.clone(),
        })
        .await
        .unwrap();
    client.follow(pane).await;
    client.wait_flat(pane, "SCRIPT-RAN-42").await;

    // Pull request actions.
    client
        .client
        .pr_rerun_failed(task.worktree.path.clone())
        .await
        .unwrap();
    assert!(
        gh_log(&home).contains("run rerun 777 --failed"),
        "{}",
        gh_log(&home)
    );
    let wrong = client
        .client
        .pr_merge(PrMerge {
            path: task.worktree.path.clone(),
            number: 41,
            strategy: MergeStrategy::Squash,
        })
        .await;
    assert!(matches!(wrong, Err(WsError::Conflict(_))), "{wrong:?}");
    let merged = client
        .client
        .pr_merge(PrMerge {
            path: task.worktree.path.clone(),
            number: 42,
            strategy: MergeStrategy::Squash,
        })
        .await
        .unwrap()
        .unwrap();
    assert_eq!(merged.state, PrState::Merged);
    assert!(gh_log(&home).contains("pr merge 42 --squash"));
    let snapshot = snapshot_where(&mut events, "the merge", |snapshot| {
        snapshot.worktrees.iter().any(|worktree| {
            worktree.path == task.worktree.path
                && worktree
                    .pr
                    .as_ref()
                    .is_some_and(|pr| pr.state == PrState::Merged)
        })
    })
    .await;
    let worktree = snapshot
        .worktrees
        .iter()
        .find(|worktree| worktree.path == task.worktree.path)
        .unwrap();
    assert!(
        worktree.merged_at.is_some(),
        "the auto-delete clock started"
    );

    // A pull request that is blocked is refused before gh is asked to merge.
    pr_fixture(&home, "quiet-otter", 42, "OPEN", "BLOCKED");
    let blocked = client
        .client
        .pr_merge(PrMerge {
            path: task.worktree.path.clone(),
            number: 42,
            strategy: MergeStrategy::Merge,
        })
        .await;
    assert!(
        matches!(&blocked, Err(WsError::Conflict(m)) if m.contains("required reviews")),
        "{blocked:?}"
    );
    assert!(!gh_log(&home).contains("pr merge 42 --merge"));
}

#[tokio::test(flavor = "multi_thread")]
async fn archive_keeps_refs_and_changes_and_restore_brings_them_back() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = repo(&home, None);
    // No gh at all: the snapshot says so once, and nothing else breaks.
    let daemon = start(&state, &home, None).await;
    let (mut client, mut events) = watcher(&daemon).await;
    let first = client.attach_and_follow().await;
    let session = client.layout.as_ref().unwrap().session_id;
    let task = client
        .client
        .task_create(TaskCreate {
            repo: text_of(&repo),
            session_id: session,
            name: "Brave Fox".into(),
            branch: None,
            base: None,
            agent: None,
        })
        .await
        .unwrap();
    assert_eq!(task.worktree.branch.as_deref(), Some("brave-fox"));
    let worktree_path = PathBuf::from(&task.worktree.path);
    let snapshot = snapshot_where(&mut events, "the task", |snapshot| {
        snapshot
            .panes
            .iter()
            .any(|pane| pane.pane_id == task.pane_id)
            && snapshot.gh != GhStatus::Unknown
    })
    .await;
    assert_eq!(snapshot.gh, GhStatus::Missing);
    let _ = first;

    std::fs::write(worktree_path.join("src/a.rs"), "changed\n").unwrap();
    std::fs::write(worktree_path.join("notes.md"), "keep me\n").unwrap();
    let refused = client
        .client
        .worktree_archive(task.worktree.path.clone(), false)
        .await;
    assert!(matches!(refused, Err(WsError::Conflict(_))), "{refused:?}");
    assert!(worktree_path.exists());
    client
        .client
        .worktree_archive(task.worktree.path.clone(), true)
        .await
        .unwrap();
    assert!(!worktree_path.exists());
    // The branch and the archive refs stay.
    run_git(&repo, &["rev-parse", "--verify", "refs/heads/brave-fox"]);
    let refs = run_git(
        &repo,
        &["for-each-ref", "--format=%(refname)", "refs/gudo/"],
    );
    assert!(refs.contains("refs/gudo/archived/1"), "{refs}");
    assert!(refs.contains("refs/gudo/archived/1/changes"), "{refs}");
    let archived = client
        .client
        .worktree_archived(Some(text_of(&repo)))
        .await
        .unwrap();
    assert_eq!(archived.len(), 1);
    assert!(archived[0].saved_changes);
    assert_eq!(archived[0].branch.as_deref(), Some("brave-fox"));

    let back = client
        .client
        .worktree_restore(archived[0].id)
        .await
        .unwrap();
    assert_eq!(back.path, task.worktree.path);
    assert_eq!(
        std::fs::read_to_string(worktree_path.join("notes.md")).unwrap(),
        "keep me\n"
    );
    assert_eq!(
        std::fs::read_to_string(worktree_path.join("src/a.rs")).unwrap(),
        "changed\n"
    );
    // Uncommitted again, on the branch, and the refs are gone.
    assert_eq!(
        run_git(&worktree_path, &["branch", "--show-current"]),
        "brave-fox"
    );
    let status = run_git(&worktree_path, &["status", "--porcelain"]);
    assert!(
        status.contains("M src/a.rs") && status.contains("?? notes.md"),
        "{status}"
    );
    assert_eq!(
        run_git(
            &repo,
            &["for-each-ref", "--format=%(refname)", "refs/gudo/"]
        ),
        ""
    );
    assert!(
        client
            .client
            .worktree_archived(None)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn merged_worktrees_are_deleted_after_n_days_unless_dirty() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = repo(&home, Some(r#"{"teardown":"touch ../teardown-ran"}"#));
    let gh = fake_gh(&home);
    let daemon_home = home.clone();
    let daemon = start_with(&state, move |config| {
        config
            .pane_env
            .push(("HOME".into(), daemon_home.to_string_lossy().into_owned()));
        config.fs_allow.push(daemon_home.clone());
        config.worktree_root = Some(daemon_home.join("worktrees"));
        config.repos.gh = Some(gh);
        config.repos.sweep = Duration::from_millis(300);
        config.repos.day = Duration::from_millis(100);
    })
    .await;
    // A client without the repository capability: the sweep runs anyway.
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    client
        .until("connected", |client| client.connected > 0)
        .await;
    client.attach_and_follow().await;
    assert_eq!(
        client.client.worktree_settings(None).await.unwrap(),
        WorktreeSettings {
            auto_delete_merged_days: 7
        }
    );
    client
        .client
        .worktree_settings(Some(WorktreeSettings {
            auto_delete_merged_days: 2,
        }))
        .await
        .unwrap();
    let worktree_request = |branch: &str| client_core::proto::WorktreeCreate {
        repo: text_of(&repo),
        branch: Some(branch.into()),
        base: None,
        path: None,
    };
    let clean = client
        .client
        .worktree_create(worktree_request("done-clean"))
        .await
        .unwrap();
    let hooks = client
        .client
        .repo_hooks(RepoHooksFor::Worktree {
            path: clean.path.clone(),
        })
        .await
        .unwrap();
    client
        .client
        .repo_trust(hooks.repo, hooks.hash)
        .await
        .unwrap();
    let dirty = client
        .client
        .worktree_create(worktree_request("done-dirty"))
        .await
        .unwrap();
    let open = client
        .client
        .worktree_create(worktree_request("still-open"))
        .await
        .unwrap();
    std::fs::write(PathBuf::from(&dirty.path).join("wip.txt"), "wip\n").unwrap();
    pr_fixture(&home, "done-clean", 1, "MERGED", "UNKNOWN");
    pr_fixture(&home, "done-dirty", 2, "MERGED", "UNKNOWN");
    pr_fixture(&home, "still-open", 3, "OPEN", "CLEAN");

    let clean_path = PathBuf::from(&clean.path);
    tokio::time::timeout(Duration::from_secs(15), async {
        while clean_path.exists() {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("the clean merged worktree was deleted");
    assert!(
        home.join("worktrees/repo/teardown-ran").exists(),
        "teardown ran"
    );
    // A few more sweeps: the dirty and the open ones stay.
    tokio::time::sleep(Duration::from_millis(1200)).await;
    assert!(PathBuf::from(&dirty.path).join("wip.txt").exists());
    assert!(PathBuf::from(&open.path).exists());
    // The branch of the deleted worktree is kept.
    run_git(&repo, &["rev-parse", "--verify", "refs/heads/done-clean"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn clients_without_the_capability_get_no_snapshot() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = repo(&home, None);
    let daemon = start(&state, &home, None).await;
    let mut plain = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let (listener, mut plain_events) = WorkspaceEventQueue::channel();
    plain.client.set_workspace_listener(listener);
    plain
        .until("connected", |client| client.connected > 0)
        .await;
    let (mut client, mut events) = watcher(&daemon).await;
    client.attach_and_follow().await;
    let pane = tab_in(&mut client, &repo).await;
    snapshot_where(&mut events, "the pane in the repo", |snapshot| {
        snapshot.panes.iter().any(|shown| shown.pane_id == pane)
    })
    .await;
    // Explicit refresh answers with the same picture.
    let snapshot = client.client.repo_refresh(None).await.unwrap();
    assert!(snapshot.panes.iter().any(|shown| shown.pane_id == pane));
    tokio::time::sleep(Duration::from_millis(300)).await;
    while let Ok(event) = plain_events.try_recv() {
        assert!(!matches!(event, WorkspaceEvent::Repos { .. }), "{event:?}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_repository_at_home_is_not_tracked() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = repo(&home, None);
    run_git(&home, &["init", "-q"]);
    let notes = home.join("notes");
    std::fs::create_dir_all(&notes).unwrap();
    let daemon = start(&state, &home, None).await;
    let (mut client, mut events) = watcher(&daemon).await;
    client.attach_and_follow().await;
    let in_home = tab_in(&mut client, &notes).await;
    let in_repo = tab_in(&mut client, &repo).await;
    let snapshot = snapshot_where(&mut events, "the pane in the repo", |snapshot| {
        snapshot.panes.iter().any(|pane| pane.pane_id == in_repo)
    })
    .await;
    assert!(
        !snapshot.panes.iter().any(|pane| pane.pane_id == in_home),
        "{snapshot:#?}"
    );
    assert!(
        !snapshot
            .worktrees
            .iter()
            .any(|worktree| Path::new(&worktree.path) == home),
        "{snapshot:#?}"
    );
}

/// Trusts the commands a new task in `repo` would run.
async fn trust_new_task(client: &TestClient, repo: &Path) {
    let hooks = client
        .client
        .repo_hooks(RepoHooksFor::NewTask {
            repo: text_of(repo),
            base: None,
        })
        .await
        .unwrap();
    client
        .client
        .repo_trust(hooks.repo, hooks.hash)
        .await
        .unwrap();
}

/// Waits a moment for `path` to appear.
async fn appears(path: &Path, within: Duration) -> bool {
    tokio::time::timeout(within, async {
        while !path.exists() {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .is_ok()
}

/// A repository's `.gudo.json` commands (a clone, an unpacked archive) run only once the
/// owner trusts exactly them, as VS Code's workspace trust or `direnv allow`; guests cannot
/// trust them, and changed commands are asked about again.
#[tokio::test(flavor = "multi_thread")]
async fn repository_commands_run_only_once_the_owner_trusts_them() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let config = r#"{"setup":"echo setup-ran > .setup-done","teardown":"touch ../teardown-ran"}"#;
    let repo = repo(&home, Some(config));
    let daemon = start(&state, &home, None).await;
    let (mut client, _events) = watcher(&daemon).await;
    client.attach_and_follow().await;
    let session = client.layout.as_ref().unwrap().session_id;
    let task = |name: &str| TaskCreate {
        repo: text_of(&repo),
        session_id: session,
        name: name.into(),
        branch: None,
        base: None,
        agent: None,
    };
    let new_task = RepoHooksFor::NewTask {
        repo: text_of(&repo),
        base: None,
    };
    let teardown_ran = home.join("worktrees/repo/teardown-ran");

    let features = client.client.daemon_info().unwrap().features;
    assert!(features.contains(client_core::proto::DaemonFeatures::REPO_TRUST));
    let asked = client.client.repo_hooks(new_task.clone()).await.unwrap();
    assert!(!asked.trusted);
    assert_eq!(
        asked.hooks.setup.as_deref(),
        Some("echo setup-ran > .setup-done")
    );
    assert_eq!(
        asked.hooks.teardown.as_deref(),
        Some("touch ../teardown-ran")
    );
    assert_eq!(PathBuf::from(&asked.repo), repo);

    // Untrusted: the task opens, but neither its setup nor its teardown runs.
    let first = client.client.task_create(task("first")).await.unwrap();
    assert_eq!(first.setup, None);
    let first_path = PathBuf::from(&first.worktree.path);
    assert!(!appears(&first_path.join(".setup-done"), Duration::from_secs(2)).await);
    client
        .client
        .worktree_archive(first.worktree.path.clone(), true)
        .await
        .unwrap();
    assert!(!teardown_ran.exists(), "untrusted teardown ran");

    // A guest cannot trust them, even one holding the owner role.
    let mut spec = client_core::grants::GrantSpec::new(Roles::OWNER, Scope::Daemon);
    spec.label = "bob".into();
    spec.expires = Some(UnixMillis(client_core::now_millis().0 + 3_600_000));
    let invite = client
        .client
        .create_invite(spec, "bob".into())
        .await
        .unwrap();
    let mut bob = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    bob.client.attach(None);
    bob.until("guest layout", |client| client.layout.is_some())
        .await;
    assert!(matches!(
        bob.client
            .repo_trust(asked.repo.clone(), asked.hash.clone())
            .await,
        Err(WsError::Denied(_))
    ));
    assert!(
        !client
            .client
            .repo_hooks(new_task.clone())
            .await
            .unwrap()
            .trusted
    );

    // The owner trusts them: they run.
    client
        .client
        .repo_trust(asked.repo.clone(), asked.hash.clone())
        .await
        .unwrap();
    assert!(
        client
            .client
            .repo_hooks(new_task.clone())
            .await
            .unwrap()
            .trusted
    );
    let second = client.client.task_create(task("second")).await.unwrap();
    assert_eq!(
        second.setup.as_deref(),
        Some("echo setup-ran > .setup-done")
    );
    let second_path = PathBuf::from(&second.worktree.path);
    assert!(appears(&second_path.join(".setup-done"), Duration::from_secs(10)).await);
    client
        .client
        .worktree_archive(second.worktree.path.clone(), true)
        .await
        .unwrap();
    assert!(teardown_ran.exists(), "trusted teardown ran");

    // Changed commands (a pull, a new branch) are untrusted again.
    std::fs::write(
        repo.join(".gudo.json"),
        r#"{"setup":"echo setup-ran > .setup-done; touch ../pwned"}"#,
    )
    .unwrap();
    run_git(&repo, &["commit", "-qam", "change setup"]);
    let changed = client.client.repo_hooks(new_task.clone()).await.unwrap();
    assert!(!changed.trusted);
    assert_ne!(changed.hash, asked.hash);
    let third = client.client.task_create(task("third")).await.unwrap();
    assert_eq!(third.setup, None);
    assert!(!appears(&home.join("worktrees/repo/pwned"), Duration::from_secs(2)).await);
}
