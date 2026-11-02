//! The app's browser from the host: `BROWSER` URLs and browser tool calls on the hook socket
//! (a fake helper here; `crates/hostd/tests/browser.rs` runs the real one) reach one
//! connection that asked for them and shows the pane, and the app's answer reaches the caller.

use std::path::Path;
use std::time::Duration;

use client_core::ClientConfig;
use client_core::proto::{BrowserPush, PaneId};
use daemon::{BROWSER_VERSION, BrowserAsk, BrowserCall, BrowserReply};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start, ticket};

fn call(dir: &Path, pane: PaneId, browser: BrowserAsk) -> BrowserCall {
    BrowserCall {
        v: BROWSER_VERSION,
        token: std::fs::read_to_string(dir.join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        browser,
    }
}

/// One line out; the stream stays open until the answer, like the shim's.
async fn send(socket: &Path, call: &BrowserCall) -> BufReader<UnixStream> {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(call).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    BufReader::new(stream)
}

async fn answer(mut stream: BufReader<UnixStream>) -> BrowserReply {
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(20), stream.read_line(&mut line))
        .await
        .expect("the daemon answered")
        .unwrap();
    serde_json::from_str(&line).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn urls_and_tool_calls_reach_the_app_showing_the_pane() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let socket = daemon.hook_socket().to_owned();
    // A client that did not ask (an older app, the CLI) is never sent anything.
    let mut plain = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = plain.attach_and_follow().await;
    let url =
        "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A4567%2Fcallback";

    // Panes carry the helper.
    plain.type_line(pane, "printf 'browser=%s\\n' \"${BROWSER##*/}\"");
    plain.wait_text(pane, "browser=gudo-open").await;
    let script = std::fs::read_to_string(dir.path().join("browser/gudo-open")).unwrap();
    assert!(script.contains(" open-url \"$@\""), "{script}");

    // Nobody can show it yet: the helper falls back to the system's opener.
    let open = BrowserAsk::Open { url: url.into() };
    let reply = answer(send(&socket, &call(dir.path(), pane, open.clone())).await).await;
    assert_eq!(reply, BrowserReply::NoApp);

    let mut app = TestClient::connect_browser(&ticket(&daemon), ClientConfig::generate_key());
    assert_eq!(app.attach_and_follow().await, pane);
    let reply = answer(send(&socket, &call(dir.path(), pane, open)).await).await;
    assert_eq!(reply, BrowserReply::Opened);
    app.until("the URL", |client| !client.browser.is_empty())
        .await;
    assert_eq!(
        app.browser[0],
        BrowserPush::Open {
            pane_id: pane,
            url: url.into()
        }
    );

    // Only web URLs, and only with the hook token.
    let bad = BrowserAsk::Open {
        url: "file:///etc/passwd".into(),
    };
    let reply = answer(send(&socket, &call(dir.path(), pane, bad)).await).await;
    assert!(matches!(reply, BrowserReply::Error(_)), "{reply:?}");
    let mut forged = call(dir.path(), pane, BrowserAsk::Open { url: url.into() });
    forged.token = "nope".into();
    let reply = answer(send(&socket, &forged).await).await;
    assert!(matches!(reply, BrowserReply::Error(_)), "{reply:?}");

    // A tool call waits for the app's answer.
    let tool = BrowserAsk::Tool {
        name: "browser_snapshot".into(),
        args: serde_json::json!({ "interactive": true }),
    };
    let pending = send(&socket, &call(dir.path(), pane, tool.clone())).await;
    app.until("the call", |client| client.browser.len() == 2)
        .await;
    let BrowserPush::Call {
        id,
        pane_id,
        tool: name,
        args,
    } = app.browser[1].clone()
    else {
        panic!("not a call: {:?}", app.browser[1]);
    };
    assert_eq!((pane_id, name.as_str()), (pane, "browser_snapshot"));
    assert_eq!(args, r#"{"interactive":true}"#);
    // An answer from another connection is ignored; the right one gets through.
    plain.client.answer_browser_call(id, Ok("forged".into()));
    app.client
        .answer_browser_call(id, Ok(r#"{"text":"- button \"Sign in\" [ref=e1]"}"#.into()));
    assert_eq!(
        answer(pending).await,
        BrowserReply::Result(r#"{"text":"- button \"Sign in\" [ref=e1]"}"#.into())
    );
    // Failures come back as errors.
    let pending = send(&socket, &call(dir.path(), pane, tool.clone())).await;
    app.until("the second call", |client| client.browser.len() == 3)
        .await;
    let BrowserPush::Call { id, .. } = app.browser[2] else {
        panic!("not a call");
    };
    app.client
        .answer_browser_call(id, Err("no browser pane".into()));
    assert_eq!(
        answer(pending).await,
        BrowserReply::Error("no browser pane".into())
    );

    // A caller that hangs up closes its call in the app.
    let pending = send(&socket, &call(dir.path(), pane, tool)).await;
    app.until("the third call", |client| client.browser.len() == 4)
        .await;
    let BrowserPush::Call { id, .. } = app.browser[3] else {
        panic!("not a call");
    };
    drop(pending);
    app.until("the call closed", |client| {
        client.browser.contains(&BrowserPush::CallClosed { id })
    })
    .await;
    assert!(plain.browser.is_empty());
}

/// A guest's browser holds the guest's own sign-ins: the host's programs (or a guest typing in
/// a shared pane) must never drive or read it, so URLs and tools reach the owner's devices only.
#[tokio::test(flavor = "multi_thread")]
async fn a_driving_guest_never_gets_the_hosts_browser_calls() {
    use client_core::grants::GrantSpec;
    use client_core::now_millis;
    use client_core::proto::{Roles, Scope, UnixMillis};

    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let socket = daemon.hook_socket().to_owned();
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut spec = GrantSpec::new(Roles::DRIVER, Scope::Daemon);
    spec.label = "bob".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "bob".into())
        .await
        .unwrap();
    let mut bob = TestClient::join_browser(&invite.to_string(), ClientConfig::generate_key());
    bob.client.attach(None);
    bob.until("guest layout", |client| client.layout.is_some())
        .await;
    bob.follow(pane).await;

    let open = BrowserAsk::Open {
        url: "https://example.com/".into(),
    };
    let reply = answer(send(&socket, &call(dir.path(), pane, open.clone())).await).await;
    assert_eq!(reply, BrowserReply::NoApp);
    let tool = BrowserAsk::Tool {
        name: "browser_get_text".into(),
        args: serde_json::json!({}),
    };
    let reply = answer(send(&socket, &call(dir.path(), pane, tool)).await).await;
    assert_eq!(reply, BrowserReply::NoApp);

    // The owner's own browser device gets them.
    let mut app = TestClient::connect_browser(&ticket(&daemon), ClientConfig::generate_key());
    assert_eq!(app.attach_and_follow().await, pane);
    let reply = answer(send(&socket, &call(dir.path(), pane, open)).await).await;
    assert_eq!(reply, BrowserReply::Opened);
    app.until("the URL", |client| !client.browser.is_empty())
        .await;
    bob.until("settled", |_| true).await;
    assert!(bob.browser.is_empty(), "{:?}", bob.browser);

    // Once the guest drives the pane, a tool call made with the pane's token (anything bob
    // types could make one) is refused: it would drive the owner's signed-in browser.
    bob.type_line(pane, "echo bob-drives");
    bob.wait_text(pane, "bob-drives").await;
    let tool = BrowserAsk::Tool {
        name: "browser_get_text".into(),
        args: serde_json::json!({}),
    };
    let reply = answer(send(&socket, &call(dir.path(), pane, tool)).await).await;
    assert!(
        matches!(&reply, BrowserReply::Error(why) if why.contains("bob is driving")),
        "{reply:?}"
    );
    app.until("settled", |_| true).await;
    assert!(
        !app.browser
            .iter()
            .any(|push| matches!(push, BrowserPush::Call { .. })),
        "{:?}",
        app.browser
    );
}
