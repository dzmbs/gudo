//! (owner only, two-person rule, claims, risk caps) and scrollback since joining.

use std::time::Duration;

use client_core::knock::{KnockOutcome, knock};
use client_core::proto::{
    Admit, AgentState, ApprovalMode, ApprovalPolicy, AuditKind, Blocker, CaseMode, History, Invite,
    InviteTerms, KnockOutcome as Outcome, KnockUpdate, MpError, OptionId, PaneId, Risk, Roles,
    Scope, SearchMode, SearchQuery, UnixMillis,
};
use client_core::{ClientConfig, ClientEvent, ConnectOptions, GrantSpec, MultiplayerEvent};
use client_core::{RelayMode, now_millis};
use daemon::{Daemon, HookRequest, HookResponse};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::task::JoinHandle;

use crate::support::{TestClient, start_with, ticket};

const PERMISSION: &str =
    include_str!("../../../agents/tests/fixtures/claude/permission_request.json");

async fn daemon(dir: &std::path::Path) -> Daemon {
    start_with(dir, |c| c.lease_idle = Duration::from_secs(3)).await
}

fn spec(roles: Roles, label: &str) -> GrantSpec {
    let mut spec = GrantSpec::new(roles, Scope::Daemon);
    spec.label = label.into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    spec.max_uses = None;
    spec
}

/// An invite with `terms`, as the text the owner shares.
async fn invite(owner: &TestClient, spec: GrantSpec, terms: InviteTerms) -> String {
    owner
        .client
        .create_invite_with_terms(spec, "alice".into(), terms)
        .await
        .expect("invite")
        .to_string_with_terms(terms)
}

async fn guest(invite: &str, pane: PaneId) -> TestClient {
    let mut g = TestClient::join(invite, ClientConfig::generate_key());
    g.client.attach(None);
    g.until("guest layout", |c| c.layout.is_some()).await;
    g.follow(pane).await;
    g
}

fn knocker_config() -> ClientConfig {
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    config
}

/// Starts knocking in the background; the handle yields how it ended and the key used.
fn start_knock(invite: &str, name: &str) -> (JoinHandle<KnockOutcome>, Vec<u8>) {
    let config = knocker_config();
    let key = config.secret_key.clone();
    let invite = invite.to_owned();
    let name = name.to_owned();
    let task = tokio::spawn(async move {
        knock(
            &invite,
            config,
            ConnectOptions::default(),
            Some(name),
            |_| {},
        )
        .await
        .expect("knock")
    });
    (task, key)
}

fn knocks_named(c: &TestClient, name: &str) -> Option<client_core::proto::Knock> {
    c.client
        .pending_knocks()
        .into_iter()
        .find(|k| k.name == name)
}

#[tokio::test(flavor = "multi_thread")]
async fn knocking_waits_for_the_owner_who_admits_or_turns_away() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let terms = InviteTerms {
        knock: true,
        history: History::Full,
    };
    let link = invite(&owner, spec(Roles::VIEWER, ""), terms).await;
    // The join card can tell it is a knock invite.
    assert_eq!(Invite::parse_with_terms(&link).unwrap().1, terms);

    // An app that cannot wait in the lobby is refused rather than let in.
    let mut old = TestClient::join(&link, ClientConfig::generate_key());
    old.until("old client refused", |c| !c.refused.is_empty())
        .await;
    assert!(old.refused[0].contains("InvalidGrant"), "{:?}", old.refused);

    // Kim knocks; the owner sees it with her name and admits her as a driver.
    let (kim, kim_key) = start_knock(&link, "Kim Lee");
    owner
        .until("kim knocks", |c| knocks_named(c, "Kim Lee").is_some())
        .await;
    let knock_id = knocks_named(&owner, "Kim Lee").unwrap().knock_id;
    assert!(
        !kim.is_finished(),
        "nobody gets in before the owner answers"
    );
    let admitted = owner
        .client
        .answer_knock(
            knock_id,
            Some(Admit {
                roles: Roles::DRIVER | Roles::VIEWER,
                history: History::Full,
                expires: None,
            }),
        )
        .await
        .unwrap()
        .expect("a grant");
    let KnockOutcome::Admitted(kim_invite) = tokio::time::timeout(Duration::from_secs(10), kim)
        .await
        .expect("kim hears back")
        .unwrap()
    else {
        panic!("kim was not admitted");
    };
    assert_eq!(
        kim_invite.chain.grant_id(),
        admitted.grant.grant_id,
        "she joins with the grant minted for her"
    );
    // A week by default, bound to her device only.
    let week = admitted.grant.expires.unwrap().0 - now_millis().0;
    assert!(week > 6 * 86_400_000 && week <= 7 * 86_400_000, "{week}");
    let mut kim = TestClient::join(&kim_invite.to_string(), kim_key);
    kim.client.attach(None);
    kim.until("kim attached", |c| c.layout.is_some()).await;
    let me = kim.client.me().unwrap();
    assert_eq!(me.roles, Roles::DRIVER | Roles::VIEWER);
    assert_eq!(me.name, "Kim Lee");
    kim.follow(pane).await;
    kim.type_line(pane, "echo kim-was-here");
    owner.wait_text(pane, "kim-was-here").await;
    // The admitted grant cannot be used from another device.
    let mut thief = TestClient::join(&kim_invite.to_string(), ClientConfig::generate_key());
    thief
        .until("stolen grant refused", |c| !c.refused.is_empty())
        .await;

    // Lou knocks and is turned away.
    let (lou, _) = start_knock(&link, "Lou");
    owner
        .until("lou knocks", |c| knocks_named(c, "Lou").is_some())
        .await;
    let lou_id = knocks_named(&owner, "Lou").unwrap().knock_id;
    assert_eq!(owner.client.answer_knock(lou_id, None).await.unwrap(), None);
    assert_eq!(lou.await.unwrap(), KnockOutcome::Denied);
    // Answering twice finds nothing.
    assert!(matches!(
        owner.client.answer_knock(lou_id, None).await,
        Err(MpError::NotFound(_))
    ));

    // Max stops waiting: the owner's knock goes away by itself.
    let (max, _) = start_knock(&link, "Max");
    owner
        .until("max knocks", |c| knocks_named(c, "Max").is_some())
        .await;
    let max_id = knocks_named(&owner, "Max").unwrap().knock_id;
    max.abort();
    owner
        .until("max withdrew", |c| {
            c.mp.iter().any(|e| {
                matches!(e, MultiplayerEvent::Knock { update: KnockUpdate::Gone { knock_id, outcome: Outcome::Withdrawn, .. } } if *knock_id == max_id)
            })
        })
        .await;
    assert!(knocks_named(&owner, "Max").is_none());

    // Guests cannot see or answer knocks.
    assert!(matches!(
        kim.client.knocks().await,
        Err(MpError::Forbidden(_))
    ));

    let page = owner.client.audit(None, 200).await.unwrap();
    assert!(page.chain_ok);
    let kinds: Vec<AuditKind> = page.records.iter().map(|r| r.kind).collect();
    assert!(kinds.contains(&AuditKind::Knock), "{kinds:?}");
    let answered: Vec<&str> = page
        .records
        .iter()
        .filter(|r| r.kind == AuditKind::KnockAnswered)
        .map(|r| r.detail.as_str())
        .collect();
    assert!(
        answered
            .iter()
            .any(|d| d.contains("admitted Kim Lee as driver+viewer")),
        "{answered:?}"
    );
    assert!(answered.iter().any(|d| d.contains("turned Lou away")));
    assert!(answered.iter().any(|d| d.contains("Max stopped waiting")));
    drop((owner, kim, old, thief));
    daemon.shutdown().await;
}

async fn hook(socket: &std::path::Path, request: &HookRequest) -> HookResponse {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
}

/// Claude asks to use `tool` (one request per `seq`), answered in the background.
fn ask(
    daemon: &Daemon,
    dir: &std::path::Path,
    pane: PaneId,
    seq: u64,
    tool: &str,
) -> JoinHandle<HookResponse> {
    let mut payload: serde_json::Value = serde_json::from_str(PERMISSION).unwrap();
    payload["tool_name"] = tool.into();
    payload["tool_input"]["command"] = format!("step {seq}").into();
    let request = HookRequest {
        v: 1,
        token: std::fs::read_to_string(dir.join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: "PermissionRequest".into(),
        seq,
        payload,
    };
    let socket = daemon.hook_socket().to_owned();
    tokio::spawn(async move { hook(&socket, &request).await })
}

fn blocked(c: &TestClient, pane: PaneId) -> Option<Blocker> {
    c.metas
        .get(&pane)
        .and_then(|m| m.agent.clone())
        .and_then(|a| match a.state {
            AgentState::Blocked(b) => Some(b),
            _ => None,
        })
}

/// Waits until `c` sees a request blocked on `pane` newer than `after` (ids only grow; a
/// client that has not pumped events for a while may still show an older one).
async fn next_block(c: &mut TestClient, pane: PaneId, after: Option<u64>) -> Blocker {
    c.until("blocked", |c| {
        blocked(c, pane).is_some_and(|b| Some(b.request_id.0) > after)
    })
    .await;
    blocked(c, pane).unwrap()
}

fn option(b: &Blocker, allow: bool) -> OptionId {
    b.options
        .iter()
        .find(|o| o.label.to_lowercase().starts_with("no") != allow)
        .map(|o| o.id)
        .expect("option")
}

fn refusal(c: &TestClient, needle: &str) -> bool {
    c.mp.iter().any(|e| {
        matches!(e, MultiplayerEvent::Forbidden { what, reason } if what == "Decide" && reason.contains(needle))
    })
}

async fn answered(waiting: JoinHandle<HookResponse>) -> String {
    let response = tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .expect("hook answered")
        .unwrap();
    let stdout: serde_json::Value = serde_json::from_str(&response.stdout.unwrap()).unwrap();
    stdout["hookSpecificOutput"]["decision"]["behavior"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn set_policy(owner: &TestClient, mode: ApprovalMode, max_risk: Risk) {
    let session = owner.layout.as_ref().unwrap().session_id;
    let policy = ApprovalPolicy { mode, max_risk };
    assert_eq!(
        owner
            .client
            .set_approval_policy(session, policy)
            .await
            .unwrap(),
        policy
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn approval_policies_decide_who_may_answer() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let session = owner.layout.as_ref().unwrap().session_id;
    let approver = spec(Roles::APPROVER | Roles::VIEWER, "");
    let open = InviteTerms::default();
    let mut ann = guest(
        &invite(
            &owner,
            GrantSpec {
                label: "ann".into(),
                ..approver.clone()
            },
            open,
        )
        .await,
        pane,
    )
    .await;
    let mut bob = guest(
        &invite(
            &owner,
            GrantSpec {
                label: "bob".into(),
                ..approver
            },
            open,
        )
        .await,
        pane,
    )
    .await;

    // Only the owner sets the rules; everyone in the session hears them.
    let two = ApprovalPolicy {
        mode: ApprovalMode::TwoPerson,
        max_risk: Risk::Any,
    };
    assert!(matches!(
        ann.client.set_approval_policy(session, two).await,
        Err(MpError::Forbidden(_))
    ));
    set_policy(&owner, ApprovalMode::TwoPerson, Risk::Any).await;
    ann.until("policy pushed", |c| {
        c.client.approval_policy_cached() == Some((session, two))
    })
    .await;

    // Two-person rule: Ann's approval of a command is held until Bob approves too.
    let waiting = ask(&daemon, dir.path(), pane, 1, "Bash");
    let b = next_block(&mut ann, pane, None).await;
    ann.client.decide(b.request_id, option(&b, true));
    bob.until("one of two", |c| {
        c.client
            .approval_statuses()
            .iter()
            .any(|s| s.request_id == b.request_id && s.approvals.len() == 1 && s.needed == 2)
    })
    .await;
    assert!(!waiting.is_finished(), "one approval is not enough");
    ann.client.decide(b.request_id, option(&b, true));
    ann.until("same person twice refused", |c| refusal(c, "second person"))
        .await;
    bob.client.decide(b.request_id, option(&b, true));
    assert_eq!(answered(waiting).await, "allow");
    // Edits need only one approval, and one "no" ends a command request.
    let waiting = ask(&daemon, dir.path(), pane, 2, "Edit");
    let b2 = next_block(&mut ann, pane, Some(b.request_id.0)).await;
    ann.client.decide(b2.request_id, option(&b2, true));
    assert_eq!(answered(waiting).await, "allow");
    let waiting = ask(&daemon, dir.path(), pane, 3, "Bash");
    let b3 = next_block(&mut ann, pane, Some(b2.request_id.0)).await;
    bob.client.decide(b3.request_id, option(&b3, false));
    assert_eq!(answered(waiting).await, "deny");

    // Owner only: approvers are refused, the owner answers.
    set_policy(&owner, ApprovalMode::OwnerOnly, Risk::Any).await;
    let waiting = ask(&daemon, dir.path(), pane, 4, "Read");
    let b4 = next_block(&mut ann, pane, Some(b3.request_id.0)).await;
    ann.client.decide(b4.request_id, option(&b4, true));
    ann.until("approver refused", |c| refusal(c, "only the owner"))
        .await;
    assert!(!waiting.is_finished());
    owner.client.decide(b4.request_id, option(&b4, true));
    assert_eq!(answered(waiting).await, "allow");

    // A risk cap: approvers allow edits but not commands; they may still say no.
    set_policy(&owner, ApprovalMode::AnyApprover, Risk::Edits).await;
    let waiting = ask(&daemon, dir.path(), pane, 5, "Bash");
    let b5 = next_block(&mut bob, pane, Some(b4.request_id.0)).await;
    bob.client.decide(b5.request_id, option(&b5, true));
    bob.until("command needs the owner", |c| refusal(c, "needs the owner"))
        .await;
    assert!(!waiting.is_finished());
    bob.client.decide(b5.request_id, option(&b5, false));
    assert_eq!(answered(waiting).await, "deny");

    // Claims: Bob takes the request; Ann can no longer answer it, Bob can.
    set_policy(&owner, ApprovalMode::Claim, Risk::Any).await;
    let waiting = ask(&daemon, dir.path(), pane, 6, "Bash");
    let b6 = next_block(&mut ann, pane, Some(b5.request_id.0)).await;
    let status = bob.client.claim(b6.request_id, true).await.unwrap();
    assert_eq!(status.claimed_by.unwrap().name, "bob");
    ann.until("claim pushed", |c| {
        c.client
            .approval_statuses()
            .iter()
            .any(|s| s.request_id == b6.request_id && s.claimed_by.is_some())
    })
    .await;
    assert!(matches!(
        ann.client.claim(b6.request_id, true).await,
        Err(MpError::Conflict(_))
    ));
    ann.client.decide(b6.request_id, option(&b6, true));
    ann.until("claimed by someone else", |c| refusal(c, "claimed"))
        .await;
    bob.client.decide(b6.request_id, option(&b6, true));
    assert_eq!(answered(waiting).await, "allow");

    // Everything is in the audit log, still intact.
    let page = owner.client.audit(None, 500).await.unwrap();
    assert!(page.chain_ok);
    let details = |kind: AuditKind| -> Vec<String> {
        page.records
            .iter()
            .filter(|r| r.kind == kind)
            .map(|r| r.detail.clone())
            .collect()
    };
    let policies = details(AuditKind::Policy);
    assert_eq!(policies.len(), 4, "{policies:?}");
    assert!(policies[0].contains("two-person"), "{policies:?}");
    assert!(
        details(AuditKind::Approval)
            .iter()
            .any(|d| d.contains("1 of 2")),
        "the held vote is audited"
    );
    assert!(
        details(AuditKind::Claim)
            .iter()
            .any(|d| d.contains("bob claimed"))
    );
    assert!(
        details(AuditKind::Denied)
            .iter()
            .any(|d| d.contains("only the owner")),
        "refusals are audited"
    );
    drop((ann, bob, owner));
    daemon.shutdown().await;
}

async fn all_history(c: &mut TestClient, pane: PaneId) -> String {
    while c.client.fetch_history(pane, 64 << 10) {
        let before = c.history.len();
        c.until("history page", |c| c.history.len() > before).await;
    }
    c.client.pane_text_all(pane).unwrap_or_default()
}

async fn search_total(c: &mut TestClient, pane: PaneId, pattern: &str) -> u32 {
    let id = c.client.search(
        pane,
        SearchQuery {
            pattern: pattern.into(),
            mode: SearchMode::Plain,
            case: CaseMode::Sensitive,
        },
        0,
        10,
    );
    let ClientEvent::SearchResult { result, .. } = c.answer(id).await else {
        unreachable!()
    };
    result.unwrap().total
}

#[tokio::test(flavor = "multi_thread")]
async fn since_join_guests_see_scrollback_only_from_joining() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    owner.type_line(
        pane,
        "i=0; while [ $i -lt 400 ]; do echo old-line-$i; i=$((i+1)); done; echo OLD''DONE",
    );
    owner.wait_text(pane, "OLDDONE").await;

    let since = InviteTerms {
        knock: false,
        history: History::SinceJoin,
    };
    let mut sam = guest(
        &invite(&owner, spec(Roles::VIEWER, "sam"), since).await,
        pane,
    )
    .await;
    let mut fay = guest(
        &invite(&owner, spec(Roles::VIEWER, "fay"), InviteTerms::default()).await,
        pane,
    )
    .await;
    owner.type_line(
        pane,
        "i=0; while [ $i -lt 300 ]; do echo new-line-$i; i=$((i+1)); done; echo NEW''DONE",
    );
    sam.wait_text(pane, "NEWDONE").await;
    fay.wait_text(pane, "NEWDONE").await;

    // Sam: everything since joining, nothing from before (the old lines had scrolled away).
    let sam_text = all_history(&mut sam, pane).await;
    assert!(sam_text.contains("new-line-0\n"), "{sam_text}");
    assert!(sam_text.contains("new-line-299"));
    assert!(!sam_text.contains("old-line-10\n"), "old history leaked");
    assert_eq!(search_total(&mut sam, pane, "old-line-1").await, 0);
    assert!(search_total(&mut sam, pane, "new-line-1").await > 100);
    // Reconnecting does not bring it back.
    sam.client.reconnect();
    sam.until("reconnected", |c| c.connected >= 2).await;
    sam.wait_text(pane, "NEWDONE").await;
    assert_eq!(search_total(&mut sam, pane, "old-line-1").await, 0);

    // Fay was invited with full history and the owner sees everything.
    let fay_text = all_history(&mut fay, pane).await;
    assert!(fay_text.contains("old-line-10\n"), "full history for fay");
    assert!(search_total(&mut owner, pane, "old-line-1").await > 100);

    drop((sam, fay, owner));
    daemon.shutdown().await;
}
