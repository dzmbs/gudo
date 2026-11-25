//! Agents the user types in a shell pane. The shell integration wraps `claude` in a function
//! that asks the daemon, through the hook shim, to start it as one it launches: the same
//! program and options, in the same terminal, with its hooks, a pinned session, Chat's controls
//! and a restore that keeps how it was started. The daemon declines what it cannot start that
//! way (a subcommand, print mode, an option it does not know), and the function runs the
//! program as typed. `command claude` skips the function.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::agent_config::TypedSession;
use crate::core::Core;

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

pub(crate) fn serve(core: &Core, call: TypedAgentCall) -> TypedAgentReply {
    let pane = call.pane;
    if !core.hooks.verify(&call.token, &pane.0.to_string()) || !core.cfg.hook_bin_runs() {
        return TypedAgentReply::Declined;
    }
    let Some(entry) = core.pane(pane) else {
        return TypedAgentReply::Declined;
    };
    let TypedAgent { program, args, cwd } = call.typed_agent;
    if program != "claude" || !cwd.is_absolute() {
        return TypedAgentReply::Declined;
    }
    let Some(typed) = parse_claude(&args) else {
        tracing::info!(%pane, program, "a typed agent runs as typed: its options are its own");
        return TypedAgentReply::Declined;
    };
    // One launch at a time: a pane already running an agent the daemon starts declines.
    if lock_has_launch(&entry) {
        return TypedAgentReply::Declined;
    }
    let context = core
        .hooks
        .launch_context(pane, cwd, agents::AccountContext::system());
    match crate::agent_config::typed_launch(
        core,
        &entry,
        context,
        typed.session,
        typed.config,
        typed.switches,
    ) {
        Ok(launch) => TypedAgentReply::Launch { launch },
        Err(error) => {
            tracing::warn!(%pane, "starting typed Claude Code through its launch: {error}");
            TypedAgentReply::Declined
        }
    }
}

fn lock_has_launch(entry: &crate::core::PaneEntry) -> bool {
    crate::core::lock(&entry.pane.agent_input_gate).has_launch()
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
}
