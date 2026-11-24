//! Chat's agent controls (`proto::agent_control`, docs/CHAT.md "Agent controls"): the model,
//! permission mode and effort of the agent in a pane, and the questions and plans it holds
//! for an answer.
//!
//! Claude Code takes a new model, mode or effort only at start, so a change restarts it on the
//! same conversation once it is idle (`claude`); a change asked for mid-turn waits for the turn
//! to end. Codex takes them with the next turn started from Chat (`agent_driver::codex`). pi
//! reports that Chat cannot change it yet.

mod claude;

use std::collections::HashMap;
use std::sync::Mutex;

use proto::{
    AgentChoice, AgentConfig, AgentConfigSupport, AgentConfigTiming, AgentConfigValues,
    AgentControls, AgentKind, PaneId, QuestionAnswer, WsError,
};
use serde_json::Value;

pub(crate) use claude::{CarriedClaudeLaunch, ClaudeLaunch, relaunch_loop};
pub use claude::{RelaunchCall, RelaunchReply, RelaunchStep};

use crate::core::{ConnId, Core, Event, PaneEntry, lock};

/// Most questions one answer may carry.
const MAX_ANSWERS: usize = 16;

#[derive(Clone, Copy)]
struct Watcher {
    conn: ConnId,
    /// Whether the connection may answer the pane's questions and plans.
    answers: bool,
}

/// Who watches which pane's controls, and what agents reported about themselves.
#[derive(Default)]
pub(crate) struct AgentControlsHub {
    watchers: Mutex<HashMap<PaneId, Vec<Watcher>>>,
    /// Claude Code's own report of its model, mode and effort (hooks and status line).
    reported: Mutex<HashMap<PaneId, AgentConfigValues>>,
    claude_cli: claude::CliOptions,
}

impl AgentControlsHub {
    pub fn watch(&self, conn: ConnId, pane: PaneId, answers: bool) {
        let mut watchers = lock(&self.watchers);
        let list = watchers.entry(pane).or_default();
        list.retain(|watcher| watcher.conn != conn);
        list.push(Watcher { conn, answers });
    }

    pub fn unwatch(&self, conn: ConnId, pane: PaneId) {
        let mut watchers = lock(&self.watchers);
        if let Some(list) = watchers.get_mut(&pane) {
            list.retain(|watcher| watcher.conn != conn);
            if list.is_empty() {
                watchers.remove(&pane);
            }
        }
    }

    pub fn watching(&self, conn: ConnId, pane: PaneId) -> bool {
        lock(&self.watchers)
            .get(&pane)
            .is_some_and(|list| list.iter().any(|watcher| watcher.conn == conn))
    }

    /// Whether someone with Chat open could answer the pane's question or plan; otherwise the
    /// agent asks in its terminal as before.
    pub fn answerable(&self, pane: PaneId) -> bool {
        lock(&self.watchers)
            .get(&pane)
            .is_some_and(|list| list.iter().any(|watcher| watcher.answers))
    }

    pub fn forget_conn(&self, conn: ConnId) {
        lock(&self.watchers).retain(|_, list| {
            list.retain(|watcher| watcher.conn != conn);
            !list.is_empty()
        });
    }

    pub fn forget_pane(&self, pane: PaneId) {
        lock(&self.watchers).remove(&pane);
        lock(&self.reported).remove(&pane);
    }

    fn forget_reports(&self, pane: PaneId) {
        lock(&self.reported).remove(&pane);
    }

    fn reported(&self, pane: PaneId) -> AgentConfigValues {
        lock(&self.reported).get(&pane).cloned().unwrap_or_default()
    }

    /// Records what the agent says it runs with; returns whether that changed anything.
    fn report(&self, pane: PaneId, update: impl FnOnce(&mut AgentConfigValues)) -> bool {
        let mut reported = lock(&self.reported);
        let values = reported.entry(pane).or_default();
        let before = values.clone();
        update(values);
        *values != before
    }
}

/// Tells the pane's watchers its controls changed.
pub(crate) fn changed(core: &Core, pane: PaneId) {
    if lock(&core.agent_controls.watchers).contains_key(&pane) {
        core.emit(Event::AgentControls(pane));
    }
}

/// The pane's controls as a watcher sees them.
pub(crate) fn controls(core: &Core, pane: PaneId) -> Result<AgentControls, WsError> {
    let entry = core
        .pane(pane)
        .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
    let kind = crate::agent_driver::chat_agent(&entry)
        .ok_or_else(|| WsError::Unavailable("No agent runs in this pane.".into()))?;
    let config = match kind {
        AgentKind::Claude => claude::config(core, &entry),
        AgentKind::Codex => codex_config(&entry),
        AgentKind::Pi => pi_config(core, pane),
    };
    Ok(AgentControls {
        pane_id: pane,
        config,
        prompt: claude::prompt(core, &entry),
    })
}

/// Starts watching `pane` for `conn`, reading what the installed agent offers first.
pub(crate) async fn watch(
    core: &Core,
    conn: ConnId,
    pane: PaneId,
    answers: bool,
) -> Result<AgentControls, WsError> {
    let entry = core
        .pane(pane)
        .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
    match crate::agent_driver::chat_agent(&entry) {
        Some(AgentKind::Claude) => core.agent_controls.claude_cli.load(core).await,
        Some(AgentKind::Codex) => {
            if let Some(source) = lock(&entry.codex).clone() {
                source.load_models(core, pane);
            }
        }
        _ => {}
    }
    let controls = controls(core, pane)?;
    core.agent_controls.watch(conn, pane, answers);
    Ok(controls)
}

/// Changes the pane agent's model, mode or effort. The caller checked that the connection is
/// the owner's.
pub(crate) async fn set(
    core: &Core,
    pane: PaneId,
    change: &AgentConfigValues,
) -> Result<AgentControls, WsError> {
    let entry = core
        .pane(pane)
        .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
    let offered = controls(core, pane)?.config;
    if let AgentConfigSupport::Unsupported(reason) = &offered.support {
        return Err(WsError::Unavailable(reason.clone()));
    }
    check_change(&offered, change)?;
    match crate::agent_driver::chat_agent(&entry) {
        Some(AgentKind::Claude) => claude::set(core, &entry, change)?,
        Some(AgentKind::Codex) => {
            let source = lock(&entry.codex)
                .clone()
                .ok_or_else(|| WsError::Unavailable("Codex control is unavailable.".into()))?;
            source.set_config(change);
        }
        Some(AgentKind::Pi) => set_pi(core, pane, change).await?,
        _ => {
            return Err(WsError::Unavailable(
                "Chat cannot change this agent.".into(),
            ));
        }
    }
    changed(core, pane);
    controls(core, pane)
}

/// Sets in `into` what `change` sets.
pub(crate) fn merge_values(into: &mut AgentConfigValues, change: &AgentConfigValues) {
    for (value, changed) in [
        (&mut into.model, &change.model),
        (&mut into.mode, &change.mode),
        (&mut into.effort, &change.effort),
    ] {
        if changed.is_some() {
            value.clone_from(changed);
        }
    }
}

fn check_change(offered: &AgentConfig, change: &AgentConfigValues) -> Result<(), WsError> {
    fn offers(value: Option<&String>, choices: &[&AgentChoice]) -> bool {
        value.is_none_or(|value| choices.iter().any(|choice| &choice.id == value))
    }
    if change.model.is_none() && change.mode.is_none() && change.effort.is_none() {
        return Err(WsError::Invalid("nothing to change".into()));
    }
    let models: Vec<_> = offered.models.iter().collect();
    let modes: Vec<_> = offered.modes.iter().map(|mode| &mode.choice).collect();
    let efforts: Vec<_> = offered.efforts.iter().collect();
    let fits = offers(change.model.as_ref(), &models)
        && offers(change.mode.as_ref(), &modes)
        && offers(change.effort.as_ref(), &efforts);
    if fits {
        Ok(())
    } else {
        Err(WsError::Invalid("the agent does not offer that".into()))
    }
}

fn unsupported(reason: &str) -> AgentConfig {
    AgentConfig {
        support: AgentConfigSupport::Unsupported(reason.into()),
        current: AgentConfigValues::default(),
        pending: None,
        models: Vec::new(),
        modes: Vec::new(),
        efforts: Vec::new(),
        timing: AgentConfigTiming::NextTurn,
        context: None,
    }
}

/// pi changes its model and thinking level at once, through its bridge.
fn pi_config(core: &Core, pane: PaneId) -> AgentConfig {
    use crate::agent_driver::pi::config::{AgentConfigDriver, PiConfig};
    let config = match PiConfig.config(core, pane) {
        Ok(config) => config,
        Err(WsError::Unavailable(reason)) => return unsupported(&reason),
        Err(_) => return unsupported("Change pi's settings in Terminal."),
    };
    let effort_label = |effort: &str| {
        let mut characters = effort.chars();
        characters.next().map_or_else(String::new, |first| {
            first.to_uppercase().chain(characters).collect()
        })
    };
    AgentConfig {
        support: AgentConfigSupport::Supported,
        current: AgentConfigValues {
            model: config.model,
            mode: None,
            effort: config.effort,
        },
        pending: None,
        models: config
            .models
            .into_iter()
            .map(|model| AgentChoice {
                id: model.id,
                label: model.label,
                detail: String::new(),
            })
            .collect(),
        modes: Vec::new(),
        efforts: config
            .efforts
            .into_iter()
            .map(|effort| AgentChoice {
                label: effort_label(&effort),
                id: effort,
                detail: String::new(),
            })
            .collect(),
        timing: AgentConfigTiming::Now,
        context: config
            .context
            .map(|(used, window)| proto::AgentContextUsage { used, window }),
    }
}

/// Changes a connected pi's model or thinking level and waits for pi to take it.
async fn set_pi(core: &Core, pane: PaneId, change: &AgentConfigValues) -> Result<(), WsError> {
    use crate::agent_driver::pi::config::{AgentConfigDriver, PiConfig};
    if change.mode.is_some() {
        return Err(WsError::Invalid("pi has no permission modes".into()));
    }
    if let Some(model) = &change.model {
        PiConfig.set_model(core, pane, model)?.await?;
    }
    if let Some(effort) = &change.effort {
        PiConfig.set_effort(core, pane, effort)?.await?;
    }
    Ok(())
}

fn codex_config(entry: &PaneEntry) -> AgentConfig {
    match lock(&entry.codex).clone() {
        Some(source) if source.is_chat_ready() => source.config(),
        _ => unsupported("Start Codex from Gudo to change its settings in Chat."),
    }
}

/// A turn ended: a change that waited for it applies now.
pub(crate) fn turn_ended(core: &Core, pane: PaneId) {
    if let Some(entry) = core.pane(pane) {
        claude::turn_ended(core, &entry);
    }
}

/// Whether the pane's Claude Code is restarting with new settings, so its exit is not the
/// agent's.
pub(crate) fn is_relaunching(entry: &PaneEntry) -> bool {
    claude::is_relaunching(entry)
}

/// The pane's agent ended for good: nothing is left to restart.
pub(crate) fn agent_ended(core: &Core, entry: &PaneEntry) {
    if lock(&entry.claude_launch).take().is_some() {
        core.agent_controls.forget_reports(entry.pane.id);
        changed(core, entry.pane.id);
    }
}

/// Notes the permission mode a Claude Code hook reports.
pub(crate) fn note_hook(core: &Core, pane: PaneId, payload: &Value) {
    let Some(mode) = payload.get("permission_mode").and_then(Value::as_str) else {
        return;
    };
    if claude::is_config_id(mode)
        && core
            .agent_controls
            .report(pane, |values| values.mode = Some(mode.to_owned()))
    {
        changed(core, pane);
    }
}

/// Notes the model, effort and mode Claude Code's status line reports.
pub(crate) fn note_status_line(core: &Core, pane: PaneId, payload: &Value) {
    let field = |pointer: &str| {
        payload
            .pointer(pointer)
            .and_then(Value::as_str)
            .filter(|value| claude::is_config_id(value))
            .map(str::to_owned)
    };
    let (model, effort, mode) = (
        field("/model/id"),
        field("/effort/level"),
        field("/permission_mode"),
    );
    let changed_values = core.agent_controls.report(pane, |values| {
        if model.is_some() {
            values.model = model;
        }
        if effort.is_some() {
            values.effort = effort;
        }
        if mode.is_some() {
            values.mode = mode;
        }
    });
    if changed_values {
        changed(core, pane);
    }
}

/// Checks a question's answers before they reach the agent.
pub(crate) fn check_answers(answers: &[QuestionAnswer]) -> Result<(), String> {
    if answers.is_empty() || answers.len() > MAX_ANSWERS {
        return Err("answer between one and 16 questions".into());
    }
    let fits = answers.iter().all(|answer| {
        !answer.question.trim().is_empty()
            && !answer.answer.trim().is_empty()
            && answer.question.len() <= proto::MAX_AGENT_ANSWER
            && answer.answer.len() <= proto::MAX_AGENT_ANSWER
    });
    if fits {
        Ok(())
    } else {
        Err("every answer needs text, at most 16 KiB".into())
    }
}

/// Serves the launch script's restart steps (`gudo-hook claude-relaunch-pending` and
/// `claude-relaunch`).
pub(crate) fn serve_relaunch(core: &Core, call: RelaunchCall) -> RelaunchReply {
    claude::serve_relaunch(core, call)
}
