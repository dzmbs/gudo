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
    PrMerge, PrState, RepoSnapshot, ScriptRun, TaskCreate, WorktreeSettings, WsError,
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

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn run_git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
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
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// `home/repo` with two commits, pushed to `home/origin.git`, plus one local commit (ahead 1).
fn repo(home: &Path, config: Option<&str>) -> PathBuf {
    let origin = home.join("origin.git");
    run_git(home, &["init", "-q", "--bare", &s(&origin)]);
    let repo = home.join("repo");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    run_git(&repo, &["init", "-q"]);
    std::fs::write(repo.join("src/a.rs"), "fn a() {}\nfn b() {}\nfn c() {}\n").unwrap();
    if let Some(config) = config {
        std::fs::write(repo.join(".unnamed.json"), config).unwrap();
    }
    run_git(&repo, &["add", "-A"]);
    run_git(&repo, &["commit", "-q", "-m", "init"]);
    run_git(&repo, &["remote", "add", "origin", &s(&origin)]);
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
    start_with(state, move |c| {
        c.pane_env
            .push(("HOME".into(), home.to_string_lossy().into_owned()));
        c.fs_allow.push(home.clone());
        c.worktree_root = Some(home.join("worktrees"));
        c.repos.gh = Some(gh.unwrap_or_else(|| home.join("no-such-gh")));
        c.repos.debounce = Duration::from_millis(100);
        c.repos.poll = Duration::from_millis(700);
        c.repos.pr_poll = Duration::from_millis(500);
    })
    .await
}

/// A client asking for the repository snapshot, with its workspace pushes.
async fn watcher(daemon: &Daemon) -> (TestClient, UnboundedReceiver<WorkspaceEvent>) {
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    config.repo_status = true;
    let mut c = TestClient::connect_with(&ticket(daemon), config, ConnectOptions::default());
    let (listener, events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);
    c.until("connected", |c| c.connected > 0).await;
    (c, events)
}

/// Opens a tab with a shell in `dir`; its pane.
async fn tab_in(c: &mut TestClient, dir: &Path) -> PaneId {
    let session = c.layout.as_ref().unwrap().session_id;
    match c
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Shell { cwd: Some(s(dir)) },
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
    let (mut c, mut events) = watcher(&daemon).await;
    c.attach_and_follow().await;
    let first = tab_in(&mut c, &repo).await;
    let snap = snapshot_where(&mut events, "the main worktree", |s| {
        s.panes.iter().any(|p| p.pane_id == first)
            && s.worktrees.iter().any(|w| w.main)
            && s.gh != GhStatus::Unknown
    })
    .await;
    let main = snap.worktrees.iter().find(|w| w.main).unwrap();
    assert_eq!(main.repo_name, "repo");
    assert_eq!(main.branch.as_deref(), Some("main"));
    assert_eq!(main.upstream.as_deref(), Some("origin/main"));
    assert_eq!((main.ahead, main.behind), (1, 0));
    assert!(!main.dirty);
    assert_eq!(
        snap.gh,
        GhStatus::Ready {
            account: Some("octo".into())
        }
    );

    // New task: worktree on a branch named after the task, setup first, then a shell.
    let session = c.layout.as_ref().unwrap().session_id;
    let task = c
        .client
        .task_create(TaskCreate {
            repo: s(&repo),
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
    let wt = PathBuf::from(&task.worktree.path);
    assert!(wt.starts_with(home.join("worktrees/repo")), "{wt:?}");
    let setup_done = wt.join(".setup-done");
    tokio::time::timeout(Duration::from_secs(10), async {
        while !setup_done.exists() {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("setup ran in the new tab");

    // Changes: a new file (2 lines, plus the setup file's 1) and an edit (-1 +1).
    std::fs::write(wt.join("new.txt"), "one\ntwo\n").unwrap();
    std::fs::write(wt.join("src/a.rs"), "fn a() {}\nfn B() {}\nfn c() {}\n").unwrap();
    let snap = snapshot_where(&mut events, "the task's changes and pull request", |s| {
        s.worktrees.iter().any(|w| {
            w.path == task.worktree.path && w.added == 4 && w.removed == 1 && w.pr.is_some()
        }) && s.panes.iter().any(|p| p.pane_id == task.pane_id)
    })
    .await;
    let w = snap
        .worktrees
        .iter()
        .find(|w| w.path == task.worktree.path)
        .unwrap();
    assert!(w.dirty && w.managed && !w.main);
    assert_eq!(w.name, "quiet-otter");
    assert_eq!(w.changed_files, 3);
    assert_eq!(w.scripts.len(), 1);
    assert_eq!(
        w.hooks.setup.as_deref(),
        Some("echo setup-ran > .setup-done")
    );
    let pr = w.pr.as_ref().unwrap();
    assert_eq!(
        (pr.number, pr.state, pr.merge_state),
        (42, PrState::Open, MergeState::Unstable)
    );
    assert_eq!(
        pr.checks.iter().map(|c| c.status).collect::<Vec<_>>(),
        [
            CheckStatus::Failure,
            CheckStatus::Pending,
            CheckStatus::Success
        ]
    );
    // Both worktrees of the repository are listed, the main one first.
    let paths: Vec<bool> = snap
        .worktrees
        .iter()
        .filter(|w| w.repo == s(&repo))
        .map(|w| w.main)
        .collect();
    assert_eq!(paths, [true, false]);

    // A commit is seen through the git directory (no file left changed).
    run_git(&wt, &["add", "-A"]);
    run_git(&wt, &["commit", "-q", "-m", "work"]);
    snapshot_where(&mut events, "the commit", |s| {
        s.worktrees
            .iter()
            .any(|w| w.path == task.worktree.path && !w.dirty && w.added == 0)
    })
    .await;

    // Repository script in its own tab.
    let pane = c
        .client
        .script_run(ScriptRun {
            cwd: task.worktree.path.clone(),
            session_id: session,
            name: "Dev".into(),
            command: w.scripts[0].command.clone(),
        })
        .await
        .unwrap();
    c.follow(pane).await;
    c.wait_flat(pane, "SCRIPT-RAN-42").await;

    // Pull request actions.
    c.client
        .pr_rerun_failed(task.worktree.path.clone())
        .await
        .unwrap();
    assert!(
        gh_log(&home).contains("run rerun 777 --failed"),
        "{}",
        gh_log(&home)
    );
    let wrong = c
        .client
        .pr_merge(PrMerge {
            path: task.worktree.path.clone(),
            number: 41,
            strategy: MergeStrategy::Squash,
        })
        .await;
    assert!(matches!(wrong, Err(WsError::Conflict(_))), "{wrong:?}");
    let merged = c
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
    let snap = snapshot_where(&mut events, "the merge", |s| {
        s.worktrees.iter().any(|w| {
            w.path == task.worktree.path
                && w.pr.as_ref().is_some_and(|p| p.state == PrState::Merged)
        })
    })
    .await;
    let w = snap
        .worktrees
        .iter()
        .find(|w| w.path == task.worktree.path)
        .unwrap();
    assert!(w.merged_at.is_some(), "the auto-delete clock started");

    // A pull request that is blocked is refused before gh is asked to merge.
    pr_fixture(&home, "quiet-otter", 42, "OPEN", "BLOCKED");
    let blocked = c
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
    let (mut c, mut events) = watcher(&daemon).await;
    let first = c.attach_and_follow().await;
    let session = c.layout.as_ref().unwrap().session_id;
    let task = c
        .client
        .task_create(TaskCreate {
            repo: s(&repo),
            session_id: session,
            name: "Brave Fox".into(),
            branch: None,
            base: None,
            agent: None,
        })
        .await
        .unwrap();
    assert_eq!(task.worktree.branch.as_deref(), Some("brave-fox"));
    let wt = PathBuf::from(&task.worktree.path);
    let snap = snapshot_where(&mut events, "the task", |s| {
        s.panes.iter().any(|p| p.pane_id == task.pane_id) && s.gh != GhStatus::Unknown
    })
    .await;
    assert_eq!(snap.gh, GhStatus::Missing);
    let _ = first;

    std::fs::write(wt.join("src/a.rs"), "changed\n").unwrap();
    std::fs::write(wt.join("notes.md"), "keep me\n").unwrap();
    let refused = c
        .client
        .worktree_archive(task.worktree.path.clone(), false)
        .await;
    assert!(matches!(refused, Err(WsError::Conflict(_))), "{refused:?}");
    assert!(wt.exists());
    c.client
        .worktree_archive(task.worktree.path.clone(), true)
        .await
        .unwrap();
    assert!(!wt.exists());
    // The branch and the archive refs stay.
    run_git(&repo, &["rev-parse", "--verify", "refs/heads/brave-fox"]);
    let refs = run_git(
        &repo,
        &["for-each-ref", "--format=%(refname)", "refs/unnamed/"],
    );
    assert!(refs.contains("refs/unnamed/archived/1"), "{refs}");
    assert!(refs.contains("refs/unnamed/archived/1/changes"), "{refs}");
    let archived = c.client.worktree_archived(Some(s(&repo))).await.unwrap();
    assert_eq!(archived.len(), 1);
    assert!(archived[0].saved_changes);
    assert_eq!(archived[0].branch.as_deref(), Some("brave-fox"));

    let back = c.client.worktree_restore(archived[0].id).await.unwrap();
    assert_eq!(back.path, task.worktree.path);
    assert_eq!(
        std::fs::read_to_string(wt.join("notes.md")).unwrap(),
        "keep me\n"
    );
    assert_eq!(
        std::fs::read_to_string(wt.join("src/a.rs")).unwrap(),
        "changed\n"
    );
    // Uncommitted again, on the branch, and the refs are gone.
    assert_eq!(run_git(&wt, &["branch", "--show-current"]), "brave-fox");
    let status = run_git(&wt, &["status", "--porcelain"]);
    assert!(
        status.contains("M src/a.rs") && status.contains("?? notes.md"),
        "{status}"
    );
    assert_eq!(
        run_git(
            &repo,
            &["for-each-ref", "--format=%(refname)", "refs/unnamed/"]
        ),
        ""
    );
    assert!(c.client.worktree_archived(None).await.unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn merged_worktrees_are_deleted_after_n_days_unless_dirty() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = repo(&home, Some(r#"{"teardown":"touch ../teardown-ran"}"#));
    let gh = fake_gh(&home);
    let homec = home.clone();
    let daemon = start_with(&state, move |c| {
        c.pane_env
            .push(("HOME".into(), homec.to_string_lossy().into_owned()));
        c.fs_allow.push(homec.clone());
        c.worktree_root = Some(homec.join("worktrees"));
        c.repos.gh = Some(gh);
        c.repos.sweep = Duration::from_millis(300);
        c.repos.day = Duration::from_millis(100);
    })
    .await;
    // A client without the repository capability: the sweep runs anyway.
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.until("connected", |c| c.connected > 0).await;
    c.attach_and_follow().await;
    assert_eq!(
        c.client.worktree_settings(None).await.unwrap(),
        WorktreeSettings {
            auto_delete_merged_days: 7
        }
    );
    c.client
        .worktree_settings(Some(WorktreeSettings {
            auto_delete_merged_days: 2,
        }))
        .await
        .unwrap();
    let mk = |branch: &str| client_core::proto::WorktreeCreate {
        repo: s(&repo),
        branch: Some(branch.into()),
        base: None,
        path: None,
    };
    let clean = c.client.worktree_create(mk("done-clean")).await.unwrap();
    let dirty = c.client.worktree_create(mk("done-dirty")).await.unwrap();
    let open = c.client.worktree_create(mk("still-open")).await.unwrap();
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
    plain.until("connected", |c| c.connected > 0).await;
    let (mut c, mut events) = watcher(&daemon).await;
    c.attach_and_follow().await;
    let pane = tab_in(&mut c, &repo).await;
    snapshot_where(&mut events, "the pane in the repo", |s| {
        s.panes.iter().any(|p| p.pane_id == pane)
    })
    .await;
    // Explicit refresh answers with the same picture.
    let snap = c.client.repo_refresh(None).await.unwrap();
    assert!(snap.panes.iter().any(|p| p.pane_id == pane));
    tokio::time::sleep(Duration::from_millis(300)).await;
    while let Ok(e) = plain_events.try_recv() {
        assert!(!matches!(e, WorkspaceEvent::Repos { .. }), "{e:?}");
    }
}
