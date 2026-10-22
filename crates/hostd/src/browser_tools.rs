//! The browser tools agents use (`un-hook mcp`, `un-hook browser <verb>`): the page beside the
//! agent's pane in the app the user is looking at. Each call goes to the app through the
//! daemon ([`BrowserAsk::Tool`]); the app answers with JSON (`text`, optional `image`), which
//! becomes the tool's content here.
//!
//! Semantics follow Anthropic's browser toolset: `read_page`-style snapshots with `ref_N`
//! references, targets `{"type":"ref","ref":"ref_3"}` or `{"type":"coordinate","x":…,"y":…}`
//! in viewport pixels of `browser_screenshot`, and actions that answer with what changed.

use std::io;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use daemon::{BrowserAsk, BrowserReply};
use serde_json::{Value, json};

use crate::mcp::Backend;

/// Snapshots longer than this many characters are saved to a file when asked to.
const INLINE_LIMIT: usize = 20_000;

/// One tool: name, description, input properties, required inputs, read-only.
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
        "description": "What to act on: {\"type\":\"ref\",\"ref\":\"ref_3\"} from a snapshot, or {\"type\":\"coordinate\",\"x\":120,\"y\":340} in viewport pixels of browser_screenshot.",
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

const TOOLS: &[Tool] = &[
    Tool {
        name: "browser_navigate",
        description: "Open a URL in the browser pane beside this terminal (opening the pane if needed), or move through history with \"back\", \"forward\" or \"reload\". The host's localhost is reachable as on the host. Returns the new page's interactive snapshot.",
        properties: || json!({ "url": { "type": "string", "description": "An http(s) URL (a bare host means https://; localhost means http://), or back, forward, reload." } }),
        required: &["url"],
        read_only: false,
    },
    Tool {
        name: "browser_snapshot",
        description: "Read the page as an accessibility tree, one element per line: role \"name\" [ref_N]. Prefer this over screenshots. filter: interactive (controls only, the default), visible (everything on screen) or all (also off screen). ref limits it to that element's subtree. Unless full is true, a snapshot after the first says only what changed.",
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
        description: "Click an element. Returns what changed on the page.",
        properties: || json!({ "target": target(), "modifiers": { "type": "string", "description": "A chord such as shift or cmd+shift." } }),
        required: &["target"],
        read_only: false,
    },
    Tool {
        name: "browser_double_click",
        description: "Double-click an element. Returns what changed on the page.",
        properties: || json!({ "target": target() }),
        required: &["target"],
        read_only: false,
    },
    Tool {
        name: "browser_hover",
        description: "Move the pointer over an element (menus, tooltips). Returns what changed.",
        properties: || json!({ "target": target() }),
        required: &["target"],
        read_only: false,
    },
    Tool {
        name: "browser_type",
        description: "Type text into the focused field, or into target first. submit presses Enter after. Password fields are left to the user on the device.",
        properties: || {
            json!({
                "text": { "type": "string" },
                "target": target(),
                "submit": { "type": "boolean", "default": false },
            })
        },
        required: &["text"],
        read_only: false,
    },
    Tool {
        name: "browser_fill",
        description: "Set a form field's value at once: text for inputs, true/false for checkboxes, an option's value or text for selects.",
        properties: || json!({ "target": target(), "value": { "type": ["string", "number", "boolean"] } }),
        required: &["target", "value"],
        read_only: false,
    },
    Tool {
        name: "browser_press",
        description: "Press keys at the focus: \"Enter\", a chord such as \"cmd+a\", or a sequence such as \"Backspace Backspace\".",
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
        description: "The pages beside this terminal: list them, open a new one (optionally at url), switch to one or close one by tab_id.",
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
        .map(|t| {
            json!({
                "name": t.name,
                "description": t.description,
                "inputSchema": { "type": "object", "properties": (t.properties)(), "required": t.required },
                "annotations": { "readOnlyHint": t.read_only, "openWorldHint": true },
            })
        })
        .collect()
}

/// Whether `name` is a browser tool.
pub fn is_tool(name: &str) -> bool {
    TOOLS.iter().any(|t| t.name == name)
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
/// step runs again approved when allowed.
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
        .find(|t| t.name == name)
        .and_then(|t| t.required.iter().find(|k| args.get(**k).is_none()))
    {
        return error(&format!("`{missing}` is required"));
    }
    if approve.is_some() {
        args["approval_by"] = json!("client");
    }
    let reply = backend.browser(BrowserAsk::Tool {
        name: name.to_owned(),
        args: args.clone(),
    });
    match reply {
        Ok(BrowserReply::Result(json)) => {
            let asked = serde_json::from_str::<Value>(&json)
                .ok()
                .and_then(|v| v["approval"]["message"].as_str().map(str::to_owned));
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
        Ok(BrowserReply::Error(why)) => error(&why),
        Ok(BrowserReply::NoApp) => error(&format!(
            "No {} app shows this terminal right now, so there is no browser to use. Ask the user to open this terminal in the app.",
            brand::PRODUCT_NAME
        )),
        Ok(BrowserReply::Opened) => error("unexpected answer"),
        Err(e) => error(&format!(
            "the {} daemon is not reachable: {e}",
            brand::PRODUCT_NAME
        )),
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

fn save_text(text: &str) -> io::Result<PathBuf> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    let path = std::env::temp_dir().join(format!("{}-snapshot-{stamp}.txt", brand::CLI_BIN));
    std::fs::write(&path, text)?;
    Ok(path)
}

/// `un-hook browser <verb> [json | key=value …]`: the same tools from a shell (Codex, scripts).
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
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
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
                Err(e) => eprintln!("saving the image: {e}"),
            },
            _ => {}
        }
    }
    status
}

/// A JSON object, or `key=value` pairs (`ref=ref_3` and `x=… y=…` make a target; values that
/// parse as JSON are taken as such).
fn parse_cli_args(args: &[String]) -> Result<Value, String> {
    if let [one] = args
        && one.trim_start().starts_with('{')
    {
        return serde_json::from_str(one).map_err(|e| format!("bad JSON: {e}"));
    }
    let mut map = serde_json::Map::new();
    for arg in args {
        let (key, value) = arg
            .split_once('=')
            .ok_or_else(|| format!("expected key=value, got {arg:?}"))?;
        let value = serde_json::from_str(value).unwrap_or_else(|_| Value::String(value.into()));
        map.insert(key.to_owned(), value);
    }
    if let Some(r) = map.remove("ref") {
        map.insert("target".into(), json!({ "type": "ref", "ref": r }));
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
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    let path = std::env::temp_dir().join(format!("{}-screenshot-{stamp}.{ext}", brand::CLI_BIN));
    std::fs::write(&path, data)?;
    Ok(path)
}

fn usage() -> String {
    let verbs: Vec<&str> = TOOLS.iter().map(|t| &t.name["browser_".len()..]).collect();
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
        for t in &tools {
            assert!(t["name"].as_str().unwrap().starts_with("browser_"));
            assert_eq!(t["inputSchema"]["type"], "object");
        }
        let read_only = |n: &str| {
            tools.iter().find(|t| t["name"] == n).unwrap()["annotations"]["readOnlyHint"]
                .as_bool()
                .unwrap()
        };
        assert!(read_only("browser_snapshot") && read_only("browser_screenshot"));
        assert!(!read_only("browser_click") && !read_only("browser_navigate"));
    }

    #[test]
    fn cli_arguments_make_targets() {
        let v = parse_cli_args(&["ref=ref_3".into()]).unwrap();
        assert_eq!(v, json!({ "target": { "type": "ref", "ref": "ref_3" } }));
        let v = parse_cli_args(&["x=10".into(), "y=20".into()]).unwrap();
        assert_eq!(
            v,
            json!({ "target": { "type": "coordinate", "x": 10, "y": 20 } })
        );
        let v = parse_cli_args(&["url=https://x.dev".into(), "full=true".into()]).unwrap();
        assert_eq!(v, json!({ "url": "https://x.dev", "full": true }));
        let v = parse_cli_args(&[r#"{"keys":"Enter"}"#.into()]).unwrap();
        assert_eq!(v, json!({ "keys": "Enter" }));
        assert!(parse_cli_args(&["nope".into()]).is_err());
    }

    #[test]
    fn answers_become_text_and_images() {
        let r = result(
            r#"{"text":"button \"Go\" [ref_1]","image":{"data":"AAA","mimeType":"image/jpeg"}}"#,
            false,
        );
        assert_eq!(r["content"][0]["text"], "button \"Go\" [ref_1]");
        assert_eq!(
            r["content"][1],
            json!({ "type": "image", "data": "AAA", "mimeType": "image/jpeg" })
        );
        let long = "x\n".repeat(INLINE_LIMIT);
        let r = result(&json!({ "text": long }).to_string(), true);
        let text = r["content"][0]["text"].as_str().unwrap();
        assert!(text.starts_with("Snapshot saved to "), "{}", &text[..60]);
        let path = text["Snapshot saved to ".len()..]
            .split(' ')
            .next()
            .unwrap();
        assert_eq!(std::fs::read_to_string(path).unwrap(), long);
        let _ = std::fs::remove_file(path);
    }
}
