//! Agents the user types in a shell pane. The shell integration wraps `claude`, `codex` and `pi`
//! in functions that ask the daemon, through the hook shim, to start them as ones it launches:
//! the same program and options, in the same terminal, with their hooks, a pinned session where
//! the agent takes one, Chat's controls and Send, and a restore that keeps how they were
//! started. The daemon declines what it cannot start that way (a subcommand, print mode, an
//! option it does not know), and the function runs the program as typed, as `command claude`
//! does.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use std::sync::Arc;

use crate::agent_config::TypedSession;
use crate::core::{AgentRecord, Core, Event, PaneEntry, lock};
use crate::resumable::{ResumableAgent, ResumableProgram};

/// The shim asking to start what the user typed (`gudo-hook agent-typed <program> <args>…`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypedAgentCall {
    pub typed_agent: TypedAgent,
    pub token: String,
    pub pane: proto::PaneId,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypedAgent {
    pub program: String,
    pub args: Vec<String>,
    /// The shell's working directory.
    pub cwd: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TypedAgentReply {
    /// Run the launch's restart loop.
    Launch { launch: String },
    /// Run the program as typed.
    Declined,
}

/// Claude Code's options that take no value and that every start of it keeps.
const CLAUDE_SWITCHES: &[&str] = &[
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
    "--verbose",
    "--ide",
];

/// Claude Code typed with options the daemon starts it with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TypedClaude {
    pub session: TypedSession,
    pub config: agents::ClaudeConfig,
    pub switches: Vec<String>,
}

/// What `claude <args>` asks for, when it is an interactive session the daemon can start; any
/// other use (a prompt, a subcommand, print mode, an unknown option) is run as typed.
pub(crate) fn parse_claude(args: &[String]) -> Option<TypedClaude> {
    let mut session = None;
    let mut config = agents::ClaudeConfig::default();
    let mut switches = Vec::new();
    let mut arguments = args.iter();
    while let Some(argument) = arguments.next() {
        let (flag, inline) = match argument.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (argument.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| arguments.next().cloned())
                .filter(|value| !value.is_empty() && !value.starts_with('-'))
        };
        let chosen = match flag {
            "--resume" | "-r" => TypedSession::Resume(session_id(value()?)?),
            "--session-id" => TypedSession::Fresh(session_id(value()?)?),
            "--continue" | "-c" if inline.is_none() => TypedSession::Continue,
            "--model" => {
                config.model = Some(value()?);
                continue;
            }
            "--permission-mode" => {
                config.mode = Some(value()?);
                continue;
            }
            "--effort" => {
                config.effort = Some(value()?);
                continue;
            }
            switch if inline.is_none() && CLAUDE_SWITCHES.contains(&switch) => {
                if !switches.iter().any(|kept| kept == switch) {
                    switches.push(switch.to_owned());
                }
                continue;
            }
            _ => return None,
        };
        if session.replace(chosen).is_some() {
            return None;
        }
    }
    let session = session.unwrap_or_else(|| TypedSession::Fresh(crate::agent::new_uuid()));
    Some(TypedClaude {
        session,
        config,
        switches,
    })
}

fn session_id(id: String) -> Option<String> {
    crate::claude_session::is_session_id(&id).then(|| id.to_ascii_lowercase())
}

pub(crate) fn serve(core: &Arc<Core>, call: TypedAgentCall) -> TypedAgentReply {
    let pane = call.pane;
    if !core.hooks.verify(&call.token, &pane.0.to_string()) || !core.cfg.hook_bin_runs() {
        return TypedAgentReply::Declined;
    }
    let Some(entry) = core.pane(pane) else {
        return TypedAgentReply::Declined;
    };
    let TypedAgent { program, args, cwd } = call.typed_agent;
    // One launch at a time: a pane already running an agent the daemon starts declines.
    if !cwd.is_absolute() || lock(&entry.pane.agent_input_gate).has_launch() {
        return TypedAgentReply::Declined;
    }
    let context = core
        .hooks
        .launch_context(pane, cwd, agents::AccountContext::system());
    let started = match program.as_str() {
        "claude" => parse_claude(&args).map(|typed| {
            crate::agent_config::typed_launch(
                core,
                &entry,
                context,
                typed.session,
                typed.config,
                typed.switches,
            )
            .map_err(|error| error.to_string())
        }),
        "codex" => parse_codex(&args).map(|resume| start_codex(core, &entry, &context, resume)),
        "pi" => parse_pi(&args).map(|session| start_pi(core, &entry, &context, session)),
        _ => None,
    };
    match started {
        Some(Ok(launch)) => {
            tracing::info!(%pane, program, "a typed agent runs through its launch");
            TypedAgentReply::Launch { launch }
        }
        Some(Err(error)) => {
            tracing::warn!(%pane, program, "starting a typed agent through its launch: {error}");
            TypedAgentReply::Declined
        }
        None => {
            tracing::info!(%pane, program, "a typed agent runs as typed: its options are its own");
            TypedAgentReply::Declined
        }
    }
}

/// A Codex typed as `codex` or `codex resume <id>`: the session it resumes. Its own options
/// and subcommands run as typed; Chat sets the model and modes of one it launches.
pub(crate) fn parse_codex(args: &[String]) -> Option<Option<String>> {
    match args {
        [] => Some(None),
        [resume, id] if resume == "resume" && crate::resumable::is_session_id(id) => {
            Some(Some(id.clone()))
        }
        _ => None,
    }
}

/// How a typed pi starts: on its session, the newest in its directory, or a new one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PiStart {
    New,
    Session(String),
    Continue,
}

/// A pi typed with no options, `--session <id>` or `--continue`; anything else runs as typed.
pub(crate) fn parse_pi(args: &[String]) -> Option<PiStart> {
    let session =
        |id: &str| crate::resumable::is_session_id(id).then(|| PiStart::Session(id.to_owned()));
    match args {
        [] => Some(PiStart::New),
        [flag] if flag == "-c" || flag == "--continue" => Some(PiStart::Continue),
        [flag, id] if flag == "--session" => session(id),
        [flag] => session(flag.strip_prefix("--session=")?),
        _ => None,
    }
}

pub(crate) fn start_codex(
    core: &Arc<Core>,
    entry: &Arc<PaneEntry>,
    context: &agents::LaunchContext,
    resume: Option<String>,
) -> Result<String, String> {
    let mode = match &resume {
        Some(id) => agents::LaunchMode::Resume {
            session_id: agents::NativeSessionId::new(id.clone()),
        },
        None => agents::LaunchMode::Fresh { session_id: None },
    };
    let (source, spec) = if core.cfg.codex_chat {
        let (source, spec) = crate::agent_driver::codex::Live::start(context, &mode)
            .map_err(|error| error.to_string())?;
        (Some(source), spec)
    } else {
        (
            None,
            agents::AgentAdapter::launch(&agents::Codex::new(), context, &mode),
        )
    };
    let pane = entry.pane.id;
    let launch = crate::agent::new_uuid();
    *lock(&entry.typed_start) = Some(TypedStart::of(&launch, &spec));
    *lock(&entry.pane.agent_input_gate) = crate::agent_input::AgentInputGate::armed(launch.clone());
    if let Some(session) = &resume {
        core.ws
            .accounts
            .pin(proto::AgentKind::Codex, session, proto::SYSTEM_ACCOUNT);
    }
    lock(&entry.record).agent = Some(AgentRecord {
        kind: proto::AgentKind::Codex,
        session_id: resume,
        account: Some(proto::SYSTEM_ACCOUNT.into()),
        transcript: None,
        config: None,
        args: Vec::new(),
    });
    let adapter = crate::agent::adapter(proto::AgentKind::Codex);
    *lock(&entry.agent) = Some(match &source {
        Some(_) => crate::agent::AgentRuntime::structured(proto::AgentKind::Codex, pane, adapter),
        None => crate::agent::AgentRuntime::new(proto::AgentKind::Codex, pane, adapter, false),
    });
    if let Some(source) = source {
        *lock(&entry.codex) = Some(Arc::clone(&source));
        source.set_owner(core, entry);
    }
    core.mark_dirty();
    core.emit(Event::Accounts);
    core.emit(Event::PaneMeta(pane));
    Ok(launch)
}

pub(crate) fn start_pi(
    core: &Core,
    entry: &PaneEntry,
    context: &agents::LaunchContext,
    start: PiStart,
) -> Result<String, String> {
    let program = ResumableProgram::Pi;
    let session = match &start {
        PiStart::Session(id) => Some(id.clone()),
        PiStart::New | PiStart::Continue => None,
    };
    let mut argv = vec!["pi".to_owned()];
    match &start {
        PiStart::Session(id) => argv.extend(["--session".to_owned(), id.clone()]),
        PiStart::Continue => argv.push("--continue".to_owned()),
        PiStart::New => {}
    }
    let extension = crate::agent_driver::pi::bridge::install(&context.state_dir)
        .map_err(|error| error.to_string())?;
    argv.extend([
        "--extension".to_owned(),
        extension.to_string_lossy().into_owned(),
    ]);
    let launch = crate::agent::new_uuid();
    *lock(&entry.typed_start) = Some(TypedStart {
        launch: launch.clone(),
        argv,
        env: agents::pane_env(context)
            .into_iter()
            .map(|(name, value)| (name, value.to_string_lossy().into_owned()))
            .collect(),
        env_remove: Vec::new(),
    });
    *lock(&entry.pane.agent_input_gate) = crate::agent_input::AgentInputGate::armed(launch.clone());
    lock(&entry.record).resumable = Some(ResumableAgent {
        program,
        session_id: session,
        cwd: Some(context.cwd.to_string_lossy().into_owned()),
    });
    core.mark_dirty();
    core.emit(Event::PaneMeta(entry.pane.id));
    Ok(launch)
}

/// The program a typed Codex or pi starts as, its environment and what it leaves out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypedStart {
    pub launch: String,
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub env_remove: Vec<String>,
}

impl TypedStart {
    fn of(launch: &str, spec: &agents::LaunchSpec) -> Self {
        let pinned = spec
            .env_pinned
            .iter()
            .map(|(name, value)| (name.clone(), value.to_string_lossy().into_owned()));
        Self {
            launch: launch.to_owned(),
            argv: std::iter::once(&spec.program)
                .chain(&spec.args)
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect(),
            env: spec
                .env
                .iter()
                .map(|(name, value)| (name.clone(), value.to_string_lossy().into_owned()))
                .chain(pinned)
                .collect(),
            env_remove: spec.env_remove.clone(),
        }
    }
}

/// The shim taking a typed Codex's or pi's start (`gudo-hook agent-start <launch>`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypedStartCall {
    pub typed_start: String,
    pub token: String,
    pub pane: proto::PaneId,
}

pub(crate) fn serve_start(core: &Core, call: TypedStartCall) -> Option<TypedStart> {
    if !core.hooks.verify(&call.token, &call.pane.0.to_string()) {
        return None;
    }
    let entry = core.pane(call.pane)?;
    let mut start = lock(&entry.typed_start);
    if start.as_ref()?.launch != call.typed_start {
        return None;
    }
    start.take()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "e4ea3b84-6daf-4905-9510-2efcd840fd83";

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    #[test]
    fn an_interactive_session_with_known_options_is_started_through_its_launch() {
        let typed = parse_claude(&args(&[
            "--model",
            "opus",
            "--dangerously-skip-permissions",
            "--permission-mode=plan",
        ]))
        .unwrap();
        assert!(matches!(typed.session, TypedSession::Fresh(_)));
        assert_eq!(typed.config.model.as_deref(), Some("opus"));
        assert_eq!(typed.config.mode.as_deref(), Some("plan"));
        assert_eq!(typed.switches, ["--dangerously-skip-permissions"]);
        assert_eq!(
            parse_claude(&args(&["--resume", ID])).unwrap().session,
            TypedSession::Resume(ID.into())
        );
        assert_eq!(
            parse_claude(&args(&["-c"])).unwrap().session,
            TypedSession::Continue
        );
        assert_eq!(
            parse_claude(&args(&[&format!("--session-id={ID}")]))
                .unwrap()
                .session,
            TypedSession::Fresh(ID.into())
        );
    }

    #[test]
    fn anything_else_runs_as_typed() {
        for typed in [
            &["-p", "explain"][..],
            &["--print"],
            &["mcp", "list"],
            &["fix the bug"],
            &["--version"],
            &["-r"],
            &["--resume", "--model"],
            &["--resume", "not-a-session"],
            &["--model"],
            &["--settings", "/tmp/s.json"],
            &["-c", "--resume", ID],
        ] {
            assert_eq!(parse_claude(&args(typed)), None, "{typed:?}");
        }
    }

    #[test]
    fn codex_and_pi_sessions_run_through_their_launch_and_the_rest_as_typed() {
        let rollout = "0199a213-81c0-7800-8aa1-bbab2a035a53";
        assert_eq!(parse_codex(&args(&[])), Some(None));
        assert_eq!(
            parse_codex(&args(&["resume", rollout])),
            Some(Some(rollout.into()))
        );
        for typed in [
            &["exec", "fix it"][..],
            &["resume", "--last"],
            &["-m", "o3"],
            &["fix the bug"],
            &["login"],
        ] {
            assert_eq!(parse_codex(&args(typed)), None, "{typed:?}");
        }
        assert_eq!(parse_pi(&args(&[])), Some(PiStart::New));
        assert_eq!(parse_pi(&args(&["-c"])), Some(PiStart::Continue));
        assert_eq!(
            parse_pi(&args(&["--session", "0199-aaaa"])),
            Some(PiStart::Session("0199-aaaa".into()))
        );
        assert_eq!(
            parse_pi(&args(&["--session=0199-aaaa"])),
            Some(PiStart::Session("0199-aaaa".into()))
        );
        for typed in [
            &["-p", "hi"][..],
            &["--session", "--model"],
            &["--model", "x"],
            &["hello"],
        ] {
            assert_eq!(parse_pi(&args(typed)), None, "{typed:?}");
        }
    }
}
