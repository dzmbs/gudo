
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::adapter::{AgentAdapter, HookCoverage, HookError};
use crate::event::{
    AgentKind, AnswerPath, ApprovalChoice, ApprovalOption, BlockedReason, Blocker, Confidence,
    EventKind, Seq, Source, Turn, TurnOutcome,
};
use crate::hook::{self, Common};
use crate::launch::{
    CLAUDE_DIR_VAR, LaunchContext, LaunchMode, LaunchSpec, SupportFile, account_env, mcp_args,
    mcp_server_name, pane_env, shell_quote, user_mcp_server,
};
use crate::manifest::Manifest;
use crate::signal::{Claim, Signal};

const BUNDLED_MANIFEST: &str = include_str!("../manifests/claude.toml");

/// Version of the hook settings file we generate. Bump when its contents change so a running
/// session keeps the file it was launched with.
const SETTINGS_VERSION: u32 = 3;

/// Seconds a `PermissionRequest` hook may wait for a phone decision. Claude's own limit is 600.
const PERMISSION_TIMEOUT_SECS: u32 = 590;
const HOOK_TIMEOUT_SECS: u32 = 10;

/// The Claude Code adapter.
#[derive(Debug, Clone)]
pub struct ClaudeCode {
    manifest: Manifest,
}

impl ClaudeCode {
    /// Creates the adapter with the bundled screen manifest.
    pub fn new() -> Self {
        Self::with_manifest(
            Manifest::from_toml(BUNDLED_MANIFEST).expect("bundled claude manifest is valid"),
        )
    }

    /// Creates the adapter with a hot-updated manifest.
    pub fn with_manifest(manifest: Manifest) -> Self {
        Self { manifest }
    }

    /// Returns Claude Code's own command that adds the daemon's MCP server to the user's
    /// configuration (`claude mcp add --scope user …`), or with `register` false removes it,
    /// so sessions the user starts by hand in a pane get it too.
    ///
    /// # Examples
    ///
    /// ```
    /// use std::path::Path;
    /// let add = agents::ClaudeCode::user_mcp_command("claude", Path::new("/b/un-hook"), Path::new("/s"), true);
    /// assert_eq!(add.join(" "), "claude mcp add --scope user unnamed -- /b/un-hook mcp --state /s");
    /// ```
    pub fn user_mcp_command(
        program: &str,
        hook_bin: &Path,
        state_dir: &Path,
        register: bool,
    ) -> Vec<String> {
        let mut argv: Vec<String> = [
            program,
            "mcp",
            if register { "add" } else { "remove" },
            "--scope",
            "user",
        ]
        .map(String::from)
        .into();
        argv.push(mcp_server_name());
        if register {
            argv.push("--".into());
            argv.extend(user_mcp_server(hook_bin, state_dir));
        }
        argv
    }

    /// Claude Code's command that removes the user's registration of server `name`.
    pub fn user_mcp_remove(program: &str, name: &str) -> Vec<String> {
        [program, "mcp", "remove", "--scope", "user", name]
            .map(String::from)
            .into()
    }

    /// Claude Code's user configuration file (account details, user MCP servers):
    /// `<dir>/.claude.json` with a configuration directory, else `~/.claude.json`.
    ///
    /// # Examples
    ///
    /// ```
    /// use std::path::Path;
    /// use agents::ClaudeCode;
    ///
    /// assert_eq!(ClaudeCode::user_config_file(Path::new("/h"), None), Path::new("/h/.claude.json"));
    /// assert_eq!(
    ///     ClaudeCode::user_config_file(Path::new("/h"), Some(Path::new("/s/a1"))),
    ///     Path::new("/s/a1/.claude.json"),
    /// );
    /// ```
    pub fn user_config_file(home: &Path, config_dir: Option<&Path>) -> PathBuf {
        config_dir.unwrap_or(home).join(".claude.json")
    }

    /// Whether the user configuration file `config` ([`Self::user_config_file`]) registers
    /// server `name`.
    pub fn user_mcp_registered(config: &Path, name: &str) -> bool {
        std::fs::read(config)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .is_some_and(|config| config["mcpServers"].get(name).is_some())
    }

    /// Claude Code's own sign-in for the context's account: `claude auth login`, with only that
    /// account's directory in the environment. The user completes it in the pane.
    pub fn sign_in(ctx: &LaunchContext) -> LaunchSpec {
        let (env_remove, env_pinned) = account_env(&ctx.account, CLAUDE_DIR_VAR);
        LaunchSpec {
            program: "claude".into(),
            args: vec!["auth".into(), "login".into()],
            env: pane_env(ctx),
            cwd: ctx.cwd.clone(),
            files: Vec::new(),
            env_remove,
            env_pinned,
        }
    }

    /// Arguments that sign an account out (`claude auth logout`).
    pub const SIGN_OUT: &[&str] = &["auth", "logout"];

    /// Arguments that report an account's sign-in as JSON (`claude auth status --json`; exit
    /// status 0 when signed in).
    pub const STATUS: &[&str] = &["auth", "status", "--json"];

    /// Returns where the hook settings file for this context lives.
    pub fn settings_path(ctx: &LaunchContext) -> PathBuf {
        ctx.state_dir
            .join("claude")
            .join(format!("settings.v{SETTINGS_VERSION}.json"))
    }

    /// Returns where this pane's MCP config (passed with `--mcp-config`) lives.
    pub fn mcp_config_path(ctx: &LaunchContext) -> PathBuf {
        ctx.state_dir
            .join("claude")
            .join("mcp")
            .join(format!("{}.json", ctx.pane_id.as_str()))
    }

    /// Builds the MCP config passed with `--mcp-config`: the daemon's drawings server
    /// (`<hook_bin> mcp …`, docs/DAEMON.md §7.12) for this pane. Claude adds it to the user's
    /// own servers.
    pub fn mcp_config(ctx: &LaunchContext) -> Value {
        json!({
            "mcpServers": {
                mcp_server_name(): {
                    "type": "stdio",
                    "command": ctx.hook_bin,
                    "args": mcp_args(ctx),
                }
            }
        })
    }

    /// Builds the settings file passed with `--settings`. Hook arrays merge with the user's own
    /// settings levels, so this adds our hooks without editing user config.
    ///
    /// Every hook runs `<hook_bin> claude <Event>`. The status line runs `<hook_bin> claude
    /// StatusLine`: the shim hands its input (which carries the plan's `rate_limits`) to the
    /// daemon, then runs and prints the user's own `statusLine` command, so the user's status
    pub fn hook_settings(ctx: &LaunchContext) -> Value {
        let bin = shell_quote(&ctx.hook_bin.to_string_lossy());
        let entry = |event: &str, matcher: Option<&str>, timeout: Option<u32>| {
            let mut handler = json!({
                "type": "command",
                "command": format!("{bin} claude {event}"),
            });
            if let Some(timeout) = timeout {
                handler["timeout"] = timeout.into();
            }
            let mut group = json!({ "hooks": [handler] });
            if let Some(matcher) = matcher {
                group["matcher"] = matcher.into();
            }
            json!([group])
        };
        let short = Some(HOOK_TIMEOUT_SECS);
        json!({
            // The server's tools that act ask like Claude's own Bash tool; the rest are allowed.
            // Permission arrays merge with the user's own.
            "permissions": {
                "allow": [format!("mcp__{}", mcp_server_name())],
                "ask": crate::ACTING_TOOLS
                    .iter()
                    .map(|tool| format!("mcp__{}__{tool}", mcp_server_name()))
                    .collect::<Vec<_>>(),
            },
            "statusLine": {
                "type": "command",
                "command": format!("{bin} claude StatusLine"),
            },
            "hooks": {
                "SessionStart": entry("SessionStart", Some("startup|resume|clear|compact|fork"), short),
                "UserPromptSubmit": entry("UserPromptSubmit", None, short),
                "PreToolUse": entry("PreToolUse", Some("AskUserQuestion"), short),
                "PermissionRequest": entry("PermissionRequest", None, Some(PERMISSION_TIMEOUT_SECS)),
                "Notification": entry(
                    "Notification",
                    Some("permission_prompt|elicitation_dialog|idle_prompt"),
                    short,
                ),
                "Stop": entry("Stop", None, short),
                "StopFailure": entry("StopFailure", None, short),
                "PostCompact": entry("PostCompact", None, short),
                // SessionEnd hooks share a 1.5 s budget; keep Claude's default.
                "SessionEnd": entry("SessionEnd", None, None),
            }
        })
    }

    /// Builds the JSON a `PermissionRequest` hook prints to answer with `choice`.
    ///
    /// `AllowSession` echoes the request's `permission_suggestions` back as `updatedPermissions`
    /// with their destination set to `session`, which is what "don't ask again" does in the TUI.
    pub fn permission_response(choice: ApprovalChoice, suggestions: &[Value]) -> Value {
        let decision = match choice {
            ApprovalChoice::AllowOnce => json!({ "behavior": "allow" }),
            ApprovalChoice::AllowSession => {
                let updated: Vec<Value> = suggestions
                    .iter()
                    .cloned()
                    .map(|mut s| {
                        if let Some(obj) = s.as_object_mut() {
                            obj.insert("destination".into(), "session".into());
                        }
                        s
                    })
                    .collect();
                json!({ "behavior": "allow", "updatedPermissions": updated })
            }
            ApprovalChoice::Deny => json!({ "behavior": "deny" }),
        };
        json!({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision,
            }
        })
    }
}

impl Default for ClaudeCode {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Deserialize)]
struct Payload {
    #[serde(flatten)]
    common: Common,
    #[serde(flatten)]
    event: Event,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SessionSource {
    Startup,
    Resume,
    Clear,
    Compact,
    Fork,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "hook_event_name")]
enum Event {
    SessionStart {
        source: Option<SessionSource>,
    },
    UserPromptSubmit {},
    PreToolUse {
        tool_name: String,
        #[serde(default)]
        tool_input: Value,
    },
    PermissionRequest {
        tool_name: String,
        #[serde(default)]
        tool_input: Value,
        #[serde(default)]
        permission_suggestions: Vec<Value>,
    },
    Notification {
        message: Option<String>,
        notification_type: Option<String>,
    },
    Stop {
        last_assistant_message: Option<String>,
    },
    StopFailure {
        error: Option<String>,
        error_details: Option<String>,
        last_assistant_message: Option<String>,
    },
    PostCompact {
        trigger: Option<String>,
    },
    SessionEnd {},
    SubagentStart {},
    SubagentStop {},
    #[serde(other)]
    Other,
}

fn permission_options(allow_session: bool) -> Vec<ApprovalOption> {
    let mut options = vec![ApprovalOption::new(ApprovalChoice::AllowOnce, "Yes")];
    if allow_session {
        options.push(ApprovalOption::new(
            ApprovalChoice::AllowSession,
            "Yes, and don't ask again",
        ));
    }
    options.push(ApprovalOption::new(ApprovalChoice::Deny, "No"));
    options
}

fn question_blocker(tool_input: &Value) -> Blocker {
    let mut blocker = Blocker::new(BlockedReason::Question);
    blocker.tool = Some("AskUserQuestion".into());
    blocker.summary = tool_input
        .pointer("/questions/0/question")
        .and_then(Value::as_str)
        .map(hook::summary);
    blocker.detail = Some(hook::bounded_detail(tool_input));
    // Free-text and option answers need screen parsing; v1 offers "open terminal".
    blocker.answer_paths = vec![AnswerPath::Keystrokes];
    blocker
}

fn parse(payload: &[u8], seq: Seq) -> Result<Option<Signal>, HookError> {
    let Payload { common, event } = serde_json::from_slice(payload)?;
    let signal = |kind| {
        let mut s = Signal::new(Source::Hook, Confidence::Authoritative, kind).with_seq(seq);
        s.session = common.session();
        s
    };

    let mut out = match event {
        Event::SessionStart { source } => {
            let kind = match source {
                Some(SessionSource::Clear | SessionSource::Compact | SessionSource::Fork) => {
                    EventKind::SessionIdChanged
                }
                Some(SessionSource::Startup | SessionSource::Resume) | None => {
                    EventKind::SessionStarted
                }
            };
            // No claim: an auto-compact restarts the session mid-turn.
            signal(kind)
        }
        Event::UserPromptSubmit {} => signal(EventKind::TurnStarted).with_claim(Claim::Working),
        Event::PreToolUse {
            tool_name,
            tool_input,
        } => {
            if tool_name == "AskUserQuestion" {
                signal(EventKind::Blocked).with_claim(Claim::Blocked(question_blocker(&tool_input)))
            } else {
                signal(EventKind::ToolStarted).with_claim(Claim::Working)
            }
        }
        Event::PermissionRequest {
            tool_name,
            tool_input,
            permission_suggestions,
        } => {
            let mut blocker = Blocker::new(BlockedReason::Permission);
            blocker.summary = hook::tool_summary(&tool_input);
            blocker.detail = Some(hook::bounded_detail(&tool_input));
            blocker.tool = Some(tool_name);
            blocker.options = permission_options(!permission_suggestions.is_empty());
            // HookDecision works only while the shim holds the request open (remote-approval
            // mode); the daemon drops it from the offer otherwise.
            blocker.answer_paths = vec![AnswerPath::HookDecision, AnswerPath::Keystrokes];
            signal(EventKind::Blocked).with_claim(Claim::Blocked(blocker))
        }
        Event::Notification {
            message,
            notification_type,
        } => {
            let blocked = |reason, summary: Option<String>| {
                let mut blocker = Blocker::new(reason);
                blocker.summary = summary;
                blocker.answer_paths = vec![AnswerPath::Keystrokes];
                signal(EventKind::Blocked).with_claim(Claim::Blocked(blocker))
            };
            match notification_type.as_deref() {
                // Usually follows the PermissionRequest for the same dialog. Its generic message
                // ("Claude needs your permission") would make the two look like different
                // requests, so it carries no summary.
                Some("permission_prompt") => blocked(BlockedReason::Permission, None),
                Some("elicitation_dialog" | "elicitation_url_dialog") => {
                    blocked(BlockedReason::Elicitation, hook::message(message))
                }
                // Fires about 60 s after the turn ended; a late confirmation of idle.
                Some("idle_prompt") => signal(EventKind::TurnEnded).with_claim(Claim::Idle),
                _ => return Ok(None),
            }
        }
        Event::Stop {
            last_assistant_message,
        } => {
            let mut s = signal(EventKind::TurnEnded).with_claim(Claim::Idle);
            s.turn = Some(Turn {
                outcome: TurnOutcome::Completed,
                last_message: hook::message(last_assistant_message),
            });
            s
        }
        Event::StopFailure {
            error,
            error_details,
            last_assistant_message,
        } => {
            let mut s = signal(EventKind::Error).with_claim(Claim::Error);
            s.turn = Some(Turn {
                outcome: TurnOutcome::Failed,
                last_message: hook::message(last_assistant_message.or(error_details).or(error)),
            });
            s
        }
        // A manual /compact emits no Stop, so its PostCompact ends the "turn". An auto-compact
        // happens mid-turn and changes nothing.
        Event::PostCompact { trigger } if trigger.as_deref() == Some("manual") => {
            signal(EventKind::TurnEnded).with_claim(Claim::Idle)
        }
        Event::PostCompact { .. } => return Ok(None),
        // SessionEnd also fires on /clear and /resume, which keep the process; process exit is
        // what ends the pane's state.
        Event::SessionEnd {} => signal(EventKind::SessionEnded),
        Event::SubagentStart {} => signal(EventKind::TurnStarted),
        Event::SubagentStop {} => signal(EventKind::TurnEnded),
        Event::Other => return Ok(None),
    };

    if let Some(subagent) = common.subagent() {
        out.claim = None;
        out.turn = None;
        out.subagent = Some(subagent);
    }
    Ok(Some(out))
}

impl AgentAdapter for ClaudeCode {
    fn kind(&self) -> AgentKind {
        AgentKind::Claude
    }

    fn program_status_app(&self) -> &str {
        "claude-code"
    }

    fn hook_coverage(&self) -> HookCoverage {
        HookCoverage::Partial
    }

    fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// `claude --session-id <id> --mcp-config <file> --settings <file>`, or `--resume <id>`
    /// first. `--resume` does not restore either, so every launch passes both. `--mcp-config`
    /// takes several values, so an option must follow it.
    fn launch(&self, ctx: &LaunchContext, mode: &LaunchMode) -> LaunchSpec {
        let settings = Self::settings_path(ctx);
        let mut args: Vec<OsString> = Vec::new();
        match mode {
            LaunchMode::Fresh {
                session_id: Some(id),
            } => args.extend(["--session-id".into(), id.as_str().into()]),
            LaunchMode::Fresh { session_id: None } => {}
            LaunchMode::Resume { session_id } => {
                args.extend(["--resume".into(), session_id.as_str().into()]);
            }
        }
        let mcp = Self::mcp_config_path(ctx);
        args.extend([
            "--mcp-config".into(),
            mcp.clone().into(),
            "--settings".into(),
            settings.clone().into(),
        ]);
        let pretty = |v: &Value| {
            serde_json::to_string_pretty(v).expect("serializing a JSON value cannot fail")
        };
        let (env_remove, env_pinned) = account_env(&ctx.account, CLAUDE_DIR_VAR);
        LaunchSpec {
            program: "claude".into(),
            args,
            env: pane_env(ctx),
            cwd: ctx.cwd.clone(),
            env_remove,
            env_pinned,
            files: vec![
                SupportFile {
                    path: settings,
                    contents: pretty(&Self::hook_settings(ctx)),
                },
                SupportFile {
                    path: mcp,
                    contents: pretty(&Self::mcp_config(ctx)),
                },
            ],
        }
    }

    fn parse_hook(&self, payload: &[u8], seq: Seq) -> Result<Option<Signal>, HookError> {
        parse(payload, seq)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::AgentState;
    use crate::event::NativeSessionId;
    use crate::launch::test_context;
    use crate::manifest::{ScreenInput, ScreenVerdict};

    macro_rules! fixture {
        ($name:literal) => {
            include_bytes!(concat!("../tests/fixtures/claude/", $name, ".json"))
        };
    }

    fn parse_fixture(bytes: &[u8]) -> Signal {
        ClaudeCode::new()
            .parse_hook(bytes, Seq(1))
            .unwrap()
            .expect("fixture maps to a signal")
    }

    #[test]
    fn session_start_reports_identity_without_a_state() {
        let s = parse_fixture(fixture!("session_start_resume"));
        assert_eq!(s.kind, EventKind::SessionStarted);
        assert_eq!(s.claim, None);
        assert_eq!(s.seq, Some(Seq(1)));
        assert_eq!(s.session.native_id, Some(NativeSessionId::new("abc123")));
        assert!(
            s.session
                .transcript
                .unwrap()
                .ends_with("00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl")
        );
    }

    #[test]
    fn session_start_after_clear_changes_the_id() {
        let payload = br#"{"session_id":"new","hook_event_name":"SessionStart","source":"clear"}"#;
        assert_eq!(parse_fixture(payload).kind, EventKind::SessionIdChanged);
    }

    #[test]
    fn prompt_submit_is_working() {
        let s = parse_fixture(fixture!("user_prompt_submit"));
        assert_eq!(
            (s.kind, s.claim),
            (EventKind::TurnStarted, Some(Claim::Working))
        );
        assert_eq!(s.confidence, Confidence::Authoritative);
    }

    #[test]
    fn permission_request_is_a_rich_blocker() {
        let s = parse_fixture(fixture!("permission_request"));
        assert_eq!(s.kind, EventKind::Blocked);
        let Some(Claim::Blocked(b)) = s.claim else {
            panic!("expected a blocked claim")
        };
        assert_eq!(b.reason, BlockedReason::Permission);
        assert_eq!(b.tool.as_deref(), Some("Bash"));
        assert_eq!(b.summary.as_deref(), Some("rm -rf node_modules"));
        assert_eq!(
            b.detail.unwrap()["description"],
            "Remove node_modules directory"
        );
        let ids: Vec<_> = b.options.iter().map(|o| o.id).collect();
        assert_eq!(
            ids,
            [
                ApprovalChoice::AllowOnce,
                ApprovalChoice::AllowSession,
                ApprovalChoice::Deny
            ]
        );
        assert_eq!(
            b.answer_paths,
            [AnswerPath::HookDecision, AnswerPath::Keystrokes]
        );
    }

    #[test]
    fn ask_user_question_blocks_on_a_question() {
        let payload = br#"{"session_id":"abc123","hook_event_name":"PreToolUse",
            "tool_name":"AskUserQuestion","tool_use_id":"t1","tool_input":{"questions":[
            {"question":"Which framework?","header":"Framework","multiSelect":false,
             "options":[{"label":"React","description":"Component library"}]}]}}"#;
        let Some(Claim::Blocked(b)) = parse_fixture(payload).claim else {
            panic!()
        };
        assert_eq!(b.reason, BlockedReason::Question);
        assert_eq!(b.summary.as_deref(), Some("Which framework?"));
        assert!(b.options.is_empty());
    }

    #[test]
    fn other_tools_are_working() {
        let s = parse_fixture(fixture!("pre_tool_use_bash"));
        assert_eq!(
            (s.kind, s.claim),
            (EventKind::ToolStarted, Some(Claim::Working))
        );
    }

    #[test]
    fn permission_notification_blocks() {
        let s = parse_fixture(fixture!("notification_permission_prompt"));
        let Some(Claim::Blocked(b)) = s.claim else {
            panic!()
        };
        assert_eq!(b.reason, BlockedReason::Permission);
        assert_eq!(b.summary, None);
    }

    #[test]
    fn notifications_by_type() {
        let notification = |kind: &str| {
            let payload = format!(
                r#"{{"session_id":"s","hook_event_name":"Notification","message":"m","notification_type":"{kind}"}}"#
            );
            ClaudeCode::new()
                .parse_hook(payload.as_bytes(), Seq(1))
                .unwrap()
        };
        assert_eq!(
            notification("idle_prompt").unwrap().claim,
            Some(Claim::Idle)
        );
        let Some(Claim::Blocked(b)) = notification("elicitation_dialog").unwrap().claim else {
            panic!()
        };
        assert_eq!(b.reason, BlockedReason::Elicitation);
        assert_eq!(notification("auth_success"), None);
    }

    #[test]
    fn stop_ends_the_turn() {
        let s = parse_fixture(fixture!("stop"));
        assert_eq!((s.kind, s.claim), (EventKind::TurnEnded, Some(Claim::Idle)));
        let turn = s.turn.unwrap();
        assert_eq!(turn.outcome, TurnOutcome::Completed);
        assert!(turn.last_message.unwrap().starts_with("I've completed"));
    }

    #[test]
    fn stop_failure_is_an_error() {
        let s = parse_fixture(fixture!("stop_failure"));
        assert_eq!((s.kind, s.claim), (EventKind::Error, Some(Claim::Error)));
        let turn = s.turn.unwrap();
        assert_eq!(turn.outcome, TurnOutcome::Failed);
        assert_eq!(
            turn.last_message.as_deref(),
            Some("API Error: Rate limit reached")
        );
    }

    #[test]
    fn manual_compact_ends_the_turn() {
        let s = parse_fixture(fixture!("post_compact"));
        assert_eq!(s.claim, Some(Claim::Idle));
        let auto = br#"{"session_id":"s","hook_event_name":"PostCompact","trigger":"auto"}"#;
        assert_eq!(ClaudeCode::new().parse_hook(auto, Seq(1)).unwrap(), None);
    }

    #[test]
    fn session_end_claims_nothing() {
        let s = parse_fixture(fixture!("session_end"));
        assert_eq!((s.kind, s.claim), (EventKind::SessionEnded, None));
    }

    #[test]
    fn subagent_hooks_never_claim_lead_state() {
        let s = parse_fixture(fixture!("subagent_stop"));
        assert_eq!(s.claim, None);
        let sub = s.subagent.unwrap();
        assert_eq!(sub.id.as_str(), "def456");
        assert_eq!(sub.agent_type.as_deref(), Some("Explore"));

        let inside = br#"{"session_id":"s","hook_event_name":"PermissionRequest","agent_id":"a1",
            "tool_name":"Bash","tool_input":{"command":"ls"}}"#;
        let s = parse_fixture(inside);
        assert_eq!(s.claim, None);
        assert!(s.subagent.is_some());
    }

    #[test]
    fn unknown_events_are_ignored_and_garbage_is_an_error() {
        let adapter = ClaudeCode::new();
        let unknown = br#"{"session_id":"s","hook_event_name":"FileChanged"}"#;
        assert_eq!(adapter.parse_hook(unknown, Seq(1)).unwrap(), None);
        assert!(adapter.parse_hook(b"not json", Seq(1)).is_err());
    }

    #[test]
    fn launch_pins_the_session_and_passes_settings() {
        let ctx = test_context();
        let spec = ClaudeCode::new().launch(
            &ctx,
            &LaunchMode::Fresh {
                session_id: Some(NativeSessionId::new("0b4f…uuid")),
            },
        );
        assert_eq!(
            spec.display_argv(),
            [
                "claude",
                "--session-id",
                "0b4f…uuid",
                "--mcp-config",
                "/state/claude/mcp/p_9f2.json",
                "--settings",
                "/state/claude/settings.v3.json"
            ]
        );
        assert_eq!(spec.cwd, ctx.cwd);
        assert!(
            spec.env
                .iter()
                .any(|(k, v)| k == "UN_PANE_ID" && v == "p_9f2")
        );
        assert_eq!(spec.files[0].path, ClaudeCode::settings_path(&ctx));
        let settings: Value = serde_json::from_str(&spec.files[0].contents).unwrap();
        assert_eq!(
            settings["hooks"]["PermissionRequest"][0]["hooks"][0]["command"],
            "/opt/un/bin/un-hook claude PermissionRequest"
        );
        assert_eq!(
            settings["statusLine"]["command"],
            "/opt/un/bin/un-hook claude StatusLine"
        );
        assert_eq!(
            settings["hooks"]["PreToolUse"][0]["matcher"],
            "AskUserQuestion"
        );
        assert_eq!(settings["permissions"]["allow"], json!(["mcp__unnamed"]));
    }

    #[test]
    fn launch_runs_under_the_account() {
        use crate::launch::work_context;
        let mode = LaunchMode::Resume {
            session_id: NativeSessionId::new("s1"),
        };
        let spec = ClaudeCode::new().launch(&work_context(), &mode);
        assert!(
            spec.env_pinned
                .iter()
                .any(|(k, v)| k == "CLAUDE_CONFIG_DIR" && v == "/state/accounts/claude/a1b2")
        );
        assert!(spec.env_remove.iter().any(|v| v == "ANTHROPIC_API_KEY"));
        assert!(spec.env_remove.iter().any(|v| v == "CODEX_HOME"));
        // Nothing secret is pinned: pinned values are on the shell's command line.
        assert!(!spec.env_pinned.iter().any(|(k, _)| k.contains("TOKEN")));
        // The system account inherits the user's own directory.
        let spec = ClaudeCode::new().launch(&test_context(), &mode);
        assert!(
            !spec
                .env_pinned
                .iter()
                .any(|(k, _)| k == "CLAUDE_CONFIG_DIR")
        );
        assert!(
            spec.env_remove
                .iter()
                .any(|v| v == "CLAUDE_CODE_OAUTH_TOKEN")
        );
    }

    #[test]
    fn sign_in_is_claudes_own_login_in_the_accounts_dir() {
        let spec = ClaudeCode::sign_in(&crate::launch::work_context());
        assert_eq!(spec.display_argv(), ["claude", "auth", "login"]);
        assert!(spec.shell_line().contains("export CLAUDE_CONFIG_DIR="));
    }

    #[test]
    fn launch_adds_the_drawings_mcp_server() {
        let ctx = test_context();
        let spec = ClaudeCode::new().launch(&ctx, &LaunchMode::Fresh { session_id: None });
        assert_eq!(spec.files[1].path, ClaudeCode::mcp_config_path(&ctx));
        let config: Value = serde_json::from_str(&spec.files[1].contents).unwrap();
        assert_eq!(
            config,
            json!({
                "mcpServers": {
                    "unnamed": {
                        "type": "stdio",
                        "command": "/opt/un/bin/un-hook",
                        "args": ["mcp", "--state", "/state", "--pane", "p_9f2"],
                    }
                }
            })
        );
        // Additive: never the flag that would drop the user's own servers.
        assert!(
            !spec
                .display_argv()
                .iter()
                .any(|a| a == "--strict-mcp-config")
        );
    }

    #[test]
    fn resume_re_passes_settings() {
        let spec = ClaudeCode::new().launch(
            &test_context(),
            &LaunchMode::Resume {
                session_id: NativeSessionId::new("abc123"),
            },
        );
        assert_eq!(
            spec.display_argv(),
            [
                "claude",
                "--resume",
                "abc123",
                "--mcp-config",
                "/state/claude/mcp/p_9f2.json",
                "--settings",
                "/state/claude/settings.v3.json"
            ]
        );
    }

    #[test]
    fn permission_responses() {
        let allow = ClaudeCode::permission_response(ApprovalChoice::AllowOnce, &[]);
        assert_eq!(
            allow["hookSpecificOutput"]["hookEventName"],
            "PermissionRequest"
        );
        assert_eq!(allow["hookSpecificOutput"]["decision"]["behavior"], "allow");
        let deny = ClaudeCode::permission_response(ApprovalChoice::Deny, &[]);
        assert_eq!(deny["hookSpecificOutput"]["decision"]["behavior"], "deny");

        let request: Value = serde_json::from_slice(fixture!("permission_request")).unwrap();
        let suggestions = request["permission_suggestions"].as_array().unwrap();
        let session = ClaudeCode::permission_response(ApprovalChoice::AllowSession, suggestions);
        let updated = &session["hookSpecificOutput"]["decision"]["updatedPermissions"][0];
        assert_eq!(updated["destination"], "session");
        assert_eq!(updated["rules"][0]["ruleContent"], "rm -rf node_modules");
    }

    fn screen_state(screen: &str, title: &str) -> (AgentState, Option<String>, bool) {
        match ClaudeCode::new().detect_screen(ScreenInput {
            screen,
            osc_title: title,
            osc_progress: "",
        }) {
            ScreenVerdict::State(m) => (m.state, m.rule_id.clone(), m.is_visible()),
            ScreenVerdict::Freeze { rule_id } => (AgentState::Unknown, Some(rule_id), false),
        }
    }

    #[test]
    fn screen_detects_a_bash_permission_dialog() {
        let screen = "\
⏺ Bash(rm -rf node_modules)
────────────────────────────────────────
 Bash command

   rm -rf node_modules
   Remove node_modules directory

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm -rf commands in /src/app
   3. No, and tell Claude what to do differently (esc)

 Esc to cancel · Tab to amend · ctrl+e to explain";
        let (state, rule, visible) = screen_state(screen, "✳ Claude Code");
        assert_eq!(state, AgentState::Blocked);
        assert!(visible);
        assert!(rule.is_some());
    }

    #[test]
    fn screen_detects_the_folder_trust_dialog() {
        let screen = "\
────────────────────────────────────────
 Accessing workspace:

 /Users/me/src/app

 Quick safety check: Is this a project you created or one you trust? (Like your
 own code, a well-known open source project, or work from your team). If not,
 take a moment to review what's in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel";
        let (state, rule, visible) = screen_state(screen, "");
        assert_eq!(state, AgentState::Blocked);
        assert_eq!(rule.as_deref(), Some("trust_directory"));
        assert!(visible);
    }

    #[test]
    fn screen_detects_the_idle_prompt() {
        let screen = "\
⏺ Done. All tests pass.

────────────────────────────────────────
❯
────────────────────────────────────────
  ? for shortcuts";
        assert_eq!(
            screen_state(screen, ""),
            (AgentState::Idle, Some("live_prompt_box".into()), true)
        );
    }

    #[test]
    fn title_spinner_is_working() {
        let (state, rule, visible) = screen_state("", "◐ Refactoring parser");
        assert_eq!(state, AgentState::Working);
        assert_eq!(rule.as_deref(), Some("osc_title_working"));
        assert!(visible);
    }

    #[test]
    fn transcript_viewer_freezes() {
        let screen = "lots of transcript\n\nShowing detailed transcript · ctrl+o to toggle";
        assert_eq!(
            screen_state(screen, "").1.as_deref(),
            Some("transcript_viewer")
        );
    }
}
