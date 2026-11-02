//! Native password prompts end to end (docs/DAEMON.md §9): the askpass helper's requests on
//! the hook socket (a fake helper here; `crates/hostd/tests/askpass.rs` runs the real one),
//! prompts pushed only to owner devices that asked, first answer wins, guests never see them
//! (and the owner is told when a guest drives), timeouts, abandoned and orphaned prompts, and
//! detected terminal password prompts answered with `TypeSecret`.

use std::path::Path;
use std::time::Duration;

use client_core::proto::{
    AskpassError, AskpassId, Caps, CloseReason, PaneId, Roles, Scope, Secret, SecretPrompt,
    SecretSource, UnixMillis,
};
use client_core::{AskpassEvent, ClientConfig, ConnectOptions, now_millis};
use daemon::{ASKPASS_VERSION, AskpassCall, HelperQuery, HelperReply};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start, start_with, ticket};

fn call(dir: &Path, pane: PaneId, prompt: &str, program: &str) -> AskpassCall {
    AskpassCall {
        v: ASKPASS_VERSION,
        token: std::fs::read_to_string(dir.join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        askpass: HelperQuery {
            prompt: prompt.into(),
            program: program.into(),
            confirm: false,
            probe: false,
        },
    }
}

/// What the helper does: one line out, one line back.
async fn helper(socket: &Path, call: AskpassCall) -> HelperReply {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(&call).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
}

fn spawn_helper(socket: &Path, call: AskpassCall) -> tokio::task::JoinHandle<HelperReply> {
    let socket = socket.to_owned();
    tokio::spawn(async move { helper(&socket, call).await })
}

async fn reply(task: tokio::task::JoinHandle<HelperReply>) -> HelperReply {
    tokio::time::timeout(Duration::from_secs(20), task)
        .await
        .expect("the helper got an answer")
        .unwrap()
}

fn prompts(client: &TestClient) -> Vec<SecretPrompt> {
    client
        .askpass
        .iter()
        .filter_map(|event| match event {
            AskpassEvent::Prompt(prompt) => Some(prompt.clone()),
            _ => None,
        })
        .collect()
}

fn closed(client: &TestClient, id: AskpassId) -> Option<CloseReason> {
    client.askpass.iter().find_map(|event| match event {
        AskpassEvent::Closed {
            id: closed_id,
            reason,
            ..
        } if *closed_id == id => Some(*reason),
        _ => None,
    })
}

fn answer_of(helper_reply: &HelperReply) -> Option<&str> {
    match helper_reply {
        HelperReply::Answer(answer) => Some(answer),
        _ => None,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn askpass_prompt_goes_to_the_app_and_the_first_answer_wins() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let socket = daemon.hook_socket().to_owned();
    let mut laptop = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    let pane = laptop.attach_and_follow().await;
    let mut tablet = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    tablet.attach_and_follow().await;
    // A client that did not ask for prompts (an older app, the CLI) is never sent one.
    let mut plain = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    plain.attach_and_follow().await;

    // Panes carry the helper and the hook socket's coordinates.
    laptop.type_line(
        pane,
        "printf '%s|%s|%s|%s\\n' \"${SUDO_ASKPASS##*/}\" \"${SSH_ASKPASS##*/}\" \
         \"$SSH_ASKPASS_REQUIRE\" \"${GIT_ASKPASS##*/}\"",
    );
    laptop
        .wait_text(pane, "gudo-askpass|gudo-askpass|prefer|gudo-askpass")
        .await;
    let helper_path = dir.path().join("askpass/gudo-askpass");
    let script = std::fs::read_to_string(&helper_path).unwrap();
    assert!(script.contains(" askpass \"$@\""), "{script}");

    let task = spawn_helper(
        &socket,
        call(
            dir.path(),
            pane,
            "[sudo] password for ana: ",
            "sudo -A apt upgrade",
        ),
    );
    laptop
        .until("prompt on a", |client| !prompts(client).is_empty())
        .await;
    tablet
        .until("prompt on b", |client| !prompts(client).is_empty())
        .await;
    let prompt = prompts(&laptop)[0].clone();
    assert_eq!(prompt.pane_id, pane);
    assert_eq!(prompt.source, SecretSource::Sudo);
    assert_eq!(prompt.prompt, "[sudo] password for ana:");
    assert_eq!(prompt.program, "sudo -A apt upgrade");
    assert!(!prompt.echo && !prompt.retry);
    assert!(prompt.expires_at > UnixMillis(now_millis().0));
    assert_eq!(laptop.client.open_askpass(), vec![prompt.clone()]);

    laptop
        .client
        .answer_askpass(prompt.id, Secret::new(b"hunter2".to_vec()))
        .await
        .expect("first answer");
    let got = reply(task).await;
    assert_eq!(answer_of(&got), Some("hunter2"));
    // The other device's sheet closes; its late answer is refused.
    tablet
        .until("closed on b", |client| closed(client, prompt.id).is_some())
        .await;
    let me = laptop.client.me().unwrap().actor.principal;
    assert_eq!(
        closed(&tablet, prompt.id),
        Some(CloseReason::Answered { by: me })
    );
    assert_eq!(
        tablet
            .client
            .answer_askpass(prompt.id, Secret::new(b"other".to_vec()))
            .await,
        Err(AskpassError::Gone)
    );
    assert!(tablet.client.open_askpass().is_empty());

    // The same question again right away is flagged as a retry; Cancel declines it.
    let task = spawn_helper(
        &socket,
        call(
            dir.path(),
            pane,
            "[sudo] password for ana: ",
            "sudo -A apt upgrade",
        ),
    );
    tablet
        .until("second prompt", |client| prompts(client).len() == 2)
        .await;
    let again = prompts(&tablet)[1].clone();
    assert!(again.retry);
    tablet.client.cancel_askpass(again.id).await.unwrap();
    assert!(matches!(reply(task).await, HelperReply::Cancelled));
    laptop
        .until("cancel seen", |client| closed(client, again.id).is_some())
        .await;

    // Answers with control characters would end the line early or signal: refused.
    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "ssh host"));
    laptop
        .until("third prompt", |client| prompts(client).len() == 3)
        .await;
    let third = prompts(&laptop)[2].clone();
    assert_eq!(third.source, SecretSource::Ssh);
    assert!(matches!(
        laptop
            .client
            .answer_askpass(third.id, Secret::new(b"a\nb".to_vec()))
            .await,
        Err(AskpassError::Failed(_))
    ));
    laptop
        .client
        .answer_askpass(third.id, Secret::new("pässwörd".as_bytes().to_vec()))
        .await
        .unwrap();
    assert_eq!(answer_of(&reply(task).await), Some("pässwörd"));

    // A yes/no question is marked as not secret.
    let task = spawn_helper(
        &socket,
        call(
            dir.path(),
            pane,
            "Are you sure you want to continue connecting (yes/no/[fingerprint])?",
            "ssh new-host",
        ),
    );
    laptop
        .until("question", |client| prompts(client).len() == 4)
        .await;
    let question = prompts(&laptop)[3].clone();
    assert!(question.echo);
    laptop
        .client
        .answer_askpass(question.id, Secret::new(b"yes".to_vec()))
        .await
        .unwrap();
    assert_eq!(answer_of(&reply(task).await), Some("yes"));

    plain.until("settled", |_| true).await;
    assert!(plain.askpass.is_empty());
    // Nothing secret reaches the daemon's log of events either.
    assert!(!laptop.log.iter().any(|line| line.contains("hunter2")));
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_never_see_prompts_and_the_owner_is_told_who_drives() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let socket = daemon.hook_socket().to_owned();
    let mut owner = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;

    let spec = |roles, label: &str| {
        let mut spec = client_core::grants::GrantSpec::new(roles, Scope::Daemon);
        spec.label = label.into();
        spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
        spec
    };
    let viewer_invite = owner
        .client
        .create_invite(spec(Roles::VIEWER, "carol"), "carol".into())
        .await
        .unwrap();
    let driver_invite = owner
        .client
        .create_invite(spec(Roles::DRIVER, "bob"), "bob".into())
        .await
        .unwrap();
    // Both guests offer to show prompts anyway, as a client ignoring the rule would.
    let insist = ConnectOptions {
        askpass: true,
        extra_caps: Caps::ASKPASS | Caps::ASKPASS_DRIVER,
        ..ConnectOptions::default()
    };
    let mut carol = TestClient::join_options(&viewer_invite.to_string(), insist.clone());
    carol.client.attach(None);
    carol
        .until("guest layout", |client| client.layout.is_some())
        .await;
    carol.follow(pane).await;
    let mut bob = TestClient::join_options(&driver_invite.to_string(), insist);
    bob.client.attach(None);
    bob.until("guest layout", |client| client.layout.is_some())
        .await;
    bob.follow(pane).await;

    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "sudo -A id"));
    owner
        .until("prompt", |client| !prompts(client).is_empty())
        .await;
    let prompt = prompts(&owner)[0].clone();

    // No guest is told, whatever its role, and guessing the id gets it nowhere: a host that
    // is not theirs must never ask for their passwords.
    for guest in [&carol, &bob] {
        assert!(matches!(
            guest
                .client
                .answer_askpass(prompt.id, Secret::new(b"guess".to_vec()))
                .await,
            Err(AskpassError::Denied(_))
        ));
        assert!(matches!(
            guest.client.cancel_askpass(prompt.id).await,
            Err(AskpassError::Denied(_))
        ));
    }
    assert!(matches!(
        carol
            .client
            .type_secret(pane, Secret::new(b"x".to_vec()))
            .await,
        Err(AskpassError::Denied(_))
    ));
    owner
        .client
        .answer_askpass(prompt.id, Secret::new(b"from-owner".to_vec()))
        .await
        .unwrap();
    assert_eq!(answer_of(&reply(task).await), Some("from-owner"));

    // Bob drives the pane: the next prompt tells the owner, since bob may have typed the
    // command that asks.
    bob.type_line(pane, "echo bob-drives");
    bob.wait_text(pane, "bob-drives").await;
    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "sudo -A id"));
    owner
        .until("the prompt names bob", |client| {
            client.askpass.iter().any(|event| {
                matches!(event, AskpassEvent::PromptWhileGuestDrives { guest, .. } if guest == "bob")
            })
        })
        .await;
    let id = owner.client.open_askpass()[0].id;
    assert_eq!(owner.client.askpass_guest(id).as_deref(), Some("bob"));
    owner.client.cancel_askpass(id).await.unwrap();
    assert!(matches!(reply(task).await, HelperReply::Cancelled));

    carol.until("settled", |_| true).await;
    bob.until("settled", |_| true).await;
    assert!(carol.askpass.is_empty(), "viewer got {:?}", carol.askpass);
    assert!(bob.askpass.is_empty(), "driver got {:?}", bob.askpass);
}

#[tokio::test(flavor = "multi_thread")]
async fn unanswered_prompts_time_out_and_abandoned_ones_close() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |config| {
        config.askpass.timeout = Duration::from_millis(800);
    })
    .await;
    let socket = daemon.hook_socket().to_owned();
    let mut laptop = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    let pane = laptop.attach_and_follow().await;

    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "sudo -A ls"));
    laptop
        .until("prompt", |client| !prompts(client).is_empty())
        .await;
    let prompt = prompts(&laptop)[0].clone();
    assert!(matches!(reply(task).await, HelperReply::Cancelled));
    laptop
        .until("timed out", |client| closed(client, prompt.id).is_some())
        .await;
    assert_eq!(closed(&laptop, prompt.id), Some(CloseReason::TimedOut));

    // The program gives up (Ctrl-C kills sudo and its helper): the prompt closes at once.
    let mut stream = UnixStream::connect(&socket).await.unwrap();
    let mut line = serde_json::to_vec(&call(dir.path(), pane, "Passphrase:", "ssh-add")).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    laptop
        .until("second prompt", |client| prompts(client).len() == 2)
        .await;
    let second = prompts(&laptop)[1].clone();
    drop(stream);
    laptop
        .until("abandoned", |client| closed(client, second.id).is_some())
        .await;
    assert_eq!(closed(&laptop, second.id), Some(CloseReason::Abandoned));
    assert_eq!(
        laptop
            .client
            .answer_askpass(second.id, Secret::new(b"late".to_vec()))
            .await,
        Err(AskpassError::Gone)
    );

    // A bad token gets nothing but "ask on the terminal".
    let mut bad = call(dir.path(), pane, "Password:", "sudo");
    bad.token = "nope".into();
    assert!(matches!(helper(&socket, bad).await, HelperReply::Terminal));
}

#[tokio::test(flavor = "multi_thread")]
async fn without_an_app_the_helper_asks_on_the_terminal() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |config| {
        config.askpass.grace = Duration::from_millis(500);
    })
    .await;
    let socket = daemon.hook_socket().to_owned();
    let mut plain = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = plain.attach_and_follow().await;

    let mut probe = call(dir.path(), pane, "", "");
    probe.askpass.probe = true;
    assert!(matches!(
        helper(&socket, probe.clone()).await,
        HelperReply::Available(false)
    ));
    assert!(matches!(
        helper(&socket, call(dir.path(), pane, "Password:", "sudo")).await,
        HelperReply::Terminal
    ));

    // An app that can answer comes; then it goes away with the prompt open.
    let mut laptop = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    laptop.attach_and_follow().await;
    assert!(matches!(
        helper(&socket, probe).await,
        HelperReply::Available(true)
    ));
    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "sudo"));
    laptop
        .until("prompt", |client| !prompts(client).is_empty())
        .await;
    drop(laptop);
    assert!(matches!(reply(task).await, HelperReply::Terminal));
}

#[tokio::test(flavor = "multi_thread")]
async fn detected_password_prompts_take_a_secret_without_echo() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut laptop = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    let pane = laptop.attach_and_follow().await;

    // At the shell prompt input is echoed: nothing is typed.
    laptop.type_line(pane, "echo ready-$((1+1))");
    laptop.wait_text(pane, "ready-2").await;
    assert_eq!(
        laptop
            .client
            .type_secret(pane, Secret::new(b"nope".to_vec()))
            .await,
        Err(AskpassError::NotHidden)
    );

    // A program that reads a password itself: echo off, then the prompt.
    laptop.type_line(
        pane,
        "stty -echo; printf 'Pass''word: '; read pw; stty echo; echo; echo \"len=${#pw} got=$pw\"",
    );
    laptop
        .until("detected", |client| {
            client.askpass.iter().any(
                |event| matches!(event, AskpassEvent::Detected(shown) if shown.pane_id == pane),
            )
        })
        .await;
    let detected = laptop.client.detected_prompt(pane).expect("kept");
    assert_eq!(detected.prompt, "Password:");

    laptop
        .client
        .type_secret(pane, Secret::new(b"s3cret".to_vec()))
        .await
        .expect("typed while hidden");
    laptop.wait_text(pane, "len=6 got=s3cret").await;
    laptop
        .until("gone", |client| {
            client.askpass.iter().any(
                |event| matches!(event, AskpassEvent::DetectedGone { pane_id } if *pane_id == pane),
            )
        })
        .await;
    assert!(laptop.client.detected_prompt(pane).is_none());
    // The secret was never echoed: it appears only in the program's own output.
    assert_eq!(
        laptop.text(pane).matches("s3cret").count(),
        1,
        "{}",
        laptop.text(pane)
    );

    // A client attaching while a prompt shows is told about it.
    laptop.type_line(
        pane,
        "stty -echo; printf 'Enter passphrase: '; read pw; stty echo",
    );
    laptop
        .until("detected again", |client| {
            client.client.detected_prompt(pane).is_some()
        })
        .await;
    let mut tablet = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    tablet.attach_and_follow().await;
    tablet
        .until("b told", |client| {
            client.client.detected_prompt(pane).is_some()
        })
        .await;
    assert_eq!(
        tablet.client.detected_prompt(pane).unwrap().prompt,
        "Enter passphrase:"
    );
    tablet
        .client
        .type_secret(pane, Secret::new(b"x".to_vec()))
        .await
        .unwrap();
    tablet
        .until("gone on b", |client| {
            client.client.detected_prompt(pane).is_none()
        })
        .await;
}
