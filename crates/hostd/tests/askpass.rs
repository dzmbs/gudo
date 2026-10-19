//! The real askpass helper (`un-hook askpass`) against a daemon in this process: programs in
//! a pane run `$SUDO_ASKPASS` / `$SSH_ASKPASS` like sudo and ssh do, the app answers, and the
//! program gets the answer on the helper's stdout. Without an app the helper asks on the
//! terminal with echo off.

#[allow(dead_code)]
#[path = "../../daemon/tests/it/support.rs"]
mod support;

use std::path::{Path, PathBuf};

use client_core::proto::{Secret, SecretPrompt, SecretSource};
use client_core::{AskpassEvent, ClientConfig};

use support::{TestClient, start_with, ticket};

const HELPER: &str = env!("CARGO_BIN_EXE_un-hook");

fn prompts(c: &TestClient) -> Vec<SecretPrompt> {
    c.askpass
        .iter()
        .filter_map(|e| match e {
            AskpassEvent::Prompt(p) => Some(p.clone()),
            _ => None,
        })
        .collect()
}

/// Writes an executable script named `name` into `dir`.
fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[tokio::test(flavor = "multi_thread")]
async fn programs_get_the_answer_typed_in_the_app() {
    let dir = tempfile::tempdir().unwrap();
    let bin = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |c| c.hook_bin = Some(HELPER.into())).await;
    let mut app = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    let pane = app.attach_and_follow().await;

    // A sudo stand-in: runs $SUDO_ASKPASS with its prompt, as `sudo -A` does.
    let sudo = script(
        bin.path(),
        "sudo",
        "pw=$(\"$SUDO_ASKPASS\" \"[sudo] password for $USER: \") || { echo 'sudo: no password was provided'; exit 1; }\n\
         echo \"sudo got ${#pw} chars: $pw\"\n",
    );
    app.type_line(pane, &format!("{} -l", sudo.display()));
    app.until("sudo prompt", |c| !prompts(c).is_empty()).await;
    let p = prompts(&app)[0].clone();
    assert_eq!(p.source, SecretSource::Sudo);
    assert!(p.prompt.starts_with("[sudo] password for"), "{}", p.prompt);
    assert!(p.program.contains("sudo -l"), "{}", p.program);
    app.client
        .answer_askpass(p.id, Secret::new(b"correct horse".to_vec()))
        .await
        .unwrap();
    app.wait_text(pane, "sudo got 13 chars: correct horse")
        .await;

    // ssh the same way through $SSH_ASKPASS; Cancel makes the helper fail.
    let ssh = script(
        bin.path(),
        "ssh",
        "pw=$(\"$SSH_ASKPASS\" \"Enter passphrase for key '/k/id_ed25519': \") || { echo \"ssh: askpass failed $?\"; exit 255; }\n\
         echo \"ssh got: $pw\"\n",
    );
    app.type_line(pane, &format!("{} host", ssh.display()));
    app.until("ssh prompt", |c| prompts(c).len() == 2).await;
    let p = prompts(&app)[1].clone();
    assert_eq!(p.source, SecretSource::Ssh);
    app.client.cancel_askpass(p.id).await.unwrap();
    app.wait_text(pane, "ssh: askpass failed 1").await;

    app.type_line(pane, &format!("{} host", ssh.display()));
    app.until("ssh prompt again", |c| prompts(c).len() == 3)
        .await;
    let p = prompts(&app)[2].clone();
    app.client
        .answer_askpass(p.id, Secret::new(b"pass phrase".to_vec()))
        .await
        .unwrap();
    app.wait_text(pane, "ssh got: pass phrase").await;

    // The `sudo` wrapper's probe: an app is here.
    app.type_line(pane, "\"$UN_ASKPASS\" --available; echo \"avail=$?\"");
    app.wait_text(pane, "avail=0").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn without_an_app_the_helper_reads_the_terminal_with_echo_off() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |c| c.hook_bin = Some(HELPER.into())).await;
    let mut cli = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = cli.attach_and_follow().await;

    cli.type_line(pane, "\"$UN_ASKPASS\" --available; echo \"avail=$?\"");
    cli.wait_text(pane, "avail=1").await;

    cli.type_line(
        pane,
        "pw=$(\"$SUDO_ASKPASS\" 'Pass''word: '); echo \"tty-got:$pw\"",
    );
    cli.wait_text(pane, "Password:").await;
    cli.type_line(pane, "typed-here");
    cli.wait_text(pane, "tty-got:typed-here").await;
    assert_eq!(
        cli.text(pane).matches("typed-here").count(),
        1,
        "{}",
        cli.text(pane)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn interactive_zsh_runs_sudo_with_askpass_while_an_app_can_answer() {
    let zsh = Path::new("/bin/zsh");
    if !zsh.exists() {
        eprintln!("no /bin/zsh; skipped");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let bin = tempfile::tempdir().unwrap();
    // A `sudo` that shows how it was called.
    script(bin.path(), "sudo", "echo \"sudo-args:$*\"\n");
    let home_dir = home.path().to_string_lossy().into_owned();
    let daemon = start_with(dir.path(), |c| {
        c.hook_bin = Some(HELPER.into());
        c.shell = Some(zsh.into());
        c.pane_env = vec![("HOME".into(), home_dir)];
    })
    .await;

    let mut cli = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = cli.attach_and_follow().await;
    // Login shells reset PATH (path_helper), so the stand-in goes first afterwards.
    cli.type_line(
        pane,
        &format!(
            "PATH={}:$PATH; whence -w sudo; sudo -u root id",
            bin.path().display()
        ),
    );
    cli.wait_text(pane, "sudo: function").await;
    // No app that can answer: plain sudo, which asks on the terminal as always.
    cli.wait_text(pane, "sudo-args:-u root id").await;

    let mut app = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    app.attach_and_follow().await;
    app.type_line(pane, "sudo -u root whoami; sudo -S true");
    app.wait_text(pane, "sudo-args:-A -u root whoami").await;
    // The caller chose how sudo reads the password: left alone.
    app.wait_text(pane, "sudo-args:-S true").await;
}
