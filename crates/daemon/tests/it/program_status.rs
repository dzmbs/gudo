//! Program status: what any program in a pane reports through OSC 7501 reaches clients that
//! asked for it, at once on joining, and never those that did not.

use client_core::ClientConfig;
use client_core::proto::{PaneId, ProgramKind, ProgramReport, ProgramState};

use crate::support::{TestClient, start, ticket};

fn last(c: &TestClient, pane: PaneId) -> Option<Option<ProgramReport>> {
    c.programs
        .iter()
        .rev()
        .find(|(p, _)| *p == pane)
        .map(|(_, s)| s.clone())
}

#[tokio::test(flavor = "multi_thread")]
async fn any_programs_status_reaches_clients_that_ask() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    // A ticket pairs one device.
    let mut watcher =
        TestClient::connect_program_status(&ticket(&daemon), ClientConfig::generate_key());
    let mut plain = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = watcher.attach_and_follow().await;
    plain.attach_and_follow().await;

    // `\033`, not `\e`: dash's printf (Linux /bin/sh) has no `\e`.
    watcher.type_line(
        pane,
        r"printf '\033]7501;state=blocked:kind=question:app=pi:msg=V2hpY2ggZnJhbWV3b3JrPw==\033\\'",
    );
    let blocked = ProgramReport {
        state: ProgramState::Blocked,
        kind: Some(ProgramKind::Question),
        app: Some("pi".into()),
        message: Some("Which framework?".into()),
        progress: None,
    };
    watcher
        .until("the blocked report", |c| {
            last(c, pane) == Some(Some(blocked.clone()))
        })
        .await;
    assert_eq!(watcher.client.program_status(pane), Some(blocked.clone()));

    // A device arriving now sees it at once, before anything else changes.
    let mut late =
        TestClient::connect_program_status(&ticket(&daemon), ClientConfig::generate_key());
    late.until("the report on joining", |c| {
        last(c, pane) == Some(Some(blocked.clone()))
    })
    .await;
    // Attaching sends it again, so a client never keeps one cleared while it looked elsewhere.
    let joined = late.programs.len();
    late.attach_and_follow().await;
    late.until("the report on attaching", |c| c.programs.len() > joined)
        .await;
    assert_eq!(late.programs[joined], (pane, Some(blocked.clone())));

    // Offline, a client forgets what it can no longer keep current; back, it hears it again.
    late.client.suspend();
    late.until("the report forgotten", |c| last(c, pane) == Some(None))
        .await;
    assert_eq!(late.client.program_status(pane), None);
    late.client.reconnect();
    late.until("the report again", |c| {
        last(c, pane) == Some(Some(blocked.clone()))
    })
    .await;

    watcher.type_line(pane, r"printf '\033]7501;state=clear\033\\'");
    watcher
        .until("the cleared report", |c| last(c, pane) == Some(None))
        .await;
    late.until("the cleared report", |c| last(c, pane) == Some(None))
        .await;
    assert_eq!(watcher.client.program_status(pane), None);

    // A title change after it, on the same ordered stream, proves the plain client was sent
    // nothing.
    plain.type_line(pane, r"printf '\033]2;after-status\007'");
    plain
        .until("the title", |c| {
            c.metas
                .get(&pane)
                .is_some_and(|m| m.title == "after-status")
        })
        .await;
    assert!(plain.programs.is_empty(), "{:?}", plain.programs);
}

/// Printed text (`cat` of a hostile file) cannot pose as one of our agents asking for
/// permission in a pane where that agent is not running.
#[tokio::test(flavor = "multi_thread")]
async fn printed_text_cannot_pose_as_an_agent() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut watcher =
        TestClient::connect_program_status(&ticket(&daemon), ClientConfig::generate_key());
    let pane = watcher.attach_and_follow().await;
    // Clients show any spelling of an agent's name with that agent's mark.
    for app in [
        "claude-code",
        "codex",
        "claude",
        "Claude-Code",
        "CODEX",
        "codex-cli",
    ] {
        watcher.type_line(
            pane,
            &format!(r"printf '\033]7501;state=blocked:kind=permission:app={app}\033\\'"),
        );
    }
    // Then a report of its own, on the same ordered stream.
    watcher.type_line(pane, r"printf '\033]7501;state=working:app=make\033\\'");
    watcher
        .until("the make report", |c| {
            last(c, pane).flatten().and_then(|r| r.app).as_deref() == Some("make")
        })
        .await;
    let apps: Vec<_> = watcher
        .programs
        .iter()
        .filter_map(|(_, r)| r.as_ref()?.app.clone())
        .collect();
    assert_eq!(apps, ["make"]);
}
