//! Claude Code's controls. A change restarts it on the same conversation: the launch script
//! runs Claude in a loop that asks the daemon, each time Claude exits, whether to start it
//! again and with which arguments (`gudo-hook claude-relaunch-pending` and `claude-relaunch`),
//! so the pane, its scrollback and its exit fence stay as they were. A Claude Code without the
//! loop (started by hand, or launched by an older helper) stops, and the line that starts it
//! again is typed at its shell's prompt.

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
/// How often a restart typed at the prompt looks for the shell to be back.
const PROMPT_POLL: Duration = Duration::from_millis(50);

/// How a Claude Code starts again with new settings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Restarts {
    /// The launch script's loop starts it.
    InLoop,
    /// It was launched without the loop (by an older helper): once its shell is back, the
    /// loop is typed there, fenced like a launch.
    TypedLoop,
    /// It was started by hand: once its shell is back, `claude --resume` is typed there.
    ByHand,
}

/// A Claude Code in a pane that the daemon can restart.
pub(crate) struct ClaudeLaunch {
    restarts: Restarts,
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
    /// It stopped, and the line that starts it again waits for its shell's prompt.
    awaits_prompt: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Relaunch {
    args: Vec<String>,
    display: bool,
}

/// A launch's restart loop as one helper build hands it to the next.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct CarriedClaudeLaunch {
    launch_id: String,
    session: String,
    resumed: bool,
    display: bool,
    #[serde(default)]
    started: ClaudeConfig,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pending: Option<AgentConfigValues>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    relaunch: Option<Relaunch>,
}

impl ClaudeLaunch {
    pub fn new(
        launch_id: String,
        context: agents::LaunchContext,
        session: String,
        resumed: bool,
        display: bool,
        started: ClaudeConfig,
    ) -> Self {
        Self {
            restarts: Restarts::InLoop,
            launch_id,
            context,
            session,
            resumed,
            display,
            started,
            pending: None,
            relaunch: None,
            relaunched_at: None,
            awaits_prompt: false,
        }
    }

    /// What the next build needs to keep restarting it; only a launch in its loop has that.
    pub fn to_carried(&self) -> Option<CarriedClaudeLaunch> {
        (self.restarts == Restarts::InLoop).then(|| CarriedClaudeLaunch {
            launch_id: self.launch_id.clone(),
            session: self.session.clone(),
            resumed: self.resumed,
            display: self.display,
            started: self.started.clone(),
            pending: self.pending.clone(),
            relaunch: self.relaunch.clone(),
        })
    }

    pub fn from_carried(carried: CarriedClaudeLaunch, context: agents::LaunchContext) -> Self {
        Self {
            restarts: Restarts::InLoop,
            launch_id: carried.launch_id,
            context,
            session: carried.session,
            resumed: carried.resumed,
            display: carried.display,
            started: carried.started,
            pending: carried.pending,
            relaunched_at: carried.relaunch.as_ref().map(|_| Instant::now()),
            awaits_prompt: false,
            relaunch: carried.relaunch,
        }
    }
}

/// The launch script's restart loop for `launch_id`, with `shim` quoted for the shell.
pub(crate) fn relaunch_loop(shim: &str, launch_id: &str) -> String {
    let launch_id = crate::core::shell_quote(launch_id);
    format!(
        "while {shim} claude-relaunch-pending {launch_id} </dev/null; do {shim} claude-relaunch {launch_id}; done"
    )
}

/// How a running Claude Code the daemon has no launch for would restart: at its shell's
/// prompt, once its conversation is known.
fn restarts_at_prompt(entry: &PaneEntry) -> Option<Restarts> {
    running_session(entry)?;
    Some(if lock(&entry.pane.agent_input_gate).has_launch() {
        Restarts::TypedLoop
    } else {
        Restarts::ByHand
    })
}

/// The conversation of the Claude Code running in `entry`: as its hooks name it, else as its
/// record keeps it (a build that handed the pane over knew it, this one has heard no hook yet).
fn running_session(entry: &PaneEntry) -> Option<String> {
    let reported = {
        let agent = lock(&entry.agent);
        let runtime = agent
            .as_ref()
            .filter(|runtime| runtime.kind() == proto::AgentKind::Claude)?;
        runtime
            .session()
            .native_id
            .as_ref()
            .map(|id| id.as_str().to_owned())
    };
    reported.or_else(|| {
        lock(&entry.record)
            .agent
            .as_ref()
            .filter(|agent| agent.kind == proto::AgentKind::Claude)?
            .session_id
            .clone()
            .filter(|id| crate::claude_session::is_session_id(id))
    })
}

/// A restart at the prompt for the Claude Code running in `entry`, starting from what it runs
/// with now.
fn launch_at_prompt(
    core: &Core,
    entry: &PaneEntry,
    restarts: Restarts,
    current: &AgentConfigValues,
) -> Result<ClaudeLaunch, WsError> {
    let session = running_session(entry).ok_or_else(|| {
        WsError::Unavailable("Claude Code has not started its conversation yet.".into())
    })?;
    let cwd = lock(&entry.meta)
        .cwd
        .clone()
        .or_else(|| lock(&entry.record).cwd.clone())
        .unwrap_or_else(|| "/".into());
    let account = lock(&entry.record)
        .agent
        .as_ref()
        .and_then(|agent| agent.account.clone())
        .and_then(|account| core.ws.accounts.context(proto::AgentKind::Claude, &account))
        .unwrap_or_else(agents::AccountContext::system);
    let context = core
        .hooks
        .launch_context(entry.pane.id, cwd.into(), account);
    let mut launch = ClaudeLaunch::new(
        crate::agent::new_uuid(),
        context,
        session,
        true,
        restarts == Restarts::TypedLoop && core.cfg.claude_chat_streaming,
        ClaudeConfig {
            model: current.model.clone(),
            mode: current.mode.clone(),
            effort: current.effort.clone(),
        },
    );
    launch.restarts = restarts;
    Ok(launch)
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
    let current = current(core, entry, &models);
    let at_prompt = restarts_at_prompt(entry);
    let launch = lock(&entry.claude_launch);
    let restarts = launch.as_ref().map(|launch| launch.restarts).or(at_prompt);
    let support = match restarts {
        Some(_) => AgentConfigSupport::Supported,
        None => AgentConfigSupport::Unsupported(
            "Chat can change Claude Code once its conversation has started.".into(),
        ),
    };
    AgentConfig {
        support,
        current,
        pending: launch.as_ref().and_then(|launch| launch.pending.clone()),
        models,
        modes: options.mode_choices(),
        efforts: options.effort_choices(),
        timing: match restarts {
            Some(Restarts::ByHand) => AgentConfigTiming::RestartInPane,
            _ => AgentConfigTiming::Restart,
        },
        context: core.agent_controls.context(entry.pane.id),
    }
}

/// What the pane's Claude Code runs with: what it reports, else what it was started with.
fn current(core: &Core, entry: &PaneEntry, models: &[proto::AgentChoice]) -> AgentConfigValues {
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
    AgentConfigValues {
        model,
        mode: reported
            .mode
            .or_else(|| started.and_then(|started| started.mode.clone())),
        effort: reported
            .effort
            .or_else(|| started.and_then(|started| started.effort.clone())),
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
    let at_prompt = restarts_at_prompt(entry);
    let has_launch = lock(&entry.claude_launch).is_some();
    let new_launch = match at_prompt.filter(|_| !has_launch) {
        Some(restarts) => {
            let models = core.agent_controls.claude_cli.get().models();
            let current = current(core, entry, &models);
            Some(launch_at_prompt(core, entry, restarts, &current)?)
        }
        None => None,
    };
    {
        let mut launch = lock(&entry.claude_launch);
        if launch.is_none() {
            *launch = new_launch;
        }
        let launch = launch.as_mut().ok_or_else(|| {
            WsError::Unavailable(
                "Chat can change Claude Code once its conversation has started.".into(),
            )
        })?;
        if launch.relaunch.is_some() || launch.awaits_prompt {
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

/// Asks Claude Code to exit, with what starts it again waiting: the arguments for the launch
/// script's loop, or the line to type at its shell's prompt.
fn restart(core: &Core, entry: &PaneEntry) -> Result<(), WsError> {
    let pane = entry.pane.id;
    let agent_pid = {
        let pty = entry.pane.pty();
        pty.foreground_pgid().filter(|pgid| *pgid != pty.pid())
    }
    .or_else(|| {
        lock(&entry.agent)
            .as_ref()
            .and_then(crate::agent::AgentRuntime::pid)
    })
    .ok_or_else(|| WsError::Unavailable("Claude Code is not running.".into()))?;
    let session = running_session(entry)
        .or_else(|| {
            lock(&entry.claude_launch)
                .as_ref()
                .map(|launch| launch.session.clone())
        })
        .ok_or_else(|| WsError::Unavailable("Claude Code cannot restart here.".into()))?;
    let has_conversation = {
        let meta = lock(&entry.meta);
        meta.turns > 0 || meta.last_turn.is_some()
    } || crate::core::agent_dir(core, entry, proto::AgentKind::Claude)
        .and_then(|dir| crate::claude_session::find_transcript(&dir, &session))
        .is_some();
    let (config, typed) = {
        let mut launch = lock(&entry.claude_launch);
        let launch = launch
            .as_mut()
            .ok_or_else(|| WsError::Unavailable("Claude Code cannot restart here.".into()))?;
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
        let (relaunch, typed) = match launch.restarts {
            Restarts::ByHand => (None, Some(typed_by_hand(&mode, &config))),
            Restarts::InLoop | Restarts::TypedLoop => {
                let relaunch = loop_relaunch(core, pane, launch, &mode, &config)?;
                let typed = (launch.restarts == Restarts::TypedLoop).then(|| {
                    let shim = crate::core::shell_quote(&launch.context.hook_bin.to_string_lossy());
                    typed_loop(&shim, &launch.launch_id)
                });
                (Some(relaunch), typed)
            }
        };
        let pid = libc::pid_t::try_from(agent_pid)
            .map_err(|_| WsError::Failed("Claude Code's process id is out of range".into()))?;
        // Armed before Claude exits, so the launch script's loop finds it.
        launch.relaunch = relaunch;
        launch.relaunched_at = Some(Instant::now());
        launch.awaits_prompt = typed.is_some();
        // SAFETY: kill has no memory preconditions; the pid is the pane's own foreground agent.
        if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
            launch.relaunch = None;
            launch.relaunched_at = None;
            launch.awaits_prompt = false;
            return Err(WsError::Failed(std::io::Error::last_os_error().to_string()));
        }
        launch.started = config.clone();
        launch.pending = None;
        (config, typed)
    };
    // What the old process reported no longer holds; the new one reports its own.
    core.agent_controls.forget_reports(pane);
    if let Some(agent) = lock(&entry.record).agent.as_mut() {
        agent.config = (!config.is_empty()).then_some(config);
    }
    core.mark_dirty();
    if let Some(line) = typed {
        type_at_prompt(core, pane, line);
    }
    tracing::info!(%pane, "restarting Claude Code with new settings");
    Ok(())
}

/// The arguments the launch script's loop starts Claude Code with, its support files written.
fn loop_relaunch(
    core: &Core,
    pane: PaneId,
    launch: &ClaudeLaunch,
    mode: &LaunchMode,
    config: &ClaudeConfig,
) -> Result<Relaunch, WsError> {
    let display_port = core
        .hooks
        .display_http
        .as_ref()
        .and_then(|listener| std::num::NonZeroU16::new(listener.port()));
    let mut spec = match display_port.filter(|_| launch.display) {
        Some(port) => crate::claude_display::prepare_launch(
            &launch.context,
            mode,
            port,
            &core.hooks.display.token(pane),
        ),
        None => None,
    }
    .unwrap_or_else(|| ClaudeCode::new().launch(&launch.context, mode));
    for file in &spec.files {
        if let Some(dir) = file.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        std::fs::write(&file.path, &file.contents)
            .map_err(|error| WsError::Failed(format!("{}: {error}", file.path.display())))?;
    }
    ClaudeCode::apply_config(&mut spec, config);
    let display = spec.program != "claude";
    let args = spec
        .args
        .iter()
        .skip(usize::from(display))
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    Ok(Relaunch { args, display })
}

/// `claude --resume <session>` with the settings, as the user would type it.
fn typed_by_hand(mode: &LaunchMode, config: &ClaudeConfig) -> String {
    debug_assert!(
        matches!(mode, LaunchMode::Resume { .. }),
        "a Claude Code started by hand restarts on its conversation"
    );
    let session = match mode {
        LaunchMode::Resume { session_id } => session_id.as_str(),
        LaunchMode::Fresh { session_id } => session_id
            .as_ref()
            .map_or("", agents::NativeSessionId::as_str),
    };
    std::iter::once("claude".to_owned())
        .chain(["--resume".to_owned(), session.to_owned()])
        .chain(
            config
                .args()
                .iter()
                .map(|arg| arg.to_string_lossy().into_owned()),
        )
        .map(|word| crate::core::shell_quote(&word))
        .collect::<Vec<_>>()
        .join(" ")
}

/// The launch script's fenced run of Claude Code in its loop, for typing at a prompt. A fence
/// that fails ends the shell rather than leave Chat's unread input to it, as a launch does.
fn typed_loop(shim: &str, launch_id: &str) -> String {
    let quoted = crate::core::shell_quote(launch_id);
    format!(
        "{shim} agent-input-arm {quoted} </dev/null; {shim} claude-relaunch {quoted}; {}; {shim} agent-exit-fence {quoted} || exit",
        relaunch_loop(shim, launch_id)
    )
}

/// Types `line` once the pane's own shell is back in the foreground, then the restart is no
/// longer waiting for it.
fn type_at_prompt(core: &Core, pane: PaneId, line: String) {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        return;
    };
    let core = core.weak();
    runtime.spawn(async move {
        let deadline = Instant::now() + RELAUNCH_GRACE;
        loop {
            tokio::time::sleep(PROMPT_POLL).await;
            let Some(core) = core.upgrade() else {
                return;
            };
            let Some(entry) = core.pane(pane) else {
                return;
            };
            let foreground = entry.pane.pty().foreground_process();
            if crate::core::is_own_shell(&entry, foreground.as_ref()) {
                {
                    let mut launch = lock(&entry.claude_launch);
                    let Some(launch) = launch.as_mut().filter(|launch| launch.awaits_prompt) else {
                        return;
                    };
                    launch.awaits_prompt = false;
                    if launch.restarts == Restarts::TypedLoop {
                        *lock(&entry.pane.agent_input_gate) =
                            crate::agent_input::AgentInputGate::pending(launch.launch_id.clone());
                        launch.restarts = Restarts::InLoop;
                    }
                }
                if let Err(error) = entry.pane.pty().try_write(format!("{line}\r").into_bytes()) {
                    tracing::warn!(%pane, "starting Claude Code again in its shell: {error}");
                }
                super::changed(&core, pane);
                return;
            }
            if Instant::now() > deadline {
                tracing::warn!(%pane, "Claude Code's shell never came back to start it again");
                if let Some(launch) = lock(&entry.claude_launch).as_mut() {
                    launch.awaits_prompt = false;
                }
                return;
            }
        }
    });
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
