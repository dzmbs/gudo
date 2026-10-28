//! The terminal tools of `un-hook mcp`: one [`TermAsk`] on the hook socket per call, answered
//! by the daemon (`daemon::term`). Every tool declares an output schema and returns its result
//! as `structuredContent`, so code-mode harnesses get typed values; the text content leads
//! with a one-line summary and then the output itself, for the model.

use daemon::{TermAsk, TermReply};
use serde_json::{Value, json};

use crate::mcp::Backend;

struct Tool {
    name: &'static str,
    title: &'static str,
    description: &'static str,
    input: Value,
    output: Value,
    read_only: bool,
    destructive: bool,
    idempotent: bool,
}

fn pane_ref(description: &str) -> Value {
    json!({ "type": "string", "description": description })
}

fn output_schema() -> Value {
    json!({
        "type": "object",
        "description": "Rendered text as a person sees it (colors removed, progress lines settled), the middle left out when long.",
        "properties": {
            "text": { "type": "string" },
            "lines": { "type": "integer" },
            "truncated": { "type": "boolean" },
            "omittedLines": { "type": "integer" },
            "cursor": { "type": "string", "description": "Pass as `since` to read only what comes after." },
        },
        "required": ["text", "lines", "truncated", "cursor"],
    })
}

fn command_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "integer" },
            "pane": { "type": "string" },
            "command": { "type": "string" },
            "cwd": { "type": "string" },
            "status": { "type": "string", "enum": ["running", "exited"] },
            "exitCode": { "type": "integer" },
            "durationMs": { "type": "integer" },
        },
        "required": ["id", "pane", "status"],
    })
}

fn pane_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "id": { "type": "string", "description": "p12; pass to other tools." },
            "tab": { "type": ["string", "null"] },
            "title": { "type": "string" },
            "cwd": { "type": ["string", "null"] },
            "kind": { "type": "string", "enum": ["shell", "agent", "command"] },
            "isSelf": { "type": "boolean" },
            "createdByYou": { "type": "boolean" },
            "scopes": { "type": "array", "items": { "type": "string", "enum": ["read", "input", "manage"] } },
            "atPrompt": { "type": "boolean", "description": "The shell waits at its prompt." },
            "altScreen": { "type": "boolean", "description": "A full-screen program owns the screen." },
            "secretPrompt": { "type": "boolean", "description": "A password is being asked for; input is refused." },
            "exited": { "type": "boolean" },
            "foreground": { "type": ["object", "null"], "properties": { "pid": { "type": "integer" }, "name": { "type": "string" } } },
            "lastCommand": { "anyOf": [command_schema(), { "type": "null" }] },
            "cursor": { "type": "string" },
            "status": status_schema(),
        },
        "required": ["id", "kind", "isSelf", "createdByYou", "scopes", "atPrompt", "altScreen", "cursor"],
    })
}

fn status_schema() -> Value {
    json!({
        "type": ["object", "null"],
        "description": "What the program says it is doing (OSC 7501, or an agent integration).",
        "properties": {
            "state": { "type": "string", "enum": ["idle", "working", "done", "blocked", "error"] },
            "kind": { "type": ["string", "null"], "enum": ["permission", "question", "auth", null] },
            "app": { "type": ["string", "null"] },
            "message": { "type": ["string", "null"] },
            "progress": { "type": ["integer", "null"] },
        },
    })
}

fn tools_list() -> Vec<Tool> {
    let object = |properties: Value, required: &[&str]| json!({ "type": "object", "properties": properties, "required": required, "additionalProperties": false });
    let timeout = json!({ "type": "integer", "description": "Give up after this long (default 30000, at most 240000); the result says timeout and the work goes on." });
    let max_bytes =
        json!({ "type": "integer", "description": "Cap on the output text (default 16384)." });
    vec![
        Tool {
            name: "whoami",
            title: "Which terminal pane am I in",
            description: "Get the terminal pane this agent runs in: its id, folder, session and host, and the limits of the terminal tools. Other tools target this pane when no pane is given.",
            input: object(json!({}), &[]),
            output: json!({
                "type": "object",
                "properties": {
                    "pane": pane_schema(),
                    "session": { "type": ["object", "null"] },
                    "host": { "type": "string" },
                    "limits": { "type": "object" },
                    "protocol": { "type": "integer" },
                },
                "required": ["pane", "host", "limits", "protocol"],
            }),
            read_only: true,
            destructive: false,
            idempotent: true,
        },
        Tool {
            name: "pane_list",
            title: "List terminal panes",
            description: "List the terminal panes in this session (or only this tab): id, folder, whether a shell waits at its prompt, the running program, the last command and its exit code, and what you may do there. You may type into and close only panes you created.",
            input: object(
                json!({
                    "scope": { "type": "string", "enum": ["session", "tab"], "default": "session" },
                }),
                &[],
            ),
            output: json!({ "type": "object", "properties": { "panes": { "type": "array", "items": pane_schema() } }, "required": ["panes"] }),
            read_only: true,
            destructive: false,
            idempotent: true,
        },
        Tool {
            name: "cmd_run",
            title: "Run a shell command",
            description: "Run a shell command in a terminal pane the user can watch, wait for it, and get its exit code and its own output. Without a pane, opens a new pane below this one (and keeps it for later commands: pass its id as `pane`). Long-running commands: give timeoutMs and continue with pane_wait or pane_read.",
            input: object(
                json!({
                    "command": { "type": "string" },
                    "pane": pane_ref("A pane you created; default: a new one."),
                    "cwd": { "type": "string", "description": "Folder to run in." },
                    "timeoutMs": timeout,
                    "maxBytes": max_bytes,
                }),
                &["command"],
            ),
            output: json!({
                "type": "object",
                "properties": {
                    "pane": { "type": "string" },
                    "status": { "type": "string", "enum": ["exited", "timeout", "unknown"], "description": "unknown: the shell does not report commands, so there is no exit code." },
                    "command": command_schema(),
                    "output": output_schema(),
                    "note": { "type": "string" },
                },
                "required": ["pane", "status"],
            }),
            read_only: false,
            destructive: false,
            idempotent: false,
        },
        Tool {
            name: "pane_read",
            title: "Read a terminal pane's output",
            description: "Read a terminal pane's output: the last lines (default 80), only what came after a cursor (`since`, from an earlier result), one command's output and exit code (`command`: an id or \"last\"), or the screen of a full-screen program. Filter with a regex (`grep`).",
            input: object(
                json!({
                    "pane": pane_ref("Default: this pane."),
                    "since": { "type": "string", "description": "A cursor from an earlier result." },
                    "command": { "description": "A command id, or \"last\".", "anyOf": [{ "type": "integer" }, { "type": "string" }] },
                    "screen": { "type": "boolean", "description": "The visible screen only." },
                    "tail": { "type": "integer", "description": "Last lines (default 80)." },
                    "grep": { "type": "string", "description": "Keep matching lines (regex)." },
                    "context": { "type": "integer", "description": "Lines kept around each match." },
                    "maxBytes": max_bytes,
                }),
                &[],
            ),
            output: json!({
                "type": "object",
                "properties": {
                    "output": output_schema(),
                    "altScreen": { "type": "boolean" },
                    "atPrompt": { "type": "boolean" },
                    "command": { "anyOf": [command_schema(), { "type": "null" }] },
                },
                "required": ["output", "altScreen", "atPrompt"],
            }),
            read_only: true,
            destructive: false,
            idempotent: true,
        },
        Tool {
            name: "pane_wait",
            title: "Wait for a terminal pane",
            description: "Wait until a terminal pane prints a line matching a regex (returns the line and its groups, e.g. a server's port), its shell is back at the prompt, it has been quiet for a while, a command exits, or its program reports a status (an agent blocked or done). Only output after `since` (default: now) counts. Times out with status timeout, not an error.",
            input: object(
                json!({
                    "pane": pane_ref("Default: this pane."),
                    "match": { "type": "string", "description": "A regex, matched line by line." },
                    "since": { "type": "string", "description": "A cursor; default now." },
                    "prompt": { "type": "boolean", "description": "Until the shell is back at its prompt." },
                    "quietMs": { "type": "integer", "description": "Until no output for this long." },
                    "exit": { "type": "integer", "description": "Until this command id exits." },
                    "status": { "type": "array", "items": { "type": "string", "enum": ["idle", "working", "done", "blocked", "error"] }, "description": "Until the program reports one of these (e.g. an agent blocked or done)." },
                    "timeoutMs": timeout,
                    "maxBytes": max_bytes,
                }),
                &[],
            ),
            output: json!({
                "type": "object",
                "properties": {
                    "status": { "type": "string", "enum": ["matched", "prompt", "exited", "quiet", "status", "closed", "timeout"] },
                    "programStatus": status_schema(),
                    "match": { "type": "object", "properties": { "line": { "type": "string" }, "groups": { "type": "array", "items": { "type": ["string", "null"] } } } },
                    "command": { "anyOf": [command_schema(), { "type": "null" }] },
                    "output": output_schema(),
                },
                "required": ["status", "output"],
            }),
            read_only: true,
            destructive: false,
            idempotent: true,
        },
        Tool {
            name: "pane_send",
            title: "Type into a terminal pane",
            description: "Type into a terminal pane you created: text (pasted as one piece), named keys (enter, esc, tab, up, ctrl+c, shift+tab, f5…), and submit to press Enter after. For answering a program's prompt or driving a full-screen program; to run a command use cmd_run. Refused at a password prompt.",
            input: object(
                json!({
                    "pane": pane_ref("A pane you created."),
                    "text": { "type": "string" },
                    "keys": { "type": "array", "items": { "type": "string" } },
                    "submit": { "type": "boolean" },
                }),
                &["pane"],
            ),
            output: json!({
                "type": "object",
                "properties": { "written": { "type": "integer" }, "cursor": { "type": "string" } },
                "required": ["written", "cursor"],
            }),
            read_only: false,
            destructive: false,
            idempotent: false,
        },
        Tool {
            name: "pane_split",
            title: "Open a terminal pane",
            description: "Open a new terminal pane beside or below a pane (default this one) without taking the user's focus: a shell, a command, or a coding agent (claude, codex). Returns the pane to use with cmd_run, pane_send and pane_wait.",
            input: object(
                json!({
                    "of": pane_ref("Default: this pane."),
                    "direction": { "type": "string", "enum": ["right", "down"], "default": "right" },
                    "cwd": { "type": "string" },
                    "command": { "type": "string", "description": "Run this instead of a shell." },
                    "agent": { "type": "string", "enum": ["claude", "codex"] },
                    "focus": { "type": "boolean", "description": "Move the user's focus there (only when asked)." },
                }),
                &[],
            ),
            output: json!({ "type": "object", "properties": { "pane": pane_schema() }, "required": ["pane"] }),
            read_only: false,
            destructive: false,
            idempotent: false,
        },
        Tool {
            name: "tab_new",
            title: "Open a terminal tab",
            description: "Open a new terminal tab in this session without switching the user to it: a shell or a command. Returns the tab and its pane.",
            input: object(
                json!({
                    "cwd": { "type": "string" },
                    "command": { "type": "string" },
                    "title": { "type": "string" },
                    "focus": { "type": "boolean" },
                }),
                &[],
            ),
            output: json!({ "type": "object", "properties": { "tab": { "type": "string" }, "pane": pane_schema() }, "required": ["tab", "pane"] }),
            read_only: false,
            destructive: false,
            idempotent: false,
        },
        Tool {
            name: "pane_close",
            title: "Close a terminal pane",
            description: "Close a terminal pane you created, ending what runs in it. Closing one that is already gone succeeds.",
            input: object(
                json!({ "pane": pane_ref("A pane you created.") }),
                &["pane"],
            ),
            output: json!({
                "type": "object",
                "properties": { "closed": { "type": "boolean" }, "alreadyClosed": { "type": "boolean" } },
                "required": ["closed", "alreadyClosed"],
            }),
            read_only: false,
            destructive: true,
            idempotent: true,
        },
        Tool {
            name: "status_set",
            title: "Report your status",
            description: "Report what you are doing on your own terminal pane, as the user and other agents see it: working (with a message and progress), blocked on a permission, question or auth, done, error, idle, or clear. The same as printing OSC 7501.",
            input: object(
                json!({
                    "state": { "type": "string", "enum": ["working", "blocked", "done", "error", "idle", "clear"] },
                    "kind": { "type": "string", "enum": ["permission", "question", "auth"], "description": "What a blocked agent needs." },
                    "message": { "type": "string" },
                    "progress": { "type": "integer", "minimum": 0, "maximum": 100 },
                }),
                &["state"],
            ),
            output: json!({ "type": "object", "properties": { "status": status_schema() }, "required": ["status"] }),
            read_only: false,
            destructive: false,
            idempotent: true,
        },
    ]
}

/// The terminal tools, as `tools/list` declares them.
pub fn tools() -> Vec<Value> {
    tools_list()
        .into_iter()
        .map(|t| {
            json!({
                "name": t.name,
                "title": t.title,
                "description": t.description,
                "inputSchema": t.input,
                "outputSchema": t.output,
                "annotations": {
                    "title": t.title,
                    "readOnlyHint": t.read_only,
                    "destructiveHint": t.destructive,
                    "idempotentHint": t.idempotent,
                    "openWorldHint": false,
                },
            })
        })
        .collect()
}

pub fn is_tool(name: &str) -> bool {
    tools_list().iter().any(|t| t.name == name)
}

/// Runs terminal tool `name`.
pub fn call(name: &str, args: &Value, backend: &mut dyn Backend) -> Value {
    let ask = TermAsk {
        tool: name.to_owned(),
        args: args.clone(),
    };
    match backend.term(ask) {
        Ok(TermReply::Ok(value)) => json!({
            "content": [{ "type": "text", "text": summary(name, &value) }],
            "structuredContent": value,
        }),
        Ok(TermReply::Error(e)) => {
            let mut text = format!(
                "{}: {}",
                serde_json::to_value(e.code)
                    .unwrap_or_default()
                    .as_str()
                    .unwrap_or("error"),
                e.message
            );
            if let Some(hint) = e.hint {
                text.push_str(&format!("\nHint: {hint}"));
            }
            json!({ "content": [{ "type": "text", "text": text }], "isError": true })
        }
        Err(e) => json!({
            "content": [{ "type": "text", "text": format!("the {} daemon is not reachable: {e}", brand::PRODUCT_NAME) }],
            "isError": true,
        }),
    }
}

/// What the model reads: a line about the result, then the output verbatim (no escaped JSON),
/// then the cursor to read on from.
fn summary(tool: &str, v: &Value) -> String {
    let mut head = Vec::new();
    if let Some(status) = v["status"].as_str() {
        head.push(format!("status: {status}"));
    }
    if let Some(code) = v.pointer("/command/exitCode").and_then(Value::as_i64) {
        head.push(format!("exit code {code}"));
    }
    if let Some(pane) = v["pane"]
        .as_str()
        .or_else(|| v.pointer("/pane/id").and_then(Value::as_str))
    {
        head.push(format!("pane {pane}"));
    }
    if let Some(line) = v.pointer("/match/line").and_then(Value::as_str) {
        head.push(format!("matched {line:?}"));
    }
    if let Some(note) = v["note"].as_str() {
        head.push(note.to_owned());
    }
    let Some(output) = v.get("output").filter(|o| o.is_object()) else {
        return if head.is_empty() || matches!(tool, "whoami" | "pane_list") {
            serde_json::to_string_pretty(v).unwrap_or_default()
        } else {
            head.join(", ")
        };
    };
    let text = output["text"].as_str().unwrap_or_default();
    let cursor = output["cursor"].as_str().unwrap_or_default();
    let mut out = head.join(", ");
    if !out.is_empty() {
        out.push('\n');
    }
    if text.is_empty() {
        out.push_str("(no output)");
    } else {
        out.push_str("```\n");
        out.push_str(text);
        out.push_str("\n```");
    }
    out.push_str(&format!("\ncursor: {cursor}"));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_declares_schemas_and_annotations() {
        for tool in tools() {
            assert_eq!(tool["inputSchema"]["type"], "object", "{tool}");
            assert_eq!(tool["outputSchema"]["type"], "object", "{tool}");
            assert!(tool["annotations"]["readOnlyHint"].is_boolean(), "{tool}");
            // Search ranks names and descriptions: every description says what it is about.
            let d = tool["description"].as_str().unwrap();
            assert!(
                d.contains("terminal") || d.contains("shell") || d.contains("pane"),
                "{d}"
            );
        }
        // The ones that act are the ones agents ask the user about.
        let acting: Vec<_> = tools_list()
            .into_iter()
            // Reporting its own status touches nothing else.
            .filter(|t| !t.read_only && t.name != "status_set")
            .map(|t| t.name)
            .collect();
        assert_eq!(acting, agents::ACTING_TOOLS);
    }

    #[test]
    fn summaries_show_output_verbatim() {
        let v = json!({
            "pane": "p3", "status": "exited",
            "command": { "id": 4, "pane": "p3", "status": "exited", "exitCode": 1 },
            "output": { "text": "a \"quoted\"\nline", "lines": 2, "truncated": false, "cursor": "c9" },
        });
        assert_eq!(
            summary("cmd_run", &v),
            "status: exited, exit code 1, pane p3\n```\na \"quoted\"\nline\n```\ncursor: c9"
        );
    }
}
