//! Claude Code's controls. A change restarts it on the same conversation: the launch script
//! runs Claude in a loop that asks the daemon, each time Claude exits, whether to start it
//! again and with which arguments (`gudo-hook claude-relaunch-pending` and `claude-relaunch`),
//! so the pane, its scrollback and its exit fence stay as they were.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use agents::{AgentAdapter, ClaudeCliOptions, ClaudeCode, ClaudeConfig, LaunchMode};
use proto::{
    AgentConfig, AgentConfigSupport, AgentConfigTiming, AgentConfigValues, AgentPlan, AgentPrompt,
    AgentQuestions, OptionId, PaneId, WsError,
};
use serde::{Deserialize, Serialize};

use crate::core::{Core, PaneEntry, lock};

/// How long a restarting Claude Code may take to come back before its exit counts as one.
const RELAUNCH_GRACE: Duration = Duration::from_secs(30);
/// How long after a turn ends a change that waited for it applies.
const TURN_SETTLE: Duration = Duration::from_millis(300);
/// How long `claude --help` may take.
const HELP_TIMEOUT: Duration = Duration::from_secs(5);
/// The most of `claude --help` read.
const MAX_HELP: usize = 256 * 1024;

/// A Claude Code the daemon launched in a pane that it can restart.
pub(crate) struct ClaudeLaunch {
    launch_id: String,
    context: agents::LaunchContext,
    session: String,
    /// It was started on an existing conversation.
    resumed: bool,
    display: bool,
    /// What the running process was started with.
    started: ClaudeConfig,
    pending: Option<AgentConfigValues>,
    relaunch: Option<Relaunch>,
    relaunched_at: Option<Instant>,
}

struct Relaunch {
    args: Vec<String>,
    display: bool,
}

impl ClaudeLaunch {
    pub fn new(
        launch_id: String,
        context: agents::LaunchContext,
        session: String,
        resumed: bool,
        display: bool,
    ) -> Self {
        Self {
            launch_id,
            context,
            session,
            resumed,
            display,
            started: ClaudeConfig::default(),
            pending: None,
            relaunch: None,
            relaunched_at: None,
        }
    }
}

/// A step of the launch script's restart loop, sent by the shim on the hook socket.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelaunchCall {
    pub claude_relaunch: RelaunchStep,
    pub token: String,
    pub pane: PaneId,
    pub launch: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RelaunchStep {
    /// Claude exited: is it to start again?
    Pending,
    /// The arguments to start it with.
    Take,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RelaunchReply {
    /// Nothing waits; the pane goes on to its shell.
    None,
    /// A restart waits.
    Waiting,
    /// Start `claude` with `args`, through the display helper when `display`.
    Launch { args: Vec<String>, display: bool },
}

/// What the installed `claude` accepts, read once.
#[derive(Default)]
pub(super) struct CliOptions(Mutex<Option<ClaudeCliOptions>>);

impl CliOptions {
    pub async fn load(&self, core: &Core) {
        if lock(&self.0).is_some() {
            return;
        }
        if let Some(options) = probe(core).await {
            *lock(&self.0) = Some(options);
        }
    }

    fn get(&self) -> ClaudeCliOptions {
        lock(&self.0).clone().unwrap_or_default()
    }
}

async fn probe(core: &Core) -> Option<ClaudeCliOptions> {
    let path = core.ws.terminal_path.cached(&core.cfg).await;
    let program = crate::ws::installs::check(&core.cfg, path.clone())
        .into_iter()
        .find(|install| install.agent == proto::AgentKind::Claude)
        .and_then(|install| match install.state {
            proto::InstallState::Installed { path } | proto::InstallState::NotOnPath { path } => {
                Some(path)
            }
            proto::InstallState::Missing => None,
        })?;
    let mut command = tokio::process::Command::new(program);
    command
        .arg("--help")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    if let Some(path) = path {
        command.env("PATH", path);
    }
    let output = tokio::time::timeout(HELP_TIMEOUT, command.output())
        .await
        .ok()?
        .ok()?;
    let help = &output.stdout[..output.stdout.len().min(MAX_HELP)];
    Some(ClaudeCliOptions::parse(&String::from_utf8_lossy(help)))
}

pub(super) fn is_config_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= proto::MAX_AGENT_CONFIG_ID
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-_.[]".contains(character))
}

pub(super) fn config(core: &Core, entry: &PaneEntry) -> AgentConfig {
    let options = core.agent_controls.claude_cli.get();
    let models = options.models();
    let reported = core.agent_controls.reported(entry.pane.id);
    let launch = lock(&entry.claude_launch);
    let started = launch.as_ref().map(|launch| &launch.started);
    let model = reported
        .model
        .map(|model| {
            models
                .iter()
                .find(|choice| model.contains(choice.id.as_str()))
                .map_or(model, |choice| choice.id.clone())
        })
        .or_else(|| started.and_then(|started| started.model.clone()));
    let current = AgentConfigValues {
        model,
        mode: reported
            .mode
            .or_else(|| started.and_then(|started| started.mode.clone())),
        effort: reported
            .effort
            .or_else(|| started.and_then(|started| started.effort.clone())),
    };
    let support = match launch.as_ref() {
        Some(_) => AgentConfigSupport::Supported,
        None => AgentConfigSupport::Unsupported(
            "Start Claude Code from Gudo to change its settings in Chat.".into(),
        ),
    };
    AgentConfig {
        support,
        current,
        pending: launch.as_ref().and_then(|launch| launch.pending.clone()),
        models,
        modes: options.mode_choices(),
        efforts: options.effort_choices(),
        timing: AgentConfigTiming::Restart,
    }
}

/// The question or plan a held hook waits on, with the options that answer it.
pub(super) fn prompt(core: &Core, entry: &PaneEntry) -> Option<AgentPrompt> {
    let held = core
        .hooks
        .held(entry.pane.id)
        .filter(|held| held.event == crate::agent::HeldEvent::PreToolUse)?;
    let (request_id, tool, choices) = lock(&entry.agent).as_mut()?.open_options()?;
    if tool.as_deref() != Some(held.tool.as_str()) {
        return None;
    }
    let option = |wanted: agents::ApprovalChoice| {
        choices
            .iter()
            .position(|choice| *choice == wanted)
            .map(|index| OptionId(index as u32))
    };
    let (allow, deny) = (
        option(agents::ApprovalChoice::AllowOnce)?,
        option(agents::ApprovalChoice::Deny)?,
    );
    if held.tool == agents::CLAUDE_QUESTION_TOOL {
        let questions = ClaudeCode::questions(&held.input);
        (!questions.is_empty()).then_some(AgentPrompt::Questions(AgentQuestions {
            request_id,
            questions,
            answer: allow,
            skip: deny,
        }))
    } else {
        Some(AgentPrompt::Plan(AgentPlan {
            request_id,
            plan: ClaudeCode::plan(&held.input)
                .unwrap_or_else(|| "The plan is in Terminal.".into()),
            approve: allow,
            keep_planning: deny,
        }))
    }
}

fn is_idle(entry: &PaneEntry) -> bool {
    let state = lock(&entry.agent)
        .as_ref()
        .map(crate::agent::AgentRuntime::state);
    matches!(
        state,
        Some(agents::AgentState::Idle | agents::AgentState::Unknown)
    ) && !lock(&entry.meta).in_turn
}

pub(super) fn set(
    core: &Core,
    entry: &PaneEntry,
    change: &AgentConfigValues,
) -> Result<(), WsError> {
    {
        let mut launch = lock(&entry.claude_launch);
        let launch = launch.as_mut().ok_or_else(|| {
            WsError::Unavailable("Start Claude Code from Gudo to change its settings.".into())
        })?;
        if launch.relaunch.is_some() {
            return Err(WsError::Conflict("Claude Code is restarting.".into()));
        }
        super::merge_values(launch.pending.get_or_insert_with(Default::default), change);
    }
    if is_idle(entry) {
        restart(core, entry)?;
    }
    Ok(())
}

fn waits_for_restart(entry: &PaneEntry) -> bool {
    lock(&entry.claude_launch)
        .as_ref()
        .is_some_and(|launch| launch.pending.is_some() && launch.relaunch.is_none())
}

pub(super) fn turn_ended(core: &Core, entry: &PaneEntry) {
    if !waits_for_restart(entry) {
        return;
    }
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        return;
    };
    let (core, pane) = (core.weak(), entry.pane.id);
    // The turn's end arrives in Claude Code's Stop hook; let it finish that first.
    runtime.spawn(async move {
        tokio::time::sleep(TURN_SETTLE).await;
        let Some(core) = core.upgrade() else {
            return;
        };
        let Some(entry) = core.pane(pane) else {
            return;
        };
        if waits_for_restart(&entry) && is_idle(&entry) {
            if let Err(error) = restart(&core, &entry) {
                tracing::warn!(%pane, "restarting Claude Code with new settings: {error}");
            }
            super::changed(&core, pane);
        }
    });
}

pub(super) fn is_relaunching(entry: &PaneEntry) -> bool {
    lock(&entry.claude_launch)
        .as_ref()
        .and_then(|launch| launch.relaunched_at)
        .is_some_and(|at| at.elapsed() < RELAUNCH_GRACE)
}

/// Asks Claude Code to exit, with the arguments of its next start waiting for the launch
/// script's loop.
fn restart(core: &Core, entry: &PaneEntry) -> Result<(), WsError> {
    let pane = entry.pane.id;
    let agent_pid = lock(&entry.agent)
        .as_ref()
        .and_then(crate::agent::AgentRuntime::pid)
        .or_else(|| {
            let pty = entry.pane.pty();
            pty.foreground_pgid().filter(|pgid| *pgid != pty.pid())
        })
        .ok_or_else(|| WsError::Unavailable("Claude Code is not running.".into()))?;
    let has_conversation = {
        let meta = lock(&entry.meta);
        meta.turns > 0 || meta.last_turn.is_some()
    };
    let session = lock(&entry.agent).as_ref().and_then(|runtime| {
        runtime
            .session()
            .native_id
            .as_ref()
            .map(|id| id.as_str().to_owned())
    });
    let mut launch = lock(&entry.claude_launch);
    let launch = launch
        .as_mut()
        .ok_or_else(|| WsError::Unavailable("Claude Code cannot restart here.".into()))?;
    let session = session.unwrap_or_else(|| launch.session.clone());
    let mode = if launch.resumed || has_conversation {
        LaunchMode::Resume {
            session_id: agents::NativeSessionId::new(session),
        }
    } else {
        LaunchMode::Fresh {
            session_id: Some(agents::NativeSessionId::new(session)),
        }
    };
    let mut next = AgentConfigValues {
        model: launch.started.model.clone(),
        mode: launch.started.mode.clone(),
        effort: launch.started.effort.clone(),
    };
    if let Some(pending) = &launch.pending {
        super::merge_values(&mut next, pending);
    }
    let config = ClaudeConfig {
        model: next.model,
        mode: next.mode,
        effort: next.effort,
    };
    let display_port = core
        .hooks
        .display_http
        .as_ref()
        .and_then(|listener| std::num::NonZeroU16::new(listener.port()));
    let mut spec = match display_port.filter(|_| launch.display) {
        Some(port) => crate::claude_display::prepare_launch(
            &launch.context,
            &mode,
            port,
            &core.hooks.display.token(pane),
        ),
        None => None,
    }
    .unwrap_or_else(|| ClaudeCode::new().launch(&launch.context, &mode));
    for file in &spec.files {
        if let Some(dir) = file.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        std::fs::write(&file.path, &file.contents)
            .map_err(|error| WsError::Failed(format!("{}: {error}", file.path.display())))?;
    }
    ClaudeCode::apply_config(&mut spec, &config);
    let display = spec.program != "claude";
    let args = spec
        .args
        .iter()
        .skip(usize::from(display))
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    let pid = libc::pid_t::try_from(agent_pid)
        .map_err(|_| WsError::Failed("Claude Code's process id is out of range".into()))?;
    // Armed before Claude exits, so the launch script's loop finds it.
    launch.relaunch = Some(Relaunch { args, display });
    launch.relaunched_at = Some(Instant::now());
    // SAFETY: kill has no memory preconditions; the pid is the pane's own foreground agent.
    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        launch.relaunch = None;
        launch.relaunched_at = None;
        return Err(WsError::Failed(std::io::Error::last_os_error().to_string()));
    }
    launch.started = config;
    launch.pending = None;
    // What the old process reported no longer holds; the new one reports its own.
    core.agent_controls.forget_reports(pane);
    tracing::info!(%pane, "restarting Claude Code with new settings");
    Ok(())
}

pub(super) fn serve_relaunch(core: &Core, call: RelaunchCall) -> RelaunchReply {
    if !core.hooks.verify(&call.token, &call.pane.0.to_string()) {
        return RelaunchReply::None;
    }
    let Some(entry) = core.pane(call.pane) else {
        return RelaunchReply::None;
    };
    let reply = {
        let mut launch = lock(&entry.claude_launch);
        let Some(launch) = launch
            .as_mut()
            .filter(|launch| launch.launch_id == call.launch)
        else {
            return RelaunchReply::None;
        };
        match (call.claude_relaunch, &launch.relaunch) {
            (_, None) => RelaunchReply::None,
            (RelaunchStep::Pending, Some(_)) => RelaunchReply::Waiting,
            (RelaunchStep::Take, Some(_)) => {
                let relaunch = launch.relaunch.take().expect("matched above");
                launch.relaunched_at = Some(Instant::now());
                RelaunchReply::Launch {
                    args: relaunch.args,
                    display: relaunch.display,
                }
            }
        }
    };
    super::changed(core, call.pane);
    reply
}
