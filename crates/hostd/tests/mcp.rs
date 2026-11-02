//! The real MCP server (`gudo-hook mcp`) against a daemon in this process: an agent's MCP client
//! initializes, lists the tools, and pulls the session's drawing as an image and as text; a
//! browser tool call reaches the app showing the pane and its answer comes back as content; a
//! terminal tool runs a real command and answers with typed results.

#[allow(dead_code)]
#[path = "../../daemon/tests/it/support.rs"]
mod support;

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use client_core::ClientConfig;
use client_core::proto::{
    ArtifactCreate, ArtifactKind, BrowserPush, CoordSpace, DrawOp, Element, ElementId, ElementKind,
    Pt, ShapeKind, Style,
};
use serde_json::{Value, json};

use support::{TestClient, start, ticket};

const HOOK: &str = env!("CARGO_BIN_EXE_gudo-hook");

struct Server {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next: u64,
}

impl Server {
    fn spawn(args: &[&str]) -> Self {
        let mut cmd = Command::new(HOOK);
        cmd.args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        // Only the flags say where the daemon is.
        for name in ["PANE_ID", "SOCK", "TOKEN", "ENDPOINT_FILE"] {
            cmd.env_remove(brand::env_var(name));
        }
        let mut child = cmd.spawn().unwrap();
        Self {
            stdin: child.stdin.take().unwrap(),
            stdout: BufReader::new(child.stdout.take().unwrap()),
            child,
            next: 1,
        }
    }

    fn send(&mut self, msg: &Value) {
        let mut line = msg.to_string();
        line.push('\n');
        self.stdin.write_all(line.as_bytes()).unwrap();
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.send(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["id"], id, "{reply}");
        reply
    }

    fn tool(&mut self, name: &str, arguments: Value) -> Value {
        self.request(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        )["result"]
            .clone()
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn agents_read_the_sessions_drawings_over_mcp() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = c.attach_and_follow().await;
    let session = c.layout.as_ref().unwrap().session_id;
    let drawing = c
        .client
        .artifact_create(ArtifactCreate {
            session_id: session,
            kind: ArtifactKind::Drawing,
            title: "arch".into(),
            space: CoordSpace::Canvas,
            anchor: None,
            image: None,
            ops: vec![DrawOp::Add(Element {
                id: ElementId(1),
                z: 0,
                style: Style {
                    color: 0x2233_44ff,
                    width: 2.0,
                },
                kind: ElementKind::Shape {
                    shape: ShapeKind::Rect,
                    from: Pt { x: 10.0, y: 10.0 },
                    to: Pt { x: 120.0, y: 60.0 },
                    filled: false,
                },
            })],
        })
        .await
        .unwrap();

    let state = dir.path().to_str().unwrap();
    let pane = pane.0.to_string();
    let mut server = Server::spawn(&["mcp", "--state", state, "--pane", &pane]);
    let init = server.request(
        "initialize",
        json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": { "name": "test", "version": "0" },
        }),
    );
    assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
    server.send(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
    let tools = server.request("tools/list", json!({}));
    assert!(tools["result"]["tools"].as_array().unwrap().len() > 2);

    let list = server.tool("list_drawings", json!({}));
    let text = list["content"][0]["text"].as_str().unwrap();
    assert!(
        text.contains(&format!("#{} drawing \"arch\"", drawing.artifact_id.0)),
        "{text}"
    );

    let png = server.tool("get_drawing", json!({}));
    assert_eq!(png["content"][1]["type"], "image", "{png}");
    assert_eq!(png["content"][1]["mimeType"], "image/png");
    assert!(
        png["content"][1]["data"]
            .as_str()
            .unwrap()
            .starts_with("iVBORw0KGgo")
    );
    let ascii = server.tool(
        "get_drawing",
        json!({ "id": drawing.artifact_id.0, "format": "ascii" }),
    );
    assert!(
        ascii["content"][1]["text"].as_str().unwrap().contains('┌'),
        "{ascii}"
    );
    let missing = server.tool("get_drawing", json!({ "id": 999 }));
    assert_eq!(missing["isError"], true);

    // A server for a pane that does not exist answers, but with tool errors only.
    let mut stray = Server::spawn(&["mcp", "--state", state, "--pane", "424242"]);
    assert_eq!(stray.tool("list_drawings", json!({}))["isError"], true);

    drop((server.stdin, stray.stdin));
    assert!(server.child.wait().unwrap().success());
    assert!(stray.child.wait().unwrap().success());
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn browser_tools_reach_the_app_showing_the_pane() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut app = TestClient::connect_browser(&ticket(&daemon), ClientConfig::generate_key());
    let pane = app.attach_and_follow().await.0.to_string();
    let state = dir.path().to_str().unwrap().to_owned();
    let (state2, pane2) = (state.clone(), pane.clone());
    let call = tokio::task::spawn_blocking(move || {
        let mut server = Server::spawn(&["mcp", "--state", &state, "--pane", &pane]);
        server.request(
            "initialize",
            json!({ "protocolVersion": "2025-11-25", "capabilities": {} }),
        );
        let snapshot = server.tool("browser_snapshot", json!({ "filter": "interactive" }));
        let missing = server.tool("browser_click", json!({}));
        drop(server.stdin);
        (snapshot, missing)
    });
    app.until("the call", |c| !c.browser.is_empty()).await;
    let BrowserPush::Call { id, tool, args, .. } = app.browser[0].clone() else {
        panic!("not a call: {:?}", app.browser[0]);
    };
    assert_eq!(tool, "browser_snapshot");
    assert_eq!(
        serde_json::from_str::<Value>(&args).unwrap()["filter"],
        "interactive"
    );
    app.client.answer_browser_call(
        id,
        Ok(json!({ "text": "button \"Sign in\" [ref_1]", "image": { "data": "AAAA", "mimeType": "image/jpeg" } }).to_string()),
    );
    let (snapshot, missing) = call.await.unwrap();
    assert_eq!(
        snapshot["content"][0]["text"], "button \"Sign in\" [ref_1]",
        "{snapshot}"
    );
    assert_eq!(snapshot["content"][1]["type"], "image");
    // Bad arguments never reach the app.
    assert_eq!(missing["isError"], true);
    assert_eq!(app.browser.len(), 1);

    // A file near the upload cap is read on the host and reaches the app in one call.
    let file = dir.path().join("photo.jpg");
    std::fs::write(&file, vec![7u8; 2_900_000]).unwrap();
    let (state, pane) = (state2, pane2);
    let path = file.to_str().unwrap().to_owned();
    let call = tokio::task::spawn_blocking(move || {
        let mut server = Server::spawn(&["mcp", "--state", &state, "--pane", &pane]);
        server.request(
            "initialize",
            json!({ "protocolVersion": "2025-11-25", "capabilities": {} }),
        );
        server.tool(
            "browser_upload",
            json!({ "target": { "type": "ref", "ref": "ref_2" }, "paths": [path] }),
        )
    });
    app.until("the upload", |c| c.browser.len() == 2).await;
    let BrowserPush::Call { id, tool, args, .. } = app.browser[1].clone() else {
        panic!("not a call: {:?}", app.browser[1]);
    };
    assert_eq!(tool, "browser_upload");
    let args: Value = serde_json::from_str(&args).unwrap();
    assert_eq!(args["files"][0]["name"], "photo.jpg");
    assert_eq!(args["files"][0]["mime_type"], "image/jpeg");
    assert_eq!(
        args["files"][0]["data"].as_str().unwrap().len(),
        2_900_000_usize.div_ceil(3) * 4
    );
    app.client
        .answer_browser_call(id, Ok(json!({ "text": "Done." }).to_string()));
    assert_eq!(call.await.unwrap()["content"][0]["text"], "Done.");
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn agents_run_commands_over_mcp_with_typed_results() {
    let Some(zsh) = ["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh"]
        .into_iter()
        .find(|p| std::path::Path::new(p).exists())
    else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start_with(dir.path(), |c| c.shell = Some(zsh.into())).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = c.attach_and_follow().await.0.to_string();
    let state = dir.path().to_str().unwrap();
    let mut server = Server::spawn(&["mcp", "--state", state, "--pane", &pane]);
    server.request(
        "initialize",
        json!({ "protocolVersion": "2025-11-25", "capabilities": {} }),
    );

    let tools = server.request("tools/list", json!({}))["result"]["tools"].clone();
    let run = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "cmd_run")
        .unwrap();
    assert_eq!(
        run["outputSchema"]["properties"]["status"]["enum"][0],
        "exited"
    );
    assert_eq!(run["annotations"]["readOnlyHint"], false);

    let result = server.tool("cmd_run", json!({ "command": "echo hi; (exit 2)" }));
    let typed = &result["structuredContent"];
    assert_eq!(typed["status"], "exited", "{result}");
    assert_eq!(typed["command"]["exitCode"], 2, "{result}");
    assert_eq!(typed["output"]["text"], "hi", "{result}");
    let text = result["content"][0]["text"].as_str().unwrap();
    assert!(text.starts_with("status: exited, exit code 2"), "{text}");

    let refused = server.tool("pane_send", json!({ "pane": "self", "text": "x" }));
    assert_eq!(refused["isError"], true, "{refused}");
    assert!(
        refused["content"][0]["text"]
            .as_str()
            .unwrap()
            .starts_with("forbidden")
    );
}
