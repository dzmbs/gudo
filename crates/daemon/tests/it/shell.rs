//! Shell integration end to end with real shells: injected scripts, OSC 133 command marks
//! (exit status, duration, command text, cwd), "finished while unseen", command output, and
//! the prompt state feeding echo prediction.

use std::path::{Path, PathBuf};
use std::time::Duration;

use client_core::ClientConfig;
use client_core::ClientEvent;
use client_core::proto::{AttentionKind, Prediction};

use crate::support::{TestClient, start_with, ticket};

/// The first existing path, for shells that live in different places per OS.
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

/// Runs the scenario in `shell` with an empty `HOME` (and `ZDOTDIR`), so no user dotfiles
/// take part. `typed_commands`: the shell marks its input area (133;B), so command lines are
/// read off the screen.
async fn scenario(shell: &Path, typed_commands: bool) {
    let dir = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let work = home.path().canonicalize().unwrap().join("work");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join("notes.txt"), "").unwrap();
    let shell = shell.to_owned();
    let home_str = home.path().to_string_lossy().into_owned();
    let daemon = start_with(dir.path(), move |c| {
        c.shell = Some(shell);
        c.pane_env = vec![
            ("HOME".into(), home_str.clone()),
            ("PS1".into(), "$ ".into()),
            ("ZDOTDIR".into(), home_str),
        ];
        c.long_command = Duration::from_millis(1200);
    })
    .await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = c.attach_and_follow().await;

    c.until("prompt hint", |c| {
        c.hints
            .iter()
            .any(|h| h.hint.at_prompt && h.prediction == Prediction::Allow)
    })
    .await;

    c.type_line(pane, &format!("cd {}", work.display()));
    c.type_line(pane, "sh -c 'exit 3'");
    c.type_line(pane, "printf 'out1\\nout2 notes.txt\\n'");
    c.until("three finished commands", |c| {
        c.marks.iter().filter(|m| m.finished.is_some()).count() >= 3
    })
    .await;
    let finished: Vec<_> = c
        .marks
        .iter()
        .filter(|m| m.finished.is_some())
        .cloned()
        .collect();
    if typed_commands {
        assert_eq!(finished[1].command.as_deref(), Some("sh -c 'exit 3'"));
    }
    assert_eq!(finished[1].finished.unwrap().exit, Some(3));
    assert_eq!(finished[2].finished.unwrap().exit, Some(0));
    assert_eq!(finished[2].cwd.as_deref(), Some(work.to_str().unwrap()));
    // While a command runs, prediction in raw mode is off again.
    assert!(c.hints.iter().any(|h| !h.hint.at_prompt));

    let id = c.client.commands(pane);
    let ClientEvent::Commands { result, .. } = c.answer(id).await else {
        unreachable!()
    };
    let list = result.unwrap();
    assert_eq!(list.commands.len(), 3, "{list:#?}");
    let rows = list.commands[2].rows;
    assert!(
        rows.prompt <= rows.output && rows.output <= rows.end,
        "{rows:?}"
    );

    let id = c.client.command_output(pane, None);
    let ClientEvent::CommandOutput { result, .. } = c.answer(id).await else {
        unreachable!()
    };
    let out = result.unwrap();
    assert_eq!(out.text, "out1\nout2 notes.txt");
    assert_eq!(out.mark.command_id, finished[2].command_id);

    // Paths in the last command's output resolve against the shell's directory.
    let id = c.client.links(pane, 1);
    let ClientEvent::Links { result, .. } = c.answer(id).await else {
        unreachable!()
    };
    let links = result.unwrap();
    assert!(
        links
            .links
            .iter()
            .any(|l| l.target == work.join("notes.txt").to_str().unwrap()
                && l.exists == Some(true)),
        "{links:#?}"
    );

    // A long command finishing while the pane is shown is not announced...
    c.type_line(pane, "sleep 1.5");
    c.until("sleep finished", |c| {
        c.marks.iter().filter(|m| m.finished.is_some()).count() >= 4
    })
    .await;
    assert!(c.unseen.is_empty());
    // ...but it is when nobody looks.
    c.client.set_view(None, vec![]);
    tokio::time::sleep(Duration::from_millis(100)).await;
    c.type_line(pane, "sleep 1.5; echo 'it broke'; false");
    c.until("unseen long command", |c| !c.unseen.is_empty())
        .await;
    let unseen = c.unseen[0].clone();
    if typed_commands {
        assert_eq!(
            unseen.command.as_deref(),
            Some("sleep 1.5; echo 'it broke'; false")
        );
    }
    let end = unseen.finished.unwrap();
    assert_eq!(end.exit, Some(1));
    assert!(end.duration_ms >= 1400, "{end:?}");
    // Its notification ends with the last line of output.
    let list = c.client.attention_list().await.unwrap();
    let item = list
        .items
        .iter()
        .find(|i| matches!(&i.kind, AttentionKind::CommandFinished(m) if m.command_id == unseen.command_id))
        .expect("an attention item for the command");
    assert!(item.title.ends_with("failed (1)"), "{item:?}");
    assert_eq!(item.body, "after 1 s · it broke");

    drop(c);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn zsh_integration_marks_commands() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    scenario(&zsh, true).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn bash_integration_marks_commands() {
    let Some(bash) = bash() else {
        eprintln!("skipping: no bash 4.4+ installed");
        return;
    };
    scenario(&bash, true).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn fish_integration_marks_commands() {
    let Some(fish) = fish() else {
        eprintln!("skipping: fish not installed");
        return;
    };
    // fish 3 sends no 133;B (fish 4 marks its prompts itself).
    scenario(&fish, false).await;
}
