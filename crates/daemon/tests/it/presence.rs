//! everyone who can see the pane while they are typed, never touch the terminal, and respect
//! roles and scope; raw typing says who types; following tracks focus and scroll; silent peers
//! turn away and then go; a reconnect sends everything again; concurrent approvals have one
//! winner that everyone sees.

use std::time::{Duration, Instant};

use client_core::grants::GrantSpec;
use client_core::proto::{
    AgentState, DeviceClass, Draft, DraftSource, OpOutcome, OptionId, PaneId, PaneLaunch, Peer,
    PeerViewport, PresenceState, PrincipalId, Roles, Scope, UnixMillis,
};
use client_core::{ClientConfig, MultiplayerEvent, now_millis};
use daemon::{Daemon, PresenceTimes};

use crate::support::{TestClient, leaves, start_with, ticket};

const PERMISSION: &str =
    include_str!("../../../agents/tests/fixtures/claude/permission_request.json");

/// Short timings so typing, idleness and silence show within a test.
async fn daemon(dir: &std::path::Path, times: PresenceTimes) -> Daemon {
    start_with(dir, |c| c.presence = times).await
}

fn quick() -> PresenceTimes {
    PresenceTimes {
        typing: Duration::from_millis(600),
        idle: Duration::from_secs(600),
        away: Duration::from_secs(600),
        gone: Duration::from_secs(600),
    }
}

fn spec(roles: Roles, label: &str, scope: Scope) -> GrantSpec {
    let mut spec = GrantSpec::new(roles, scope);
    spec.label = label.into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    spec
}

async fn guest(owner: &TestClient, spec: GrantSpec, pane: PaneId) -> TestClient {
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .expect("invite");
    let mut g = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    g.client.attach(None);
    g.until("guest layout", |c| c.layout.is_some()).await;
    g.follow(pane).await;
    g
}

fn principal(c: &TestClient) -> PrincipalId {
    c.client.me().expect("joined").actor.principal
}

/// `who`'s presence as `c` holds it (their most recent connection).
fn peer(c: &TestClient, who: PrincipalId) -> Option<Peer> {
    c.client
        .peers()
        .1
        .into_iter()
        .filter(|p| p.actor.principal == who)
        .max_by_key(|p| p.peer)
}

fn draft_text(c: &TestClient, who: PrincipalId) -> Option<String> {
    peer(c, who)?.draft.map(|d| d.text)
}

fn draft(pane: PaneId, text: &str) -> Draft {
    Draft {
        pane_id: pane,
        source: DraftSource::Composer,
        text: text.into(),
        caret: text.chars().count() as u32,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn drafts_reach_everyone_live_and_never_the_terminal() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path(), quick()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let kim = guest(&owner, spec(Roles::DRIVER, "Kim", Scope::Daemon), pane).await;
    let mut rex = guest(&owner, spec(Roles::VIEWER, "Rex", Scope::Daemon), pane).await;
    assert!(kim.client.has_live_presence());
    let kim_p = principal(&kim);
    owner
        .until("three peers", |c| c.client.peers().1.len() == 3)
        .await;

    // Typed one character at a time: every guest follows along, and the last keystroke
    // arrives well within a frame budget on loopback.
    let prompt = "refactor the parser";
    let mut worst = Duration::ZERO;
    for end in 1..=prompt.len() {
        let typed = &prompt[..end];
        let at = Instant::now();
        kim.client.set_draft(Some(draft(pane, typed)));
        owner
            .until("draft on the owner", |c| {
                draft_text(c, kim_p).as_deref() == Some(typed)
            })
            .await;
        worst = worst.max(at.elapsed());
        rex.until("draft on the viewer", |c| {
            draft_text(c, kim_p).as_deref() == Some(typed)
        })
        .await;
    }
    eprintln!("worst keystroke-to-peer latency: {worst:?}");
    assert!(
        worst < Duration::from_millis(300),
        "draft latency {worst:?}"
    );
    let seen = peer(&owner, kim_p).unwrap();
    assert_eq!(seen.typing, Some(pane), "typing while drafting");
    assert_eq!(seen.draft.unwrap().caret, prompt.len() as u32);

    // The old participant list says "typing" too, for clients without live presence.
    owner
        .until("old-style typing", |c| {
            c.mp.iter().any(|e| {
                matches!(e, MultiplayerEvent::Presence { presence }
                    if presence.actor.principal == kim_p && presence.typing)
            })
        })
        .await;

    // Typing stops: the draft stays, the indicator goes.
    owner
        .until("typing over", |c| {
            peer(c, kim_p).is_some_and(|p| p.typing.is_none() && p.draft.is_some())
        })
        .await;

    // Sent or discarded: gone for everyone. It never reached the terminal or the audit log.
    kim.client.set_draft(None);
    rex.until("draft cleared", |c| {
        peer(c, kim_p).is_some_and(|p| p.draft.is_none())
    })
    .await;
    assert!(!owner.text(pane).contains("refactor"));
    let audit = owner.client.audit(None, 500).await.unwrap();
    assert!(audit.records.iter().all(|r| !r.detail.contains("refactor")));

    // A viewer cannot draft: refused, and nobody sees it.
    let rex_p = principal(&rex);
    rex.client.set_draft(Some(draft(pane, "rm -rf")));
    rex.until("draft refused", |c| {
        c.mp.iter()
            .any(|e| matches!(e, MultiplayerEvent::Forbidden { what, .. } if what == "Draft"))
    })
    .await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    owner.until("settled", |_| true).await;
    assert_eq!(draft_text(&owner, rex_p), None);

    drop((kim, rex, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn typing_in_the_terminal_says_who_types() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path(), quick()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut kim = guest(&owner, spec(Roles::VIEWER, "Kim", Scope::Daemon), pane).await;
    let owner_p = principal(&owner);
    kim.until("owner listed", |c| peer(c, owner_p).is_some())
        .await;

    // The keystrokes themselves arrive as terminal output; presence adds who.
    owner.type_line(pane, "echo typed-by-owner");
    kim.wait_text(pane, "typed-by-owner").await;
    kim.until("owner typing", |c| {
        peer(c, owner_p).is_some_and(|p| p.typing == Some(pane))
    })
    .await;
    kim.until("typing over", |c| {
        peer(c, owner_p).is_some_and(|p| p.typing.is_none())
    })
    .await;
    drop((kim, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn following_tracks_focus_and_scroll() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path(), quick()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let first = owner.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: second } = owner
        .op(client_core::proto::LayoutOp::Split {
            pane_id: first,
            axis: client_core::proto::Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split failed")
    };
    let mut kim = guest(&owner, spec(Roles::DRIVER, "Kim", Scope::Daemon), first).await;
    let owner_p = principal(&owner);
    let kim_p = principal(&kim);

    kim.client.follow(Some(owner_p));
    kim.client.set_device_class(DeviceClass::Tablet);
    owner
        .until("kim follows", |c| {
            peer(c, kim_p)
                .is_some_and(|p| p.following == Some(owner_p) && p.device == DeviceClass::Tablet)
        })
        .await;

    // The leader moves: focus and scroll position reach the follower.
    owner.client.set_view(Some(second), vec![first, second]);
    let viewport = PeerViewport {
        pane_id: second,
        from_bottom: 42,
        rows: 30,
    };
    owner.client.set_viewport(Some(viewport));
    kim.until("leader moved", |c| {
        peer(c, owner_p).is_some_and(|p| p.focus == Some(second) && p.viewport == Some(viewport))
    })
    .await;

    kim.client.follow(None);
    owner
        .until("kim stopped", |c| {
            peer(c, kim_p).is_some_and(|p| p.following.is_none())
        })
        .await;
    drop((kim, owner));
    daemon.shutdown().await;
}

/// A session-scoped viewer follows the owner into a tab opened after joining (an agent gets
/// its own tab): the tab, the owner's focus on it and its live output reach the guest within
/// a second, and every frame keeps coming.
#[tokio::test(flavor = "multi_thread")]
async fn a_follower_sees_a_new_tab_and_its_output_live() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path(), quick()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let first = owner.attach_and_follow().await;
    let session = owner.layout.as_ref().unwrap().session_id;
    let mut gus = guest(
        &owner,
        spec(Roles::VIEWER, "Gus", Scope::Session(session)),
        first,
    )
    .await;
    let owner_p = principal(&owner);
    gus.client.follow(Some(owner_p));
    gus.until("owner listed", |c| peer(c, owner_p).is_some())
        .await;

    let at = Instant::now();
    let OpOutcome::TabCreated { pane_id: agent, .. } = owner
        .op(client_core::proto::LayoutOp::NewTab {
            session_id: session,
            name: "agent".into(),
            launch: PaneLaunch::Command {
                argv: vec![
                    "sh".into(),
                    "-c".into(),
                    "i=0; while :; do i=$((i+1)); printf '\\rframe %d ' $i; sleep 0.02; done"
                        .into(),
                ],
                cwd: None,
            },
        })
        .await
    else {
        panic!("new tab failed")
    };
    owner.client.set_view(Some(agent), vec![agent]);

    // What the follower's window does: the tab arrives, the leader is on it, so show it.
    gus.until("the new tab and the leader on it", |c| {
        c.layout
            .as_ref()
            .is_some_and(|l| l.tabs.iter().any(|t| leaves(&t.root).contains(&agent)))
            && peer(c, owner_p).is_some_and(|p| p.focus == Some(agent))
    })
    .await;
    gus.follow(agent).await;
    gus.wait_text(agent, "frame").await;
    let latency = at.elapsed();
    eprintln!("new tab to follower's screen: {latency:?}");
    assert!(latency < Duration::from_secs(1), "took {latency:?}");

    // Live, not a snapshot: frames keep arriving.
    let frame = |c: &TestClient| -> u32 {
        let text = c.text(agent);
        text.rsplit("frame ")
            .next()
            .and_then(|s| s.split_whitespace().next())
            .and_then(|n| n.parse().ok())
            .unwrap_or(0)
    };
    let seen = frame(&gus);
    gus.until("ten more frames", |c| frame(c) >= seen + 10)
        .await;

    drop((gus, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn silent_peers_turn_away_then_go_and_come_back_whole() {
    let dir = tempfile::tempdir().unwrap();
    let times = PresenceTimes {
        away: Duration::from_millis(1200),
        gone: Duration::from_millis(2500),
        ..quick()
    };
    let daemon = daemon(dir.path(), times).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let kim = guest(&owner, spec(Roles::DRIVER, "Kim", Scope::Daemon), pane).await;
    let kim_p = principal(&kim);
    kim.client.set_draft(Some(draft(pane, "half a thought")));
    owner
        .until("draft", |c| draft_text(c, kim_p).is_some())
        .await;
    let first = peer(&owner, kim_p).unwrap().peer;

    // Kim's app says nothing (its heartbeat is every 10 s): away, then dropped, so no ghost
    // stays. Its client reconnects at once and says everything again, draft included.
    owner
        .until("kim away", |c| {
            peer(c, kim_p).is_some_and(|p| p.state == PresenceState::Away)
        })
        .await;
    owner
        .until("old connection gone, new one whole", |c| {
            let peers = c.client.peers().1;
            !peers.iter().any(|p| p.peer == first)
                && peers.iter().any(|p| {
                    p.actor.principal == kim_p
                        && p.state == PresenceState::Active
                        && p.draft.as_ref().is_some_and(|d| d.text == "half a thought")
                })
        })
        .await;
    drop((kim, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn scoped_guest_sees_presence_only_in_its_scope() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path(), quick()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shared = owner.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: private } = owner
        .op(client_core::proto::LayoutOp::Split {
            pane_id: shared,
            axis: client_core::proto::Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split failed")
    };
    let mut pam = guest(
        &owner,
        spec(Roles::DRIVER, "Pam", Scope::Pane(shared)),
        shared,
    )
    .await;
    let owner_p = principal(&owner);

    // In the private pane: Pam sees the owner is here, not where or what.
    owner.client.set_view(Some(private), vec![shared, private]);
    owner.client.set_draft(Some(draft(private, "secret plan")));
    owner.client.set_viewport(Some(PeerViewport {
        pane_id: private,
        from_bottom: 0,
        rows: 30,
    }));
    tokio::time::sleep(Duration::from_millis(300)).await;
    pam.until("owner listed", |c| peer(c, owner_p).is_some())
        .await;
    let seen = peer(&pam, owner_p).unwrap();
    assert_eq!(seen.focus, None);
    assert_eq!(seen.draft, None);
    assert_eq!(seen.viewport, None);
    assert_eq!(seen.typing, None);

    // In the shared pane: all of it.
    owner.client.set_view(Some(shared), vec![shared, private]);
    owner.client.set_draft(Some(draft(shared, "shared plan")));
    pam.until("owner's shared draft", |c| {
        peer(c, owner_p).is_some_and(|p| {
            p.focus == Some(shared) && p.draft.is_some_and(|d| d.text == "shared plan")
        })
    })
    .await;
    drop((pam, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_typing_burst_is_coalesced_and_ends_on_the_last_keystroke() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path(), quick()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut kim = guest(&owner, spec(Roles::DRIVER, "Kim", Scope::Daemon), pane).await;
    let mut rex = guest(&owner, spec(Roles::VIEWER, "Rex", Scope::Daemon), pane).await;
    let owner_p = principal(&owner);
    for c in [&mut kim, &mut rex] {
        c.until("owner listed", |c| peer(c, owner_p).is_some())
            .await;
    }

    // 2 000 edits as fast as the app can make them: the wire carries a few, the last wins.
    let mut text = String::new();
    for i in 0..2000 {
        text.push(char::from(b'a' + (i % 26) as u8));
        owner.client.set_draft(Some(draft(pane, &text)));
    }
    for c in [&mut kim, &mut rex] {
        c.until("last keystroke", |c| {
            draft_text(c, owner_p).is_some_and(|t| t == text)
        })
        .await;
        let changes: Vec<u64> =
            c.mp.iter()
                .filter_map(|e| match e {
                    MultiplayerEvent::PeerChanged { peer } if peer.actor.principal == owner_p => {
                        Some(peer.rev)
                    }
                    _ => None,
                })
                .collect();
        assert!(
            changes.len() < 200,
            "{} pushes for 2 000 edits",
            changes.len()
        );
        assert!(
            changes.windows(2).all(|w| w[0] < w[1]),
            "revisions only grow"
        );
    }
    drop((kim, rex, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn concurrent_approvals_have_one_winner_everyone_sees() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path(), quick()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut ann = guest(
        &owner,
        spec(Roles::APPROVER | Roles::VIEWER, "Ann", Scope::Daemon),
        pane,
    )
    .await;
    let mut viv = guest(&owner, spec(Roles::VIEWER, "Viv", Scope::Daemon), pane).await;

    let socket = daemon.hook_socket().to_owned();
    let token = std::fs::read_to_string(dir.path().join("hook.token")).unwrap();
    let request = daemon::HookRequest {
        v: 1,
        token,
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: "PermissionRequest".into(),
        seq: 1,
        payload: serde_json::from_str(PERMISSION).unwrap(),
    };
    let waiting = tokio::spawn(async move {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
        let mut stream = tokio::net::UnixStream::connect(&socket).await.unwrap();
        let mut line = serde_json::to_vec(&request).unwrap();
        line.push(b'\n');
        stream.write_all(&line).await.unwrap();
        let mut answer = String::new();
        tokio::io::BufReader::new(stream)
            .read_line(&mut answer)
            .await
            .unwrap();
        answer
    });
    // Everyone in the session sees the request, viewers included.
    let blocked = |c: &TestClient| {
        c.metas
            .get(&pane)
            .and_then(|m| m.agent.clone())
            .and_then(|a| match a.state {
                AgentState::Blocked(b) => Some(b),
                _ => None,
            })
    };
    viv.until("viewer sees the request", |c| blocked(c).is_some())
        .await;
    ann.until("approver sees the request", |c| blocked(c).is_some())
        .await;
    let request = blocked(&ann).unwrap().request_id;

    // Two answers at once: exactly one wins, the other is told who did.
    ann.client.decide(request, OptionId(0));
    owner.client.decide(request, OptionId(0));
    tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .expect("hook answered")
        .unwrap();
    let winner = |c: &TestClient| {
        c.mp.iter().find_map(|e| match e {
            MultiplayerEvent::Decided { decided } if decided.request_id == request => {
                Some(decided.decided_by)
            }
            _ => None,
        })
    };
    viv.until("viewer sees who answered", |c| winner(c).is_some())
        .await;
    let won = winner(&viv).unwrap();
    for c in [&mut ann, &mut owner] {
        c.until("same winner", |c| winner(c) == Some(won)).await;
    }
    let loser = if won.principal == principal(&ann) {
        &mut owner
    } else {
        &mut ann
    };
    loser
        .until("loser told", |c| {
            c.mp.iter()
                .any(|e| matches!(e, MultiplayerEvent::AlreadyDecided { by, .. } if *by == won))
        })
        .await;
    drop((ann, viv, owner));
    daemon.shutdown().await;
}
