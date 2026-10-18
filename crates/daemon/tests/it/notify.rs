//! Push notifications: attention items reach a fake push relay sealed to the device, signed
//! by the daemon, debounced and retried; Approve / Deny come back over iroh from a one-shot
//! "lock screen" connection.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use client_core::proto::{
    AgentState, Axis, LayoutOp, OpOutcome, PaneId, PaneLaunch, PushPrefs, PushRegistration, WsError,
};
use client_core::push::{ActionError, Decision, send_action};
use client_core::{ClientConfig, ConnectOptions, RelayMode};
use daemon::{Daemon, HookRequest};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, UnixStream};
use tokio::sync::mpsc;

use crate::support::{TestClient, start_with, ticket};

const PERMISSION: &str =
    include_str!("../../../agents/tests/fixtures/claude/permission_request.json");

/// What the fake relay received.
#[derive(Debug, Clone)]
struct Received {
    path: String,
    signature: String,
    body: Vec<u8>,
}

/// A fake push relay: records every request and answers with the next scripted status
/// (then 200 forever).
struct FakeRelay {
    url: String,
    rx: mpsc::UnboundedReceiver<Received>,
    script: Arc<Mutex<Vec<u16>>>,
}

impl FakeRelay {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = mpsc::unbounded_channel();
        let script: Arc<Mutex<Vec<u16>>> = Arc::default();
        let answers = Arc::clone(&script);
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let tx = tx.clone();
                let answers = Arc::clone(&answers);
                tokio::spawn(async move {
                    let mut reader = BufReader::new(stream);
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
                            return;
                        }
                        let path = line.split_whitespace().nth(1).unwrap_or("").to_owned();
                        let (mut len, mut signature) = (0, String::new());
                        loop {
                            let mut header = String::new();
                            reader.read_line(&mut header).await.unwrap();
                            let header = header.trim_end();
                            if header.is_empty() {
                                break;
                            }
                            let (name, value) = header.split_once(':').unwrap();
                            match name.to_ascii_lowercase().as_str() {
                                "content-length" => len = value.trim().parse().unwrap(),
                                "x-push-signature" => signature = value.trim().to_owned(),
                                _ => {}
                            }
                        }
                        let mut body = vec![0; len];
                        reader.read_exact(&mut body).await.unwrap();
                        let status = {
                            let mut script = answers.lock().unwrap();
                            if script.is_empty() {
                                200
                            } else {
                                script.remove(0)
                            }
                        };
                        let _ = tx.send(Received {
                            path,
                            signature,
                            body,
                        });
                        let reply = format!(
                            "HTTP/1.1 {status} X\r\ncontent-length: 2\r\nretry-after: 0\r\n\r\nok"
                        );
                        if reader.get_mut().write_all(reply.as_bytes()).await.is_err() {
                            return;
                        }
                    }
                });
            }
        });
        Self { url, rx, script }
    }

    async fn next(&mut self, what: &str) -> Received {
        tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
            .unwrap()
    }

    /// Asserts nothing arrives for `wait`.
    async fn quiet(&mut self, wait: Duration, why: &str) {
        if let Ok(Some(r)) = tokio::time::timeout(wait, self.rx.recv()).await {
            panic!(
                "unexpected push ({why}): {}",
                String::from_utf8_lossy(&r.body)
            );
        }
    }
}

async fn start(state: &Path, relay: &FakeRelay, delay_ms: u64) -> Daemon {
    start_at(state, relay, delay_ms, None).await
}

async fn start_at(
    state: &Path,
    relay: &FakeRelay,
    delay_ms: u64,
    bind: Option<std::net::SocketAddr>,
) -> Daemon {
    let url = relay.url.clone();
    start_with(state, move |c| {
        if bind.is_some() {
            c.bind = bind;
        }
        c.push.relay_url = url;
        c.push.delay = Duration::from_millis(delay_ms);
        c.push.backoff = Duration::from_millis(50);
    })
    .await
}

/// Sends a hook; a `PermissionRequest` waits for its decision, returned by the handle.
async fn hook(
    daemon: &Daemon,
    state: &Path,
    pane: PaneId,
    event: &str,
    payload: serde_json::Value,
) -> tokio::task::JoinHandle<String> {
    let token = std::fs::read_to_string(state.join("hook.token")).unwrap();
    let request = HookRequest {
        v: 1,
        token,
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: event.into(),
        seq: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64,
        payload,
    };
    let mut stream = UnixStream::connect(daemon.hook_socket()).await.unwrap();
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let answer = tokio::spawn(async move {
        let mut answer = String::new();
        let _ = BufReader::new(stream).read_line(&mut answer).await;
        answer
    });
    // Permission requests hold the connection until decided; others answer at once.
    if event == "PermissionRequest" {
        answer
    } else {
        let text = answer.await.unwrap();
        tokio::spawn(async move { text })
    }
}

/// A registered device: its iroh key, sealing key and connected client.
struct Device {
    key: Vec<u8>,
    seal_secret: [u8; 32],
    client: TestClient,
}

async fn device(ticket: &str, cap: &str, prefs: PushPrefs) -> Device {
    let key = ClientConfig::generate_key();
    let mut client = TestClient::connect(ticket, key.clone());
    client.until("connected", |c| c.connected > 0).await;
    let (seal_secret, seal_public) = client_core::push::x25519_keypair();
    let status = client
        .client
        .push_register(PushRegistration {
            cap: cap.into(),
            seal_key: seal_public,
            relay_url: None,
            prefs,
            activity_cap: None,
        })
        .await
        .unwrap();
    assert_eq!(status.registered, Some(prefs));
    assert!(status.enabled);
    Device {
        key,
        seal_secret,
        client,
    }
}

/// Splits the attached session: returns (shown, hidden).
async fn two_panes(c: &mut TestClient) -> (PaneId, PaneId) {
    let shown = c.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: hidden } = c
        .op(LayoutOp::Split {
            pane_id: shown,
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!()
    };
    c.client.set_view(Some(shown), vec![shown]);
    (shown, hidden)
}

fn verify(r: &Received, daemon: &Daemon) -> push::RelayRequest {
    assert_eq!(r.path, "/v1/push");
    let request = push::verify_request(&r.body, &r.signature).expect("signed by the daemon");
    assert_eq!(request.daemon, push::hex(&daemon.daemon_id().0));
    request
}

fn options(key: &[u8]) -> ClientConfig {
    let mut config = ClientConfig::new(key.to_vec());
    config.relay = RelayMode::Disabled;
    config
}

#[tokio::test(flavor = "multi_thread")]
async fn approval_is_pushed_sealed_retried_and_answered_from_the_lock_screen() {
    let state = tempfile::tempdir().unwrap();
    let mut relay = FakeRelay::start().await;
    let daemon = start(state.path(), &relay, 200).await;
    let ticket_a = ticket(&daemon);
    let a = device(&ticket_a, "cap-a", PushPrefs::default()).await;
    // Another device shows one pane; the agent runs in the other, which nobody shows.
    let ticket_b = ticket(&daemon);
    let mut b = TestClient::connect(&ticket_b, ClientConfig::generate_key());
    let (_shown, hidden) = two_panes(&mut b).await;
    // Device A's app went to the background.
    a.client.client.set_view(None, vec![]);

    // The first attempt hits a relay error and is retried.
    relay.script.lock().unwrap().push(503);
    let mut payload: serde_json::Value = serde_json::from_str(PERMISSION).unwrap();
    payload["cwd"] = "/".into();
    let waiting = hook(&daemon, state.path(), hidden, "PermissionRequest", payload).await;
    b.until("blocked agent", |c| {
        c.metas
            .get(&hidden)
            .and_then(|m| m.agent.as_ref())
            .is_some_and(|a| matches!(a.state, AgentState::Blocked(_)))
    })
    .await;

    let first = verify(&relay.next("first attempt").await, &daemon);
    let second = verify(&relay.next("retry").await, &daemon);
    assert_ne!(first.nonce, second.nonce, "each attempt is signed afresh");
    assert_eq!(first.sealed, second.sealed);
    assert_eq!(second.cap, "cap-a");
    assert_eq!(second.push_type, push::PushType::Alert);
    assert_eq!(second.category, Some(push::Category::Approval));
    assert_eq!(second.collapse.as_ref().map(String::len), Some(32));
    // Nothing readable outside the ciphertext.
    let body = String::from_utf8(relay_body(&second)).unwrap();
    assert!(!body.contains("node_modules"), "{body}");

    let note = client_core::push::open_notification(&a.seal_secret, &second.sealed).unwrap();
    assert_eq!(note.kind, push::Kind::Approval);
    assert_eq!(note.pane, hidden.0);
    assert!(note.body.contains("rm -rf node_modules"), "{note:?}");
    let offer = note.action.clone().expect("approve / deny offered");
    assert_eq!(offer.approve, "Yes");
    assert!(!offer.deny.is_empty());
    let token = client_core::push::token_bytes(&offer).unwrap();

    // Another device cannot use A's token.
    let b_key = ClientConfig::generate_key();
    let mut c = TestClient::connect(&ticket(&daemon), b_key.clone());
    c.until("connected", |c| c.connected > 0).await;
    let stolen = send_action(
        &ticket_a,
        options(&b_key),
        ConnectOptions::default(),
        token.clone(),
        Decision::Approve,
        Duration::from_secs(10),
    )
    .await;
    assert!(
        matches!(stolen, Err(ActionError::Rejected(WsError::Denied(_)))),
        "{stolen:?}"
    );

    // The lock-screen action: a one-shot connection with A's key.
    let decided = send_action(
        &ticket_a,
        options(&a.key),
        ConnectOptions::default(),
        token.clone(),
        Decision::Approve,
        Duration::from_secs(10),
    )
    .await
    .expect("approved");
    assert_eq!(decided.pane_id, hidden);
    assert_eq!(decided.decided_by.device.0.to_vec(), device_id(&a.key));
    // The waiting hook got "allow".
    let answer = tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .expect("hook answered")
        .unwrap();
    let response: daemon::HookResponse = serde_json::from_str(&answer).unwrap();
    let stdout: serde_json::Value = serde_json::from_str(&response.stdout.unwrap()).unwrap();
    assert_eq!(
        stdout["hookSpecificOutput"]["decision"]["behavior"], "allow",
        "{stdout}"
    );

    // A second tap is refused.
    let again = send_action(
        &ticket_a,
        options(&a.key),
        ConnectOptions::default(),
        token,
        Decision::Deny,
        Duration::from_secs(10),
    )
    .await;
    assert!(
        matches!(
            again,
            Err(ActionError::Rejected(
                WsError::Conflict(_) | WsError::NotFound(_)
            ))
        ),
        "{again:?}"
    );
    let list = a.client.client.attention_list().await.unwrap();
    assert!(list.items.iter().all(|i| i.seen), "{list:#?}");
    // The lock-screen approval is in the signed audit log like an in-app one.
    let page = a.client.client.audit(None, 100).await.unwrap();
    assert!(page.chain_ok);
    let record = page
        .records
        .iter()
        .find(|r| r.kind == proto::AuditKind::Approval)
        .expect("approval audited");
    let approval = record.approval.as_ref().unwrap();
    assert_eq!(record.actor.unwrap().device.0.to_vec(), device_id(&a.key));
    assert!(grants::verify_signature(
        record.actor.unwrap().device,
        &approval.signed,
        &approval.sig
    ));
    drop((a, b, c));
    daemon.shutdown().await;
}

fn relay_body(r: &push::RelayRequest) -> Vec<u8> {
    serde_json::to_vec(r).unwrap()
}

fn device_id(key: &[u8]) -> Vec<u8> {
    push::ed25519_public(key.try_into().unwrap()).to_vec()
}

#[tokio::test(flavor = "multi_thread")]
async fn pushes_respect_viewing_seen_prefs_and_gone_tokens() {
    let state = tempfile::tempdir().unwrap();
    let mut relay = FakeRelay::start().await;
    let daemon = start(state.path(), &relay, 400).await;
    let prefs = PushPrefs {
        commands: false,
        ..PushPrefs::default()
    };
    let mut a = device(&ticket(&daemon), "cap-a", prefs).await;
    let (shown, hidden) = two_panes(&mut a.client).await;
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    let prompt = |name: &str| {
        serde_json::json!({
            "session_id": "s", "cwd": home, "hook_event_name": name, "prompt": "go",
        })
    };
    let stop = serde_json::json!({
        "session_id": "s", "cwd": home, "hook_event_name": "Stop",
        "last_assistant_message": "All tests pass.",
    });

    // 1. A is in the foreground on this host (showing another pane): no push.
    hook(
        &daemon,
        state.path(),
        hidden,
        "UserPromptSubmit",
        prompt("UserPromptSubmit"),
    )
    .await;
    hook(&daemon, state.path(), hidden, "Stop", stop.clone()).await;
    relay
        .quiet(
            Duration::from_millis(1200),
            "device is looking at this host",
        )
        .await;

    // 2. A backgrounded, but another device focuses the pane within the delay: seen, no push.
    a.client.client.set_view(None, vec![]);
    let mut b = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    b.until("connected", |c| c.connected > 0).await;
    b.client.attach(None);
    b.until("layout", |c| c.layout.is_some()).await;
    hook(
        &daemon,
        state.path(),
        hidden,
        "UserPromptSubmit",
        prompt("UserPromptSubmit"),
    )
    .await;
    hook(&daemon, state.path(), hidden, "Stop", stop.clone()).await;
    b.client.set_view(Some(hidden), vec![hidden]);
    relay
        .quiet(Duration::from_millis(1200), "item was seen")
        .await;

    // 3. Nobody looks: a "done" push, without actions.
    b.client.set_view(Some(shown), vec![shown]);
    tokio::time::sleep(Duration::from_millis(100)).await;
    hook(
        &daemon,
        state.path(),
        hidden,
        "UserPromptSubmit",
        prompt("UserPromptSubmit"),
    )
    .await;
    hook(&daemon, state.path(), hidden, "Stop", stop.clone()).await;
    let r = verify(&relay.next("done push").await, &daemon);
    assert_eq!(r.category, Some(push::Category::Done));
    let note = client_core::push::open_notification(&a.seal_secret, &r.sealed).unwrap();
    assert_eq!(note.kind, push::Kind::Done);
    assert_eq!(note.body, "All tests pass.");
    assert!(note.action.is_none());

    // 4. The relay says the APNs token is gone: the registration is dropped.
    relay.script.lock().unwrap().push(410);
    hook(
        &daemon,
        state.path(),
        hidden,
        "UserPromptSubmit",
        prompt("UserPromptSubmit"),
    )
    .await;
    hook(&daemon, state.path(), hidden, "Stop", stop).await;
    relay.next("push answered 410").await;
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let status = a.client.client.push_status().await.unwrap();
        if status.registered.is_none() {
            assert_eq!(status.devices, 0);
            break;
        }
        assert!(std::time::Instant::now() < deadline, "still registered");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    drop((a, b));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn registrations_persist_and_bad_keys_are_refused() {
    let state = tempfile::tempdir().unwrap();
    let relay = FakeRelay::start().await;
    let daemon = start(state.path(), &relay, 100).await;
    let mut a = device(&ticket(&daemon), "cap-a", PushPrefs::default()).await;
    let bad = a
        .client
        .client
        .push_register(PushRegistration {
            cap: "cap".into(),
            seal_key: [0; 32],
            relay_url: None,
            prefs: PushPrefs::default(),
            activity_cap: None,
        })
        .await;
    assert!(matches!(bad, Err(WsError::Invalid(_))), "{bad:?}");
    let ticket_text = ticket(&daemon);
    let bound = daemon.bound_sockets()[0];
    drop(a.client);
    daemon.shutdown().await;
    assert!(state.path().join("push.json").exists());

    // Same address, so the ticket still dials it.
    let daemon = start_at(state.path(), &relay, 100, Some(bound)).await;
    a.client = TestClient::connect(&ticket_text, a.key.clone());
    a.client.until("connected", |c| c.connected > 0).await;
    let status = a.client.client.push_status().await.unwrap();
    assert_eq!(status.registered, Some(PushPrefs::default()));
    let status = a.client.client.push_unregister().await.unwrap();
    assert_eq!(status.registered, None);
    drop(a);
    daemon.shutdown().await;
}

/// The real Worker in `wrangler dev` with the fake APNs (docs/PUSH.md "Local development"):
///
/// ```text
/// cd services/push-relay && npm run gen-dev-vars && npm run fake-apns   # terminal 1
/// cd services/push-relay && npm run dev                                 # terminal 2
/// PUSH_DEV_RELAY=http://127.0.0.1:8787 cargo test -p daemon --test it local_dev_relay -- --ignored
/// ```
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs wrangler dev and the fake APNs running"]
async fn local_dev_relay_end_to_end() {
    let relay_url = std::env::var("PUSH_DEV_RELAY").expect("PUSH_DEV_RELAY");
    let apns_log =
        std::env::var("PUSH_DEV_APNS_LOG").unwrap_or_else(|_| "http://127.0.0.1:8790/log".into());
    let _ = rustls::crypto::ring::default_provider().install_default();
    let http = reqwest::Client::new();
    let state = tempfile::tempdir().unwrap();
    let url = relay_url.clone();
    let daemon = start_with(state.path(), move |c| {
        c.push.relay_url = url;
        c.push.delay = Duration::from_millis(200);
    })
    .await;

    // What the app does: trade the APNs token for a capability bound to this daemon...
    let mut raw = [0u8; 32];
    getrandom::fill(&mut raw).unwrap();
    let apns_token = push::hex(&raw);
    let body = serde_json::json!({
        "token": apns_token,
        "env": "sandbox",
        "daemon": push::hex(&daemon.daemon_id().0),
    });
    let reg: serde_json::Value = http
        .post(format!("{relay_url}/v1/register"))
        .header("content-type", "application/json")
        .body(body.to_string())
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let cap = reg["cap"].as_str().expect("a capability").to_owned();
    // ...and hand it to the daemon.
    let mut a = device(&ticket(&daemon), &cap, PushPrefs::default()).await;
    let (_shown, hidden) = two_panes(&mut a.client).await;
    a.client.client.set_view(None, vec![]);
    let home = std::env::var("HOME").unwrap();
    let prompt = serde_json::json!({
        "session_id": "s", "cwd": home, "hook_event_name": "UserPromptSubmit", "prompt": "go",
    });
    hook(&daemon, state.path(), hidden, "UserPromptSubmit", prompt).await;
    let stop = serde_json::json!({
        "session_id": "s", "cwd": home, "hook_event_name": "Stop",
        "last_assistant_message": "Done via wrangler dev.",
    });
    hook(&daemon, state.path(), hidden, "Stop", stop).await;

    // The fake APNs got a mutable alert for our token whose payload opens on the "device".
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let entry = loop {
        let text = http
            .get(&apns_log)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        let log: Vec<serde_json::Value> = serde_json::from_str(&text).unwrap();
        if let Some(e) = log.into_iter().find(|e| e["token"] == apns_token.as_str()) {
            break e;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "nothing reached the fake APNs"
        );
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    assert_eq!(entry["problems"], serde_json::json!([]));
    assert_eq!(entry["payload"]["aps"]["mutable-content"], 1);
    assert_eq!(entry["payload"]["aps"]["category"], "AGENT_DONE");
    let sealed = entry["payload"]["s"].as_str().unwrap();
    let note = client_core::push::open_notification(&a.seal_secret, sealed).unwrap();
    assert_eq!(note.body, "Done via wrangler dev.");
    drop(a);
    daemon.shutdown().await;
}
