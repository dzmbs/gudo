//! Chat sending to an agent the user started by hand, with no launch of the daemon's around it
//! (one started before the shell integration wrapped it, or with `command`). Chat can type into
//! a launched agent only, so the first send restarts it in its pane through its launch: once
//! it is idle, the agent is stopped and the pane's shell runs it again on the conversation it
//! was writing, with the options it was started with, fenced as a launch is. The message is
//! sent once that agent is up. Clients learn they may send this way from
//! `AgentCapabilities::SEND_AFTER_TAKEOVER`; one that does not know it keeps Chat read-only.

use std::sync::Arc;
use std::time::{Duration, Instant};

use proto::{AgentKind, WsError};

use crate::core::{Core, PaneEntry, lock};
use crate::resumable::ResumableProgram;
use crate::typed_agent::PiStart;

/// How long a send waits for the agent to finish its turn before it asks to send again.
const IDLE_WAIT: Duration = Duration::from_secs(20);
/// How long a stopped agent has to give its shell back, and a restarted one to come up.
const RESTART_WAIT: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(50);

/// What the pane shows as its agent starts again.
const NOTICE: &str = "Restarted here so Chat can send to it.";

/// The agent a pane runs by hand and how it starts again through its launch.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Plan {
    Claude(crate::typed_agent::TypedClaude),
    Codex(String),
    Pi(PiStart),
}

impl Plan {
    fn kind(&self) -> &'static str {
        match self {
            Self::Claude(_) => "claude",
            Self::Codex(_) => "codex",
            Self::Pi(_) => "pi",
        }
    }
}

/// Whether Chat may send to the pane's agent by restarting it through its launch.
pub(crate) fn is_possible(core: &Core, entry: &PaneEntry) -> bool {
    core.cfg.hook_bin_runs() && plan(entry).is_ok()
}

/// How the pane's hand-started agent starts again: its own options, on the conversation it
/// is writing.
fn plan(entry: &PaneEntry) -> Result<Plan, WsError> {
    if lock(&entry.pane.agent_input_gate).has_launch() {
        return Err(unavailable("Chat already sends to this agent."));
    }
    let foreground = entry
        .pane
        .pty()
        .foreground_process()
        .ok_or_else(|| unavailable("The agent is not running."))?;
    let options = foreground.argv.get(1..).unwrap_or_default();
    let running = crate::agent::running_agent(&foreground);
    let unknown = || unavailable("Chat cannot restart this agent: its options are its own.");
    match running {
        Some(AgentKind::Claude) => {
            let mut typed = crate::typed_agent::parse_claude(options).ok_or_else(unknown)?;
            let conversation = crate::agent_config::conversation(entry)
                .ok_or_else(|| unavailable("Claude Code has not started its conversation yet."))?;
            typed.session = crate::agent_config::TypedSession::Resume(conversation);
            Ok(Plan::Claude(typed))
        }
        Some(AgentKind::Codex) => {
            crate::typed_agent::parse_codex(options).ok_or_else(unknown)?;
            let session = lock(&entry.record)
                .agent
                .as_ref()
                .filter(|agent| agent.kind == AgentKind::Codex)
                .and_then(|agent| agent.session_id.clone())
                .ok_or_else(|| unavailable("Codex has not saved its conversation yet."))?;
            Ok(Plan::Codex(session))
        }
        _ if ResumableProgram::of(&foreground) == Some(ResumableProgram::Pi) => {
            let typed = crate::typed_agent::parse_pi(options).ok_or_else(unknown)?;
            let session = lock(&entry.record)
                .resumable
                .as_ref()
                .and_then(|agent| agent.session_id.clone());
            Ok(Plan::Pi(match (session, typed) {
                (Some(session), _) => PiStart::Session(session),
                (None, typed) => typed,
            }))
        }
        _ => Err(unavailable("Chat cannot send to this program.")),
    }
}

/// Restarts the pane's hand-started agent through its launch, so the send that asked can go
/// to it. Returns once the agent is up and Chat may type into it.
pub(crate) async fn take_over(core: &Arc<Core>, entry: &Arc<PaneEntry>) -> Result<(), WsError> {
    let pane = entry.pane.id;
    let _taking = Taking::start(pane)?;
    restart(core, entry).await
}

/// The panes whose agent a send is restarting: a second send waits for the first's.
static TAKING: std::sync::Mutex<Vec<proto::PaneId>> = std::sync::Mutex::new(Vec::new());

struct Taking(proto::PaneId);

impl Taking {
    fn start(pane: proto::PaneId) -> Result<Self, WsError> {
        let mut taking = lock(&TAKING);
        if taking.contains(&pane) {
            return Err(unavailable(
                "Chat is restarting the agent. Send again in a moment.",
            ));
        }
        taking.push(pane);
        Ok(Self(pane))
    }
}

impl Drop for Taking {
    fn drop(&mut self) {
        lock(&TAKING).retain(|pane| *pane != self.0);
    }
}

async fn restart(core: &Arc<Core>, entry: &Arc<PaneEntry>) -> Result<(), WsError> {
    let pane = entry.pane.id;
    let plan = plan(entry)?;
    wait_until_idle(entry).await?;
    let plan = plan_still(entry, plan)?;
    tracing::info!(%pane, program = plan.kind(), "Chat restarts the agent through its launch to send to it");
    stop_agent(entry).await?;
    let cwd = lock(&entry.meta)
        .cwd
        .clone()
        .or_else(|| lock(&entry.record).cwd.clone())
        .unwrap_or_else(|| "/".into());
    let context = core
        .hooks
        .launch_context(pane, cwd.into(), agents::AccountContext::system());
    let shim = crate::core::shell_quote(&context.hook_bin.to_string_lossy());
    let fish = crate::shell::Shell::detect(&core.cfg.shell()) == Some(crate::shell::Shell::Fish);
    let line = match plan {
        Plan::Claude(typed) => {
            let launch = crate::agent_config::typed_launch(
                core,
                entry,
                context,
                typed.session,
                typed.config,
                typed.switches,
            )?;
            claude_line(&shim, &launch, fish)
        }
        Plan::Codex(session) => {
            let launch = crate::typed_agent::start_codex(core, entry, &context, Some(session))
                .map_err(WsError::Failed)?;
            start_line(&shim, &launch, fish)
        }
        Plan::Pi(start) => {
            let launch = crate::typed_agent::start_pi(core, entry, &context, start)
                .map_err(WsError::Failed)?;
            start_line(&shim, &launch, fish)
        }
    };
    entry
        .pane
        .pty()
        .try_write(format!("{line}\r").into_bytes())
        .map_err(|error| WsError::Failed(format!("typing the restart: {error}")))?;
    wait_until_up(entry).await?;
    // It started with an empty input line: nothing typed there for the send to replace.
    let session = lock(&entry.agent)
        .as_ref()
        .and_then(|runtime| {
            runtime
                .session()
                .native_id
                .as_ref()
                .map(|id| id.as_str().to_owned())
        })
        .or_else(|| {
            lock(&entry.pane.agent_input_gate)
                .active_launch()
                .map(str::to_owned)
        });
    if let Some(session) = session {
        lock(&entry.pane.agent_input_gate).cleared_in_terminal(&session);
    }
    Ok(())
}

/// The plan again once the agent is idle: what it runs may have changed while it worked.
fn plan_still(entry: &PaneEntry, planned: Plan) -> Result<Plan, WsError> {
    let now = plan(entry)?;
    if std::mem::discriminant(&now) != std::mem::discriminant(&planned) {
        return Err(unavailable("The agent changed; send again."));
    }
    Ok(now)
}

async fn wait_until_idle(entry: &PaneEntry) -> Result<(), WsError> {
    let deadline = Instant::now() + IDLE_WAIT;
    loop {
        if is_idle(entry) {
            return Ok(());
        }
        if Instant::now() > deadline {
            return Err(unavailable(
                "The agent is working. Send again when it is done.",
            ));
        }
        tokio::time::sleep(POLL).await;
    }
}

fn is_idle(entry: &PaneEntry) -> bool {
    let agent_idle = lock(&entry.agent).as_ref().is_none_or(|runtime| {
        matches!(
            runtime.state(),
            agents::AgentState::Idle | agents::AgentState::Unknown
        ) && !runtime.is_blocked()
    });
    let meta = lock(&entry.meta);
    // pi reports its own state (OSC 7501); the others through their runtime.
    let reports_work = meta
        .program
        .as_ref()
        .is_some_and(|status| status.state == agents::ProgramState::Working);
    agent_idle && !meta.in_turn && !reports_work
}

/// Ends the agent and waits for its shell's prompt.
async fn stop_agent(entry: &PaneEntry) -> Result<(), WsError> {
    let pgid = {
        let pty = entry.pane.pty();
        pty.foreground_pgid().filter(|pgid| *pgid != pty.pid())
    }
    .ok_or_else(|| unavailable("The agent is not running."))?;
    let pgid = libc::pid_t::try_from(pgid)
        .map_err(|_| WsError::Failed("the agent's process id is out of range".into()))?;
    // SAFETY: kill has no memory preconditions; the group is the pane's own foreground agent.
    if unsafe { libc::killpg(pgid, libc::SIGTERM) } != 0 {
        return Err(WsError::Failed(std::io::Error::last_os_error().to_string()));
    }
    let deadline = Instant::now() + RESTART_WAIT;
    loop {
        let foreground = entry.pane.pty().foreground_process();
        if crate::core::is_own_shell(entry, foreground.as_ref()) {
            return Ok(());
        }
        if Instant::now() > deadline {
            return Err(WsError::Failed(
                "the agent did not stop; Chat could not restart it".into(),
            ));
        }
        tokio::time::sleep(POLL).await;
    }
}

/// Waits for the restarted agent to take input.
async fn wait_until_up(entry: &PaneEntry) -> Result<(), WsError> {
    let deadline = Instant::now() + RESTART_WAIT;
    loop {
        let foreground = entry.pane.pty().foreground_process();
        let runs_agent = foreground.as_ref().is_some_and(|process| {
            crate::agent::running_agent(process).is_some()
                || ResumableProgram::of(process).is_some()
        });
        let open = lock(&entry.pane.agent_input_gate).active_launch().is_some();
        let starting = crate::agent_config::is_starting(entry);
        if runs_agent && open && !starting && entry.pane.line_snapshot().bracketed {
            return Ok(());
        }
        if Instant::now() > deadline {
            return Err(WsError::Failed(
                "the restarted agent did not come up in time".into(),
            ));
        }
        tokio::time::sleep(POLL).await;
    }
}

/// The line that runs a Claude Code's launch at its shell's prompt: its restart loop, then the
/// exit fence, which ends the shell if it fails.
fn claude_line(shim: &str, launch: &str, fish: bool) -> String {
    let launch = crate::core::shell_quote(launch);
    let notice = crate::core::shell_quote(NOTICE);
    if fish {
        format!(
            " printf '%s\\n' {notice}; {shim} claude-relaunch {launch}; while {shim} claude-relaunch-pending {launch} </dev/null; {shim} claude-relaunch {launch}; end; {shim} agent-exit-fence {launch}; or exit"
        )
    } else {
        format!(
            " printf '%s\\n' {notice}; {shim} claude-relaunch {launch}; while {shim} claude-relaunch-pending {launch} </dev/null; do {shim} claude-relaunch {launch}; done; {shim} agent-exit-fence {launch} || exit"
        )
    }
}

/// The line that runs a Codex's or pi's launch at its shell's prompt, then the exit fence.
fn start_line(shim: &str, launch: &str, fish: bool) -> String {
    let launch = crate::core::shell_quote(launch);
    let notice = crate::core::shell_quote(NOTICE);
    let or_exit = if fish { "; or exit" } else { " || exit" };
    format!(
        " printf '%s\\n' {notice}; {shim} agent-start {launch}; {shim} agent-exit-fence {launch}{or_exit}"
    )
}

fn unavailable(message: &str) -> WsError {
    WsError::Unavailable(message.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// fish has no `do`/`done` and no `||`, POSIX shells no `end`/`or`: each gets its own.
    #[test]
    fn the_restart_line_parses_in_each_shell() {
        for (shell, fish) in [
            ("/bin/sh", false),
            ("bash", false),
            ("zsh", false),
            ("fish", true),
        ] {
            for line in [
                claude_line("'/x y/hook'", "launch-1", fish),
                start_line("'/x y/hook'", "launch-1", fish),
            ] {
                let Ok(output) = std::process::Command::new(shell)
                    .args(["-n", "-c", &line])
                    .output()
                else {
                    continue;
                };
                assert!(
                    output.status.success(),
                    "{shell}: {line}: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
            }
        }
    }
}
