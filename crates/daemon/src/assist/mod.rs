//! Input assistance for the mobile line editor: the foreground program per pane, the prompt
//! state and input line, atomic submit, persistent history, completion, file search for `@`
//! mentions and the options of a blocked agent.
//!
//! One task ([`run`]) samples the foreground process group of the panes clients show every
//! [`foreground::SAMPLE`] (the rest of their sessions' panes ten times less often) and, for
//! panes some connection watches, re-reads the prompt state whenever output arrived, pushing
//! changes; with no client connected it sleeps. Requests are answered by [`handle`]; the
//! policy check happens in the connection before it.

pub(crate) mod blocked;
pub(crate) mod complete;
pub(crate) mod files;
pub(crate) mod foreground;
mod histimport;
pub(crate) mod history;
pub(crate) mod line;
pub(crate) mod marks;
pub(crate) mod submit;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use proto::{
    Actor, AnswerBlocked, AssistError, AssistPush, AssistRequest, AssistResponse, BlockedChoice,
    BlockedOption, BlockedPrompt, BlockedSource, CommandMark, Foreground, InputPayload, Keymap,
    OptionId, PaneAssist, PaneId, ProgramProfile, PromptInput, PromptPhase, PromptState, Seq,
    ShellKind, SubmitLine,
};

use crate::config::Config;
use crate::core::{ConnId, Core, Event, PaneEntry, lock};
use marks::{LineView, Phase};

pub use history::HistoryConfig;

/// How often watched panes are checked for a changed prompt.
const PROMPT_TICK: Duration = Duration::from_millis(40);
/// Completion candidates returned at most.
const MAX_COMPLETIONS: usize = 200;

/// What a pane's terminal says about its prompt, copied out under the VT lock.
#[derive(Debug, Clone)]
pub(crate) struct LineSnapshot {
    pub view: LineView,
    pub screen: Option<line::Screen>,
    pub alt: bool,
    pub bracketed: bool,
    pub at_seq: Seq,
}

/// The input-assistance state owned by the core.
pub(crate) struct Assist {
    /// Connections watching each pane's prompt.
    watchers: Mutex<HashMap<PaneId, Vec<ConnId>>>,
    /// The last prompt state pushed per watched pane, with the output head it was read at.
    pushed: Mutex<HashMap<PaneId, (Seq, PromptState)>>,
    foreground: Mutex<HashMap<PaneId, foreground::Tracker>>,
    pub history: history::History,
    completion: complete::Caches,
    files: files::FileIndex,
}

impl Assist {
    pub fn new(config: &Config) -> Self {
        Self {
            watchers: Mutex::default(),
            pushed: Mutex::default(),
            foreground: Mutex::default(),
            history: history::History::open(
                &config.state_dir,
                config.history.clone(),
                &config.home(),
            ),
            completion: complete::Caches::default(),
            files: files::FileIndex::default(),
        }
    }

    /// Whether `conn` watches `pane`'s prompt.
    pub fn watching(&self, conn: ConnId, pane: PaneId) -> bool {
        lock(&self.watchers)
            .get(&pane)
            .is_some_and(|watchers| watchers.contains(&conn))
    }

    fn set_watch(&self, conn: ConnId, pane: PaneId, on: bool) {
        let mut watchers = lock(&self.watchers);
        let list = watchers.entry(pane).or_default();
        list.retain(|&watcher| watcher != conn);
        if on {
            list.push(conn);
        }
        if list.is_empty() {
            watchers.remove(&pane);
            lock(&self.pushed).remove(&pane);
        }
    }

    pub fn forget_conn(&self, conn: ConnId) {
        let mut watchers = lock(&self.watchers);
        watchers.retain(|_, list| {
            list.retain(|&watcher| watcher != conn);
            !list.is_empty()
        });
        let watched: Vec<PaneId> = watchers.keys().copied().collect();
        lock(&self.pushed).retain(|pane, _| watched.contains(pane));
    }

    fn reported(&self, pane: PaneId) -> Option<Foreground> {
        lock(&self.foreground)
            .get(&pane)
            .and_then(|tracker| tracker.current().cloned())
    }

    /// The pane's foreground program: the reported one, else read now (panes no client sees
    /// are not sampled).
    pub fn foreground(&self, entry: &PaneEntry) -> Option<Foreground> {
        self.reported(entry.pane.id).or_else(|| {
            entry
                .pane
                .pty()
                .foreground_process()
                .map(|process| foreground::foreground(entry.pane.id, process))
        })
    }
}

fn shell_kind(name: &str) -> ShellKind {
    match name
        .rsplit('/')
        .next()
        .unwrap_or(name)
        .trim_start_matches('-')
    {
        "zsh" => ShellKind::Zsh,
        "bash" => ShellKind::Bash,
        "fish" => ShellKind::Fish,
        _ => ShellKind::Other,
    }
}

/// The shell at the pane's prompt: the foreground program when it is a shell, else the
/// configured shell.
fn pane_shell(core: &Core, entry: &PaneEntry) -> ShellKind {
    match core.assist.foreground(entry) {
        Some(program) if program.profile == ProgramProfile::Shell => shell_kind(&program.name),
        _ => shell_kind(&core.cfg.shell().to_string_lossy()),
    }
}

fn state_of(pane: PaneId, snapshot: &LineSnapshot, shell: ShellKind) -> PromptState {
    let phase = match snapshot.view.phase {
        Phase::Running(id) => PromptPhase::Running { command_id: id },
        Phase::Prompt if !snapshot.alt => match &snapshot.screen {
            Some(screen) => {
                let input = line::read(screen, &snapshot.view);
                PromptPhase::AtPrompt(PromptInput {
                    confident: input.doubt.is_none(),
                    text: input.text,
                    cursor: input.cursor,
                    doubt: input.doubt,
                    suggestion: input.suggestion,
                    right_prompt: input.right_prompt,
                    shell,
                    bracketed_paste: snapshot.bracketed,
                    keymap: Keymap::Unknown,
                })
            }
            None => PromptPhase::AtPrompt(PromptInput {
                text: String::new(),
                cursor: 0,
                confident: false,
                doubt: Some(proto::InputDoubt::Unreadable),
                suggestion: None,
                right_prompt: false,
                shell,
                bracketed_paste: snapshot.bracketed,
                keymap: Keymap::Unknown,
            }),
        },
        _ => PromptPhase::Unknown,
    };
    PromptState {
        pane_id: pane,
        prompt_id: snapshot.view.prompt_id,
        at_seq: snapshot.at_seq,
        phase,
    }
}

/// The pane's prompt state now.
pub(crate) fn prompt_state(core: &Core, entry: &PaneEntry) -> PromptState {
    let snapshot = entry.pane.line_snapshot();
    state_of(entry.pane.id, &snapshot, pane_shell(core, entry))
}

fn pane_assist(core: &Core, entry: &PaneEntry) -> PaneAssist {
    PaneAssist {
        foreground: core.assist.foreground(entry),
        prompt: prompt_state(core, entry),
    }
}

/// Records a finished command in the history.
pub(crate) fn command_finished(core: &Core, entry: &PaneEntry, mark: &CommandMark) {
    let (Some(end), Some(command)) = (mark.finished, mark.command.as_deref()) else {
        return;
    };
    let private = entry.pane.command_private(mark.command_id);
    core.assist.history.record(
        command,
        private,
        mark.cwd.as_deref(),
        end.exit,
        end.duration_ms,
    );
}

/// Samples foregrounds and refreshes watched prompts until the daemon stops. Both are only
/// for clients: with none connected the task sleeps until one arrives.
pub(crate) async fn run(core: Arc<Core>) {
    let mut last_sample: Option<Instant> = None;
    let mut samples = 0u32;
    let mut reads = ProcessReads::default();
    loop {
        if core.connected_clients() == 0 {
            // Stale programs must not be reported to the next client as current.
            lock(&core.assist.foreground).clear();
            reads.clear();
            let arrived = core.client_arrived.notified();
            tokio::pin!(arrived);
            arrived.as_mut().enable();
            if core.connected_clients() == 0 {
                arrived.await;
            }
            last_sample = None;
            samples = 0;
            continue;
        }
        let watched = !lock(&core.assist.watchers).is_empty();
        tokio::time::sleep(if watched {
            PROMPT_TICK
        } else {
            foreground::SAMPLE
        })
        .await;
        if last_sample.is_none_or(|sampled_at| sampled_at.elapsed() >= foreground::SAMPLE) {
            last_sample = Some(Instant::now());
            samples += 1;
            // The first sample after a client arrives covers every pane.
            sample_foregrounds(&core, &mut reads, samples % ALL_PANES_EVERY == 1);
        }
        if watched {
            refresh_prompts(&core);
        }
    }
}

/// The last process read per pane, reused while its foreground group stays the same: the
/// group id is one syscall, the name and arguments are several plus an allocation.
#[derive(Default)]
struct ProcessReads(HashMap<PaneId, (u32, Instant, Option<pty::ForegroundProcess>)>);

impl ProcessReads {
    /// How long a read stands for an unchanged group (a program may `exec` in place).
    const REUSE: Duration = Duration::from_secs(1);

    fn clear(&mut self) {
        self.0.clear();
    }

    fn read(
        &mut self,
        id: PaneId,
        entry: &PaneEntry,
        now: Instant,
    ) -> Option<pty::ForegroundProcess> {
        let pty = entry.pane.pty();
        let Some(pgid) = pty.foreground_pgid() else {
            self.0.remove(&id);
            return None;
        };
        if let Some((seen, at, process)) = self.0.get(&id)
            && *seen == pgid
            && now.duration_since(*at) < Self::REUSE
        {
            return process.clone();
        }
        let process = pty::ForegroundProcess::of(pgid);
        self.0.insert(id, (pgid, now, process.clone()));
        process
    }
}

/// Panes on screen are sampled every [`foreground::SAMPLE`] (the key bar follows them); the
/// rest of the attached sessions' panes on every this many samples.
const ALL_PANES_EVERY: u32 = 10;

/// Samples the foreground of the panes clients show, or with `all` of every pane in an attached
/// session.
fn sample_foregrounds(core: &Core, reads: &mut ProcessReads, all: bool) {
    let now = Instant::now();
    let attached = core.attached_panes();
    let viewed = (!all).then(|| core.viewed_panes());
    // The process lookups happen before the trackers are locked.
    let samples: Vec<(PaneId, Option<pty::ForegroundProcess>)> = attached
        .iter()
        .filter(|(id, _)| viewed.as_ref().is_none_or(|viewed| viewed.contains(id)))
        .map(|(id, entry)| (*id, reads.read(*id, entry, now)))
        .collect();
    let mut changed = Vec::new();
    {
        let mut trackers = lock(&core.assist.foreground);
        if all {
            reads
                .0
                .retain(|pane, _| attached.iter().any(|(id, _)| id == pane));
            trackers.retain(|pane, _| attached.iter().any(|(id, _)| id == pane));
        }
        for (id, process) in samples {
            if let Some(program) = trackers.entry(id).or_default().sample(id, process, now) {
                changed.push(program);
            }
        }
    }
    for program in changed {
        core.emit(Event::Assist(AssistPush::Foreground(program)));
    }
}

fn refresh_prompts(core: &Core) {
    let watched: Vec<PaneId> = lock(&core.assist.watchers).keys().copied().collect();
    for pane in watched {
        let Some(entry) = core.pane(pane) else {
            lock(&core.assist.watchers).remove(&pane);
            lock(&core.assist.pushed).remove(&pane);
            continue;
        };
        let head = entry.pane.head();
        if lock(&core.assist.pushed)
            .get(&pane)
            .is_some_and(|(seen, _)| *seen == head)
        {
            continue;
        }
        let state = prompt_state(core, &entry);
        let changed = {
            let mut pushed = lock(&core.assist.pushed);
            let changed = pushed.get(&pane).is_none_or(|(_, last)| {
                last.prompt_id != state.prompt_id || last.phase != state.phase
            });
            pushed.insert(pane, (head, state.clone()));
            changed
        };
        if changed {
            core.emit(Event::Assist(AssistPush::Prompt(state)));
        }
    }
}

/// Who is asking.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Caller {
    pub conn: ConnId,
    pub actor: Actor,
}

fn pane_entry(core: &Core, pane: PaneId) -> Result<Arc<PaneEntry>, AssistError> {
    core.pane(pane).ok_or(AssistError::UnknownPane)
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, AssistError> + Send + 'static,
) -> Result<T, AssistError> {
    tokio::task::spawn_blocking(work)
        .await
        .unwrap_or_else(|error| Err(AssistError::Failed(error.to_string())))
}

/// Answers one request (already allowed by the policy).
pub(crate) async fn handle(
    core: &Arc<Core>,
    caller: Caller,
    request: AssistRequest,
) -> Result<AssistResponse, AssistError> {
    match request {
        AssistRequest::Watch { pane_id, watch } => {
            let entry = pane_entry(core, pane_id)?;
            core.assist.set_watch(caller.conn, pane_id, watch);
            let state = pane_assist(core, &entry);
            if watch {
                lock(&core.assist.pushed)
                    .insert(pane_id, (entry.pane.head(), state.prompt.clone()));
            }
            Ok(AssistResponse::State(state))
        }
        AssistRequest::State { pane_id } => {
            let entry = pane_entry(core, pane_id)?;
            Ok(AssistResponse::State(pane_assist(core, &entry)))
        }
        AssistRequest::SubmitLine(submit) => submit_line(core, caller, submit).await,
        AssistRequest::History(query) => {
            let core = Arc::clone(core);
            blocking(move || Ok(AssistResponse::History(core.assist.history.query(&query)))).await
        }
        AssistRequest::Complete(request) => {
            let entry = pane_entry(core, request.pane_id)?;
            let cwd = lock(&entry.meta).cwd.clone().map(PathBuf::from);
            let path_var = crate::procinfo::process_env_var(entry.pane.pty().pid(), "PATH")
                .map(Into::into)
                .or_else(|| core.cfg.pane_var("PATH"));
            let core = Arc::clone(core);
            blocking(move || {
                let context = complete::Context {
                    cwd,
                    home: core.cfg.home(),
                    path_var,
                    history: &core.assist.history,
                    limit: (request.limit as usize).clamp(1, MAX_COMPLETIONS),
                };
                let items = complete::complete(
                    &context,
                    &core.assist.completion,
                    &request.line,
                    request.cursor as usize,
                );
                Ok(AssistResponse::Completions(proto::Completions {
                    cwd: context.cwd.map(|cwd| cwd.to_string_lossy().into_owned()),
                    items,
                }))
            })
            .await
        }
        AssistRequest::FileSearch(search) => {
            let root =
                core.ws
                    .policy
                    .resolve_followed(&search.root)
                    .map_err(|error| match error {
                        proto::WsError::Denied(why) => AssistError::Denied(why),
                        proto::WsError::Invalid(why) => AssistError::Invalid(why),
                        other => AssistError::NotFound(other.to_string()),
                    })?;
            if !root.is_dir() {
                return Err(AssistError::NotFound(format!(
                    "{} is not a directory",
                    root.display()
                )));
            }
            let core = Arc::clone(core);
            blocking(move || {
                Ok(AssistResponse::Files(core.assist.files.search(
                    &root,
                    &search.query,
                    search.limit as usize,
                )))
            })
            .await
        }
        AssistRequest::BlockedOptions { pane_id } => {
            let entry = pane_entry(core, pane_id)?;
            Ok(AssistResponse::Blocked(blocked_prompt(core, &entry)))
        }
        AssistRequest::AnswerBlocked(answer) => answer_blocked(core, answer).await,
    }
}

/// Verifies the prompt, then writes clear + paste + Return in one write.
async fn submit_line(
    core: &Arc<Core>,
    caller: Caller,
    request: SubmitLine,
) -> Result<AssistResponse, AssistError> {
    let entry = pane_entry(core, request.pane_id)?;
    let snapshot = entry.pane.line_snapshot();
    let state = state_of(request.pane_id, &snapshot, pane_shell(core, &entry));
    // Sampled now, not the debounced report: a program started a moment ago owns the line.
    let shell_in_front = entry
        .pane
        .pty()
        .foreground_process()
        .is_some_and(|process| {
            ProgramProfile::classify(&process.name, &process.argv) == ProgramProfile::Shell
        });
    let at_prompt = matches!(state.phase, PromptPhase::AtPrompt(_))
        && state.prompt_id == request.prompt_id
        && !snapshot.view.continuation
        && shell_in_front;
    if !at_prompt {
        return Err(AssistError::NotAtPrompt(state));
    }
    submit::check(&request.text, snapshot.bracketed)
        .map_err(|error| AssistError::Invalid(error.to_string()))?;
    // One driver at a time: the same lease rule as raw input.
    if let Err(lease) = core.mp.input(core, request.pane_id, caller.actor) {
        core.emit(Event::Lease(lease));
        return Err(AssistError::Denied(
            "another participant holds this pane's control lease".into(),
        ));
    }
    let paste = entry.pane.encode_input(InputPayload::Paste(request.text));
    let at_seq = entry
        .pane
        .write(submit::bytes(&paste, request.run))
        .await
        .map_err(|_| AssistError::UnknownPane)?;
    Ok(AssistResponse::Submitted {
        prompt_id: request.prompt_id,
        at_seq,
    })
}

fn choice_of(choice: agents::ApprovalChoice) -> BlockedChoice {
    match choice {
        agents::ApprovalChoice::AllowOnce => BlockedChoice::AllowOnce,
        agents::ApprovalChoice::AllowSession => BlockedChoice::AllowSession,
        agents::ApprovalChoice::Deny => BlockedChoice::Deny,
    }
}

/// The blocked agent's options, from its hook when it holds the request open, with keys
/// from the menu on screen.
fn blocked_prompt(core: &Core, entry: &PaneEntry) -> Option<BlockedPrompt> {
    let pane = entry.pane.id;
    let detail = lock(&entry.agent)
        .as_mut()
        .map(|runtime| runtime.blocked_detail());
    let detail = detail?;
    let menu = blocked::parse_menu(&entry.pane.screen_text());
    let (request_id, summary, hook_options, hook_held) = match &detail {
        Some(blocked) => (
            Some(blocked.wire),
            blocked.summary.clone(),
            blocked.options.clone(),
            core.hooks.is_pending(pane, &blocked.request),
        ),
        None => (None, String::new(), Vec::new(), false),
    };
    if detail.is_none() && menu.is_empty() {
        return None;
    }
    let options: Vec<BlockedOption> = if !hook_options.is_empty() {
        hook_options
            .iter()
            .enumerate()
            .map(|(i, (label, choice))| {
                let choice = choice_of(*choice);
                // Keys from the screen menu: same position when the menus agree in size, else
                // the first entry meaning the same.
                let on_screen = if menu.len() == hook_options.len() {
                    menu.get(i)
                } else {
                    menu.iter().find(|item| item.choice == choice)
                };
                BlockedOption {
                    label: label.clone(),
                    choice,
                    option_id: hook_held.then_some(OptionId(i as u32)),
                    keys: on_screen.map(|item| item.keys.clone()).unwrap_or_default(),
                    selected: on_screen.is_some_and(|item| item.selected),
                }
            })
            .collect()
    } else {
        menu.iter()
            .map(|item| BlockedOption {
                label: item.label.clone(),
                choice: item.choice,
                option_id: None,
                keys: item.keys.clone(),
                selected: item.selected,
            })
            .collect()
    };
    if options.is_empty() && detail.is_none() {
        return None;
    }
    Some(BlockedPrompt {
        pane_id: pane,
        request_id: request_id.filter(|_| hook_held),
        summary,
        source: if hook_options.is_empty() {
            BlockedSource::Screen
        } else {
            BlockedSource::Hook
        },
        options,
    })
}

/// Picks a menu option by typing its keys, after re-reading the menu.
async fn answer_blocked(
    core: &Arc<Core>,
    answer: AnswerBlocked,
) -> Result<AssistResponse, AssistError> {
    let entry = pane_entry(core, answer.pane_id)?;
    if lock(&entry.agent).is_none() {
        return Err(AssistError::NotFound("no agent in this pane".into()));
    }
    let menu = blocked::parse_menu(&entry.pane.screen_text());
    let option = menu
        .get(answer.index as usize)
        .filter(|item| item.label == answer.label)
        .ok_or_else(|| {
            AssistError::NotFound(format!(
                "the dialog no longer offers {:?} as option {}",
                answer.label,
                answer.index + 1
            ))
        })?;
    if option.keys.is_empty() {
        return Err(AssistError::NotFound("that option has no key".into()));
    }
    entry
        .pane
        .write(option.keys.clone())
        .await
        .map_err(|_| AssistError::UnknownPane)?;
    Ok(AssistResponse::Done)
}
