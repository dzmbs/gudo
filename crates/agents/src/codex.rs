//!
//! Codex hooks need trust hashes in the user's config, so v1 launches without them and reads state
//! from the screen, the `[ ! ] Action Required` title and OSC 9 notifications, which per-run `-c`
//! flags turn on. Hook payloads are still parsed for users who opt into the marker-block install.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::adapter::{AgentAdapter, HookCoverage, HookError};
use crate::event::{
    AgentKind, AnswerPath, ApprovalChoice, ApprovalOption, BlockedReason, Blocker, Confidence,
    EventKind, Seq, Source, Turn, TurnOutcome,
};
use crate::hook::{self, Common};
use crate::launch::{
    CODEX_DIR_VAR, LaunchContext, LaunchMode, LaunchSpec, account_env, mcp_args, mcp_server_name,
    pane_env, toml_quote, user_mcp_server,
};
use crate::manifest::Manifest;
use crate::signal::{Claim, Signal};

const BUNDLED_MANIFEST: &str = include_str!("../manifests/codex.toml");

/// `-c` overrides that make the TUI emit OSC 9 on approvals and turn ends, focused or not. Values
/// are TOML.
const NOTIFICATION_OVERRIDES: [&str; 3] = [
    r#"tui.notifications=["approval-requested","agent-turn-complete"]"#,
    r#"tui.notification_method="osc9""#,
    r#"tui.notification_condition="always""#,
];

/// `-c` overrides that add the daemon's drawings MCP server (docs/DAEMON.md §7.12) for this
/// run only, next to the user's own `mcp_servers`.
fn mcp_overrides(ctx: &LaunchContext) -> [String; 2] {
    let name = mcp_server_name();
    let args: Vec<String> = mcp_args(ctx).iter().map(|a| toml_quote(a)).collect();
    [
        format!(
            "mcp_servers.{name}.command={}",
            toml_quote(&ctx.hook_bin.to_string_lossy())
        ),
        format!("mcp_servers.{name}.args=[{}]", args.join(",")),
    ]
}

/// The Codex CLI adapter.
#[derive(Debug, Clone)]
pub struct Codex {
    manifest: Manifest,
}

impl Codex {
    /// Creates the adapter with the bundled screen manifest.
    pub fn new() -> Self {
        Self::with_manifest(
            Manifest::from_toml(BUNDLED_MANIFEST).expect("bundled codex manifest is valid"),
        )
    }

    /// Creates the adapter with a hot-updated manifest.
    pub fn with_manifest(manifest: Manifest) -> Self {
        Self { manifest }
    }

    /// Returns Codex's own command that adds the daemon's MCP server to the user's
    /// `~/.codex/config.toml` (`codex mcp add …`), or with `register` false removes it, so
    /// sessions the user starts by hand in a pane get it too.
    ///
    /// # Examples
    ///
    /// ```
    /// use std::path::Path;
    /// let remove = agents::Codex::user_mcp_command("codex", Path::new("/b/un-hook"), Path::new("/s"), false);
    /// assert_eq!(remove.join(" "), "codex mcp remove unnamed");
    /// ```
    pub fn user_mcp_command(
        program: &str,
        hook_bin: &Path,
        state_dir: &Path,
        register: bool,
    ) -> Vec<String> {
        let mut argv = vec![
            program.to_owned(),
            "mcp".into(),
            if register { "add" } else { "remove" }.into(),
            mcp_server_name(),
        ];
        if register {
            argv.push("--".into());
            argv.extend(user_mcp_server(hook_bin, state_dir));
        }
        argv
    }

    /// Codex's command that removes the user's registration of server `name`.
    pub fn user_mcp_remove(program: &str, name: &str) -> Vec<String> {
        [program, "mcp", "remove", name].map(String::from).into()
    }

    /// Codex's configuration file: `<CODEX_HOME>/config.toml`, else `~/.codex/config.toml`.
    pub fn config_file(home: &Path, codex_home: Option<&Path>) -> PathBuf {
        codex_home
            .map_or_else(|| home.join(".codex"), Path::to_path_buf)
            .join("config.toml")
    }

    /// What a new account's `config.toml` says: MCP servers' OAuth logins in the account's
    /// own files, because Codex keys those keyring items by server alone, shared across homes.
    pub const ACCOUNT_CONFIG: &str = "# MCP OAuth logins stay in this account: Codex's keyring \
        entries for them are shared by every home.\nmcp_oauth_credentials_store = \"file\"\n";

    /// Codex's own sign-in for the context's account: `codex login`, or `codex login
    /// --device-auth` for a host whose browser is not the user's, with only that account's
    /// home in the environment. The user completes it in the pane.
    pub fn sign_in(ctx: &LaunchContext, device_code: bool) -> LaunchSpec {
        let (env_remove, env_pinned) = account_env(&ctx.account, CODEX_DIR_VAR);
        let mut args = vec![OsString::from("login")];
        if device_code {
            args.push("--device-auth".into());
        }
        LaunchSpec {
            program: "codex".into(),
            args,
            env: pane_env(ctx),
            cwd: ctx.cwd.clone(),
            files: Vec::new(),
            env_remove,
            env_pinned,
        }
    }

    /// Arguments that sign an account out (`codex logout`).
    pub const SIGN_OUT: &[&str] = &["logout"];

    /// Whether the configuration file `config` ([`Self::config_file`]) registers server
    /// `name`.
    pub fn user_mcp_registered(config: &Path, name: &str) -> bool {
        std::fs::read_to_string(config).is_ok_and(|config| {
            config.lines().any(|line| {
                let line = line.trim_start_matches(['[', ' ']);
                line.strip_prefix("mcp_servers.")
                    .and_then(|rest| rest.strip_prefix(name))
                    .is_some_and(|rest| rest.starts_with([']', '.', ' ', '=']))
            })
        })
    }
}

impl Default for Codex {
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
    },
    PermissionRequest {
        tool_name: String,
        #[serde(default)]
        tool_input: Value,
    },
    Stop {
        last_assistant_message: Option<String>,
    },
    Interrupt {},
    SessionEnd {},
    #[serde(other)]
    Other,
}

fn permission_options() -> Vec<ApprovalOption> {
    vec![
        ApprovalOption::new(ApprovalChoice::AllowOnce, "Yes, proceed"),
        ApprovalOption::new(ApprovalChoice::AllowSession, "Yes, and don't ask again"),
        ApprovalOption::new(ApprovalChoice::Deny, "No"),
    ]
}

fn parse(payload: &[u8], seq: Seq) -> Result<Option<Signal>, HookError> {
    let Payload { common, event } = serde_json::from_slice(payload)?;
    let signal = |kind| {
        let mut s = Signal::new(Source::Hook, Confidence::Authoritative, kind).with_seq(seq);
        s.session = common.session();
        s
    };
    let mut out = match event {
        Event::SessionStart { source } => signal(match source {
            Some(SessionSource::Clear | SessionSource::Compact | SessionSource::Fork) => {
                EventKind::SessionIdChanged
            }
            Some(SessionSource::Startup | SessionSource::Resume) | None => {
                EventKind::SessionStarted
            }
        }),
        Event::UserPromptSubmit {} => signal(EventKind::TurnStarted).with_claim(Claim::Working),
        Event::PreToolUse { tool_name } if tool_name == "request_user_input" => {
            let mut blocker = Blocker::new(BlockedReason::Question);
            blocker.tool = Some(tool_name);
            blocker.answer_paths = vec![AnswerPath::Keystrokes];
            signal(EventKind::Blocked).with_claim(Claim::Blocked(blocker))
        }
        Event::PreToolUse { .. } => signal(EventKind::ToolStarted).with_claim(Claim::Working),
        Event::PermissionRequest {
            tool_name,
            tool_input,
        } => {
            let mut blocker = Blocker::new(BlockedReason::Permission);
            blocker.summary = hook::tool_summary(&tool_input);
            blocker.detail = Some(hook::bounded_detail(&tool_input));
            blocker.tool = Some(tool_name);
            blocker.options = permission_options();
            blocker.answer_paths = vec![AnswerPath::HookDecision, AnswerPath::Keystrokes];
            signal(EventKind::Blocked).with_claim(Claim::Blocked(blocker))
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
        Event::Interrupt {} => {
            let mut s = signal(EventKind::Interrupted).with_claim(Claim::Idle);
            s.turn = Some(Turn {
                outcome: TurnOutcome::Cancelled,
                last_message: None,
            });
            s
        }
        Event::SessionEnd {} => signal(EventKind::SessionEnded),
        Event::Other => return Ok(None),
    };
    if let Some(subagent) = common.subagent() {
        out.claim = None;
        out.turn = None;
        out.subagent = Some(subagent);
    }
    Ok(Some(out))
}

/// Maps the TUI's notification text (`codex-rs/tui/src/chatwidget/notifications.rs`) to a signal.
fn parse_osc9(body: &str) -> Option<Signal> {
    // `9;4;…` is ConEmu progress and other numeric subcommands are not notifications.
    if body
        .split_once(';')
        .is_some_and(|(head, _)| !head.is_empty() && head.bytes().all(|b| b.is_ascii_digit()))
    {
        return None;
    }
    let blocked = |reason, tool: Option<&str>, summary: &str| {
        let mut blocker = Blocker::new(reason);
        blocker.tool = tool.map(str::to_owned);
        blocker.summary = Some(summary.to_owned()).filter(|s| !s.is_empty());
        blocker.answer_paths = vec![AnswerPath::Keystrokes];
        Signal::new(Source::Osc9, Confidence::Strong, EventKind::Blocked)
            .with_claim(Claim::Blocked(blocker))
    };
    if let Some(command) = body.strip_prefix("Approval requested: ") {
        return Some(blocked(BlockedReason::Permission, None, command));
    }
    if let Some(server) = body.strip_prefix("Approval requested by ") {
        return Some(blocked(BlockedReason::Elicitation, None, server));
    }
    if let Some(target) = body.strip_prefix("Codex wants to edit ") {
        return Some(blocked(
            BlockedReason::Permission,
            Some("apply_patch"),
            target,
        ));
    }
    if let Some(title) = body
        .strip_prefix("Plan mode prompt: ")
        .or_else(|| body.strip_prefix("Question: "))
    {
        return Some(blocked(BlockedReason::Question, None, title));
    }
    // Anything else is `agent-turn-complete`, whose body is a preview of the agent's reply. Reply
    // text is arbitrary, so this is weak evidence.
    let mut signal =
        Signal::new(Source::Osc9, Confidence::Weak, EventKind::TurnEnded).with_claim(Claim::Idle);
    signal.turn = Some(Turn {
        outcome: TurnOutcome::Completed,
        last_message: Some(body.to_owned()).filter(|m| m != "Agent turn complete"),
    });
    Some(signal)
}

impl AgentAdapter for Codex {
    fn kind(&self) -> AgentKind {
        AgentKind::Codex
    }

    fn program_status_app(&self) -> &str {
        "codex"
    }

    fn hook_coverage(&self) -> HookCoverage {
        HookCoverage::Partial
    }

    fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// `codex -c <notifications…> -c <drawings MCP server…> [resume <id>]`. Codex cannot pin a
    /// new session id, so a `Fresh` id is ignored; the id arrives later from a hook or the rollout
    /// file. Resume must run with the same `CODEX_HOME` that created the session: the account's,
    /// or for the system account the inherited one, untouched.
    fn launch(&self, ctx: &LaunchContext, mode: &LaunchMode) -> LaunchSpec {
        let mut args: Vec<OsString> = NOTIFICATION_OVERRIDES
            .iter()
            .map(|o| (*o).to_owned())
            .chain(mcp_overrides(ctx))
            .flat_map(|o| ["-c".into(), OsString::from(o)])
            .collect();
        if let LaunchMode::Resume { session_id } = mode {
            args.extend(["resume".into(), session_id.as_str().into()]);
        }
        let (env_remove, env_pinned) = account_env(&ctx.account, CODEX_DIR_VAR);
        LaunchSpec {
            program: "codex".into(),
            args,
            env: pane_env(ctx),
            cwd: ctx.cwd.clone(),
            files: Vec::new(),
            env_remove,
            env_pinned,
        }
    }

    fn parse_hook(&self, payload: &[u8], seq: Seq) -> Result<Option<Signal>, HookError> {
        parse(payload, seq)
    }

    fn parse_osc9(&self, body: &str) -> Option<Signal> {
        parse_osc9(body)
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn finds_a_user_registration_by_exact_name() {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir(home.path().join(".codex")).unwrap();
        let config = Codex::config_file(home.path(), None);
        std::fs::write(
            &config,
            "[mcp_servers.unnamed_drawings_x]\ncommand = \"x\"\n",
        )
        .unwrap();
        assert!(!Codex::user_mcp_registered(&config, "unnamed_drawings"));
        std::fs::write(&config, "[mcp_servers.unnamed_drawings]\ncommand = \"x\"\n").unwrap();
        assert!(Codex::user_mcp_registered(&config, "unnamed_drawings"));
        std::fs::write(&config, "mcp_servers.unnamed_drawings.command = \"x\"\n").unwrap();
        assert!(Codex::user_mcp_registered(&config, "unnamed_drawings"));
    }
    use super::*;
    use crate::AgentState;
    use crate::event::NativeSessionId;
    use crate::launch::test_context;
    use crate::manifest::{ScreenInput, ScreenVerdict};

    macro_rules! fixture {
        ($name:literal) => {
            include_bytes!(concat!("../tests/fixtures/codex/", $name, ".json"))
        };
    }

    fn hook(bytes: &[u8]) -> Signal {
        Codex::new().parse_hook(bytes, Seq(9)).unwrap().unwrap()
    }

    #[test]
    fn launch_and_sign_in_run_under_the_account() {
        let ctx = crate::launch::work_context();
        let spec = Codex::new().launch(&ctx, &LaunchMode::Fresh { session_id: None });
        assert!(spec.env_pinned.iter().any(|(k, _)| k == "CODEX_HOME"));
        assert!(spec.env_remove.iter().any(|v| v == "OPENAI_API_KEY"));
        assert!(spec.env_remove.iter().any(|v| v == "CLAUDE_CONFIG_DIR"));
        let remote = Codex::sign_in(&ctx, true);
        assert_eq!(remote.display_argv(), ["codex", "login", "--device-auth"]);
        assert_eq!(Codex::sign_in(&ctx, false).display_argv(), ["codex", "login"]);
        assert!(Codex::ACCOUNT_CONFIG.contains("mcp_oauth_credentials_store = \"file\""));
        let doc: toml::Table = toml::from_str(Codex::ACCOUNT_CONFIG).unwrap();
        assert_eq!(doc["mcp_oauth_credentials_store"].as_str(), Some("file"));
    }

    #[test]
    fn launch_turns_on_osc9_notifications() {
        let spec = Codex::new().launch(&test_context(), &LaunchMode::Fresh { session_id: None });
        assert_eq!(
            spec.display_argv(),
            [
                "codex",
                "-c",
                r#"tui.notifications=["approval-requested","agent-turn-complete"]"#,
                "-c",
                r#"tui.notification_method="osc9""#,
                "-c",
                r#"tui.notification_condition="always""#,
                "-c",
                r#"mcp_servers.unnamed.command="/opt/un/bin/un-hook""#,
                "-c",
                r#"mcp_servers.unnamed.args=["mcp","--state","/state","--pane","p_9f2"]"#,
            ]
        );
        assert!(spec.files.is_empty());
        assert!(spec.env.iter().any(|(k, _)| k == "UN_HOOK"));
    }

    #[test]
    fn resume_appends_the_subcommand() {
        let spec = Codex::new().launch(
            &test_context(),
            &LaunchMode::Resume {
                session_id: NativeSessionId::new("0199a213"),
            },
        );
        assert_eq!(spec.display_argv()[11..], ["resume", "0199a213"]);
    }

    #[test]
    fn mcp_overrides_are_valid_toml_for_any_path() {
        let mut ctx = test_context();
        ctx.hook_bin = r#"/Users/A "B"\x/un-hook"#.into();
        ctx.state_dir = "/Users/A B/Library/Application Support/unnamed".into();
        let mut doc = toml::Table::new();
        for o in mcp_overrides(&ctx) {
            let (key, value) = o.split_once('=').unwrap();
            let value: toml::Table = toml::from_str(&format!("v = {value}")).unwrap();
            doc.insert(key.rsplit('.').next().unwrap().into(), value["v"].clone());
        }
        assert_eq!(doc["command"].as_str(), Some(r#"/Users/A "B"\x/un-hook"#));
        let args: Vec<&str> = doc["args"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a.as_str().unwrap())
            .collect();
        assert_eq!(
            args,
            [
                "mcp",
                "--state",
                "/Users/A B/Library/Application Support/unnamed",
                "--pane",
                "p_9f2"
            ]
        );
    }

    #[test]
    fn hooks_map_to_signals() {
        let start = hook(fixture!("session_start"));
        assert_eq!((start.kind, start.claim), (EventKind::SessionStarted, None));
        assert_eq!(
            start.session.native_id.unwrap().as_str(),
            "0199a213-81c0-7800-8aa1-bbab2a035a53"
        );

        assert_eq!(
            hook(fixture!("user_prompt_submit")).claim,
            Some(Claim::Working)
        );

        let Some(Claim::Blocked(b)) = hook(fixture!("permission_request")).claim else {
            panic!()
        };
        assert_eq!(b.summary.as_deref(), Some("cargo publish --dry-run"));
        assert_eq!(b.answer_paths[0], AnswerPath::HookDecision);

        let stop = hook(fixture!("stop"));
        assert_eq!(
            (stop.kind, stop.claim),
            (EventKind::TurnEnded, Some(Claim::Idle))
        );

        let interrupt = hook(fixture!("interrupt"));
        assert_eq!(interrupt.kind, EventKind::Interrupted);
        assert_eq!(interrupt.turn.unwrap().outcome, TurnOutcome::Cancelled);
    }

    #[test]
    fn osc9_approvals_block() {
        let s = parse_osc9("Approval requested: cargo publish --dry-run").unwrap();
        assert_eq!((s.source, s.confidence), (Source::Osc9, Confidence::Strong));
        let Some(Claim::Blocked(b)) = s.claim else {
            panic!()
        };
        assert_eq!(b.reason, BlockedReason::Permission);
        assert_eq!(b.summary.as_deref(), Some("cargo publish --dry-run"));

        let Some(Claim::Blocked(edit)) =
            parse_osc9("Codex wants to edit src/main.rs").unwrap().claim
        else {
            panic!()
        };
        assert_eq!(edit.tool.as_deref(), Some("apply_patch"));

        let Some(Claim::Blocked(mcp)) = parse_osc9("Approval requested by github").unwrap().claim
        else {
            panic!()
        };
        assert_eq!(mcp.reason, BlockedReason::Elicitation);

        let Some(Claim::Blocked(q)) = parse_osc9("Question: Which database?").unwrap().claim else {
            panic!()
        };
        assert_eq!(q.reason, BlockedReason::Question);
    }

    #[test]
    fn osc9_other_text_is_a_weak_turn_end() {
        let s = parse_osc9("Fixed the failing test and pushed the branch.").unwrap();
        assert_eq!(
            (s.kind, s.confidence),
            (EventKind::TurnEnded, Confidence::Weak)
        );
        assert_eq!(
            s.turn.unwrap().last_message.as_deref(),
            Some("Fixed the failing test and pushed the branch.")
        );
        assert_eq!(
            parse_osc9("Agent turn complete")
                .unwrap()
                .turn
                .unwrap()
                .last_message,
            None
        );
    }

    #[test]
    fn osc9_progress_is_not_a_notification() {
        assert_eq!(parse_osc9("4;1;50"), None);
        assert_eq!(parse_osc9("4;0"), None);
    }

    fn screen(screen: &str, title: &str) -> (AgentState, Option<String>) {
        match Codex::new().detect_screen(ScreenInput {
            screen,
            osc_title: title,
            osc_progress: "",
        }) {
            ScreenVerdict::State(m) => (m.state, m.rule_id),
            ScreenVerdict::Freeze { rule_id } => (AgentState::Unknown, Some(rule_id)),
        }
    }

    #[test]
    fn title_signals() {
        assert_eq!(screen("", "[ ! ] Action Required").0, AgentState::Blocked);
        assert_eq!(screen("", "⠋ app").0, AgentState::Working);
        assert_eq!(screen("", "app").0, AgentState::Idle);
    }

    #[test]
    fn screen_working_timer_and_approval() {
        let working = "• Ran cargo test\n• Working (12s • esc to interrupt)\n› ";
        assert_eq!(screen(working, "").0, AgentState::Working);

        let approval = "› fix the tests\n\n  Would you like to run the following command?\n  $ cargo publish\n\n  Allow command?\n  › 1. Yes, proceed (y)\n    2. No (esc)\n\n  Press enter to confirm or esc to cancel";
        assert_eq!(screen(approval, "").0, AgentState::Blocked);
    }

    #[test]
    fn screen_trust_dialog_blocks() {
        let trust = "> You are in /Users/me/src/app\n\n  Do you trust the contents of this directory?\n\n  › 1. Yes, continue\n    2. No, quit\n\n  Press enter to continue";
        assert_eq!(
            screen(trust, ""),
            (AgentState::Blocked, Some("trust_directory".into()))
        );
    }
}
