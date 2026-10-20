//! `un-hook mcp`: a stdio MCP server through which an agent reads the drawings of its terminal
//! session (docs/DAEMON.md §7.12).
//!
//! JSON-RPC 2.0, one message per line. Each tool call becomes one [`PullCall`] on the daemon's
//! hook socket. The socket comes from `<state>/hook.endpoint` and the token from
//! `<state>/hook.token` (never from the command line); without `--state` the pane's
//! environment (`UN_ENDPOINT_FILE` / `UN_SOCK`, `UN_TOKEN`) is used, then the default state
//! directory. The pane is `--pane`, else `UN_PANE_ID`.

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use daemon::{PULL_FORMATS, PULL_VERSION, PullCall, PullExport, PullOp, PullReply, PullSummary};
use serde_json::{Value, json};

/// MCP protocol revisions this server speaks; the last is the default.
const PROTOCOL_VERSIONS: &[&str] = &["2024-11-05", "2025-03-26", "2025-06-18"];

/// How long one daemon call may take (a PNG may need rasterising).
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// Where the daemon's answers come from.
pub trait Backend {
    /// Runs one pull operation.
    ///
    /// # Errors
    ///
    /// Fails when the daemon cannot be reached or answers garbage; refusals arrive as
    /// [`PullReply::Error`].
    fn pull(&mut self, op: PullOp) -> io::Result<PullReply>;
}

/// Runs the server with the arguments after `mcp`; returns the exit status.
pub fn main(args: &[String]) -> i32 {
    let mut backend = match SocketBackend::from_args(args) {
        Ok(b) => b,
        Err(e) => {
            eprintln!(
                "{}: {e}\nusage: {} mcp [--state <dir>] [--pane <id>]",
                brand::HOOK_BIN,
                brand::HOOK_BIN
            );
            return 2;
        }
    };
    let stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();
    for line in stdin.lines() {
        let Ok(line) = line else {
            break;
        };
        if line.trim().is_empty() {
            continue;
        }
        if let Some(reply) = handle_line(&line, &mut backend) {
            let mut out = reply.to_string();
            out.push('\n');
            if stdout
                .write_all(out.as_bytes())
                .and_then(|()| stdout.flush())
                .is_err()
            {
                break;
            }
        }
    }
    0
}

/// Answers one line of input; `None` for notifications and responses.
pub fn handle_line(line: &str, backend: &mut dyn Backend) -> Option<Value> {
    match serde_json::from_str::<Value>(line) {
        Ok(msg) => handle(&msg, backend),
        Err(_) => Some(error(Value::Null, -32700, "Parse error")),
    }
}

/// Answers one JSON-RPC message; `None` for notifications and responses.
pub fn handle(msg: &Value, backend: &mut dyn Backend) -> Option<Value> {
    let Some(method) = msg.get("method").and_then(Value::as_str) else {
        // A response to us (we send no requests) is dropped; anything else is malformed.
        let is_response = msg.get("result").is_some() || msg.get("error").is_some();
        return (!is_response).then(|| {
            let id = msg.get("id").cloned().unwrap_or(Value::Null);
            error(id, -32600, "Invalid Request")
        });
    };
    let id = msg.get("id")?.clone();
    let params = msg.get("params").unwrap_or(&Value::Null);
    let result = match method {
        "initialize" => initialize(params),
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools() }),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params.get("arguments").unwrap_or(&Value::Null);
            match call_tool(name, args, backend) {
                Some(result) => result,
                None => return Some(error(id, -32602, &format!("Unknown tool: {name}"))),
            }
        }
        _ => return Some(error(id, -32601, "Method not found")),
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

fn error(id: Value, code: i32, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

fn initialize(params: &Value) -> Value {
    let asked = params.get("protocolVersion").and_then(Value::as_str);
    let version = asked
        .filter(|v| PROTOCOL_VERSIONS.contains(v))
        .unwrap_or(PROTOCOL_VERSIONS[PROTOCOL_VERSIONS.len() - 1]);
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": {} },
        "serverInfo": {
            "name": format!("{}-drawings", brand::PRODUCT_NAME),
            "version": env!("CARGO_PKG_VERSION"),
        },
        "instructions": "Drawings, sketches and images the user made in this terminal session. \
            Call list_drawings to see them and get_drawing to look at one; with no id, \
            get_drawing returns the most recent drawing.",
    })
}

fn tools() -> Value {
    let formats: Vec<&str> = PULL_FORMATS.iter().map(|f| f.name).collect();
    let read_only = json!({ "readOnlyHint": true, "openWorldHint": false });
    json!([
        {
            "name": "list_drawings",
            "description": "List the drawings, sketches and images the user made in this \
                terminal session, newest first: id, kind, title, version, when it changed, and \
                where it is shown.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": read_only,
        },
        {
            "name": "get_drawing",
            "description": "Get one drawing from this terminal session: png returns the image, \
                svg the vector markup, ascii a text rendering (boxes, arrows and labels). \
                Without an id, the most recently changed drawing.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "integer", "description": "The drawing's id from list_drawings." },
                    "format": { "type": "string", "enum": formats, "default": formats[0] },
                    "version": { "type": "integer", "description": "An earlier version; the current one when absent." },
                },
            },
            "annotations": read_only,
        },
    ])
}

/// Runs tool `name`; `None` if there is no such tool.
fn call_tool(name: &str, args: &Value, backend: &mut dyn Backend) -> Option<Value> {
    let op = match name {
        "list_drawings" => Ok(PullOp::List),
        "get_drawing" => get_op(args),
        _ => return None,
    };
    let result = op.and_then(|op| {
        backend
            .pull(op)
            .map_err(|e| format!("the {} daemon is not reachable: {e}", brand::PRODUCT_NAME))
    });
    Some(match result {
        Ok(PullReply::List { session, artifacts }) => list_result(session, &artifacts),
        Ok(PullReply::Export(export)) => export_result(&export),
        Ok(PullReply::Error(e)) | Err(e) => tool_error(&e),
    })
}

fn get_op(args: &Value) -> Result<PullOp, String> {
    let int = |key: &str| match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_u64()
            .map(Some)
            .ok_or_else(|| format!("`{key}` must be a non-negative integer")),
    };
    let format = match args.get("format") {
        None | Some(Value::Null) => None,
        Some(Value::String(f)) => Some(f.clone()),
        Some(_) => return Err("`format` must be a string".into()),
    };
    Ok(PullOp::Get {
        id: int("id")?,
        format,
        version: int("version")?,
    })
}

fn tool_error(message: &str) -> Value {
    json!({ "content": [{ "type": "text", "text": message }], "isError": true })
}

fn list_result(session: u64, artifacts: &[PullSummary]) -> Value {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let mut text = if artifacts.is_empty() {
        format!("No drawings in session {session} yet.\n")
    } else {
        format!(
            "{} in session {session}, newest first:\n",
            count(artifacts.len())
        )
    };
    for a in artifacts {
        text.push_str(&format!("- #{} {} ", a.id, a.kind));
        if !a.title.is_empty() {
            text.push_str(&format!("{:?} ", a.title));
        }
        text.push_str(&format!("v{}, ", a.version));
        if a.kind != "image" {
            text.push_str(&format!("{} elements, ", a.elements));
        }
        if let (Some(w), Some(h)) = (a.width, a.height) {
            text.push_str(&format!("{w}×{h} px, "));
        }
        text.push_str(&format!(
            "changed {}",
            ago(now.saturating_sub(a.updated_at))
        ));
        if let Some(pane) = a.ink_over {
            text.push_str(&format!(", drawn over pane {pane}"));
        }
        text.push('\n');
    }
    let json = serde_json::to_string_pretty(&json!({ "session": session, "drawings": artifacts }))
        .unwrap_or_default();
    json!({
        "content": [
            { "type": "text", "text": text },
            { "type": "text", "text": json },
        ],
    })
}

fn count(n: usize) -> String {
    if n == 1 {
        "1 drawing".into()
    } else {
        format!("{n} drawings")
    }
}

fn ago(ms: u64) -> String {
    match ms / 1000 {
        s @ 0..60 => format!("{s} s ago"),
        s @ 60..3600 => format!("{} min ago", s / 60),
        s @ 3600..86_400 => format!("{} h ago", s / 3600),
        s => format!("{} days ago", s / 86_400),
    }
}

fn export_result(e: &PullExport) -> Value {
    let title = if e.title.is_empty() {
        String::new()
    } else {
        format!(" {:?}", e.title)
    };
    let caption = format!(
        "Drawing #{}{title}, version {}, {}:",
        e.id, e.version, e.format
    );
    // Binary formats are images; text formats (SVG, ASCII) are read as they are.
    let body = if e.base64 {
        json!({ "type": "image", "data": e.data, "mimeType": e.mime })
    } else {
        json!({ "type": "text", "text": e.data })
    };
    json!({ "content": [{ "type": "text", "text": caption }, body] })
}

/// Where the socket path comes from.
#[derive(Debug)]
enum Endpoint {
    /// A file holding the path, re-read per call so the server outlives a daemon restart.
    File(PathBuf),
    /// The path itself.
    Socket(PathBuf),
}

/// Where the token comes from.
#[derive(Debug)]
enum Token {
    /// `<state>/hook.token`, read per call.
    File(PathBuf),
    /// From the environment.
    Value(String),
}

/// The daemon's hook socket.
#[derive(Debug)]
pub struct SocketBackend {
    endpoint: Endpoint,
    token: Token,
    pane: String,
}

impl SocketBackend {
    /// Resolves the socket, token and pane from `--state` / `--pane` and the environment.
    ///
    /// # Errors
    ///
    /// Fails on unknown arguments and when no pane is given.
    pub fn from_args(args: &[String]) -> Result<Self, String> {
        let mut state = None;
        let mut pane = None;
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let (flag, inline) = match arg.split_once('=') {
                Some((f, v)) => (f, Some(v.to_owned())),
                None => (arg.as_str(), None),
            };
            let slot = match flag {
                "--state" => &mut state,
                "--pane" => &mut pane,
                _ => return Err(format!("unknown argument {arg:?}")),
            };
            *slot = Some(
                inline
                    .or_else(|| it.next().cloned())
                    .ok_or_else(|| format!("{flag} needs a value"))?,
            );
        }
        let env = |name: &str| std::env::var(brand::env_var(name)).ok();
        let pane = pane
            .or_else(|| env("PANE_ID"))
            .ok_or("no pane: pass --pane <id> (the pane's UN_PANE_ID)")?;
        let from_state = |dir: PathBuf| Self {
            endpoint: Endpoint::File(dir.join("hook.endpoint")),
            token: Token::File(dir.join("hook.token")),
            pane: pane.clone(),
        };
        if let Some(dir) = state {
            return Ok(from_state(dir.into()));
        }
        let endpoint = env("ENDPOINT_FILE")
            .map(|f| Endpoint::File(f.into()))
            .or_else(|| env("SOCK").map(|s| Endpoint::Socket(s.into())));
        Ok(match (endpoint, env("TOKEN")) {
            (Some(endpoint), Some(token)) => Self {
                endpoint,
                token: Token::Value(token),
                pane,
            },
            _ => from_state(daemon::default_state_dir()),
        })
    }

    fn socket(&self) -> io::Result<PathBuf> {
        match &self.endpoint {
            Endpoint::File(f) => Ok(PathBuf::from(std::fs::read_to_string(f)?.trim())),
            Endpoint::Socket(s) => Ok(s.clone()),
        }
    }

    fn token(&self) -> io::Result<String> {
        match &self.token {
            Token::File(f) => Ok(std::fs::read_to_string(f)?.trim().to_owned()),
            Token::Value(t) => Ok(t.clone()),
        }
    }
}

impl Backend for SocketBackend {
    fn pull(&mut self, op: PullOp) -> io::Result<PullReply> {
        let call = PullCall {
            v: PULL_VERSION,
            token: self.token()?,
            pane: self.pane.clone(),
            pull: op,
        };
        let mut stream = UnixStream::connect(self.socket()?)?;
        stream.set_read_timeout(Some(CALL_TIMEOUT))?;
        stream.set_write_timeout(Some(CALL_TIMEOUT))?;
        let mut line = serde_json::to_vec(&call)?;
        line.push(b'\n');
        stream.write_all(&line)?;
        let mut answer = String::new();
        BufReader::new(stream).read_line(&mut answer)?;
        if answer.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the daemon closed the connection (too old for the pull channel?)",
            ));
        }
        Ok(serde_json::from_str(&answer)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Answers from a script and records what was asked.
    #[derive(Default)]
    struct Fake {
        asked: Vec<PullOp>,
        reply: Option<PullReply>,
    }

    impl Backend for Fake {
        fn pull(&mut self, op: PullOp) -> io::Result<PullReply> {
            self.asked.push(op);
            self.reply
                .clone()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no socket"))
        }
    }

    fn rpc(fake: &mut Fake, method: &str, params: Value) -> Value {
        let msg = json!({ "jsonrpc": "2.0", "id": 7, "method": method, "params": params });
        handle(&msg, fake).expect("a request is answered")
    }

    fn summary(id: u64) -> PullSummary {
        PullSummary {
            id,
            kind: "excalidraw".into(),
            title: "flow".into(),
            version: 4,
            updated_at: 0,
            elements: 6,
            placed_in: vec![3],
            canvas_in: vec![],
            ink_over: Some(3),
            width: Some(640),
            height: Some(320),
        }
    }

    #[test]
    fn initialize_echoes_a_known_protocol_version() {
        let mut fake = Fake::default();
        let r = rpc(
            &mut fake,
            "initialize",
            json!({ "protocolVersion": "2025-03-26" }),
        );
        assert_eq!(r["id"], 7);
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(r["result"]["capabilities"], json!({ "tools": {} }));
        assert_eq!(r["result"]["serverInfo"]["name"], "unnamed-drawings");
        let r = rpc(
            &mut fake,
            "initialize",
            json!({ "protocolVersion": "2099-01-01" }),
        );
        assert_eq!(r["result"]["protocolVersion"], "2025-06-18");
    }

    #[test]
    fn notifications_get_no_answer_and_errors_have_codes() {
        let mut fake = Fake::default();
        let note = json!({ "jsonrpc": "2.0", "method": "notifications/initialized" });
        assert_eq!(handle(&note, &mut fake), None);
        let response = json!({ "jsonrpc": "2.0", "id": 1, "result": {} });
        assert_eq!(handle(&response, &mut fake), None);
        assert_eq!(rpc(&mut fake, "ping", Value::Null)["result"], json!({}));
        assert_eq!(
            rpc(&mut fake, "resources/list", Value::Null)["error"]["code"],
            -32601
        );
        let parse = handle_line("{nope", &mut fake).unwrap();
        assert_eq!(parse["error"]["code"], -32700);
        assert_eq!(parse["id"], Value::Null);
        let unknown = rpc(&mut fake, "tools/call", json!({ "name": "rm" }));
        assert_eq!(unknown["error"]["code"], -32602);
        assert!(fake.asked.is_empty());
    }

    #[test]
    fn tools_are_listed_with_the_daemons_formats() {
        let r = rpc(&mut Fake::default(), "tools/list", Value::Null);
        let tools = r["result"]["tools"].as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["list_drawings", "get_drawing"]);
        let format = &tools[1]["inputSchema"]["properties"]["format"];
        assert_eq!(format["enum"], json!(["png", "svg", "ascii"]));
        assert_eq!(format["default"], "png");
    }

    #[test]
    fn list_drawings_reads_and_shows_json() {
        let mut fake = Fake {
            reply: Some(PullReply::List {
                session: 2,
                artifacts: vec![summary(5)],
            }),
            ..Fake::default()
        };
        let r = rpc(
            &mut fake,
            "tools/call",
            json!({ "name": "list_drawings", "arguments": {} }),
        );
        assert_eq!(fake.asked, [PullOp::List]);
        let content = &r["result"]["content"];
        let text = content[0]["text"].as_str().unwrap();
        assert!(text.starts_with("1 drawing in session 2"), "{text}");
        assert!(
            text.contains(r#"#5 excalidraw "flow" v4, 6 elements, 640×320 px"#),
            "{text}"
        );
        let json: Value = serde_json::from_str(content[1]["text"].as_str().unwrap()).unwrap();
        assert_eq!(json["drawings"][0]["id"], 5);
        assert_eq!(r["result"].get("isError"), None);
    }

    #[test]
    fn get_drawing_returns_an_image_or_text() {
        let export = |format: &str, mime: &str, data: &str, base64| {
            Some(PullReply::Export(PullExport {
                id: 5,
                title: "flow".into(),
                version: 4,
                format: format.into(),
                mime: mime.into(),
                data: data.into(),
                base64,
            }))
        };
        let mut fake = Fake {
            reply: export("png", "image/png", "iVBORw0K", true),
            ..Fake::default()
        };
        let r = rpc(
            &mut fake,
            "tools/call",
            json!({ "name": "get_drawing", "arguments": { "id": 5 } }),
        );
        assert_eq!(
            fake.asked,
            [PullOp::Get {
                id: Some(5),
                format: None,
                version: None
            }]
        );
        assert_eq!(
            r["result"]["content"][1],
            json!({ "type": "image", "data": "iVBORw0K", "mimeType": "image/png" })
        );

        fake.reply = export("ascii", "text/plain", "┌──┐", false);
        let r = rpc(
            &mut fake,
            "tools/call",
            json!({ "name": "get_drawing", "arguments": { "format": "ascii", "version": 2 } }),
        );
        assert_eq!(
            fake.asked[1],
            PullOp::Get {
                id: None,
                format: Some("ascii".into()),
                version: Some(2)
            }
        );
        assert_eq!(
            r["result"]["content"][1],
            json!({ "type": "text", "text": "┌──┐" })
        );
    }

    #[test]
    fn failures_are_tool_errors() {
        let mut fake = Fake {
            reply: Some(PullReply::Error("no artifact 9 in this session".into())),
            ..Fake::default()
        };
        let call = |fake: &mut Fake, args: Value| {
            rpc(
                fake,
                "tools/call",
                json!({ "name": "get_drawing", "arguments": args }),
            )["result"]
                .clone()
        };
        let r = call(&mut fake, json!({ "id": 9 }));
        assert_eq!(r["isError"], true);
        assert_eq!(r["content"][0]["text"], "no artifact 9 in this session");
        // Bad arguments never reach the daemon.
        let r = call(&mut fake, json!({ "id": "nine" }));
        assert_eq!(r["isError"], true);
        assert_eq!(fake.asked.len(), 1);
        // Nor does a missing daemon break the protocol.
        fake.reply = None;
        let r = call(&mut fake, json!({}));
        assert_eq!(r["isError"], true);
        assert!(
            r["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("not reachable")
        );
    }

    #[test]
    fn arguments_pick_state_files_and_pane() {
        let b = SocketBackend::from_args(&["--state".into(), "/s t".into(), "--pane=12".into()])
            .unwrap();
        assert_eq!(b.pane, "12");
        assert!(
            matches!(&b.endpoint, Endpoint::File(f) if f == &PathBuf::from("/s t/hook.endpoint"))
        );
        assert!(matches!(&b.token, Token::File(f) if f == &PathBuf::from("/s t/hook.token")));
        assert!(SocketBackend::from_args(&["--bogus".into()]).is_err());
        assert!(SocketBackend::from_args(&["--pane".into()]).is_err());
    }
}
