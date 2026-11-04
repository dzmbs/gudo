//! The browser tools agents use (`gudo-hook mcp`, `gudo-hook browser <verb>`): the page beside the
//! agent's pane in the app the user is looking at. Each call goes to the app through the
//! daemon ([`BrowserAsk::Tool`]); the app answers with JSON (`text`, optional `image`), which
//! becomes the tool's content here.
//!
//! Semantics follow Anthropic's browser toolset: `read_page`-style snapshots with `ref_N`
//! references, targets `{"type":"ref","ref":"ref_3"}` or `{"type":"coordinate","x":…,"y":…}`
//! in viewport pixels of `browser_screenshot`, and actions that answer with what changed.

use std::io::{self, Write};
use std::path::PathBuf;

use daemon::{BrowserAsk, BrowserReply};
use serde_json::{Value, json};

use crate::browser_upload::{REVIEW_TOOL, Upload, UploadScope};
use crate::mcp::Backend;

/// Snapshots longer than this many characters are saved to a file when asked to.
const INLINE_LIMIT: usize = 20_000;

struct Tool {
    name: &'static str,
    description: &'static str,
    properties: fn() -> Value,
    required: &'static [&'static str],
    read_only: bool,
}

fn target() -> Value {
    json!({
        "type": "object",
        "description": "What to act on: {\"type\":\"ref\",\"ref\":\"ref_3\"} from a snapshot (ref_f1_3 is in a frame), or {\"type\":\"coordinate\",\"x\":120,\"y\":340} in pixels of the last browser_screenshot.",
        "properties": {
            "type": { "type": "string", "enum": ["ref", "coordinate"] },
            "ref": { "type": "string" },
            "x": { "type": "integer" },
            "y": { "type": "integer" },
        },
        "required": ["type"],
    })
}

fn none() -> Value {
    json!({})
}

fn force() -> Value {
    json!({ "type": "boolean", "default": false, "description": "Skip the checks that the element is visible, enabled, still and not covered." })
}

const TOOLS: &[Tool] = &[
    Tool {
        name: "browser_navigate",
        description: "Open a URL in the browser pane beside this terminal (opening the pane if needed), or move through history with \"back\", \"forward\" or \"reload\". The host's localhost is reachable as on the host. Waits for the page to load; returns its interactive snapshot.",
        properties: || json!({ "url": { "type": "string", "description": "An http(s) URL (a bare host means https://; localhost means http://), or back, forward, reload." } }),
        required: &["url"],
        read_only: false,
    },
    Tool {
        name: "browser_snapshot",
        description: "Read the page as an accessibility tree, one element per line: role \"name\" = \"value\" (states) [ref_N]; [cursor=pointer] marks other clickable elements, a frame's elements follow its iframe with refs like ref_f1_3. Prefer this over screenshots. filter: interactive (controls in view, the default), visible (everything in view) or all (also off screen). ref limits it to that element's subtree. Unless full is true, a snapshot after the first lists only changes: * new element, + changed, - gone.",
        properties: || {
            json!({
                "filter": { "type": "string", "enum": ["interactive", "visible", "all"], "default": "interactive" },
                "depth": { "type": "integer", "minimum": 1, "default": 15 },
                "ref": { "type": "string", "description": "Only this element's subtree." },
                "full": { "type": "boolean", "default": false, "description": "The whole tree, not what changed." },
                "save_to_file": { "type": "boolean", "default": false, "description": "Write a long snapshot to a file on the host and return its path." },
            })
        },
        required: &[],
        read_only: true,
    },
    Tool {
        name: "browser_find",
        description: "Find elements by a plain description (\"search field\", \"sign in button\"): up to 20 matches in snapshot format.",
        properties: || json!({ "query": { "type": "string" } }),
        required: &["query"],
        read_only: true,
    },
    Tool {
        name: "browser_get_text",
        description: "The page's visible text, main content first.",
        properties: none,
        required: &[],
        read_only: true,
    },
    Tool {
        name: "browser_click",
        description: "Click an element. Waits until it is visible, enabled and not covered (else says what covers it), clicks, waits for what the click started, and says what changed, or that nothing did and why.",
        properties: || json!({ "target": target(), "modifiers": { "type": "string", "description": "A chord such as shift or cmd+shift." }, "force": force() }),
        required: &["target"],
        read_only: false,
    },
    Tool {
        name: "browser_double_click",
        description: "Double-click an element. Says what changed on the page.",
        properties: || json!({ "target": target(), "force": force() }),
        required: &["target"],
        read_only: false,
    },
    Tool {
        name: "browser_hover",
        description: "Move the pointer over an element (menus, tooltips). Says what changed; hover styles made in CSS alone do not show for it.",
        properties: || json!({ "target": target(), "force": force() }),
        required: &["target"],
        read_only: false,
    },
    Tool {
        name: "browser_type",
        description: "Type text key by key into the focused field, or click target first. submit presses Enter after. Password fields are left to the user on the device.",
        properties: || {
            json!({
                "text": { "type": "string" },
                "target": target(),
                "submit": { "type": "boolean", "default": false },
                "force": force(),
            })
        },
        required: &["text"],
        read_only: false,
    },
    Tool {
        name: "browser_fill",
        description: "Set a form field's value at once, replacing what is there: text for inputs and text areas, a date or number as text, true/false for checkboxes and switches, an option's value or text for selects.",
        properties: || json!({ "target": target(), "value": { "type": ["string", "number", "boolean"] } }),
        required: &["target", "value"],
        read_only: false,
    },
    Tool {
        name: "browser_press",
        description: "Press keys at the focus: \"Enter\", a chord such as \"cmd+a\", or a sequence such as \"Tab Tab Enter\". Useful when a site ignores clicks: focus the control, then press Enter or Space.",
        properties: || json!({ "keys": { "type": "string" }, "repeat": { "type": "integer", "minimum": 1, "maximum": 100, "default": 1 } }),
        required: &["keys"],
        read_only: false,
    },
    Tool {
        name: "browser_scroll",
        description: "Scroll the page, or the element under target, by notches.",
        properties: || {
            json!({
                "direction": { "type": "string", "enum": ["up", "down", "left", "right"] },
                "amount": { "type": "integer", "minimum": 1, "maximum": 10, "default": 3 },
                "target": target(),
            })
        },
        required: &["direction"],
        read_only: false,
    },
    Tool {
        name: "browser_scroll_to",
        description: "Scroll an element into view.",
        properties: || json!({ "target": target() }),
        required: &["target"],
        read_only: false,
    },
    Tool {
        name: "browser_drag",
        description: "Drag from target to `to` (sliders, sortable lists, HTML drag and drop). Returns what changed.",
        properties: || json!({ "target": target(), "to": target() }),
        required: &["target", "to"],
        read_only: false,
    },
    Tool {
        name: "browser_wait",
        description: "Wait until text appears, a CSS selector matches, the page loaded (until: load) or the network is idle (until: network_idle), or for seconds; at most 30 s.",
        properties: || {
            json!({
                "text": { "type": "string" },
                "selector": { "type": "string" },
                "until": { "type": "string", "enum": ["load", "network_idle"] },
                "seconds": { "type": "number", "minimum": 0, "maximum": 30 },
            })
        },
        required: &[],
        read_only: true,
    },
    Tool {
        name: "browser_screenshot",
        description: "A picture of the visible page. Its pixels are the coordinates targets use. annotate labels each interactive element with its ref.",
        properties: || json!({ "annotate": { "type": "boolean", "default": false } }),
        required: &[],
        read_only: true,
    },
    Tool {
        name: "browser_zoom",
        description: "A close-up of a region [x0, y0, x1, y1] of the visible page, in screenshot pixels.",
        properties: || json!({ "region": { "type": "array", "items": { "type": "integer" }, "minItems": 4, "maxItems": 4 } }),
        required: &["region"],
        read_only: true,
    },
    Tool {
        name: "browser_tabs",
        description: "The pages beside this terminal, with ids t1, t2, …: list them, open a new one (optionally at url), switch to one or close one by tab_id. Pages a page opens (links to a new window) become tabs here.",
        properties: || {
            json!({
                "action": { "type": "string", "enum": ["list", "new", "switch", "close"] },
                "tab_id": { "type": "string" },
                "url": { "type": "string" },
            })
        },
        required: &["action"],
        read_only: false,
    },
    Tool {
        name: "browser_dialog",
        description: "Answer the dialog the page shows (alert, confirm, prompt, or a leave-page check), which tool results report as \"Dialog: …\": accept or dismiss it, with text for a prompt. The page waits until it is answered.",
        properties: || {
            json!({
                "accept": { "type": "boolean", "description": "true for OK or Leave, false for Cancel or Stay." },
                "text": { "type": "string", "description": "What a prompt answers with." },
            })
        },
        required: &["accept"],
        read_only: false,
    },
    Tool {
        name: "browser_upload",
        description: "Choose files for a file input: target its ref (or the button or label that opens it), or leave target out to answer the file picker an action opened. Files are paths in this project on this host, or given as name, mime_type and base64 data; at most 3 MB in all. The user approves each upload on the device first; keys, credentials and files outside the project are never uploaded. cancel closes an open picker without files.",
        properties: || {
            json!({
                "target": target(),
                "paths": { "type": "array", "items": { "type": "string" }, "description": "Files in this project on this host." },
                "files": {
                    "type": "array",
                    "description": "Files given inline.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": { "type": "string" },
                            "mime_type": { "type": "string" },
                            "data": { "type": "string", "description": "The bytes, base64." },
                        },
                        "required": ["name", "data"],
                    },
                },
                "cancel": { "type": "boolean", "default": false },
            })
        },
        required: &[],
        read_only: false,
    },
    Tool {
        name: "browser_console",
        description: "Console messages and uncaught errors since the last read.",
        properties: none,
        required: &[],
        read_only: true,
    },
    Tool {
        name: "browser_network",
        description: "Requests the page made since the last read: method, URL, status, type, duration.",
        properties: none,
        required: &[],
        read_only: true,
    },
];

/// The tools' MCP definitions.
pub fn tools() -> Vec<Value> {
    TOOLS
        .iter()
        .map(|tool| {
            json!({
                "name": tool.name,
                "description": tool.description,
                "inputSchema": { "type": "object", "properties": (tool.properties)(), "required": tool.required },
                "annotations": { "readOnlyHint": tool.read_only, "openWorldHint": true },
            })
        })
        .collect()
}

pub fn is_tool(name: &str) -> bool {
    TOOLS.iter().any(|tool| tool.name == name)
}

/// How a step that needs the user's approval is answered.
pub enum Approval {
    /// Approved: the step runs.
    Allow,
    /// Declined: the tool says so.
    Deny,
    /// Asked later: this result goes back as it is (an MCP `input_required` result).
    Pending(Value),
}

/// Asks the agent's client to approve a step: its message and the call's arguments.
pub type Approver<'a> = dyn FnMut(&str, &Value) -> Approval + 'a;

/// Runs browser tool `name` through the app; the MCP result. Steps that need approval are
/// approved on the device.
pub fn call(name: &str, args: &Value, backend: &mut dyn Backend) -> Value {
    call_with(name, &own(args), backend, None)
}

/// The caller's arguments without the ones only this module sets (an approval).
pub fn own(args: &Value) -> Value {
    let mut args = args.clone();
    if let Some(map) = args.as_object_mut() {
        map.remove("approved");
        map.remove("approval_by");
    }
    args
}

/// As [`call`]; with `approve`, steps that need approval are put to the agent's client
/// (elicitation) instead of the device: the app answers at once with what to ask, and the
/// step runs again approved when allowed. Uploads are always approved on the device.
pub fn call_with(
    name: &str,
    args: &Value,
    backend: &mut dyn Backend,
    mut approve: Option<&mut Approver<'_>>,
) -> Value {
    let mut args = if args.is_object() {
        args.clone()
    } else {
        json!({})
    };
    if let Some(missing) = TOOLS
        .iter()
        .find(|tool| tool.name == name)
        .and_then(|tool| tool.required.iter().find(|key| args.get(**key).is_none()))
    {
        return error(&format!("`{missing}` is required"));
    }
    if name == "browser_upload" {
        return upload(&own(&args), backend, &UploadScope::current());
    }
    if approve.is_some() {
        args["approval_by"] = json!("client");
    }
    let json = match ask(name, &args, backend) {
        Ok(json) => json,
        Err(error) => return error,
    };
    let asked = serde_json::from_str::<Value>(&json)
        .ok()
        .and_then(|answer| answer["approval"]["message"].as_str().map(str::to_owned));
    if let (Some(message), Some(approve)) = (asked, approve.as_mut()) {
        return match approve(&message, &args) {
            Approval::Allow => {
                args["approved"] = json!(true);
                call_with(name, &args, backend, None)
            }
            Approval::Deny => error(&format!("The user declined: {message}")),
            Approval::Pending(result) => result,
        };
    }
    result(&json, args.get("save_to_file") == Some(&Value::Bool(true)))
}

/// Runs tool `name` in the app: its JSON answer, or the tool's error result.
fn ask(name: &str, args: &Value, backend: &mut dyn Backend) -> Result<String, Value> {
    match backend.browser(BrowserAsk::Tool {
        name: name.to_owned(),
        args: args.clone(),
    }) {
        Ok(BrowserReply::Result(json)) => Ok(json),
        Ok(BrowserReply::Error(why)) => Err(error(&why)),
        Ok(BrowserReply::NoApp) => Err(error(&format!(
            "No {} app shows this terminal right now, so there is no browser to use. Ask the user to open this terminal in the app.",
            brand::PRODUCT_NAME
        ))),
        Ok(BrowserReply::Opened) => Err(error("unexpected answer")),
        Err(io_error) => Err(error(&format!(
            "the {} daemon is not reachable: {io_error}",
            brand::PRODUCT_NAME
        ))),
    }
}

/// `browser_upload`: the owner approves the files and the origin on the device before any file
/// on this host is read; then they go to that origin only.
fn upload(args: &Value, backend: &mut dyn Backend, scope: &UploadScope) -> Value {
    if args.get("cancel") == Some(&Value::Bool(true)) {
        return match ask("browser_upload", &json!({ "cancel": true }), backend) {
            Ok(json) => result(&json, false),
            Err(error) => error,
        };
    }
    let plan = match Upload::plan(args, scope) {
        Ok(plan) if plan.is_empty() => {
            return error("Name the files: paths, or files given inline.");
        }
        Ok(plan) => plan,
        Err(why) => return error(&why),
    };
    let review = match ask(REVIEW_TOOL, &plan.review(args.get("target")), backend) {
        Ok(json) => json,
        Err(failure) if failure.to_string().contains(REVIEW_TOOL) => {
            return error(&format!(
                "Update the {} app to upload files: this version cannot ask the user to approve them.",
                brand::PRODUCT_NAME
            ));
        }
        Err(failure) => return failure,
    };
    let Some(origin) = serde_json::from_str::<Value>(&review)
        .ok()
        .and_then(|answer| answer["approved"]["origin"].as_str().map(str::to_owned))
    else {
        return error("The user did not approve the upload.");
    };
    let files = match plan.read() {
        Ok(files) => files,
        Err(why) => return error(&why),
    };
    let mut approved = json!({ "files": files, "approved": true, "approved_origin": origin });
    if let Some(target) = args.get("target") {
        approved["target"] = target.clone();
    }
    match ask("browser_upload", &approved, backend) {
        Ok(json) => result(&json, false),
        Err(error) => error,
    }
}

/// A MIME type from a file name's extension.
pub(crate) fn mime_for(name: &str) -> &'static str {
    let ext = name
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase());
    match ext.as_deref() {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("heic") => "image/heic",
        Some("svg") => "image/svg+xml",
        Some("pdf") => "application/pdf",
        Some("json") => "application/json",
        Some("zip") => "application/zip",
        Some("csv") => "text/csv",
        Some("html" | "htm") => "text/html",
        Some("txt" | "md" | "log") => "text/plain",
        Some("mp4") => "video/mp4",
        Some("mov") => "video/quicktime",
        Some("mp3") => "audio/mpeg",
        _ => "application/octet-stream",
    }
}

fn error(message: &str) -> Value {
    json!({ "content": [{ "type": "text", "text": message }], "isError": true })
}

/// The app's answer (`{"text": …, "image": {"data", "mimeType"}}`) as MCP content.
fn result(json: &str, save: bool) -> Value {
    let Ok(answer) = serde_json::from_str::<Value>(json) else {
        return error("the app answered garbage");
    };
    let mut content = Vec::new();
    if let Some(text) = answer.get("text").and_then(Value::as_str) {
        let text = match save.then(|| save_text(text)) {
            Some(Ok(path)) if text.len() > INLINE_LIMIT => format!(
                "Snapshot saved to {} ({} lines, {} characters).\n{}",
                path.display(),
                text.lines().count(),
                text.len(),
                text.lines().take(40).collect::<Vec<_>>().join("\n")
            ),
            _ => text.to_owned(),
        };
        content.push(json!({ "type": "text", "text": text }));
    }
    if let Some(image) = answer.get("image") {
        content
            .push(json!({ "type": "image", "data": image["data"], "mimeType": image["mimeType"] }));
    }
    json!({ "content": content })
}

/// Page content is private: a new 0600 file with an unguessable name, never one planted in a
/// shared temporary directory.
fn save_private(prefix: &str, ext: &str, data: &[u8]) -> io::Result<PathBuf> {
    let (path, mut file) =
        daemon::create_private_temp_file(&format!("{}-{prefix}", brand::CLI_BIN), ext)?;
    file.write_all(data)?;
    Ok(path)
}

fn save_text(text: &str) -> io::Result<PathBuf> {
    save_private("snapshot", "txt", text.as_bytes())
}

/// `gudo-hook browser <verb> [json | key=value …]`: the same tools from a shell (Codex, scripts).
/// `<verb>` is the tool's name without `browser_`. Prints the text and saves an image to a file.
pub fn cli(args: &[String], backend: &mut dyn Backend) -> i32 {
    let Some(verb) = args.first() else {
        eprintln!("{}", usage());
        return 2;
    };
    let name = format!("browser_{}", verb.replace('-', "_"));
    if !is_tool(&name) {
        eprintln!("unknown verb {verb:?}\n{}", usage());
        return 2;
    }
    let input = match parse_cli_args(&args[1..]) {
        Ok(input) => input,
        Err(message) => {
            eprintln!("{message}");
            return 2;
        }
    };
    let out = call(&name, &input, backend);
    let mut status = 0;
    if out.get("isError") == Some(&Value::Bool(true)) {
        status = 1;
    }
    for item in out["content"].as_array().into_iter().flatten() {
        match item["type"].as_str() {
            Some("text") => println!("{}", item["text"].as_str().unwrap_or_default()),
            Some("image") => match save_image(item) {
                Ok(path) => println!("Image saved to {}", path.display()),
                Err(io_error) => eprintln!("saving the image: {io_error}"),
            },
            _ => {}
        }
    }
    status
}

/// A JSON object, or `key=value` pairs (`ref=ref_3` and `x=… y=…` make a target; each
/// `path=…` is a file to upload; values that parse as JSON are taken as such).
fn parse_cli_args(args: &[String]) -> Result<Value, String> {
    if let [one] = args
        && one.trim_start().starts_with('{')
    {
        return serde_json::from_str(one).map_err(|parse_error| format!("bad JSON: {parse_error}"));
    }
    let mut map = serde_json::Map::new();
    for arg in args {
        let (key, value) = arg
            .split_once('=')
            .ok_or_else(|| format!("expected key=value, got {arg:?}"))?;
        if key == "path" {
            let paths = map.entry("paths").or_insert_with(|| json!([]));
            if let Some(paths) = paths.as_array_mut() {
                paths.push(json!(value));
            }
            continue;
        }
        let value = serde_json::from_str(value).unwrap_or_else(|_| Value::String(value.into()));
        map.insert(key.to_owned(), value);
    }
    if let Some(reference) = map.remove("ref") {
        map.insert("target".into(), json!({ "type": "ref", "ref": reference }));
    } else if let (Some(x), Some(y)) = (map.get("x").cloned(), map.get("y").cloned())
        && !map.contains_key("region")
    {
        map.remove("x");
        map.remove("y");
        map.insert(
            "target".into(),
            json!({ "type": "coordinate", "x": x, "y": y }),
        );
    }
    Ok(Value::Object(map))
}

fn save_image(item: &Value) -> io::Result<PathBuf> {
    use base64::Engine;
    let data = base64::engine::general_purpose::STANDARD
        .decode(item["data"].as_str().unwrap_or_default())
        .map_err(io::Error::other)?;
    let ext = if item["mimeType"] == "image/png" {
        "png"
    } else {
        "jpg"
    };
    save_private("screenshot", ext, &data)
}

fn usage() -> String {
    let verbs: Vec<&str> = TOOLS
        .iter()
        .map(|tool| &tool.name["browser_".len()..])
        .collect();
    format!(
        "usage: {} browser <verb> [json | key=value …]\nverbs: {}",
        brand::HOOK_BIN,
        verbs.join(", ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_has_a_schema_and_read_only_ones_say_so() {
        let tools = tools();
        assert!(tools.len() >= 15);
        for tool in &tools {
            assert!(tool["name"].as_str().unwrap().starts_with("browser_"));
            assert_eq!(tool["inputSchema"]["type"], "object");
        }
        let read_only = |name: &str| {
            tools.iter().find(|tool| tool["name"] == name).unwrap()["annotations"]["readOnlyHint"]
                .as_bool()
                .unwrap()
        };
        assert!(read_only("browser_snapshot") && read_only("browser_screenshot"));
        assert!(!read_only("browser_click") && !read_only("browser_navigate"));
    }

    #[test]
    fn cli_arguments_make_targets() {
        let parsed = parse_cli_args(&["ref=ref_3".into()]).unwrap();
        assert_eq!(
            parsed,
            json!({ "target": { "type": "ref", "ref": "ref_3" } })
        );
        let parsed = parse_cli_args(&["x=10".into(), "y=20".into()]).unwrap();
        assert_eq!(
            parsed,
            json!({ "target": { "type": "coordinate", "x": 10, "y": 20 } })
        );
        let parsed = parse_cli_args(&["url=https://x.dev".into(), "full=true".into()]).unwrap();
        assert_eq!(parsed, json!({ "url": "https://x.dev", "full": true }));
        let parsed = parse_cli_args(&[r#"{"keys":"Enter"}"#.into()]).unwrap();
        assert_eq!(parsed, json!({ "keys": "Enter" }));
        assert!(parse_cli_args(&["nope".into()]).is_err());
        let parsed =
            parse_cli_args(&["ref=ref_4".into(), "path=a.png".into(), "path=7".into()]).unwrap();
        assert_eq!(
            parsed,
            json!({ "target": { "type": "ref", "ref": "ref_4" }, "paths": ["a.png", "7"] })
        );
    }

    #[test]
    fn saved_pages_are_private_and_unguessable() {
        use std::os::unix::fs::PermissionsExt;
        let first = save_text("secret page").unwrap();
        let second = save_text("secret page").unwrap();
        assert_ne!(
            first, second,
            "two saves in the same millisecond must not share a name"
        );
        let mode = std::fs::metadata(&first).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert_eq!(std::fs::read_to_string(&first).unwrap(), "secret page");
        let _ = std::fs::remove_file(first);
        let _ = std::fs::remove_file(second);
    }

    /// Answers browser calls from a script (then "Done.") and records what was asked.
    #[derive(Default)]
    struct Recorder {
        asked: Vec<(String, Value)>,
        replies: Vec<BrowserReply>,
    }

    impl Backend for Recorder {
        fn pull(&mut self, _: daemon::PullOp) -> io::Result<daemon::PullReply> {
            Err(io::ErrorKind::NotFound.into())
        }
        fn browser(&mut self, ask: BrowserAsk) -> io::Result<BrowserReply> {
            if let BrowserAsk::Tool { name, args } = ask {
                self.asked.push((name, args));
            }
            if self.replies.is_empty() {
                return Ok(BrowserReply::Result(json!({ "text": "Done." }).to_string()));
            }
            Ok(self.replies.remove(0))
        }
        fn term(&mut self, _: daemon::TermAsk) -> io::Result<daemon::TermReply> {
            Err(io::ErrorKind::NotFound.into())
        }
    }

    fn approved(origin: &str) -> BrowserReply {
        BrowserReply::Result(json!({ "text": "", "approved": { "origin": origin } }).to_string())
    }

    #[test]
    fn dialog_calls_reach_the_app() {
        let mut fake = Recorder::default();
        let result = call(
            "browser_dialog",
            &json!({ "accept": true, "text": "Ada" }),
            &mut fake,
        );
        assert_eq!(result["content"][0]["text"], "Done.");
        assert_eq!(
            fake.asked[0],
            (
                "browser_dialog".into(),
                json!({ "accept": true, "text": "Ada" })
            )
        );
        // Required arguments are checked here.
        let result = call("browser_dialog", &json!({}), &mut fake);
        assert_eq!(result["isError"], true);

        let tools = tools();
        for name in ["browser_dialog", "browser_upload"] {
            let tool = tools.iter().find(|tool| tool["name"] == name).unwrap();
            assert_eq!(tool["annotations"]["readOnlyHint"], false);
        }
    }

    #[test]
    fn host_files_never_reach_the_app_without_an_owner_approval() {
        let dir = tempfile::tempdir().unwrap();
        let key = dir.path().join("id_ed25519");
        std::fs::write(&key, "PRIVATE KEY").unwrap();
        let mut fake = Recorder::default();
        call(
            "browser_upload",
            &json!({ "paths": [key.to_str().unwrap()] }),
            &mut fake,
        );
        let leaked = fake
            .asked
            .iter()
            .any(|(_, args)| args.to_string().contains("UFJJVkFURSBLRVk="));
        assert!(!leaked, "{:?}", fake.asked);
    }

    fn project() -> (tempfile::TempDir, UploadScope) {
        let home = tempfile::tempdir().unwrap();
        let tree = home.path().join("app");
        std::fs::create_dir_all(tree.join(".git")).unwrap();
        std::fs::write(tree.join("notes.txt"), "hi").unwrap();
        let scope = UploadScope::new(home.path(), &tree, &[]);
        (home, scope)
    }

    #[test]
    fn uploads_are_approved_with_their_origin_before_any_file_is_read() {
        let (_home, scope) = project();
        let mut fake = Recorder {
            replies: vec![approved("https://forms.example")],
            ..Recorder::default()
        };
        let target = json!({ "type": "ref", "ref": "ref_4" });
        let result = upload(
            &json!({ "paths": ["notes.txt"], "files": [{ "name": "a.txt", "data": "aGk=" }], "target": target }),
            &mut fake,
            &scope,
        );
        assert_eq!(result["content"][0]["text"], "Done.");
        let (review, asked) = &fake.asked[0];
        assert_eq!(review, REVIEW_TOOL);
        assert_eq!(
            asked,
            &json!({
                "files": [
                    { "name": "a.txt", "size": 2 },
                    { "name": "notes.txt", "path": "~/app/notes.txt", "size": 2 },
                ],
                "target": target,
            })
        );
        let (name, sent) = &fake.asked[1];
        assert_eq!(name, "browser_upload");
        assert_eq!(sent["approved"], true);
        assert_eq!(sent["approved_origin"], "https://forms.example");
        assert_eq!(sent["target"], target);
        assert_eq!(sent["files"][0]["mime_type"], "text/plain");
        assert_eq!(sent["files"][1]["data"], "aGk=");
        assert!(sent.get("paths").is_none());
    }

    #[test]
    fn a_declined_or_unanswered_review_sends_nothing() {
        let (_home, scope) = project();
        for reply in [
            BrowserReply::Error("The user declined the upload.".into()),
            BrowserReply::Result(json!({ "text": "Done." }).to_string()),
            BrowserReply::Error("Unknown tool browser_upload_review.".into()),
            BrowserReply::NoApp,
        ] {
            let mut fake = Recorder {
                replies: vec![reply],
                ..Recorder::default()
            };
            let result = upload(&json!({ "paths": ["notes.txt"] }), &mut fake, &scope);
            assert_eq!(result["isError"], true);
            assert_eq!(fake.asked.len(), 1, "{:?}", fake.asked);
        }
        let mut fake = Recorder {
            replies: vec![BrowserReply::Error(
                "Unknown tool browser_upload_review.".into(),
            )],
            ..Recorder::default()
        };
        let result = upload(&json!({ "paths": ["notes.txt"] }), &mut fake, &scope);
        assert!(
            result["content"][0]["text"]
                .as_str()
                .unwrap()
                .starts_with("Update the")
        );
    }

    #[test]
    fn approvals_cannot_be_passed_in_and_cancel_needs_none() {
        let (_home, scope) = project();
        let mut fake = Recorder::default();
        let args = own(
            &json!({ "paths": ["notes.txt"], "approved": true, "approved_origin": "https://x" }),
        );
        upload(&args, &mut fake, &scope);
        assert_eq!(fake.asked.len(), 1);
        assert_eq!(fake.asked[0].0, REVIEW_TOOL);

        let mut fake = Recorder::default();
        let result = upload(
            &json!({ "cancel": true, "paths": ["notes.txt"] }),
            &mut fake,
            &scope,
        );
        assert_eq!(result["content"][0]["text"], "Done.");
        assert_eq!(
            fake.asked,
            vec![("browser_upload".into(), json!({ "cancel": true }))]
        );

        let mut fake = Recorder::default();
        let result = upload(&json!({ "paths": ["/nonexistent/f"] }), &mut fake, &scope);
        assert_eq!(result["isError"], true);
        assert!(fake.asked.is_empty());
    }

    #[test]
    fn answers_become_text_and_images() {
        let content = result(
            r#"{"text":"button \"Go\" [ref_1]","image":{"data":"AAA","mimeType":"image/jpeg"}}"#,
            false,
        );
        assert_eq!(content["content"][0]["text"], "button \"Go\" [ref_1]");
        assert_eq!(
            content["content"][1],
            json!({ "type": "image", "data": "AAA", "mimeType": "image/jpeg" })
        );
        let long = "x\n".repeat(INLINE_LIMIT);
        let content = result(&json!({ "text": long }).to_string(), true);
        let text = content["content"][0]["text"].as_str().unwrap();
        assert!(text.starts_with("Snapshot saved to "), "{}", &text[..60]);
        let path = text["Snapshot saved to ".len()..]
            .split(' ')
            .next()
            .unwrap();
        assert_eq!(std::fs::read_to_string(path).unwrap(), long);
        let _ = std::fs::remove_file(path);
    }
}
