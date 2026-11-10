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
    candidates
        .iter()
        .map(PathBuf::from)
        .find(|path| path.exists())
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
    let daemon = start_with(dir.path(), move |config| {
        config.shell = Some(shell);
        config.pane_env = vec![
            ("HOME".into(), home_str.clone()),
            ("PS1".into(), "$ ".into()),
            ("ZDOTDIR".into(), home_str),
        ];
        config.long_command = Duration::from_millis(1200);
    })
    .await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;

    // The prompt is marked: raw-mode prediction is allowed only there.
    client
        .until("prompt hint", |client| {
            client
                .hints
                .iter()
                .any(|hint| hint.hint.at_prompt && hint.prediction == Prediction::Allow)
        })
        .await;

    client.type_line(pane, &format!("cd {}", work.display()));
    client.type_line(pane, "sh -c 'exit 3'");
    client.type_line(pane, "printf 'out1\\nout2 notes.txt\\n'");
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
    let finished: Vec<_> = client
        .marks
        .iter()
        .filter(|mark| mark.finished.is_some())
        .cloned()
        .collect();
    if typed_commands {
        assert_eq!(finished[1].command.as_deref(), Some("sh -c 'exit 3'"));
    }
    assert_eq!(finished[1].finished.unwrap().exit, Some(3));
    assert_eq!(finished[2].finished.unwrap().exit, Some(0));
    assert_eq!(finished[2].cwd.as_deref(), Some(work.to_str().unwrap()));
    // While a command runs, prediction in raw mode is off again.
    assert!(client.hints.iter().any(|hint| !hint.hint.at_prompt));

    let id = client.client.commands(pane);
    let ClientEvent::Commands { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    let list = result.unwrap();
    assert_eq!(list.commands.len(), 3, "{list:#?}");
    let rows = list.commands[2].rows;
    assert!(
        rows.prompt <= rows.output && rows.output <= rows.end,
        "{rows:?}"
    );

    let id = client.client.command_output(pane, None);
    let ClientEvent::CommandOutput { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    let output = result.unwrap();
    assert_eq!(output.text, "out1\nout2 notes.txt");
    assert_eq!(output.mark.command_id, finished[2].command_id);

    // Paths in the last command's output resolve against the shell's directory.
    let id = client.client.links(pane, 1);
    let ClientEvent::Links { result, .. } = client.answer(id).await else {
        unreachable!()
    };
    let links = result.unwrap();
    assert!(
        links.links.iter().any(
            |link| link.target == work.join("notes.txt").to_str().unwrap()
                && link.exists == Some(true)
        ),
        "{links:#?}"
    );

    // A long command finishing while the pane is shown is not announced...
    client.type_line(pane, "sleep 1.5");
    client
        .until("sleep finished", |client| {
            client
                .marks
                .iter()
                .filter(|mark| mark.finished.is_some())
                .count()
                >= 4
        })
        .await;
    assert!(client.unseen.is_empty());
    // ...but it is when nobody looks.
    client.client.set_view(None, vec![]);
    tokio::time::sleep(Duration::from_millis(100)).await;
    client.type_line(pane, "sleep 1.5; echo 'it broke'; false");
    client
        .until("unseen long command", |client| !client.unseen.is_empty())
        .await;
    let unseen = client.unseen[0].clone();
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
    let list = client.client.attention_list().await.unwrap();
    let item = list
        .items
        .iter()
        .find(|item| matches!(&item.kind, AttentionKind::CommandFinished(mark) if mark.command_id == unseen.command_id))
        .expect("an attention item for the command");
    assert!(item.title.ends_with("failed (1)"), "{item:?}");
    assert_eq!(item.body, "after 1 s · it broke");

    drop(client);
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

/// Shell integration reports the directory (OSC 7) and titles it (OSC 2); a directory named with
/// BEL and ESC, raw or as backslash escapes, must not end those early and send an OSC 52
/// clipboard write of its own. A real write afterwards shows the client would have copied it.
async fn directory_names_cannot_inject_sequences(
    shell: &Path,
    cd_command: impl Fn(&str) -> String,
) {
    let dir = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let home_path = home.path().canonicalize().unwrap();
    let raw_name = "x\x07\x1b]52;c;aW5qZWN0ZWQ=\x07y";
    let escaped_name = r"x\a\e]52;c;aW5qZWN0ZWQ=\ay";
    for name in [raw_name, escaped_name] {
        std::fs::create_dir_all(home_path.join(name)).unwrap();
    }
    let shell = shell.to_owned();
    let home_str = home_path.to_string_lossy().into_owned();
    let daemon = start_with(dir.path(), move |config| {
        config.shell = Some(shell);
        config.pane_env = vec![
            ("HOME".into(), home_str.clone()),
            ("PS1".into(), "$ ".into()),
            ("ZDOTDIR".into(), home_str),
        ];
    })
    .await;
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = client_core::RelayMode::Disabled;
    let options = client_core::ConnectOptions {
        clipboard: true,
        ..client_core::ConnectOptions::default()
    };
    let mut client = TestClient::connect_with(&ticket(&daemon), config, options);
    let pane = client.attach_and_follow().await;
    client
        .until("prompt hint", |client| {
            client.hints.iter().any(|hint| hint.hint.at_prompt)
        })
        .await;

    client.type_line(pane, &format!("cd {}", home_path.display()));
    client.type_line(pane, &cd_command(r"x\x07\x1b]52;c;aW5qZWN0ZWQ=\x07y"));
    client.type_line(pane, &format!("cd {}", home_path.display()));
    client.type_line(pane, &cd_command(r"x\\a\\e]52;c;aW5qZWN0ZWQ=\\ay"));
    client.type_line(pane, "printf '\\033]52;c;%s\\007' Y29udHJvbA==");
    client
        .until("the real clipboard write", |client| {
            !client.clipboard.is_empty()
        })
        .await;
    assert_eq!(client.clipboard, [(pane, "control".to_owned())]);
    let escaped_directory = home_path.join(escaped_name).to_string_lossy().into_owned();
    client
        .until("the escaped directory reported", |client| {
            client.metas.get(&pane).and_then(|meta| meta.cwd.as_deref())
                == Some(escaped_directory.as_str())
        })
        .await;

    drop(client);
    daemon.shutdown().await;
}

fn posix_cd(printf_format: &str) -> String {
    format!("cd \"$(printf '{printf_format}')\"")
}

#[tokio::test(flavor = "multi_thread")]
async fn zsh_directory_names_cannot_inject_sequences() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    directory_names_cannot_inject_sequences(&zsh, posix_cd).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn bash_directory_names_cannot_inject_sequences() {
    let Some(bash) = bash() else {
        eprintln!("skipping: no bash 4.4+ installed");
        return;
    };
    directory_names_cannot_inject_sequences(&bash, posix_cd).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn fish_directory_names_cannot_inject_sequences() {
    let Some(fish) = fish() else {
        eprintln!("skipping: fish not installed");
        return;
    };
    directory_names_cannot_inject_sequences(&fish, |printf_format| {
        format!("cd (printf '{printf_format}')")
    })
    .await;
}

/// The zle-line-init fallback can mark a fresh input area without another 133;A.
/// Replay through a real pane PTY, with enough completion rows to scroll the old input away.
#[tokio::test(flavor = "multi_thread")]
async fn fallback_completion_redraw_does_not_capture_the_listing() {
    let dir = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let mut bytes =
        String::from("\x1b[2J\x1b[H\x1b]133;P;k=i\x07$ \x1b]133;B\x07cp Downloads/\r\n");
    for i in 0..200 {
        bytes.push_str(&format!("download-{i:03}.txt\r\n"));
    }
    bytes.push_str(
        "$ \x1b]133;B\x07cp Downloads/x\r\n\x1b]133;C\x07result\r\n\x1b]133;D;0\x07REPLAY-DONE\r\n",
    );
    let fixture = home.path().join("completion.vt");
    std::fs::write(&fixture, bytes).unwrap();
    let private_home = home.path().to_string_lossy().into_owned();
    let daemon = start_with(dir.path(), move |config| {
        config.shell = Some("/bin/sh".into());
        config.pane_env = vec![("HOME".into(), private_home)];
    })
    .await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;
    client.type_line(
        pane,
        &format!("stty -echo; cat '{}'; sleep 30", fixture.display()),
    );
    client
        .until("replayed command finished", |client| {
            client.marks.iter().any(|mark| mark.finished.is_some())
        })
        .await;
    let command = client
        .marks
        .iter()
        .find(|mark| mark.finished.is_some())
        .unwrap()
        .command
        .clone();
    drop(client);
    daemon.shutdown().await;
    assert_eq!(command.as_deref(), Some("cp Downloads/x"));
}

/// Real zsh/ZLE, with a private theme hook that regenerates PS1 after integration, as p10k
/// can do. No user theme/config is sourced. Optional captures are Debug replay evidence.
#[tokio::test(flavor = "multi_thread")]
async fn zsh_theme_fallback_completion_keeps_command_metadata_single_line() {
    let Some(zsh) = zsh() else { return };
    let dir = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let downloads = home.path().join("Downloads");
    std::fs::create_dir(&downloads).unwrap();
    for i in 0..200 {
        std::fs::write(
            downloads.join(format!("x{i:03}-{}", "a".repeat(64))),
            "private fixture",
        )
        .unwrap();
    }
    std::fs::write(
        home.path().join(".zshrc"),
        r#"
autoload -Uz compinit
compinit -D
bindkey -e
unsetopt BEEP AUTO_MENU MENU_COMPLETE
setopt AUTO_LIST LIST_AMBIGUOUS
LISTMAX=-1
_private_theme() {
  PS1='PRIVATE> '
  precmd_functions=(${precmd_functions:#_private_theme} _private_theme)
}
typeset -ga precmd_functions
precmd_functions+=(_private_theme)
PS1='PRIVATE> '
"#,
    )
    .unwrap();
    let private_home = home.path().to_string_lossy().into_owned();
    let daemon = start_with(dir.path(), move |config| {
        config.shell = Some(zsh);
        config.pane_env = vec![
            ("HOME".into(), private_home.clone()),
            ("ZDOTDIR".into(), private_home),
        ];
    })
    .await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;
    client.wait_text(pane, "PRIVATE>").await;
    client.type_line(pane, &format!("cd '{}'", home.path().display()));
    client
        .until("private directory entered", |client| {
            client.marks.iter().any(|mark| mark.finished.is_some())
        })
        .await;
    client
        .client
        .send_input(pane, b"cp Downloads/\t\t".to_vec());
    client
        .until("200 real completion matches", |client| {
            client
                .client
                .pane_text_all(pane)
                .is_some_and(|text| text.contains("x199-"))
        })
        .await;
    let capture = |stage: &str, client: &TestClient| {
        if let Ok(path) = std::env::var("GUDO_SHELL_CAPTURE_DIR") {
            let root = PathBuf::from(path);
            std::fs::create_dir_all(&root).unwrap();
            std::fs::write(
                root.join(format!("zsh-{stage}.snapshot")),
                client.client.pane_snapshot(pane).unwrap(),
            )
            .unwrap();
            std::fs::write(
                root.join(format!("zsh-{stage}.screen.txt")),
                client.text(pane),
            )
            .unwrap();
            std::fs::write(
                root.join("commands.json"),
                serde_json::to_vec_pretty(&client.marks).unwrap(),
            )
            .unwrap();
        }
    };
    capture("listing", &client);
    // Clear a known shell draft, not an agent draft, then actually copy a private fixture.
    client.client.send_input(pane, vec![0x15]);
    client.type_line(
        pane,
        &format!(
            "cp Downloads/x000-{} copied.txt; for i in {{1..40}}; do print private-output-$i; done",
            "a".repeat(64)
        ),
    );
    client
        .until("copy command completed", |client| {
            client
                .marks
                .iter()
                .filter(|mark| mark.finished.is_some())
                .count()
                >= 2
        })
        .await;
    capture("output", &client);
    let command = client
        .marks
        .iter()
        .rev()
        .find(|mark| mark.finished.is_some())
        .unwrap()
        .command
        .clone();
    let copied = std::fs::read_to_string(home.path().join("copied.txt"));
    drop(client);
    daemon.shutdown().await;
    assert_eq!(copied.unwrap(), "private fixture");
    let command = command.expect("a command read from the fallback prompt");
    assert!(
        !command.contains('\n'),
        "completion listing entered metadata: {command}"
    );
    assert!(!command.contains("x199-"));
}
