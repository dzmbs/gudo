//! Agents reaching other hosts through the owner's device (`proto::cross_host`): two daemons,
//! one owner device paired with both relaying between them, and an agent on the first host
//! calling the terminal tools with `host`.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use client_core::proto::{
    AuditKind, Axis, CrossHostRequest, LayoutOp, OpOutcome, PaneId, PaneLaunch, Roles, Scope,
    UnixMillis,
};
use client_core::{
    ClientConfig, ConnectOptions, CrossHostChoice, CrossHostEvent, CrossHostEventQueue,
    CrossHostRelay, GrantSpec, RelayHost, now_millis,
};
use daemon::{Daemon, TERM_VERSION, TermAsk, TermCall, TermErrorCode, TermReply};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::task::JoinHandle;

use crate::support::{TIMEOUT, TestClient, start_with, ticket};

/// A program in pane `pane` of a daemon calling the terminal tools.
#[derive(Clone)]
struct Caller {
    socket: PathBuf,
    token: String,
    pane: PaneId,
}

impl Caller {
    fn new(dir: &Path, daemon: &Daemon, pane: PaneId) -> Self {
        Self {
            socket: daemon.hook_socket().to_owned(),
            token: std::fs::read_to_string(dir.join("hook.token")).unwrap(),
            pane,
        }
    }

    fn spawn(&self, tool: &str, args: Value) -> JoinHandle<TermReply> {
        let call = TermCall {
            v: TERM_VERSION,
            token: self.token.clone(),
            pane: self.pane.0.to_string(),
            term: TermAsk {
                tool: tool.into(),
                args,
            },
        };
        let socket = self.socket.clone();
        tokio::spawn(async move {
            let mut stream = UnixStream::connect(socket).await.unwrap();
            let mut line = serde_json::to_vec(&call).unwrap();
            line.push(b'\n');
            stream.write_all(&line).await.unwrap();
            let mut answer = String::new();
            BufReader::new(stream).read_line(&mut answer).await.unwrap();
            serde_json::from_str(&answer).unwrap()
        })
    }

    async fn call(&self, tool: &str, args: Value) -> TermReply {
        reply(self.spawn(tool, args)).await
    }
}

async fn reply(call: JoinHandle<TermReply>) -> TermReply {
    tokio::time::timeout(Duration::from_secs(30), call)
        .await
        .expect("the call answered")
        .unwrap()
}

fn ok(reply: TermReply) -> Value {
    match reply {
        TermReply::Ok(value) => value,
        TermReply::Error(error) => panic!("refused: {error:?}"),
    }
}

fn refused(reply: TermReply) -> daemon::ToolError {
    match reply {
        TermReply::Error(error) => error,
        TermReply::Ok(value) => panic!("allowed: {value}"),
    }
}

/// Host A (where the agent runs) and host B, an owner device paired with both relaying
/// through `relay`, and two panes on A: the user's first one and the agent's.
struct Hosts {
    _dir_a: tempfile::TempDir,
    _dir_b: tempfile::TempDir,
    a: Daemon,
    b: Daemon,
    on_a: TestClient,
    on_b: TestClient,
    relay: CrossHostRelay,
    cards: UnboundedReceiver<CrossHostEvent>,
    agent: Caller,
    /// The user's pane on B.
    users_pane_on_b: PaneId,
}

const HOST_A: &str = "host-a";
const HOST_B: &str = "host-b";

impl Hosts {
    async fn start(wait: Duration) -> Self {
        Self::start_with(wait, |_| {}).await
    }

    async fn start_with(wait: Duration, edit: impl Fn(&mut daemon::Config)) -> Self {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        let a = start_with(dir_a.path(), |config| {
            config.drive_ask_wait = wait;
            edit(config);
        })
        .await;
        let b = start_with(dir_b.path(), |config| {
            config.drive_ask_wait = wait;
            edit(config);
        })
        .await;
        let device_key = ClientConfig::generate_key();
        let mut on_a = TestClient::connect_cross_host(&ticket(&a), device_key.clone());
        let mut on_b = TestClient::connect_cross_host(&ticket(&b), device_key);
        let user_on_a = on_a.attach_and_follow().await;
        let users_pane_on_b = on_b.attach_and_follow().await;
        let OpOutcome::PaneCreated {
            pane_id: agent_pane,
        } = on_a
            .op(LayoutOp::Split {
                pane_id: user_on_a,
                axis: Axis::Horizontal,
                launch: PaneLaunch::Shell { cwd: None },
            })
            .await
        else {
            panic!("split")
        };
        let (listener, cards) = CrossHostEventQueue::channel();
        let relay = CrossHostRelay::new(listener);
        relay.add_host(RelayHost::owner(HOST_A, "mac", Arc::clone(&on_a.client)));
        relay.add_host(RelayHost::owner(HOST_B, "ops", Arc::clone(&on_b.client)));
        let agent = Caller::new(dir_a.path(), &a, agent_pane);
        let hosts = Self {
            _dir_a: dir_a,
            _dir_b: dir_b,
            a,
            b,
            on_a,
            on_b,
            relay,
            cards,
            agent,
            users_pane_on_b,
        };
        hosts.listed("ops").await;
        hosts
    }

    /// The next card the device shows, skipping other events.
    async fn card(&mut self) -> client_core::CrossHostCard {
        let deadline = tokio::time::Instant::now() + TIMEOUT;
        loop {
            let event = tokio::time::timeout_at(deadline, self.cards.recv())
                .await
                .expect("a card")
                .expect("the relay lives");
            if let CrossHostEvent::Card(card) = event {
                return card;
            }
        }
    }

    /// No card shows within a moment.
    async fn no_card(&mut self) {
        let quiet = tokio::time::sleep(Duration::from_millis(400));
        tokio::pin!(quiet);
        loop {
            tokio::select! {
                () = &mut quiet => return,
                event = self.cards.recv() => {
                    if let Some(CrossHostEvent::Card(card)) = event {
                        panic!("asked: {card:?}");
                    }
                }
            }
        }
    }

    /// Waits until agents on A can list `name` (the device's host list reached A).
    async fn listed(&self, name: &str) {
        let deadline = tokio::time::Instant::now() + TIMEOUT;
        loop {
            let listed = ok(self.agent.call("host_list", json!({})).await);
            if listed["hosts"]
                .as_array()
                .is_some_and(|hosts| hosts.iter().any(|host| host["name"] == name))
            {
                return;
            }
            assert!(tokio::time::Instant::now() < deadline, "{listed}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    async fn shutdown(self) {
        drop(self.relay);
        drop(self.on_a);
        drop(self.on_b);
        self.a.shutdown().await;
        self.b.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn allow_once_runs_exactly_the_shown_call_on_the_other_host() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);

    let run = hosts.agent.spawn(
        "cmd_run",
        json!({ "host": "ops", "command": "echo from-a-$((40+2))" }),
    );
    let card = hosts.card().await;
    assert!(!card.agent.is_empty());
    assert_eq!(
        (card.from_name.as_str(), card.to_name.as_str()),
        ("mac", "ops")
    );
    assert_eq!(card.action, "run $ echo from-a-$((40+2))");
    assert_eq!(
        card.title(),
        format!(
            "{} on mac wants to run $ echo from-a-$((40+2)) on ops",
            card.agent
        )
    );
    assert!(!run.is_finished(), "nothing runs before the owner answers");
    hosts.relay.answer(&card.key, CrossHostChoice::AllowOnce);
    let result = ok(reply(run).await);
    assert!(
        result["output"]["text"]
            .as_str()
            .unwrap()
            .contains("from-a-42"),
        "{result}"
    );
    let opened: PaneId = PaneId(
        result["pane"].as_str().unwrap()[1..]
            .parse::<u64>()
            .unwrap(),
    );
    hosts.on_b.follow(opened).await;
    hosts.on_b.wait_text(opened, "from-a-42").await;

    // A yes covers reads from then on, but every change is asked again.
    let listed = ok(hosts
        .agent
        .call("pane_list", json!({ "host": "ops" }))
        .await);
    hosts.no_card().await;
    let mine: Vec<&Value> = listed["panes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|pane| pane["createdByYou"] == true)
        .collect();
    assert_eq!(mine.len(), 1, "{listed}");
    let again = hosts.agent.spawn(
        "cmd_run",
        json!({ "host": "ops", "pane": format!("p{}", opened.0), "command": "echo twice" }),
    );
    let second = hosts.card().await;
    assert_eq!(second.action, format!("run $ echo twice in p{}", opened.0));
    hosts.relay.answer(&second.key, CrossHostChoice::AllowOnce);
    ok(reply(again).await);
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn deny_refuses_and_nothing_runs_on_the_other_host() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let users_pane = hosts.users_pane_on_b;
    let typing = hosts.agent.spawn(
        "pane_send",
        json!({ "host": "ops", "pane": format!("p{}", users_pane.0), "text": "echo denied-text", "submit": true }),
    );
    let card = hosts.card().await;
    assert_eq!(
        card.action,
        format!(
            "type “echo denied-text”, then Return into p{}",
            users_pane.0
        )
    );
    hosts.relay.answer(&card.key, CrossHostChoice::Deny);
    let denied = refused(reply(typing).await);
    assert_eq!(denied.code, TermErrorCode::Forbidden);
    assert!(denied.message.contains("said no"), "{denied:?}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!hosts.on_b.text(users_pane).contains("denied-text"));

    // A no is not a yes: reads are still asked.
    let read = hosts.agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::Deny);
    refused(reply(read).await);
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn allow_all_covers_the_agent_on_that_host_until_its_pane_closes() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let users_pane = hosts.users_pane_on_b;

    let first = hosts
        .agent
        .spawn("cmd_run", json!({ "host": "ops", "command": "echo all-1" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowAgent);
    ok(reply(first).await);
    assert_eq!(hosts.relay.standing().len(), 1);

    // Everything this agent asks on ops goes through, the user's own panes included.
    ok(hosts
        .agent
        .call(
            "pane_send",
            json!({ "host": "ops", "pane": format!("p{}", users_pane.0), "text": "echo all-2", "submit": true }),
        )
        .await);
    hosts.on_b.wait_text(users_pane, "all-2").await;
    hosts.no_card().await;

    // A password prompt on ops is never typed into, whatever was allowed.
    hosts
        .on_b
        .type_line(users_pane, "stty -echo; read secret; stty echo");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let secret = refused(
        hosts
            .agent
            .call(
                "pane_send",
                json!({ "host": "ops", "pane": format!("p{}", users_pane.0), "text": "hunter2" }),
            )
            .await,
    );
    assert_eq!(secret.code, TermErrorCode::SecretPrompt, "{secret:?}");
    hosts.on_b.type_line(users_pane, "");

    // The agent's pane closes: its yes ends, and a new agent in a new pane is asked.
    let OpOutcome::Done = hosts
        .on_a
        .op(LayoutOp::ClosePane {
            pane_id: hosts.agent.pane,
        })
        .await
    else {
        panic!("closed")
    };
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    while !hosts.relay.standing().is_empty() {
        assert!(tokio::time::Instant::now() < deadline, "the allow ended");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let user_on_a = hosts.on_a.focused();
    let OpOutcome::PaneCreated { pane_id: next } = hosts
        .on_a
        .op(LayoutOp::Split {
            pane_id: user_on_a,
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split")
    };
    hosts.agent.pane = next;
    let read = hosts.agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowOnce);
    ok(reply(read).await);
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn allow_all_ends_when_an_agent_starts_or_ends_in_the_asking_pane() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let first = hosts.agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowAgent);
    ok(reply(first).await);
    assert_eq!(hosts.relay.standing().len(), 1);

    // Claude starts in the pane the shell asked from: the shell's yes is not Claude's.
    let pane = hosts.agent.pane.0.to_string();
    crate::term::claude_hook(
        hosts.a.hook_socket(),
        &hosts.agent.token,
        &pane,
        "SessionStart",
        1,
        crate::term::hook_payload("SessionStart", json!({ "source": "startup" })),
    )
    .await;
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    while !hosts.relay.standing().is_empty() {
        assert!(tokio::time::Instant::now() < deadline, "the allow ended");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let read = hosts.agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::Deny);
    refused(reply(read).await);
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn revoking_a_pair_ends_every_standing_allow_and_turns_it_off() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let first = hosts.agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowAgent);
    ok(reply(first).await);

    hosts.relay.revoke(HOST_A, HOST_B);
    assert!(hosts.relay.standing().is_empty());
    let off = refused(
        hosts
            .agent
            .call("pane_list", json!({ "host": "ops" }))
            .await,
    );
    assert_eq!(
        off.message,
        format!(
            "ops isn't enabled for agents on {}. Turn it on in {} › Hosts › ops.",
            if cfg!(target_os = "macos") {
                "this Mac"
            } else {
                "this computer"
            },
            brand::PRODUCT_NAME
        )
    );

    // Turned on again, it asks again.
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let read = hosts.agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowOnce);
    ok(reply(read).await);

    // Each direction is its own switch.
    assert!(!hosts.relay.pair_enabled(HOST_B, HOST_A));
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn turning_a_pair_off_withdraws_its_open_cards_and_answers_are_judged_again() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let users_pane = hosts.users_pane_on_b;
    let run = hosts.agent.spawn(
        "pane_send",
        json!({ "host": "ops", "pane": format!("p{}", users_pane.0), "text": "echo pair-was-off", "submit": true }),
    );
    let card = hosts.card().await;
    hosts.relay.set_pair(HOST_A, HOST_B, false);
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    loop {
        let event = tokio::time::timeout_at(deadline, hosts.cards.recv())
            .await
            .expect("the card closed")
            .expect("the relay lives");
        if event == CrossHostEvent::CardClosed(card.key.clone()) {
            break;
        }
    }
    let off = refused(reply(run).await);
    assert!(off.message.contains("isn't enabled"), "{off:?}");
    hosts.relay.answer(&card.key, CrossHostChoice::AllowOnce);

    // A card answered after its target went away is refused, not run.
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let run = hosts.agent.spawn(
        "pane_send",
        json!({ "host": "ops", "pane": format!("p{}", users_pane.0), "text": "echo host-was-gone", "submit": true }),
    );
    let card = hosts.card().await;
    hosts.relay.remove_host(HOST_B);
    hosts.relay.answer(&card.key, CrossHostChoice::AllowAgent);
    let gone = refused(reply(run).await);
    assert!(gone.message.starts_with("No host named ops"), "{gone:?}");
    assert!(hosts.relay.standing().is_empty());

    tokio::time::sleep(Duration::from_millis(500)).await;
    let screen = hosts.on_b.text(users_pane);
    assert!(
        !screen.contains("pair-was-off") && !screen.contains("host-was-gone"),
        "{screen}"
    );
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn nothing_happens_while_no_device_is_connected() {
    let mut hosts = Hosts::start(Duration::from_secs(3)).await;
    hosts.relay.remove_host(HOST_A);
    hosts.on_a.client.suspend();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let alone = refused(
        hosts
            .agent
            .call(
                "cmd_run",
                json!({ "host": "ops", "command": "echo nobody" }),
            )
            .await,
    );
    assert_eq!(
        alone.message,
        format!(
            "No {} device is connected to approve this.",
            brand::PRODUCT_NAME
        )
    );
    assert!(alone.retryable);

    // A device that connects while the request waits gets it.
    let waiting = hosts.agent.spawn(
        "cmd_run",
        json!({ "host": "ops", "command": "echo arrived" }),
    );
    tokio::time::sleep(Duration::from_millis(500)).await;
    hosts.on_a.client.reconnect();
    hosts.relay.add_host(RelayHost::owner(
        HOST_A,
        "mac",
        Arc::clone(&hosts.on_a.client),
    ));
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowOnce);
    ok(reply(waiting).await);

    // The owner was notified of the request nobody could answer.
    let feed = hosts.on_a.client.attention_list().await.unwrap();
    assert!(
        feed.items
            .iter()
            .any(|item| item.title.ends_with("wants to reach ops")
                && item.body == "run $ echo nobody"),
        "{feed:#?}"
    );
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_owner_alone_is_notified_with_the_host_name_cleaned() {
    let hosts = Hosts::start(Duration::from_secs(2)).await;
    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    spec.label = "bob".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = hosts
        .on_a
        .client
        .create_invite(spec, "alice".into())
        .await
        .unwrap();
    let mut guest = TestClient::join_options(&invite.to_string(), ConnectOptions::default());
    guest.client.attach(None);
    guest
        .until("the guest is in", |client| client.layout.is_some())
        .await;
    hosts.relay.remove_host(HOST_A);
    hosts.on_a.client.suspend();
    tokio::time::sleep(Duration::from_millis(300)).await;

    let host = format!("ops\u{202e}\u{2028}{}", "x".repeat(200));
    refused(hosts.agent.call("pane_list", json!({ "host": host })).await);
    hosts.on_a.client.reconnect();
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    let item = loop {
        if let Ok(feed) = hosts.on_a.client.attention_list().await
            && let Some(item) = feed
                .items
                .into_iter()
                .find(|item| item.title.contains("wants to reach"))
        {
            break item;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the owner was notified"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    assert!(
        item.title
            .ends_with(&format!("wants to reach ops {}…", "x".repeat(60))),
        "{}",
        item.title
    );
    let theirs = guest.client.attention_list().await.unwrap();
    assert!(
        !theirs
            .items
            .iter()
            .any(|item| item.title.contains("wants to reach")),
        "{theirs:#?}"
    );
    drop(guest);
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_device_unpaired_while_connected_is_sent_nothing_and_cannot_claim() {
    let mut hosts = Hosts::start(Duration::from_secs(2)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let device = hosts.on_a.client.me().unwrap().actor.device;
    let device_hex: String = device.0.iter().map(|byte| format!("{byte:02x}")).collect();
    daemon::unpair_device(hosts._dir_a.path(), &device_hex).unwrap();

    let alone = refused(
        hosts
            .agent
            .call("pane_list", json!({ "host": "ops" }))
            .await,
    );
    hosts.no_card().await;
    assert_eq!(
        alone.message,
        format!(
            "No {} device is connected to approve this.",
            brand::PRODUCT_NAME
        )
    );
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_never_get_requests_and_are_never_targets() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);

    // A guest on A that claims the capability anyway is never sent a request.
    let mut spec = GrantSpec::new(Roles::DRIVER | Roles::APPROVER, Scope::Daemon);
    spec.label = "bob".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = hosts
        .on_a
        .client
        .create_invite(spec, "alice".into())
        .await
        .unwrap();
    let mut guest = TestClient::join_options(
        &invite.to_string(),
        ConnectOptions {
            extra_caps: client_core::proto::Caps::CROSS_HOST,
            ..ConnectOptions::default()
        },
    );
    guest.client.attach(None);
    guest
        .until("the guest is in", |client| client.layout.is_some())
        .await;
    let (guest_listener, mut guest_pushes) = client_core::CrossHostPushQueue::channel();
    guest.client.set_cross_host_listener(guest_listener);
    let call = hosts.agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    assert!(
        guest_pushes.try_recv().is_err(),
        "a guest was sent the request"
    );
    hosts.relay.answer(&card.key, CrossHostChoice::Deny);
    refused(reply(call).await);
    assert!(guest_pushes.try_recv().is_err());

    // A host the device joined as a guest is never a target.
    hosts
        .relay
        .add_host(RelayHost::guest("their-host", "theirs"));
    hosts.relay.set_pair(HOST_A, "their-host", true);
    hosts.listed("theirs").await;
    let theirs = refused(
        hosts
            .agent
            .call("pane_list", json!({ "host": "theirs" }))
            .await,
    );
    assert!(theirs.message.contains("joined as a guest"), "{theirs:?}");

    // Nor is a host the app reaches over plain SSH alone.
    hosts.relay.add_host(RelayHost::ssh_only("pi-host", "pi"));
    hosts.listed("pi").await;
    let plain = refused(hosts.agent.call("pane_list", json!({ "host": "pi" })).await);
    assert_eq!(plain.message, "Install the helper on pi to reach it.");
    drop(guest);
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn one_request_at_a_time_per_agent_and_a_rate_limit_per_agent() {
    let mut hosts = Hosts::start_with(Duration::from_secs(20), |config| {
        config.cross_host_requests_per_minute = 3;
    })
    .await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let first = hosts.agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    let busy = refused(
        hosts
            .agent
            .call("pane_list", json!({ "host": "ops" }))
            .await,
    );
    assert_eq!(busy.code, TermErrorCode::AgentBlocked, "{busy:?}");
    assert!(busy.retryable);
    hosts.relay.answer(&card.key, CrossHostChoice::AllowAgent);
    ok(reply(first).await);
    ok(hosts
        .agent
        .call("pane_list", json!({ "host": "ops" }))
        .await);
    let limited = refused(
        hosts
            .agent
            .call("pane_list", json!({ "host": "ops" }))
            .await,
    );
    assert!(limited.retryable);
    assert!(limited.message.contains("too many"), "{limited:?}");
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn over_long_and_unknown_hosts_are_refused_uncounted_and_each_agent_has_its_own_limit() {
    let mut hosts = Hosts::start_with(Duration::from_secs(20), |config| {
        config.cross_host_requests_per_minute = 2;
    })
    .await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    hosts.listed("ops").await;

    for unique in 0..4 {
        let flood = refused(
            hosts
                .agent
                .call(
                    "pane_list",
                    json!({ "host": format!("{unique}{}", "h".repeat(64 * 1024)) }),
                )
                .await,
        );
        assert_eq!(flood.code, TermErrorCode::InvalidArgs, "{flood:?}");
        let unknown = refused(
            hosts
                .agent
                .call("pane_list", json!({ "host": format!("nowhere-{unique}") }))
                .await,
        );
        assert!(
            unknown.message.starts_with("No host named nowhere-"),
            "{unknown:?}"
        );
    }
    hosts.no_card().await;

    // Neither counted: the agent still has its two this minute.
    for _ in 0..2 {
        let read = hosts.agent.spawn("pane_list", json!({ "host": "OPS" }));
        let card = hosts.card().await;
        hosts.relay.answer(&card.key, CrossHostChoice::Deny);
        refused(reply(read).await);
    }
    let limited = refused(
        hosts
            .agent
            .call("pane_list", json!({ "host": "ops" }))
            .await,
    );
    assert!(limited.message.contains("too many"), "{limited:?}");

    // Another agent's requests are its own to count.
    let user_on_a = hosts.on_a.focused();
    let OpOutcome::PaneCreated { pane_id: other } = hosts
        .on_a
        .op(LayoutOp::Split {
            pane_id: user_on_a,
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split")
    };
    let other_agent = Caller {
        pane: other,
        ..hosts.agent.clone()
    };
    let read = other_agent.spawn("pane_list", json!({ "host": "ops" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowOnce);
    ok(reply(read).await);
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn both_hosts_audit_every_relayed_call() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let run = hosts.agent.spawn(
        "cmd_run",
        json!({ "host": "ops", "command": "echo audited" }),
    );
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowOnce);
    ok(reply(run).await);

    // A: the request, and the device's signed answer.
    let on_a = hosts.on_a.client.audit(None, 200).await.unwrap();
    assert!(on_a.chain_ok);
    assert!(
        on_a.records
            .iter()
            .any(|record| record.kind == AuditKind::CrossHost
                && record.pane_id == Some(hosts.agent.pane)
                && record.detail.contains("run $ echo audited on ops")),
        "{:#?}",
        on_a.records
    );
    let answer = on_a
        .records
        .iter()
        .filter(|record| record.kind == AuditKind::Approval)
        .find_map(|record| record.approval.as_ref())
        .expect("the signed answer");
    assert_eq!(answer.option, "Allow once");
    assert_eq!(answer.option_id, CrossHostRequest::ALLOW_ONCE);
    assert_eq!(answer.tool.as_deref(), Some("cmd_run"));
    assert!(!answer.sig.is_empty());

    // B: the call, under the owner device, on behalf of the agent on A.
    let on_b = hosts.on_b.client.audit(None, 200).await.unwrap();
    let device = hosts.on_b.client.me().unwrap().actor.device;
    let call = on_b
        .records
        .iter()
        .find(|record| record.kind == AuditKind::CrossHost)
        .expect("the call on B");
    assert_eq!(call.actor.map(|actor| actor.device), Some(device));
    assert!(
        call.detail.contains(&format!(
            "on_behalf_of={}/p{}",
            hosts
                .a
                .daemon_id()
                .0
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>(),
            hosts.agent.pane.0
        )),
        "{}",
        call.detail
    );
    assert!(
        call.detail.contains("run $ echo audited"),
        "{}",
        call.detail
    );
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn panes_a_remote_agent_opens_are_its_own_and_go_back_to_the_user() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let run = hosts
        .agent
        .spawn("cmd_run", json!({ "host": "ops", "command": "echo owned" }));
    let card = hosts.card().await;
    hosts.relay.answer(&card.key, CrossHostChoice::AllowAgent);
    let opened = ok(reply(run).await)["pane"].as_str().unwrap().to_owned();

    // Another agent on A sees it as not its own.
    let user_on_a = hosts.on_a.focused();
    let OpOutcome::PaneCreated { pane_id: other } = hosts
        .on_a
        .op(LayoutOp::Split {
            pane_id: user_on_a,
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split")
    };
    let other_agent = Caller {
        pane: other,
        ..hosts.agent.clone()
    };
    let list = other_agent.spawn("pane_list", json!({ "host": "ops", "scope": "mine" }));
    let card = hosts.card().await;
    assert_ne!(card.key, client_core::CrossHostCardKey::default());
    hosts.relay.answer(&card.key, CrossHostChoice::AllowOnce);
    let theirs = ok(reply(list).await);
    assert_eq!(theirs["panes"], json!([]), "{theirs}");

    // An agent on B itself is asked before it drives the pane the remote agent opened.
    let local = Caller::new(hosts._dir_b.path(), &hosts.b, hosts.users_pane_on_b);
    let seen = ok(local.call("pane_list", json!({})).await);
    let entry = seen["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] == opened)
        .unwrap()
        .clone();
    assert_eq!(entry["scopes"], json!(["read", "ask"]), "{entry}");

    // The remote agent's own listing has it; once it is gone, nobody's but the user's.
    let mine = ok(hosts
        .agent
        .call("pane_list", json!({ "host": "ops", "scope": "mine" }))
        .await);
    assert_eq!(mine["panes"][0]["id"], json!(opened), "{mine}");
    assert_eq!(hosts.b.remote_agents(), 2);
    hosts
        .on_a
        .op(LayoutOp::ClosePane {
            pane_id: hosts.agent.pane,
        })
        .await;
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    while hosts.b.remote_agents() > 1 {
        assert!(tokio::time::Instant::now() < deadline, "B forgot the agent");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    hosts.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn tools_that_stay_on_their_host_are_refused_and_host_list_shows_the_pairs() {
    let mut hosts = Hosts::start(Duration::from_secs(20)).await;
    let events = refused(
        hosts
            .agent
            .call("events_wait", json!({ "host": "ops" }))
            .await,
    );
    assert_eq!(events.code, TermErrorCode::InvalidArgs);
    hosts.no_card().await;

    let off = ok(hosts.agent.call("host_list", json!({})).await);
    let ops = off["hosts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|host| host["name"] == "ops")
        .cloned()
        .unwrap_or_else(|| panic!("{off}"));
    assert_eq!(ops["state"], "off");
    hosts.relay.add_host(RelayHost::ssh_only("pi-host", "pi"));
    hosts.relay.set_pair(HOST_A, HOST_B, true);
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    loop {
        let listed = ok(hosts.agent.call("host_list", json!({})).await);
        let states: Vec<(String, String)> = listed["hosts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|host| {
                (
                    host["name"].as_str().unwrap().to_owned(),
                    host["state"].as_str().unwrap().to_owned(),
                )
            })
            .collect();
        if states.contains(&("ops".into(), "enabled".into()))
            && states.contains(&("pi".into(), "no_helper".into()))
        {
            let pi = listed["hosts"]
                .as_array()
                .unwrap()
                .iter()
                .find(|host| host["name"] == "pi")
                .unwrap();
            assert_eq!(pi["note"], "Install the helper on pi to reach it.");
            assert!(
                !states.iter().any(|(name, _)| name == "mac"),
                "a host never lists itself"
            );
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "{listed}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    hosts.shutdown().await;
}
