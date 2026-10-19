//! Native password prompts end to end (docs/DAEMON.md §9): the askpass helper's requests on
//! the hook socket (a fake helper here; `crates/hostd/tests/askpass.rs` runs the real one),
//! prompts pushed only to connections that asked and may drive the pane, first answer wins,
//! guests who only watch never see them, timeouts, abandoned and orphaned prompts, and
//! detected terminal password prompts answered with `TypeSecret`.

use std::path::Path;
use std::time::Duration;

use client_core::proto::{
    AskpassError, AskpassId, CloseReason, PaneId, Roles, Scope, Secret, SecretPrompt, SecretSource,
    UnixMillis,
};
use client_core::{AskpassEvent, ClientConfig, now_millis};
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

fn prompts(c: &TestClient) -> Vec<SecretPrompt> {
    c.askpass
        .iter()
        .filter_map(|e| match e {
            AskpassEvent::Prompt(p) => Some(p.clone()),
            _ => None,
        })
        .collect()
}

fn closed(c: &TestClient, id: AskpassId) -> Option<CloseReason> {
    c.askpass.iter().find_map(|e| match e {
        AskpassEvent::Closed { id: i, reason, .. } if *i == id => Some(*reason),
        _ => None,
    })
}

fn answer_of(r: &HelperReply) -> Option<&str> {
    match r {
        HelperReply::Answer(s) => Some(s),
        _ => None,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn askpass_prompt_goes_to_the_app_and_the_first_answer_wins() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let socket = daemon.hook_socket().to_owned();
    let mut a = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    let pane = a.attach_and_follow().await;
    let mut b = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    b.attach_and_follow().await;
    // A client that did not ask for prompts (an older app, the CLI) is never sent one.
    let mut plain = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    plain.attach_and_follow().await;

    // Panes carry the helper and the hook socket's coordinates.
    a.type_line(
        pane,
        "printf '%s|%s|%s|%s\\n' \"${SUDO_ASKPASS##*/}\" \"${SSH_ASKPASS##*/}\" \
         \"$SSH_ASKPASS_REQUIRE\" \"${GIT_ASKPASS##*/}\"",
    );
    a.wait_text(pane, "un-askpass|un-askpass|prefer|un-askpass")
        .await;
    let helper_path = dir.path().join("askpass/un-askpass");
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
    a.until("prompt on a", |c| !prompts(c).is_empty()).await;
    b.until("prompt on b", |c| !prompts(c).is_empty()).await;
    let p = prompts(&a)[0].clone();
    assert_eq!(p.pane_id, pane);
    assert_eq!(p.source, SecretSource::Sudo);
    assert_eq!(p.prompt, "[sudo] password for ana:");
    assert_eq!(p.program, "sudo -A apt upgrade");
    assert!(!p.echo && !p.retry);
    assert!(p.expires_at > UnixMillis(now_millis().0));
    assert_eq!(a.client.open_askpass(), vec![p.clone()]);

    a.client
        .answer_askpass(p.id, Secret::new(b"hunter2".to_vec()))
        .await
        .expect("first answer");
    let got = reply(task).await;
    assert_eq!(answer_of(&got), Some("hunter2"));
    // The other device's sheet closes; its late answer is refused.
    b.until("closed on b", |c| closed(c, p.id).is_some()).await;
    let me = a.client.me().unwrap().actor.principal;
    assert_eq!(closed(&b, p.id), Some(CloseReason::Answered { by: me }));
    assert_eq!(
        b.client
            .answer_askpass(p.id, Secret::new(b"other".to_vec()))
            .await,
        Err(AskpassError::Gone)
    );
    assert!(b.client.open_askpass().is_empty());

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
    b.until("second prompt", |c| prompts(c).len() == 2).await;
    let again = prompts(&b)[1].clone();
    assert!(again.retry);
    b.client.cancel_askpass(again.id).await.unwrap();
    assert!(matches!(reply(task).await, HelperReply::Cancelled));
    a.until("cancel seen", |c| closed(c, again.id).is_some())
        .await;

    // Answers with control characters would end the line early or signal: refused.
    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "ssh host"));
    a.until("third prompt", |c| prompts(c).len() == 3).await;
    let third = prompts(&a)[2].clone();
    assert_eq!(third.source, SecretSource::Ssh);
    assert!(matches!(
        a.client
            .answer_askpass(third.id, Secret::new(b"a\nb".to_vec()))
            .await,
        Err(AskpassError::Failed(_))
    ));
    a.client
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
    a.until("question", |c| prompts(c).len() == 4).await;
    let question = prompts(&a)[3].clone();
    assert!(question.echo);
    a.client
        .answer_askpass(question.id, Secret::new(b"yes".to_vec()))
        .await
        .unwrap();
    assert_eq!(answer_of(&reply(task).await), Some("yes"));

    plain.until("settled", |_| true).await;
    assert!(plain.askpass.is_empty());
    // Nothing secret reaches the daemon's log of events either.
    assert!(!a.log.iter().any(|l| l.contains("hunter2")));
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_who_only_watch_never_see_prompts_and_cannot_answer() {
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
    let mut carol =
        TestClient::join_askpass(&viewer_invite.to_string(), ClientConfig::generate_key());
    carol.client.attach(None);
    carol.until("guest layout", |c| c.layout.is_some()).await;
    carol.follow(pane).await;
    let mut bob =
        TestClient::join_askpass(&driver_invite.to_string(), ClientConfig::generate_key());
    bob.client.attach(None);
    bob.until("guest layout", |c| c.layout.is_some()).await;
    bob.follow(pane).await;

    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "sudo -A id"));
    owner.until("prompt", |c| !prompts(c).is_empty()).await;
    bob.until("driver sees it", |c| !prompts(c).is_empty())
        .await;
    let p = prompts(&owner)[0].clone();

    // The viewer is told nothing, and guessing the id gets it nowhere.
    assert_eq!(
        carol
            .client
            .answer_askpass(p.id, Secret::new(b"guess".to_vec()))
            .await
            .map_err(|e| matches!(e, AskpassError::Denied(_))),
        Err(true)
    );
    assert!(matches!(
        carol.client.cancel_askpass(p.id).await,
        Err(AskpassError::Denied(_))
    ));
    assert!(matches!(
        carol
            .client
            .type_secret(pane, Secret::new(b"x".to_vec()))
            .await,
        Err(AskpassError::Denied(_))
    ));

    bob.client
        .answer_askpass(p.id, Secret::new(b"from-bob".to_vec()))
        .await
        .unwrap();
    assert_eq!(answer_of(&reply(task).await), Some("from-bob"));
    owner
        .until("closed for the owner", |c| closed(c, p.id).is_some())
        .await;
    carol.until("settled", |_| true).await;
    assert!(carol.askpass.is_empty(), "viewer got {:?}", carol.askpass);
}

#[tokio::test(flavor = "multi_thread")]
async fn unanswered_prompts_time_out_and_abandoned_ones_close() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |c| {
        c.askpass.timeout = Duration::from_millis(800);
    })
    .await;
    let socket = daemon.hook_socket().to_owned();
    let mut a = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    let pane = a.attach_and_follow().await;

    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "sudo -A ls"));
    a.until("prompt", |c| !prompts(c).is_empty()).await;
    let p = prompts(&a)[0].clone();
    assert!(matches!(reply(task).await, HelperReply::Cancelled));
    a.until("timed out", |c| closed(c, p.id).is_some()).await;
    assert_eq!(closed(&a, p.id), Some(CloseReason::TimedOut));

    // The program gives up (Ctrl-C kills sudo and its helper): the prompt closes at once.
    let mut stream = UnixStream::connect(&socket).await.unwrap();
    let mut line = serde_json::to_vec(&call(dir.path(), pane, "Passphrase:", "ssh-add")).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    a.until("second prompt", |c| prompts(c).len() == 2).await;
    let second = prompts(&a)[1].clone();
    drop(stream);
    a.until("abandoned", |c| closed(c, second.id).is_some())
        .await;
    assert_eq!(closed(&a, second.id), Some(CloseReason::Abandoned));
    assert_eq!(
        a.client
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
    let daemon = start_with(dir.path(), |c| {
        c.askpass.grace = Duration::from_millis(500);
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
    let mut a = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    a.attach_and_follow().await;
    assert!(matches!(
        helper(&socket, probe).await,
        HelperReply::Available(true)
    ));
    let task = spawn_helper(&socket, call(dir.path(), pane, "Password:", "sudo"));
    a.until("prompt", |c| !prompts(c).is_empty()).await;
    drop(a);
    assert!(matches!(reply(task).await, HelperReply::Terminal));
}

#[tokio::test(flavor = "multi_thread")]
async fn detected_password_prompts_take_a_secret_without_echo() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut a = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    let pane = a.attach_and_follow().await;

    // At the shell prompt input is echoed: nothing is typed.
    a.type_line(pane, "echo ready-$((1+1))");
    a.wait_text(pane, "ready-2").await;
    assert_eq!(
        a.client
            .type_secret(pane, Secret::new(b"nope".to_vec()))
            .await,
        Err(AskpassError::NotHidden)
    );

    // A program that reads a password itself: echo off, then the prompt.
    a.type_line(
        pane,
        "stty -echo; printf 'Pass''word: '; read pw; stty echo; echo; echo \"len=${#pw} got=$pw\"",
    );
    a.until("detected", |c| {
        c.askpass
            .iter()
            .any(|e| matches!(e, AskpassEvent::Detected(d) if d.pane_id == pane))
    })
    .await;
    let detected = a.client.detected_prompt(pane).expect("kept");
    assert_eq!(detected.prompt, "Password:");

    a.client
        .type_secret(pane, Secret::new(b"s3cret".to_vec()))
        .await
        .expect("typed while hidden");
    a.wait_text(pane, "len=6 got=s3cret").await;
    a.until("gone", |c| {
        c.askpass
            .iter()
            .any(|e| matches!(e, AskpassEvent::DetectedGone { pane_id } if *pane_id == pane))
    })
    .await;
    assert!(a.client.detected_prompt(pane).is_none());
    // The secret was never echoed: it appears only in the program's own output.
    assert_eq!(
        a.text(pane).matches("s3cret").count(),
        1,
        "{}",
        a.text(pane)
    );

    // A client attaching while a prompt shows is told about it.
    a.type_line(
        pane,
        "stty -echo; printf 'Enter passphrase: '; read pw; stty echo",
    );
    a.until("detected again", |c| {
        c.client.detected_prompt(pane).is_some()
    })
    .await;
    let mut b = TestClient::connect_askpass(&ticket(&daemon), ClientConfig::generate_key());
    b.attach_and_follow().await;
    b.until("b told", |c| c.client.detected_prompt(pane).is_some())
        .await;
    assert_eq!(
        b.client.detected_prompt(pane).unwrap().prompt,
        "Enter passphrase:"
    );
    b.client
        .type_secret(pane, Secret::new(b"x".to_vec()))
        .await
        .unwrap();
    b.until("gone on b", |c| c.client.detected_prompt(pane).is_none())
        .await;
}
