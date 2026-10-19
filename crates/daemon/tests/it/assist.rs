//! prompt state and the input line (D2), atomic submit (D3), history (D4), completion with a
//! latency benchmark (D5), file search (D7), blocked-agent options (D9), and the roles each
//! request needs.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use client_core::proto::{
    AgentKind, AssistError, Axis, BlockedChoice, BlockedSource, CompletionKind, HistoryQuery,
    InputDoubt, LayoutOp, OpOutcome, OptionId, PaneId, PaneLaunch, ProgramProfile, PromptPhase,
    PromptState, Roles, Scope, ShellKind, UnixMillis,
};
use client_core::{AssistEvent, AssistEventQueue, ClientConfig, GrantSpec, now_millis};
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TestClient, start_with, ticket};

fn find(candidates: &[&str]) -> Option<PathBuf> {
    candidates.iter().map(PathBuf::from).find(|p| p.exists())
}

fn zsh() -> Option<PathBuf> {
    find(&["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh"])
}

/// A bash with automatic integration (4.4+; macOS's /bin/bash is 3.2).
fn bash() -> Option<PathBuf> {
    let candidates: &[&str] = if cfg!(target_os = "macos") {
        &["/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
    } else {
        &["/bin/bash", "/usr/bin/bash"]
    };
    find(candidates)
}

fn fish() -> Option<PathBuf> {
    find(&[
        "/usr/bin/fish",
        "/opt/homebrew/bin/fish",
        "/usr/local/bin/fish",
    ])
}

/// A home directory with a `work` folder, and a daemon running `shell` there.
struct Env {
    _dir: tempfile::TempDir,
    _home: tempfile::TempDir,
    work: PathBuf,
    daemon: daemon::Daemon,
}

impl Env {
    async fn new(shell: &Path, setup: impl FnOnce(&Path)) -> Self {
        Self::with_config(shell, setup, |_| {}).await
    }

    async fn with_config(
        shell: &Path,
        setup: impl FnOnce(&Path),
        edit: impl FnOnce(&mut daemon::Config),
    ) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let work = home.path().canonicalize().unwrap().join("work");
        std::fs::create_dir_all(&work).unwrap();
        std::fs::write(work.join("notes.txt"), "").unwrap();
        setup(home.path());
        let shell = shell.to_owned();
        let home_str = home.path().to_string_lossy().into_owned();
        let daemon = start_with(dir.path(), move |c| {
            c.shell = Some(shell);
            c.pane_env = vec![
                ("HOME".into(), home_str.clone()),
                ("PS1".into(), "$ ".into()),
                ("ZDOTDIR".into(), home_str),
                // Keep fish's greeting and the user's universal variables out.
                ("fish_greeting".into(), String::new()),
            ];
            edit(c);
        })
        .await;
        Self {
            _dir: dir,
            _home: home,
            work,
            daemon,
        }
    }

    fn client(&self) -> (TestClient, UnboundedReceiver<AssistEvent>) {
        let c = TestClient::connect(&ticket(&self.daemon), ClientConfig::generate_key());
        let (listener, rx) = AssistEventQueue::channel();
        c.client.set_assist_listener(listener);
        (c, rx)
    }
}

/// Waits until the client's latest prompt state for `pane` satisfies `pred`.
async fn prompt(
    c: &mut TestClient,
    pane: PaneId,
    what: &str,
    pred: impl Fn(&PromptState) -> bool,
) -> PromptState {
    c.until(what, |c| {
        c.client.prompt_state(pane).is_some_and(|s| pred(&s))
    })
    .await;
    c.client.prompt_state(pane).unwrap()
}

fn input(state: &PromptState) -> Option<&client_core::proto::PromptInput> {
    match &state.phase {
        PromptPhase::AtPrompt(i) => Some(i),
        _ => None,
    }
}

/// Whether `got` is the expected command text. Without `133;B` (fish 3) the inferred input
/// start can land inside a prompt drawn in slow pieces, so a prompt tail may precede it.
fn same(marked: bool, got: &str, want: &str) -> bool {
    if marked {
        got == want
    } else {
        got.ends_with(want)
    }
}

/// An `.zshrc` that draws a right prompt and imitates zsh-autosuggestions: after `ech` the
/// suggestion `o ghost` appears after the cursor in color 8 (`POSTDISPLAY` + `region_highlight`,
/// exactly what the plugin does).
const ZSHRC: &str = r#"
RPROMPT='[rp]'
_fake_suggest() {
  if [[ $BUFFER == ech ]]; then
    POSTDISPLAY='o ghost'
    region_highlight=("${#BUFFER} $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=8")
  else
    POSTDISPLAY=''
    region_highlight=()
  fi
}
zle -N zle-line-pre-redraw _fake_suggest
"#;

async fn prompt_scenario(shell: &Path, kind: ShellKind) {
    let env = Env::new(shell, |home| {
        std::fs::write(home.join(".zshrc"), ZSHRC).unwrap();
    })
    .await;
    let (mut c, _rx) = env.client();
    let pane = c.attach_and_follow().await;
    let first = c.client.watch_prompt(pane, true).await.unwrap();
    assert_eq!(first.prompt.pane_id, pane);
    let marked = kind != ShellKind::Fish;

    c.type_line(pane, &format!("cd {}", env.work.display()));
    let st = prompt(&mut c, pane, "prompt in work", |s| {
        input(s).is_some_and(|i| i.text.is_empty()) && s.prompt_id >= 1
    })
    .await;
    let i = input(&st).unwrap();
    assert_eq!(i.shell, kind, "{st:?}");
    assert!(i.bracketed_paste, "{st:?}");

    if kind == ShellKind::Zsh {
        // The fake autosuggestion is cut and reported; the right prompt is left out.
        c.client.send_input(pane, b"ech".to_vec());
        let st = prompt(&mut c, pane, "suggestion", |s| {
            input(s).is_some_and(|i| i.suggestion.is_some())
        })
        .await;
        let i = input(&st).unwrap();
        assert_eq!(i.text, "ech", "{st:?}");
        assert_eq!(i.cursor, 3);
        assert_eq!(i.suggestion.as_deref(), Some("o ghost"));
        assert!(i.right_prompt, "{st:?}");
        assert!(i.confident, "{st:?}");
        c.client.send_input(pane, b"o hello world".to_vec());
    } else {
        // fish's input start is inferred from output in the 25 ms after the prompt starts;
        // typing that fast would land in it (a documented limit), so a person's pause first.
        tokio::time::sleep(Duration::from_millis(100)).await;
        c.client.send_input(pane, b"echo hello world".to_vec());
    }
    let st = prompt(&mut c, pane, "typed line", |s| {
        input(s).is_some_and(|i| same(marked, &i.text, "echo hello world"))
    })
    .await;
    let i = input(&st).unwrap();
    let end = i.text.chars().count() as u32;
    assert_eq!(i.cursor, end);
    assert_eq!(i.suggestion, None);
    if marked {
        assert!(i.confident, "{st:?}");
    } else {
        // fish 3 sends no 133;B: the input start is inferred, so the editor is not prefilled.
        assert_eq!(i.doubt, Some(InputDoubt::NoInputMark));
    }
    // Cursor movement is followed.
    c.client
        .send_input(pane, b"\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D".to_vec());
    let st = prompt(&mut c, pane, "cursor moved", |s| {
        input(s).is_some_and(|i| i.cursor == end - 5)
    })
    .await;
    let id = st.prompt_id;

    // D3: atomic submit replaces the half-typed line and runs.
    let marks_before = c.marks.len();
    c.client
        .submit_line(pane, id, "echo submitted-ok", true)
        .await
        .expect("submitted");
    c.until("submitted command finished", |c| {
        c.marks[marks_before..].iter().any(|m| {
            m.finished.is_some()
                && m.command
                    .as_deref()
                    .is_some_and(|t| same(marked, t, "echo submitted-ok"))
        })
    })
    .await;
    assert!(
        !c.marks.iter().any(|m| m
            .command
            .as_deref()
            .is_some_and(|t| t.contains("hello world"))),
        "{:?}",
        c.marks
    );
    // The prompt id moved on: a submit naming the old one is refused, nothing written.
    let stale = c.client.submit_line(pane, id, "echo never-1", true).await;
    let Err(AssistError::NotAtPrompt(now)) = stale else {
        panic!("{stale:?}")
    };
    assert_ne!(now.prompt_id, id);

    // While a command runs, submit is refused without side effects.
    c.type_line(pane, "sleep 1.5");
    let running = prompt(&mut c, pane, "running", |s| {
        matches!(s.phase, PromptPhase::Running { .. })
    })
    .await;
    let refused = c
        .client
        .submit_line(pane, running.prompt_id, "echo never-2", true)
        .await;
    assert!(
        matches!(refused, Err(AssistError::NotAtPrompt(_))),
        "{refused:?}"
    );
    let after_sleep = prompt(&mut c, pane, "prompt after sleep", |s| {
        input(s).is_some() && s.prompt_id == running.prompt_id
    })
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    c.until("settled", |_| true).await;
    assert!(!c.text(pane).contains("never-"), "{}", c.text(pane));
    assert_eq!(input(&after_sleep).unwrap().text, "");

    // D4: history keeps the command with its directory and exit status, but not one typed
    // with a leading space.
    c.type_line(pane, " echo private-secret");
    c.until("private command finished", |c| {
        c.marks.iter().any(|m| {
            m.finished.is_some()
                && m.command
                    .as_deref()
                    .is_some_and(|t| same(marked, t, "echo private-secret"))
        })
    })
    .await;
    let history = c
        .client
        .history(HistoryQuery {
            cwd: Some(env.work.to_string_lossy().into_owned()),
            prefix: None,
            contains: Some("echo".into()),
            since: None,
            limit: 20,
        })
        .await
        .unwrap();
    let ok = history
        .iter()
        .find(|h| same(marked, &h.command, "echo submitted-ok"))
        .unwrap_or_else(|| panic!("{history:?}"));
    assert_eq!(ok.exit, Some(0));
    assert_eq!(ok.cwd.as_deref(), Some(env.work.to_str().unwrap()));
    // fish: only when its inferred input start was exact (DAEMON.md §7.10).
    let exact = ok.command == "echo submitted-ok";
    if exact {
        assert!(
            !history.iter().any(|h| h.command.contains("private")),
            "{history:?}"
        );
    }

    // D5: completion in the shell's directory.
    let done = c.client.complete(pane, "cat no", 6, 20).await.unwrap();
    assert_eq!(done.cwd.as_deref(), Some(env.work.to_str().unwrap()));
    assert!(
        done.items
            .iter()
            .any(|i| i.text == "notes.txt" && i.kind == CompletionKind::Path),
        "{done:?}"
    );
    let done = c.client.complete(pane, "echo sub", 8, 20).await.unwrap();
    assert!(
        !exact
            || done
                .items
                .iter()
                .any(|i| i.text == "echo submitted-ok" && i.kind == CompletionKind::History),
        "{done:?}"
    );

    drop(c);
    env.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn zsh_prompt_state_submit_history_completion() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    prompt_scenario(&zsh, ShellKind::Zsh).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn bash_prompt_state_submit_history_completion() {
    let Some(bash) = bash() else {
        eprintln!("skipping: no bash 4.4+ installed");
        return;
    };
    prompt_scenario(&bash, ShellKind::Bash).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn fish_prompt_state_submit_history_completion() {
    let Some(fish) = fish() else {
        eprintln!("skipping: fish not installed");
        return;
    };
    prompt_scenario(&fish, ShellKind::Fish).await;
}

/// D1: profiles for pagers, monitors and editors; short-lived commands never reported.
#[tokio::test(flavor = "multi_thread")]
async fn foreground_programs_are_reported_debounced() {
    let shell = zsh().unwrap_or_else(|| PathBuf::from("/bin/sh"));
    let env = Env::new(&shell, |_| {}).await;
    let (mut c, mut rx) = env.client();
    let pane = c.attach_and_follow().await;
    c.until("shell in front", |c| {
        c.client
            .foreground(pane)
            .is_some_and(|f| f.profile == ProgramProfile::Shell)
    })
    .await;
    let mut seen: Vec<(String, ProgramProfile)> = Vec::new();
    let file = env.work.join("notes.txt");
    std::fs::write(&file, "line\n".repeat(200)).unwrap();
    let programs: Vec<(String, &[u8], ProgramProfile)> = {
        let mut p: Vec<(String, &[u8], ProgramProfile)> = vec![
            (
                format!("less {}", file.display()),
                b"q",
                ProgramProfile::Pager,
            ),
            ("top".into(), b"q", ProgramProfile::Monitor),
        ];
        if Path::new("/usr/bin/vi").exists() {
            p.push(("vi".into(), b"\x1b:q!\r", ProgramProfile::Vim));
        }
        p
    };
    for (cmd, quit, profile) in programs {
        // Short commands first: never reported.
        c.type_line(pane, "/bin/echo quick; /bin/echo quick");
        c.type_line(pane, &cmd);
        c.until(&format!("{profile:?} in front"), |c| {
            c.client
                .foreground(pane)
                .is_some_and(|f| f.profile == profile)
        })
        .await;
        c.client.send_input(pane, quit.to_vec());
        c.until("shell back", |c| {
            c.client
                .foreground(pane)
                .is_some_and(|f| f.profile == ProgramProfile::Shell)
        })
        .await;
    }
    while let Ok(event) = rx.try_recv() {
        if let AssistEvent::Foreground { foreground } = event
            && foreground.pane_id == pane
        {
            seen.push((foreground.name.clone(), foreground.profile));
        }
    }
    assert!(!seen.iter().any(|(name, _)| name == "echo"), "{seen:?}");
    let profiles: Vec<_> = seen.iter().map(|(_, p)| *p).collect();
    assert!(profiles.contains(&ProgramProfile::Pager), "{seen:?}");
    assert!(profiles.contains(&ProgramProfile::Monitor), "{seen:?}");
    // State answers with the foreground too.
    let state = c.client.pane_assist(pane).await.unwrap();
    assert_eq!(state.foreground.unwrap().profile, ProgramProfile::Shell);
    drop(c);
    env.daemon.shutdown().await;
}

fn git(dir: &Path, args: &[&str]) {
    let ok = std::process::Command::new("git")
        .current_dir(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .output()
        .expect("git runs")
        .status
        .success();
    assert!(ok, "git {args:?}");
}

/// Writes `n` history records spread over directories, as the daemon would have.
fn seed_history(state: &Path, n: usize, cwd: &Path) {
    let dir = state.join("history");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("imported.json"), "{}").unwrap();
    let words = [
        "git", "cargo", "make", "ls", "cd", "docker", "kubectl", "npm", "rg", "vim",
    ];
    let sub = [
        "status", "build", "test", "run", "log", "push", "-la", "src", "up", "install",
    ];
    let now = now_millis().0;
    let mut body = String::new();
    for i in 0..n {
        let cmd = format!(
            "{} {} --flag-{i} {}",
            words[i % 10],
            sub[(i / 10) % 10],
            i % 97
        );
        let d = if i % 5 == 0 {
            cwd.to_string_lossy().into_owned()
        } else {
            format!("/srv/p{}", i % 50)
        };
        body.push_str(
            &serde_json::json!({"c": cmd, "d": d, "x": (i % 7 == 0) as i32, "ms": 12, "t": now - (i as u64) * 60_000})
                .to_string(),
        );
        body.push('\n');
    }
    std::fs::write(dir.join("commands.jsonl"), body).unwrap();
}

/// D5: git refs and paths, `$PATH` commands, and p95 latency on a host with 10 000 history
/// entries.
#[tokio::test(flavor = "multi_thread")]
async fn completion_sources_and_latency_with_10k_history() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let repo = home.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    std::fs::write(repo.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(repo.join("Cargo.toml"), "").unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "init"]);
    git(&repo, &["branch", "feature/completion"]);
    std::fs::write(repo.join("src/main.rs"), "fn main() { changed() }\n").unwrap();
    std::fs::write(repo.join("untracked.txt"), "").unwrap();
    let bin = home.path().canonicalize().unwrap().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let tool = bin.join("zzfrobnicate");
    std::fs::write(&tool, "#!/bin/sh\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
    seed_history(state.path(), 10_000, &repo);

    let home_str = home.path().to_string_lossy().into_owned();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let repo_str = repo.to_string_lossy().into_owned();
    let daemon = start_with(state.path(), move |c| {
        c.pane_env.push(("HOME".into(), home_str));
        c.pane_env.push(("PATH".into(), path));
        c.pane_env.push(("PS1".into(), "$ ".into()));
        let _ = repo_str;
    })
    .await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = c.attach_and_follow().await;
    c.type_line(pane, &format!("cd {}", repo.display()));
    // `/bin/sh` reports no OSC 7, so tell the daemon the directory the way shells do.
    c.type_line(
        pane,
        &format!("printf '\\033]7;file://localhost{}\\007'", repo.display()),
    );
    c.until("cwd", |c| {
        c.metas
            .get(&pane)
            .and_then(|m| m.cwd.as_deref())
            .is_some_and(|d| d == repo.to_str().unwrap())
    })
    .await;

    let items = |line: &str| {
        let client = &c.client;
        let line = line.to_owned();
        async move {
            let n = line.chars().count() as u32;
            client.complete(pane, line, n, 50).await.unwrap().items
        }
    };
    // Cold caches: the first ref lookup runs `for-each-ref` and `status`.
    let t = Instant::now();
    let got = items("git checkout feat").await;
    let cold_refs = t.elapsed();
    assert!(
        got.iter()
            .any(|i| i.text == "feature/completion" && i.kind == CompletionKind::GitRef),
        "{got:?}"
    );
    let got = items("git add ").await;
    let texts: Vec<_> = got.iter().map(|i| i.text.as_str()).collect();
    assert!(
        texts.contains(&"src/main.rs") && texts.contains(&"untracked.txt"),
        "{got:?}"
    );
    // Changed files first, then the directory's other entries.
    assert!(
        got[..2].iter().all(|i| i.kind == CompletionKind::GitPath),
        "{got:?}"
    );
    let got = items("git che").await;
    assert_eq!(got[0].text, "checkout");
    // Cold: the first command lookup lists every `$PATH` directory.
    let t = Instant::now();
    let got = items("zzfrob").await;
    eprintln!(
        "cold completion: refs and status {:.1} ms, $PATH scan {:.1} ms",
        cold_refs.as_secs_f64() * 1e3,
        t.elapsed().as_secs_f64() * 1e3
    );
    assert!(
        got.iter()
            .any(|i| i.text == "zzfrobnicate" && i.kind == CompletionKind::Command),
        "{got:?}"
    );
    let got = items("vim src/ma").await;
    assert_eq!(got[0].text, "src/main.rs");
    // History ranked for this directory: entries recorded here come first.
    let got = items("git status").await;
    let first = got
        .iter()
        .find(|i| i.kind == CompletionKind::History)
        .expect("history item");
    assert_eq!(
        first.detail.as_deref(),
        Some(repo.to_str().unwrap()),
        "{got:?}"
    );

    // Latency: a mix of lines, measured round trip through the client.
    let lines = [
        "git checkout feat",
        "git st",
        "cargo b",
        "ls sr",
        "cat ",
        "make t",
        "docker ",
        "zzfr",
        "vim src/",
        "kubectl lo",
        "git add ",
        "npm i",
    ];
    let mut times = Vec::new();
    for round in 0..25 {
        for line in lines {
            let t = Instant::now();
            let n = line.chars().count() as u32;
            let _ = c.client.complete(pane, line, n, 50).await.unwrap();
            times.push(t.elapsed());
            let _ = round;
        }
    }
    times.sort();
    let pct = |p: f64| times[((times.len() as f64 * p) as usize).min(times.len() - 1)];
    let (p50, p95, max) = (pct(0.50), pct(0.95), *times.last().unwrap());
    eprintln!(
        "completion over {} requests, 10k history: p50 {:.1} ms, p95 {:.1} ms, max {:.1} ms",
        times.len(),
        p50.as_secs_f64() * 1e3,
        p95.as_secs_f64() * 1e3,
        max.as_secs_f64() * 1e3
    );
    assert!(p95 < Duration::from_millis(150), "p95 {p95:?}");
    // The history request itself on 10k entries.
    let t = Instant::now();
    let h = c
        .client
        .history(HistoryQuery {
            cwd: Some(repo.to_string_lossy().into_owned()),
            prefix: Some("git".into()),
            contains: None,
            since: Some(UnixMillis(0)),
            limit: 100,
        })
        .await
        .unwrap();
    eprintln!(
        "history query over 10k entries: {:.1} ms",
        t.elapsed().as_secs_f64() * 1e3
    );
    assert_eq!(h.len(), 100);
    drop(c);
    daemon.shutdown().await;
}

/// D7: fuzzy file search honours .gitignore and hidden files and stays inside allowed roots.
#[tokio::test(flavor = "multi_thread")]
async fn file_search_for_mentions() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let root = home.path().canonicalize().unwrap().join("proj");
    for f in [
        "src/daemon/conn.rs",
        "src/daemon/core.rs",
        "docs/connectivity.md",
        "target/debug/conn.rs",
        ".secret/conn.rs",
    ] {
        let p = root.join(f);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, "").unwrap();
    }
    std::fs::write(root.join(".gitignore"), "target/\n").unwrap();
    let home_str = home.path().to_string_lossy().into_owned();
    let daemon = start_with(state.path(), move |c| {
        c.pane_env.push(("HOME".into(), home_str));
    })
    .await;
    let c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let found = c.client.file_search("~/proj", "conrs", 10).await.unwrap();
    let paths: Vec<_> = found.matches.iter().map(|m| m.path.as_str()).collect();
    assert_eq!(paths.first(), Some(&"src/daemon/conn.rs"), "{found:?}");
    assert!(
        !paths
            .iter()
            .any(|p| p.starts_with("target") || p.starts_with(".secret"))
    );
    assert!(!found.truncated);
    assert_eq!(found.matches[0].positions.len(), 5);
    let denied = c.client.file_search("/etc", "passwd", 5).await;
    assert!(matches!(denied, Err(AssistError::Denied(_))), "{denied:?}");
    drop(c);
    daemon.shutdown().await;
}

/// A stand-in for Claude Code that shows a permission dialog and echoes the key it gets.
const FAKE_CLAUDE: &str = r#"#!/bin/sh
printf '\033[2J\033[H'
printf 'Bash command\r\n  rm -rf build\r\n\r\nDo you want to proceed?\r\n'
printf '\342\235\257 1. Yes\r\n  2. Yes, and don'"'"'t ask again for rm commands in this project\r\n  3. No, and tell Claude what to do differently (esc)\r\n\r\n'
printf 'Esc to cancel\r\n'
stty raw -echo
key=$(dd bs=1 count=1 2>/dev/null | od -An -c | tr -d ' ')
stty sane
printf '\r\nANSWER:%s\r\n' "$key"
sleep 30
"#;

const PERMISSION: &str =
    include_str!("../../../agents/tests/fixtures/claude/permission_request.json");

/// D9: options for the decision strip, from the screen and from a held hook, and answering
/// by keys after re-checking the dialog.
#[tokio::test(flavor = "multi_thread")]
async fn blocked_agent_options_and_answer() {
    let state = tempfile::tempdir().unwrap();
    let bin = tempfile::tempdir().unwrap();
    let claude = bin.path().join("claude");
    std::fs::write(&claude, FAKE_CLAUDE).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        bin.path().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    // A home of its own, so no profile puts a real `claude` ahead of the fake one.
    let home = tempfile::tempdir().unwrap();
    let home_str = home.path().to_string_lossy().into_owned();
    let daemon = start_with(state.path(), move |c| {
        c.pane_env.push(("PATH".into(), path));
        c.pane_env.push(("HOME".into(), home_str));
    })
    .await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell_pane = c.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: pane } = c
        .op(LayoutOp::Split {
            pane_id: shell_pane,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Agent {
                agent: AgentKind::Claude,
                resume: None,
                cwd: None,
            },
        })
        .await
    else {
        panic!("split failed")
    };
    c.follow(pane).await;
    c.wait_text(pane, "Esc to cancel").await;

    // From the screen: labels, meanings, keys, the selected row.
    let blocked = c.client.blocked_options(pane).await.unwrap().expect("menu");
    assert_eq!(blocked.source, BlockedSource::Screen);
    assert_eq!(blocked.options.len(), 3, "{blocked:?}");
    assert_eq!(blocked.options[0].label, "Yes");
    assert!(blocked.options[0].selected);
    assert_eq!(blocked.options[0].keys, b"1");
    assert_eq!(blocked.options[1].choice, BlockedChoice::AllowSession);
    assert_eq!(blocked.options[2].choice, BlockedChoice::Deny);
    assert_eq!(blocked.options[2].keys, b"\x1b");
    assert!(blocked.options.iter().all(|o| o.option_id.is_none()));

    // A shell pane has no dialog.
    assert_eq!(c.client.blocked_options(shell_pane).await.unwrap(), None);

    // With the hook holding the request open, options carry decision ids too.
    let request = daemon::HookRequest {
        v: 1,
        token: std::fs::read_to_string(state.path().join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: "PermissionRequest".into(),
        seq: 1,
        payload: serde_json::from_str(PERMISSION).unwrap(),
    };
    let socket = daemon.hook_socket().to_owned();
    let waiting = tokio::spawn(async move {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        let mut stream = tokio::net::UnixStream::connect(&socket).await.unwrap();
        let mut line = serde_json::to_vec(&request).unwrap();
        line.push(b'\n');
        stream.write_all(&line).await.unwrap();
        let mut answer = String::new();
        BufReader::new(stream).read_line(&mut answer).await.unwrap();
        answer
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    let hooked = loop {
        let b = c.client.blocked_options(pane).await.unwrap();
        if let Some(b) = b.filter(|b| b.source == BlockedSource::Hook && b.request_id.is_some()) {
            break b;
        }
        assert!(Instant::now() < deadline, "hook options never appeared");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert_eq!(hooked.options[0].option_id, Some(OptionId(0)));
    assert_eq!(hooked.options[0].keys, b"1");
    let deny = hooked
        .options
        .iter()
        .find(|o| o.choice == BlockedChoice::Deny)
        .unwrap();
    assert_eq!(deny.keys, b"\x1b");
    c.client.decide(hooked.request_id.unwrap(), OptionId(0));
    let answer = tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .unwrap()
        .unwrap();
    assert!(answer.contains("allow"), "{answer}");

    // Answering on screen: a stale label is refused; the right one types its key.
    let stale = c.client.answer_blocked(pane, 0, "No").await;
    assert!(matches!(stale, Err(AssistError::NotFound(_))), "{stale:?}");
    c.client.answer_blocked(pane, 0, "Yes").await.unwrap();
    c.wait_text(pane, "ANSWER:1").await;
    drop(c);
    daemon.shutdown().await;
}

fn denied<T>(r: &Result<T, AssistError>) -> bool {
    matches!(r, Err(AssistError::Denied(_)))
}

/// Roles: viewers read prompt state and foreground and blocked options, but cannot submit,
/// read history, complete or search files.
#[tokio::test(flavor = "multi_thread")]
async fn roles_gate_assist_requests() {
    let state = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), |_| {}).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    spec.label = "carol".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .unwrap();
    let mut viewer = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    viewer.client.attach(None);
    viewer.until("layout", |c| c.layout.is_some()).await;

    let st = viewer.client.watch_prompt(pane, true).await.unwrap();
    assert_eq!(st.prompt.pane_id, pane);
    assert!(viewer.client.blocked_options(pane).await.unwrap().is_none());
    let r = viewer
        .client
        .submit_line(pane, st.prompt.prompt_id, "ls", true)
        .await;
    assert!(denied(&r), "{r:?}");
    let r = viewer
        .client
        .history(HistoryQuery {
            cwd: None,
            prefix: None,
            contains: None,
            since: None,
            limit: 5,
        })
        .await;
    assert!(denied(&r), "{r:?}");
    let r = viewer.client.complete(pane, "l", 1, 5).await;
    assert!(denied(&r), "{r:?}");
    let r = viewer.client.file_search("~", "x", 5).await;
    assert!(denied(&r), "{r:?}");
    let r = viewer.client.answer_blocked(pane, 0, "Yes").await;
    assert!(denied(&r), "{r:?}");
    // The owner may.
    assert!(owner.client.complete(pane, "l", 1, 5).await.is_ok());
    drop((owner, viewer));
    daemon.shutdown().await;
}
