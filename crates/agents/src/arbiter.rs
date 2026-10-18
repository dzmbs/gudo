//!
//! The [`Arbiter`] is a deterministic state machine. It never reads a clock: every input carries
//! `now`, and [`Arbiter::next_deadline`] says when the caller should call [`Arbiter::tick`] for the
//! time-based rules (blocked debounce, idle-prompt override, staleness).
//!
//! # Rules
//!
//! 1. **Process truth wins.** Once the agent process is gone the state is `unknown` and every claim
//!    is dropped; signals are ignored until [`Arbiter::process_started`].
//! 2. **Sequence ordering.** A signal whose `seq` is not newer than the last one accepted from the
//!    same source is dropped.
//! 3. **Confidence.** A claim replaces the current claim if it is at least as confident, or if both
//!    come from our hook shim (hook socket, OSC 7501) and its `seq` is newer, since they share one
//!    clock. A `Release` withdraws a claim from the same source or a weaker one.
//! 4. **Screen overrides.** Only *visible* screen matches override claims:
//!    - a visible blocker overrides a `working` claim at once, and an `idle`/`error` claim if it
//!      appeared after the claim;
//!    - a visible idle prompt that appeared after a `working`/`blocked` claim and lasted
//!      [`ArbiterConfig::idle_override`] wins (Claude cancel, answered-in-terminal);
//!    - with [`HookCoverage::Partial`] hooks, a visible working state that appeared after a
//!      `blocked`/`idle`/`error` claim wins at once (leaving `blocked` is confirmed by the screen).
//!
//!    Without a claim, the screen decides.
//! 5. **Staleness.** A `working` claim with no PTY output or newer signal for
//!    [`ArbiterConfig::stale_after`] is dropped.
//! 6. **Notifications.** Entering `blocked` notifies at once when the evidence is authoritative,
//!    else after it persists for [`ArbiterConfig::blocked_debounce`]. `working → idle|error` sets
//!    `unseen_done` and notifies unless a client is viewing the pane or the session was restored
//!    and has not worked since. Subagents never notify.
//! 7. **Single-response approvals.** The first valid [`Decision`] for a request wins; later ones
//!    get [`DecisionError::AlreadyDecided`] naming the winner.

use std::collections::HashMap;
use std::fmt;
use std::time::Duration;

use crate::adapter::HookCoverage;
use crate::event::{
    ActorId, AgentEvent, AgentState, AnswerPath, ApprovalChoice, Blocked, BlockedReason, Blocker,
    Confidence, Decided, Decision, EventKind, PaneId, RequestId, SchemaVersion, Seq, SessionInfo,
    Source, Status, UnixMillis,
};
use crate::manifest::{ScreenMatch, ScreenVerdict};
use crate::signal::{Claim, Signal};

/// Timing and trust settings for an [`Arbiter`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArbiterConfig {
    /// How far the agent's hooks are trusted.
    pub coverage: HookCoverage,
    /// How long a non-authoritative blocker must persist before it notifies. Default 1.5 s.
    pub blocked_debounce: Duration,
    /// How long a visible idle prompt must persist to override a stale claim. Default 2 s.
    pub idle_override: Duration,
    /// How long a `working` claim survives with no PTY output or newer signal. Default 30 min.
    pub stale_after: Duration,
}

impl ArbiterConfig {
    pub fn new(coverage: HookCoverage) -> Self {
        Self {
            coverage,
            blocked_debounce: Duration::from_millis(1500),
            idle_override: Duration::from_secs(2),
            stale_after: Duration::from_secs(30 * 60),
        }
    }
}

/// Something the user should be told about, typically by push.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notify {
    /// The agent needs the user.
    Blocked {
        /// The request to answer.
        request_id: RequestId,
    },
    /// A turn finished while nobody was looking.
    Done,
    /// A turn failed while nobody was looking.
    Failed,
}

/// The outcome of one arbiter input.
#[derive(Debug, Clone, Default, PartialEq)]
#[must_use]
pub struct Update {
    /// An event to append to the session log and fan out, if anything changed.
    pub event: Option<AgentEvent>,
    /// A notification to send, if one is due.
    pub notify: Option<Notify>,
}

/// Why a [`Decision`] was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecisionError {
    /// Someone already answered this request.
    AlreadyDecided {
        /// Who answered first.
        by: ActorId,
        /// What they chose.
        choice: ApprovalChoice,
    },
    /// The request is not the one currently showing (stale or unknown id).
    NotPending,
    /// The choice is not among the request's options.
    NotOffered,
}

impl fmt::Display for DecisionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyDecided { by, .. } => write!(f, "already decided by {by}"),
            Self::NotPending => f.write_str("request is no longer pending"),
            Self::NotOffered => f.write_str("choice is not offered for this request"),
        }
    }
}

impl std::error::Error for DecisionError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Process {
    Running,
    Exited,
}

#[derive(Debug, Clone)]
struct ClaimRecord {
    /// Never [`Claim::Release`].
    claim: Claim,
    source: Source,
    confidence: Confidence,
    seq: Option<Seq>,
    at: UnixMillis,
}

impl ClaimRecord {
    fn state(&self) -> AgentState {
        match self.claim {
            Claim::Working => AgentState::Working,
            Claim::Blocked(_) => AgentState::Blocked,
            Claim::Idle => AgentState::Idle,
            Claim::Error | Claim::Release => AgentState::Error,
        }
    }
}

#[derive(Debug, Clone)]
struct ScreenRecord {
    state: AgentState,
    visible: bool,
    source: Source,
    since: UnixMillis,
}

impl ScreenRecord {
    fn confidence(&self) -> Confidence {
        if self.visible {
            Confidence::Strong
        } else {
            Confidence::Weak
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BlockedNotify {
    Idle,
    Pending { since: UnixMillis },
    Sent,
}

/// What the evidence says, before request ids are assigned.
#[derive(Debug, Clone)]
enum Target {
    Working,
    Blocked(Blocker),
    Idle,
    Error,
    Unknown,
}

impl Target {
    fn from_screen(state: AgentState) -> Self {
        match state {
            AgentState::Working => Self::Working,
            AgentState::Blocked => {
                let mut blocker = Blocker::new(BlockedReason::Other);
                blocker.answer_paths = vec![AnswerPath::Keystrokes];
                Self::Blocked(blocker)
            }
            AgentState::Idle => Self::Idle,
            AgentState::Error => Self::Error,
            AgentState::Unknown => Self::Unknown,
        }
    }
}

struct Provenance {
    source: Source,
    confidence: Confidence,
}

/// What triggered a refresh, for the event it may produce.
struct Cause {
    source: Source,
    confidence: Confidence,
    seq: Option<Seq>,
    kind: Option<EventKind>,
    /// Emit an event even if the state did not change.
    force: bool,
    signal: Option<Signal>,
}

impl Cause {
    fn quiet(source: Source, confidence: Confidence) -> Self {
        Self {
            source,
            confidence,
            seq: None,
            kind: None,
            force: false,
            signal: None,
        }
    }
}

/// The arbitration state machine for one pane's agent session.
///
/// # Examples
///
/// ```
/// use agents::{
///     AgentKind, AgentState, Arbiter, ArbiterConfig, Claim, Confidence, EventKind, HookCoverage,
///     Lane, PaneId, SessionInfo, Signal, Source, UnixMillis,
/// };
///
/// let mut arbiter = Arbiter::new(
///     ArbiterConfig::new(HookCoverage::Partial),
///     Some(PaneId::new("p1")),
///     SessionInfo::new(AgentKind::Claude, Lane::Pty),
///     UnixMillis(0),
/// );
/// let prompt = Signal::new(Source::Hook, Confidence::Authoritative, EventKind::TurnStarted)
///     .with_claim(Claim::Working);
/// let update = arbiter.apply(prompt, UnixMillis(10));
/// assert_eq!(update.event.unwrap().kind, EventKind::TurnStarted);
/// assert_eq!(arbiter.status().state(), AgentState::Working);
/// ```
#[derive(Debug, Clone)]
pub struct Arbiter {
    config: ArbiterConfig,
    pane_id: Option<PaneId>,
    session: SessionInfo,
    process: Process,
    claim: Option<ClaimRecord>,
    screen: Option<ScreenRecord>,
    last_seq: HashMap<Source, Seq>,
    status: Status,
    next_request: u64,
    decided: Option<Decided>,
    blocked_notify: BlockedNotify,
    viewed: bool,
    unseen_done: bool,
    restored_unconfirmed: bool,
    last_activity: UnixMillis,
}

impl Arbiter {
    /// Creates an arbiter for a freshly launched session. The state is `unknown` until evidence
    /// arrives.
    pub fn new(
        config: ArbiterConfig,
        pane_id: Option<PaneId>,
        session: SessionInfo,
        now: UnixMillis,
    ) -> Self {
        Self {
            config,
            pane_id,
            session,
            process: Process::Running,
            claim: None,
            screen: None,
            last_seq: HashMap::new(),
            status: Status::Unknown,
            next_request: 1,
            decided: None,
            blocked_notify: BlockedNotify::Idle,
            viewed: false,
            unseen_done: false,
            restored_unconfirmed: false,
            last_activity: now,
        }
    }

    /// Creates an arbiter for a session resumed after a daemon restart. It starts `idle` and never
    pub fn restored(
        config: ArbiterConfig,
        pane_id: Option<PaneId>,
        session: SessionInfo,
        now: UnixMillis,
    ) -> Self {
        let mut arbiter = Self::new(config, pane_id, session, now);
        arbiter.status = Status::Idle;
        arbiter.restored_unconfirmed = true;
        arbiter
    }

    /// Returns the effective status.
    pub fn status(&self) -> &Status {
        &self.status
    }

    /// Returns the session facts gathered so far.
    pub fn session(&self) -> &SessionInfo {
        &self.session
    }

    /// Replaces the session's display resume argv (the adapter rebuilds it when the id changes).
    pub fn set_resume_argv(&mut self, argv: Vec<String>) {
        self.session.resume_argv = argv;
    }

    /// Returns whether a turn finished while nobody was viewing the pane.
    pub fn unseen_done(&self) -> bool {
        self.unseen_done
    }

    /// Returns whether this is a restored session that has not worked since.
    pub fn is_restored_unconfirmed(&self) -> bool {
        self.restored_unconfirmed
    }

    /// Returns the accepted decision for the current or most recent request.
    pub fn decided(&self) -> Option<&Decided> {
        self.decided.as_ref()
    }

    /// Records that a client is viewing the pane, which clears `unseen_done`.
    pub fn viewed(&mut self) {
        self.viewed = true;
        self.unseen_done = false;
    }

    /// Records that no client is viewing the pane any more.
    pub fn unviewed(&mut self) {
        self.viewed = false;
    }

    /// Records PTY output, which keeps a `working` claim from going stale.
    pub fn pty_output(&mut self, now: UnixMillis) {
        self.last_activity = self.last_activity.max(now);
    }

    /// Applies a parsed signal.
    pub fn apply(&mut self, signal: Signal, now: UnixMillis) -> Update {
        if self.process == Process::Exited {
            return Update::default();
        }
        if let Some(seq) = signal.seq {
            if self
                .last_seq
                .get(&signal.source)
                .is_some_and(|&last| seq <= last)
            {
                return Update::default();
            }
            self.last_seq.insert(signal.source, seq);
        }
        self.last_activity = self.last_activity.max(now);

        let mut force = signal.turn.is_some() || signal.subagent.is_some();
        if !signal.session.is_empty() {
            let update = &signal.session;
            if update.native_id.is_some() && update.native_id != self.session.native_id {
                force = true;
            }
            self.session.native_id = update.native_id.clone().or(self.session.native_id.take());
            self.session.transcript = update.transcript.clone().or(self.session.transcript.take());
            self.session.cwd = update.cwd.clone().or(self.session.cwd.take());
        }
        force |= matches!(
            signal.kind,
            EventKind::SessionStarted | EventKind::SessionIdChanged | EventKind::SessionEnded
        );

        let mut fresh_claim = false;
        if signal.subagent.is_none() {
            match &signal.claim {
                None => {}
                Some(Claim::Release) => {
                    if self.claim.as_ref().is_some_and(|cur| {
                        cur.source == signal.source || signal.confidence >= cur.confidence
                    }) {
                        self.claim = None;
                    }
                }
                Some(claim) => {
                    let accept = self.claim.as_ref().is_none_or(|cur| {
                        signal.confidence >= cur.confidence || shim_newer(cur, &signal)
                    });
                    if accept {
                        self.claim = Some(ClaimRecord {
                            claim: claim.clone(),
                            source: signal.source,
                            confidence: signal.confidence,
                            seq: signal.seq,
                            at: now,
                        });
                        fresh_claim = true;
                    }
                }
            }
        }

        let cause = Cause {
            source: signal.source,
            confidence: signal.confidence,
            seq: signal.seq,
            kind: Some(signal.kind),
            force,
            signal: Some(signal),
        };
        self.refresh(cause, fresh_claim, now)
    }

    /// Applies a screen-manifest verdict. Call it whenever the screen or title changes.
    pub fn observe_screen(&mut self, verdict: &ScreenVerdict, now: UnixMillis) -> Update {
        let ScreenVerdict::State(m) = verdict else {
            return Update::default();
        };
        if self.process == Process::Exited {
            return Update::default();
        }
        self.record_screen(m, now);
        let cause = Cause::quiet(
            m.source,
            if m.is_visible() {
                Confidence::Strong
            } else {
                Confidence::Weak
            },
        );
        self.refresh(cause, false, now)
    }

    /// Re-evaluates time-based rules. Call it at [`Arbiter::next_deadline`].
    pub fn tick(&mut self, now: UnixMillis) -> Update {
        let source = self.screen.as_ref().map_or(Source::Process, |s| s.source);
        self.refresh(Cause::quiet(source, Confidence::Weak), false, now)
    }

    /// Records that the agent is no longer the pane's foreground process.
    pub fn process_exited(&mut self, now: UnixMillis) -> Update {
        self.process = Process::Exited;
        self.claim = None;
        self.screen = None;
        let mut cause = Cause::quiet(Source::Process, Confidence::Authoritative);
        cause.kind = Some(EventKind::SessionEnded);
        self.refresh(cause, false, now)
    }

    /// Records that the agent is (again) the pane's foreground process.
    pub fn process_started(&mut self, now: UnixMillis) {
        self.process = Process::Running;
        self.last_activity = now;
    }

    /// Accepts the first valid decision for the showing request.
    ///
    /// The state stays `blocked` until evidence (a hook, the screen) shows the agent moved on.
    ///
    /// # Errors
    ///
    /// Returns [`DecisionError::AlreadyDecided`] if someone answered first,
    /// [`DecisionError::NotPending`] if the request is not the one showing, and
    /// [`DecisionError::NotOffered`] if the choice is not among its options.
    pub fn decide(
        &mut self,
        decision: Decision,
        now: UnixMillis,
    ) -> Result<Decided, DecisionError> {
        if let Some(d) = self
            .decided
            .as_ref()
            .filter(|d| d.request_id == decision.request_id)
        {
            return Err(DecisionError::AlreadyDecided {
                by: d.decided_by.clone(),
                choice: d.choice,
            });
        }
        let Status::Blocked(blocked) = &self.status else {
            return Err(DecisionError::NotPending);
        };
        if blocked.request_id != decision.request_id {
            return Err(DecisionError::NotPending);
        }
        if !blocked
            .blocker
            .options
            .iter()
            .any(|o| o.id == decision.choice)
        {
            return Err(DecisionError::NotOffered);
        }
        let decided = Decided {
            request_id: decision.request_id,
            choice: decision.choice,
            decided_by: decision.actor,
            at: now,
        };
        self.decided = Some(decided.clone());
        self.blocked_notify = BlockedNotify::Sent;
        Ok(decided)
    }

    /// Returns when [`Arbiter::tick`] should next run, if any time-based rule is armed.
    pub fn next_deadline(&self) -> Option<UnixMillis> {
        let mut deadlines = Vec::new();
        if let BlockedNotify::Pending { since } = self.blocked_notify {
            deadlines.push(since.saturating_add(self.config.blocked_debounce));
        }
        if let Some(claim) = &self.claim {
            if let Some(screen) = self.screen.as_ref().filter(|s| {
                s.visible
                    && s.state == AgentState::Idle
                    && s.since > claim.at
                    && matches!(claim.state(), AgentState::Working | AgentState::Blocked)
            }) {
                deadlines.push(screen.since.saturating_add(self.config.idle_override));
            }
            if claim.state() == AgentState::Working {
                deadlines.push(
                    self.last_activity
                        .max(claim.at)
                        .saturating_add(self.config.stale_after),
                );
            }
        }
        deadlines.into_iter().min()
    }

    fn record_screen(&mut self, m: &ScreenMatch, now: UnixMillis) {
        if m.state == AgentState::Unknown {
            self.screen = None;
            return;
        }
        let same = self
            .screen
            .as_ref()
            .is_some_and(|s| s.state == m.state && s.visible == m.is_visible());
        if same {
            if let Some(s) = &mut self.screen {
                s.source = m.source;
            }
        } else {
            self.screen = Some(ScreenRecord {
                state: m.state,
                visible: m.is_visible(),
                source: m.source,
                since: now,
            });
        }
    }

    /// Works out what the evidence says, dropping claims the screen has overruled.
    fn target(&mut self, now: UnixMillis) -> (Target, Provenance, bool) {
        if self.process == Process::Exited {
            let p = Provenance {
                source: Source::Process,
                confidence: Confidence::Authoritative,
            };
            return (Target::Unknown, p, false);
        }

        let mut stale = false;
        if let Some(claim) = &self.claim {
            let claim_state = claim.state();
            if let Some(screen) = self.screen.as_ref().filter(|s| s.visible) {
                let newer = screen.since > claim.at;
                let screen_wins = match (screen.state, claim_state) {
                    (AgentState::Blocked, AgentState::Working) => true,
                    (AgentState::Blocked, AgentState::Idle | AgentState::Error) => newer,
                    (AgentState::Idle, AgentState::Working | AgentState::Blocked) => {
                        newer && now.since(screen.since) >= self.config.idle_override
                    }
                    (
                        AgentState::Working,
                        AgentState::Blocked | AgentState::Idle | AgentState::Error,
                    ) => newer && self.config.coverage == HookCoverage::Partial,
                    _ => false,
                };
                if screen_wins {
                    // A visible blocker over a working claim is transient (the hook may still be
                    // right once the dialog closes); every other override retires the claim.
                    if !(screen.state == AgentState::Blocked && claim_state == AgentState::Working)
                    {
                        self.claim = None;
                    }
                    let p = Provenance {
                        source: screen.source,
                        confidence: screen.confidence(),
                    };
                    return (Target::from_screen(screen.state), p, false);
                }
            }
            if claim_state == AgentState::Working
                && now.since(self.last_activity.max(claim.at)) >= self.config.stale_after
            {
                self.claim = None;
                stale = true;
            }
        }

        if let Some(claim) = &self.claim {
            let target = match &claim.claim {
                Claim::Working => Target::Working,
                Claim::Blocked(blocker) => Target::Blocked(blocker.clone()),
                Claim::Idle => Target::Idle,
                Claim::Error | Claim::Release => Target::Error,
            };
            let p = Provenance {
                source: claim.source,
                confidence: claim.confidence,
            };
            return (target, p, false);
        }
        if let Some(screen) = &self.screen {
            let p = Provenance {
                source: screen.source,
                confidence: screen.confidence(),
            };
            return (Target::from_screen(screen.state), p, stale);
        }
        let p = Provenance {
            source: Source::Process,
            confidence: Confidence::Weak,
        };
        let target = if self.restored_unconfirmed && !stale {
            Target::Idle
        } else {
            Target::Unknown
        };
        (target, p, stale)
    }

    fn mint_request(&mut self) -> RequestId {
        let n = self.next_request;
        self.next_request += 1;
        let scope = self
            .pane_id
            .as_ref()
            .map(PaneId::as_str)
            .or(self.session.native_id.as_ref().map(|id| id.as_str()))
            .unwrap_or("session");
        RequestId::new(format!("{scope}/r{n}"))
    }

    fn refresh(&mut self, cause: Cause, fresh_claim: bool, now: UnixMillis) -> Update {
        let (target, provenance, stale) = self.target(now);
        let old = self.status.clone();

        let mut new_request = false;
        let status = match target {
            Target::Working => Status::Working,
            Target::Idle => Status::Idle,
            Target::Error => Status::Error,
            Target::Unknown => Status::Unknown,
            Target::Blocked(blocker) => match &self.status {
                Status::Blocked(current)
                    if current.blocker.is_compatible(&blocker)
                        && !(fresh_claim && self.decided.is_some()) =>
                {
                    let mut merged = current.clone();
                    merged.blocker.merge_from(blocker);
                    Status::Blocked(merged)
                }
                _ => {
                    new_request = true;
                    Status::Blocked(Blocked {
                        request_id: self.mint_request(),
                        blocker,
                    })
                }
            },
        };
        self.status = status;

        let mut notify = None;
        if new_request {
            self.decided = None;
            if provenance.confidence == Confidence::Authoritative {
                self.blocked_notify = BlockedNotify::Sent;
                notify = self.blocked_notification();
            } else {
                self.blocked_notify = BlockedNotify::Pending { since: now };
            }
        } else if self.status.state() != AgentState::Blocked {
            self.blocked_notify = BlockedNotify::Idle;
        } else if let BlockedNotify::Pending { since } = self.blocked_notify
            && now.since(since) >= self.config.blocked_debounce
        {
            self.blocked_notify = BlockedNotify::Sent;
            notify = self.blocked_notification();
        }

        let (old_state, new_state) = (old.state(), self.status.state());
        if new_state == AgentState::Working {
            self.restored_unconfirmed = false;
            self.unseen_done = false;
        }
        if old_state == AgentState::Working
            && matches!(new_state, AgentState::Idle | AgentState::Error)
            && !self.restored_unconfirmed
            && !self.viewed
        {
            self.unseen_done = true;
            notify = notify.or(Some(if new_state == AgentState::Error {
                Notify::Failed
            } else {
                Notify::Done
            }));
        }

        let changed = old != self.status;
        if !changed && !cause.force {
            return Update {
                event: None,
                notify,
            };
        }

        let derived = derive_kind(old_state, new_state, stale);
        let signal_kind_fits = cause
            .kind
            .is_some_and(|kind| !changed || kind_fits(kind, new_state));
        let kind = if signal_kind_fits {
            cause.kind.unwrap_or(derived)
        } else {
            derived
        };
        // A state change is attributed to the evidence that decided it; a forced event with no
        // change (session id, turn details, subagent) to the signal that carried it.
        let (source, confidence, seq) = if changed && provenance.source != cause.source {
            (provenance.source, provenance.confidence, None)
        } else {
            (cause.source, cause.confidence, cause.seq)
        };
        let (turn, subagent) = cause.signal.map_or((None, None), |s| (s.turn, s.subagent));
        let event = AgentEvent {
            v: SchemaVersion,
            pane_id: self.pane_id.clone(),
            session: self.session.clone(),
            seq,
            source,
            confidence,
            kind,
            status: self.status.clone(),
            turn,
            subagent,
            ts: now,
        };
        Update {
            event: Some(event),
            notify,
        }
    }

    fn blocked_notification(&self) -> Option<Notify> {
        self.status.blocked().map(|b| Notify::Blocked {
            request_id: b.request_id.clone(),
        })
    }
}

/// Hook socket reports and OSC 7501 reports come from the same shim and share its clock, so their
/// sequence numbers order them even though the sources differ.
fn shim_newer(current: &ClaimRecord, signal: &Signal) -> bool {
    let shim = |s: Source| matches!(s, Source::Hook | Source::Osc7501);
    shim(current.source)
        && shim(signal.source)
        && matches!((current.seq, signal.seq), (Some(a), Some(b)) if b > a)
}

fn kind_fits(kind: EventKind, state: AgentState) -> bool {
    match kind {
        EventKind::TurnStarted | EventKind::ToolStarted => state == AgentState::Working,
        EventKind::Blocked => state == AgentState::Blocked,
        EventKind::Unblocked => state != AgentState::Blocked,
        EventKind::TurnEnded | EventKind::Interrupted => state == AgentState::Idle,
        EventKind::Error => state == AgentState::Error,
        EventKind::Stale => state == AgentState::Unknown,
        EventKind::SessionStarted | EventKind::SessionIdChanged | EventKind::SessionEnded => true,
    }
}

fn derive_kind(old: AgentState, new: AgentState, stale: bool) -> EventKind {
    match (old, new) {
        (_, AgentState::Blocked) => EventKind::Blocked,
        (_, AgentState::Unknown) if stale => EventKind::Stale,
        (_, AgentState::Unknown) => EventKind::SessionEnded,
        (AgentState::Blocked, _) => EventKind::Unblocked,
        (_, AgentState::Working) => EventKind::TurnStarted,
        (_, AgentState::Error) => EventKind::Error,
        (_, AgentState::Idle) => EventKind::TurnEnded,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{AgentKind, ApprovalOption, Lane, NativeSessionId, Subagent, SubagentId};
    use crate::signal::SessionUpdate;

    const T0: UnixMillis = UnixMillis(1_000_000);

    fn at(ms: u64) -> UnixMillis {
        UnixMillis(T0.0 + ms)
    }

    fn arbiter(coverage: HookCoverage) -> Arbiter {
        Arbiter::new(
            ArbiterConfig::new(coverage),
            Some(PaneId::new("p1")),
            SessionInfo::new(AgentKind::Claude, Lane::Pty),
            T0,
        )
    }

    fn hook(kind: EventKind, claim: Claim, seq: u64) -> Signal {
        Signal::new(Source::Hook, Confidence::Authoritative, kind)
            .with_claim(claim)
            .with_seq(Seq(seq))
    }

    fn permission(tool: &str) -> Blocker {
        let mut b = Blocker::new(BlockedReason::Permission);
        b.tool = Some(tool.into());
        b.options = vec![
            ApprovalOption::new(ApprovalChoice::AllowOnce, "Yes"),
            ApprovalOption::new(ApprovalChoice::Deny, "No"),
        ];
        b.answer_paths = vec![AnswerPath::HookDecision];
        b
    }

    fn screen(state: AgentState, visible: bool) -> ScreenVerdict {
        ScreenVerdict::State(ScreenMatch::new(
            state,
            Source::Screen,
            Some("r".into()),
            visible,
        ))
    }

    fn request_id(a: &Arbiter) -> RequestId {
        a.status().blocked().expect("blocked").request_id.clone()
    }

    fn decision(a: &Arbiter, choice: ApprovalChoice, actor: &str) -> Decision {
        Decision {
            request_id: request_id(a),
            choice,
            actor: ActorId::new(actor),
        }
    }

    #[test]
    fn starts_unknown_and_follows_hooks() {
        let mut a = arbiter(HookCoverage::Partial);
        assert_eq!(a.status(), &Status::Unknown);
        let up = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(10));
        let event = up.event.unwrap();
        assert_eq!(event.kind, EventKind::TurnStarted);
        assert_eq!(event.status, Status::Working);
        assert_eq!(event.source, Source::Hook);
        assert_eq!(event.seq, Some(Seq(1)));
        assert_eq!(event.ts, at(10));
        assert_eq!(event.pane_id, Some(PaneId::new("p1")));
    }

    #[test]
    fn unchanged_state_emits_nothing() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let up = a.apply(hook(EventKind::ToolStarted, Claim::Working, 2), at(5));
        assert_eq!(up, Update::default());
    }

    #[test]
    fn process_truth_wins() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let up = a.process_exited(at(5));
        let event = up.event.unwrap();
        assert_eq!(event.status, Status::Unknown);
        assert_eq!(event.kind, EventKind::SessionEnded);
        assert_eq!(event.source, Source::Process);

        // Late hooks and screens from the dead process change nothing.
        assert_eq!(
            a.apply(hook(EventKind::TurnStarted, Claim::Working, 2), at(6)),
            Update::default()
        );
        assert_eq!(
            a.observe_screen(&screen(AgentState::Idle, true), at(7)),
            Update::default()
        );
        assert_eq!(a.status(), &Status::Unknown);

        // A new process starts from a clean slate.
        a.process_started(at(10));
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 3), at(11));
        assert_eq!(a.status(), &Status::Working);
    }

    #[test]
    fn out_of_order_seq_is_dropped() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.apply(hook(EventKind::TurnEnded, Claim::Idle, 20), at(0));
        let late = a.apply(hook(EventKind::TurnStarted, Claim::Working, 10), at(1));
        assert_eq!(late, Update::default());
        let dup = a.apply(hook(EventKind::TurnStarted, Claim::Working, 20), at(2));
        assert_eq!(dup, Update::default());
        assert_eq!(a.status(), &Status::Idle);
    }

    #[test]
    fn seq_is_per_source() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 100), at(0));
        let osc = Signal::new(Source::Osc7501, Confidence::Strong, EventKind::TurnStarted)
            .with_claim(Claim::Working)
            .with_seq(Seq(5));
        let _ = a.apply(osc.clone(), at(1));
        // A repeated OSC seq is dropped even though the hook stream is far ahead.
        assert_eq!(a.apply(osc, at(2)), Update::default());
    }

    #[test]
    fn weaker_claims_do_not_override_stronger_ones() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let weak_idle = Signal::new(Source::Osc9, Confidence::Weak, EventKind::TurnEnded)
            .with_claim(Claim::Idle);
        assert_eq!(a.apply(weak_idle, at(1)), Update::default());
        assert_eq!(a.status().state(), AgentState::Blocked);
    }

    #[test]
    fn shim_seq_orders_osc7501_against_hooks() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnEnded, Claim::Idle, 50), at(0));
        // An OSC 7501 report written before the hook (older seq) arrives late through the PTY.
        let old = Signal::new(Source::Osc7501, Confidence::Strong, EventKind::TurnStarted)
            .with_claim(Claim::Working)
            .with_seq(Seq(40));
        let _ = a.apply(old, at(1));
        assert_eq!(a.status(), &Status::Idle);
        // A newer one (socket down, shim fell back to the tty) is believed.
        let newer = Signal::new(Source::Osc7501, Confidence::Strong, EventKind::TurnStarted)
            .with_claim(Claim::Working)
            .with_seq(Seq(60));
        let _ = a.apply(newer, at(2));
        assert_eq!(a.status(), &Status::Working);
    }

    #[test]
    fn release_withdraws_a_claim() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let osc = |claim| {
            Signal::new(Source::Osc7501, Confidence::Strong, EventKind::TurnStarted)
                .with_claim(claim)
        };
        let _ = a.apply(osc(Claim::Working), at(0));
        let _ = a.observe_screen(&screen(AgentState::Idle, false), at(1));
        assert_eq!(a.status(), &Status::Working);
        let _ = a.apply(osc(Claim::Release), at(2));
        assert_eq!(a.status(), &Status::Idle, "falls back to the screen");
    }

    #[test]
    fn authoritative_blocker_notifies_at_once() {
        let mut a = arbiter(HookCoverage::Partial);
        let up = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let id = request_id(&a);
        assert_eq!(id.as_str(), "p1/r1");
        assert_eq!(up.notify, Some(Notify::Blocked { request_id: id }));
        assert_eq!(up.event.unwrap().kind, EventKind::Blocked);
        assert_eq!(a.next_deadline(), None);
    }

    #[test]
    fn non_authoritative_blocker_is_debounced() {
        let mut a = arbiter(HookCoverage::Partial);
        let up = a.observe_screen(&screen(AgentState::Blocked, true), at(0));
        assert!(up.event.is_some());
        assert_eq!(up.notify, None);
        assert_eq!(a.next_deadline(), Some(at(1500)));
        assert_eq!(a.tick(at(1499)).notify, None);
        let up = a.tick(at(1500));
        assert_eq!(
            up.notify,
            Some(Notify::Blocked {
                request_id: request_id(&a)
            })
        );
        assert_eq!(up.event, None);
        assert_eq!(a.tick(at(5000)).notify, None, "notifies once");
    }

    #[test]
    fn momentary_blocker_never_notifies() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.observe_screen(&screen(AgentState::Working, true), at(0));
        let _ = a.observe_screen(&screen(AgentState::Blocked, true), at(100));
        let _ = a.observe_screen(&screen(AgentState::Working, true), at(900));
        assert_eq!(a.tick(at(2000)).notify, None);
        assert_eq!(a.next_deadline(), None);
    }

    #[test]
    fn visible_blocker_overrides_a_working_claim() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let up = a.observe_screen(&screen(AgentState::Blocked, true), at(100));
        assert_eq!(up.event.unwrap().source, Source::Screen);
        assert_eq!(a.status().state(), AgentState::Blocked);
        // When the dialog closes, the still-valid hook claim is back in charge.
        let _ = a.observe_screen(&screen(AgentState::Idle, false), at(200));
        assert_eq!(a.status(), &Status::Working);
    }

    #[test]
    fn invisible_screen_never_overrides_a_claim() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = a.observe_screen(&screen(AgentState::Idle, false), at(100));
        assert_eq!(a.tick(at(60_000)).event, None);
        assert_eq!(a.status(), &Status::Working);
    }

    #[test]
    fn visible_idle_prompt_overrides_a_stale_working_claim_after_two_seconds() {
        // Claude sends no hook when the user cancels with Esc.
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = a.observe_screen(&screen(AgentState::Working, true), at(50));
        assert_eq!(
            a.observe_screen(&screen(AgentState::Idle, true), at(5000))
                .event,
            None
        );
        assert_eq!(a.next_deadline(), Some(at(7000)));
        assert_eq!(a.tick(at(6999)).event, None);
        let up = a.tick(at(7000));
        let event = up.event.unwrap();
        assert_eq!(event.status, Status::Idle);
        assert_eq!(event.kind, EventKind::TurnEnded);
        assert_eq!(event.source, Source::Screen);
        assert_eq!(up.notify, Some(Notify::Done));
    }

    #[test]
    fn idle_prompt_seen_before_the_claim_does_not_override_it() {
        // The hook fires before the TUI redraws, so an idle prompt already on screen is older
        // evidence than the claim.
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.observe_screen(&screen(AgentState::Idle, true), at(0));
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(100));
        let _ = a.observe_screen(&screen(AgentState::Idle, true), at(200));
        assert_eq!(a.tick(at(10_000)).event, None);
        assert_eq!(a.status(), &Status::Working);
    }

    #[test]
    fn partial_coverage_leaves_blocked_when_the_screen_shows_work() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.observe_screen(&screen(AgentState::Working, true), at(0));
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(100),
        );
        // The spinner that was already showing is older than the claim: still blocked.
        let _ = a.observe_screen(&screen(AgentState::Working, true), at(150));
        assert_eq!(a.status().state(), AgentState::Blocked);
        let _ = a.observe_screen(&screen(AgentState::Blocked, true), at(200));
        // Answered in the terminal: the spinner comes back.
        let up = a.observe_screen(&screen(AgentState::Working, true), at(3000));
        let event = up.event.unwrap();
        assert_eq!(event.kind, EventKind::Unblocked);
        assert_eq!(event.status, Status::Working);
    }

    #[test]
    fn full_lifecycle_hooks_are_not_overridden_by_screen_work() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let _ = a.observe_screen(&screen(AgentState::Working, true), at(500));
        assert_eq!(a.status().state(), AgentState::Blocked);
    }

    #[test]
    fn answered_in_terminal_falls_back_to_idle_prompt() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let _ = a.observe_screen(&screen(AgentState::Blocked, true), at(100));
        let _ = a.observe_screen(&screen(AgentState::Idle, true), at(4000));
        assert_eq!(a.status().state(), AgentState::Blocked);
        let up = a.tick(at(6000));
        assert_eq!(up.event.unwrap().kind, EventKind::Unblocked);
        assert_eq!(a.status(), &Status::Idle);
    }

    #[test]
    fn screen_blocker_after_turn_end_wins() {
        // E.g. Codex's update dialog after a turn, which no hook reports.
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnEnded, Claim::Idle, 1), at(0));
        let _ = a.observe_screen(&screen(AgentState::Blocked, true), at(100));
        assert_eq!(a.status().state(), AgentState::Blocked);
    }

    #[test]
    fn hook_and_screen_share_one_request() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.observe_screen(&screen(AgentState::Blocked, true), at(0));
        let first = request_id(&a);
        let up = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(50),
        );
        assert_eq!(request_id(&a), first, "same dialog, same request");
        let blocked = a.status().blocked().unwrap();
        assert_eq!(blocked.blocker.reason, BlockedReason::Permission);
        assert_eq!(blocked.blocker.tool.as_deref(), Some("Bash"));
        assert!(
            blocked
                .blocker
                .answer_paths
                .contains(&AnswerPath::Keystrokes)
        );
        assert!(
            blocked
                .blocker
                .answer_paths
                .contains(&AnswerPath::HookDecision)
        );
        assert_eq!(up.event.unwrap().kind, EventKind::Blocked, "enriched card");
    }

    #[test]
    fn a_different_tool_is_a_new_request() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let first = request_id(&a);
        let up = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Write")), 2),
            at(10),
        );
        assert_ne!(request_id(&a), first);
        assert!(matches!(up.notify, Some(Notify::Blocked { .. })));
    }

    #[test]
    fn first_decision_wins() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let alice = decision(&a, ApprovalChoice::AllowOnce, "alice");
        let bob = decision(&a, ApprovalChoice::Deny, "bob");
        let decided = a.decide(alice, at(100)).unwrap();
        assert_eq!(decided.decided_by, ActorId::new("alice"));
        assert_eq!(decided.choice, ApprovalChoice::AllowOnce);
        assert_eq!(decided.at, at(100));
        assert_eq!(
            a.decide(bob, at(101)),
            Err(DecisionError::AlreadyDecided {
                by: ActorId::new("alice"),
                choice: ApprovalChoice::AllowOnce
            })
        );
        assert_eq!(
            a.status().state(),
            AgentState::Blocked,
            "until evidence arrives"
        );
    }

    #[test]
    fn late_deciders_still_learn_who_won_after_unblock() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let late = decision(&a, ApprovalChoice::Deny, "bob");
        a.decide(decision(&a, ApprovalChoice::AllowOnce, "alice"), at(1))
            .unwrap();
        let _ = a.apply(hook(EventKind::TurnEnded, Claim::Idle, 2), at(2));
        assert!(matches!(
            a.decide(late, at(3)),
            Err(DecisionError::AlreadyDecided { .. })
        ));
    }

    #[test]
    fn decisions_are_validated() {
        let mut a = arbiter(HookCoverage::Partial);
        let stray = Decision {
            request_id: RequestId::new("p1/r9"),
            choice: ApprovalChoice::AllowOnce,
            actor: ActorId::new("alice"),
        };
        assert_eq!(
            a.decide(stray.clone(), at(0)),
            Err(DecisionError::NotPending)
        );
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        assert_eq!(a.decide(stray, at(1)), Err(DecisionError::NotPending));
        let session = decision(&a, ApprovalChoice::AllowSession, "alice");
        assert_eq!(a.decide(session, at(1)), Err(DecisionError::NotOffered));

        // Screen-only blockers offer no options: "open the terminal".
        let mut b = arbiter(HookCoverage::Partial);
        let _ = b.observe_screen(&screen(AgentState::Blocked, true), at(0));
        let any = decision(&b, ApprovalChoice::AllowOnce, "alice");
        assert_eq!(b.decide(any, at(1)), Err(DecisionError::NotOffered));
    }

    #[test]
    fn same_dialog_after_a_decision_keeps_its_id_but_a_new_hook_request_does_not() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let first = request_id(&a);
        a.decide(decision(&a, ApprovalChoice::AllowOnce, "alice"), at(10))
            .unwrap();
        // The dialog is still drawn for a moment after the answer.
        let _ = a.observe_screen(&screen(AgentState::Blocked, true), at(20));
        assert_eq!(request_id(&a), first);
        // A second PermissionRequest for the same tool is a new request.
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 2),
            at(30),
        );
        assert_ne!(request_id(&a), first);
        assert_eq!(a.decided(), None);
    }

    #[test]
    fn unseen_done_is_set_only_when_nobody_is_viewing() {
        let mut a = arbiter(HookCoverage::Partial);
        a.viewed();
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let up = a.apply(hook(EventKind::TurnEnded, Claim::Idle, 2), at(10));
        assert_eq!(up.notify, None);
        assert!(!a.unseen_done());

        a.unviewed();
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 3), at(20));
        let up = a.apply(hook(EventKind::TurnEnded, Claim::Idle, 4), at(30));
        assert_eq!(up.notify, Some(Notify::Done));
        assert!(a.unseen_done());

        a.viewed();
        assert!(!a.unseen_done());
    }

    #[test]
    fn a_new_turn_clears_unseen_done() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = a.apply(hook(EventKind::TurnEnded, Claim::Idle, 2), at(10));
        assert!(a.unseen_done());
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 3), at(20));
        assert!(!a.unseen_done());
    }

    #[test]
    fn failed_turns_notify_as_failed() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let up = a.apply(hook(EventKind::Error, Claim::Error, 2), at(10));
        assert_eq!(up.notify, Some(Notify::Failed));
        assert_eq!(up.event.unwrap().kind, EventKind::Error);
    }

    #[test]
    fn idle_without_prior_work_is_not_done() {
        let mut a = arbiter(HookCoverage::Partial);
        let up = a.observe_screen(&screen(AgentState::Idle, true), at(0));
        assert_eq!(up.notify, None);
        assert!(!a.unseen_done());
    }

    #[test]
    fn restored_sessions_never_report_done_until_they_work() {
        let mut a = Arbiter::restored(
            ArbiterConfig::new(HookCoverage::Partial),
            Some(PaneId::new("p1")),
            SessionInfo::new(AgentKind::Claude, Lane::Pty),
            T0,
        );
        assert_eq!(a.status(), &Status::Idle);
        assert!(a.is_restored_unconfirmed());
        assert_eq!(a.tick(at(10)), Update::default(), "no evidence keeps idle");
        let _ = a.observe_screen(&screen(AgentState::Idle, true), at(20));
        assert!(!a.unseen_done());
        let _ = a.observe_screen(&screen(AgentState::Working, true), at(30));
        assert!(!a.is_restored_unconfirmed());
        let up = a.observe_screen(&screen(AgentState::Idle, true), at(40));
        assert_eq!(up.notify, Some(Notify::Done));
    }

    #[test]
    fn working_claims_go_stale_without_output() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let thirty_min = 30 * 60 * 1000;
        a.pty_output(at(1000));
        assert_eq!(a.next_deadline(), Some(at(1000 + thirty_min)));
        assert_eq!(a.tick(at(thirty_min)).event, None);
        let up = a.tick(at(1000 + thirty_min));
        let event = up.event.unwrap();
        assert_eq!(event.kind, EventKind::Stale);
        assert_eq!(event.status, Status::Unknown);
    }

    #[test]
    fn blocked_never_goes_stale() {
        let mut a = arbiter(HookCoverage::FullLifecycle);
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        assert_eq!(a.tick(at(10 * 60 * 60 * 1000)).event, None);
        assert_eq!(a.status().state(), AgentState::Blocked);
    }

    #[test]
    fn session_facts_are_merged_and_force_an_event() {
        let mut a = arbiter(HookCoverage::Partial);
        let mut start = Signal::new(
            Source::Hook,
            Confidence::Authoritative,
            EventKind::SessionStarted,
        )
        .with_seq(Seq(1));
        start.session = SessionUpdate {
            native_id: Some(NativeSessionId::new("abc")),
            transcript: Some("/t/abc.jsonl".into()),
            cwd: Some("/src".into()),
        };
        let up = a.apply(start, at(0));
        let event = up.event.unwrap();
        assert_eq!(event.kind, EventKind::SessionStarted);
        assert_eq!(event.status, Status::Unknown);
        assert_eq!(event.session.native_id, Some(NativeSessionId::new("abc")));

        let mut changed = Signal::new(
            Source::Hook,
            Confidence::Authoritative,
            EventKind::SessionIdChanged,
        )
        .with_seq(Seq(2));
        changed.session.native_id = Some(NativeSessionId::new("def"));
        let event = a.apply(changed, at(1)).event.unwrap();
        assert_eq!(event.kind, EventKind::SessionIdChanged);
        assert_eq!(a.session().native_id, Some(NativeSessionId::new("def")));
        assert_eq!(
            a.session().cwd.as_deref(),
            Some(std::path::Path::new("/src"))
        );
    }

    #[test]
    fn subagent_signals_pass_through_without_changing_state() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let mut sub = hook(EventKind::TurnEnded, Claim::Idle, 2);
        sub.subagent = Some(Subagent {
            id: SubagentId::new("def456"),
            agent_type: Some("Explore".into()),
        });
        let up = a.apply(sub, at(10));
        let event = up.event.unwrap();
        assert_eq!(event.status, Status::Working);
        assert!(event.subagent.is_some());
        assert_eq!(up.notify, None);
        assert_eq!(a.status(), &Status::Working);
    }

    #[test]
    fn turn_details_arriving_after_the_screen_still_emit() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = a.observe_screen(&screen(AgentState::Idle, true), at(1000));
        let _ = a.tick(at(3000));
        assert_eq!(a.status(), &Status::Idle);
        let mut stop = hook(EventKind::TurnEnded, Claim::Idle, 2);
        stop.turn = Some(crate::Turn {
            outcome: crate::TurnOutcome::Completed,
            last_message: Some("done".into()),
        });
        let event = a.apply(stop, at(3100)).event.unwrap();
        assert_eq!(event.kind, EventKind::TurnEnded);
        assert_eq!(event.turn.unwrap().last_message.as_deref(), Some("done"));
    }

    #[test]
    fn freeze_verdicts_are_ignored() {
        let mut a = arbiter(HookCoverage::Partial);
        let _ = a.observe_screen(&screen(AgentState::Working, true), at(0));
        let freeze = ScreenVerdict::Freeze {
            rule_id: "transcript_viewer".into(),
        };
        assert_eq!(a.observe_screen(&freeze, at(10)), Update::default());
        assert_eq!(a.status(), &Status::Working);
    }

    #[test]
    fn request_ids_fall_back_to_the_native_session() {
        let mut session = SessionInfo::new(AgentKind::Kimi, Lane::Acp);
        session.native_id = Some(NativeSessionId::new("k1"));
        let mut a = Arbiter::new(
            ArbiterConfig::new(HookCoverage::FullLifecycle),
            None,
            session,
            T0,
        );
        let _ = a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        assert_eq!(request_id(&a).as_str(), "k1/r1");
    }

    /// A deterministic replay of a full Claude turn mixing every source.
    #[test]
    fn claude_turn_scenario() {
        let mut a = arbiter(HookCoverage::Partial);
        let mut log = Vec::new();
        let mut push = |up: Update| {
            if let Some(e) = up.event {
                log.push((e.kind, e.status.state(), e.source));
            }
        };
        push(a.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0)));
        push(a.observe_screen(&screen(AgentState::Working, true), at(100)));
        push(a.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 2),
            at(5000),
        ));
        push(a.observe_screen(&screen(AgentState::Blocked, true), at(5100)));
        a.decide(decision(&a, ApprovalChoice::AllowOnce, "alice"), at(8000))
            .unwrap();
        push(a.observe_screen(&screen(AgentState::Working, true), at(8100)));
        push(a.apply(hook(EventKind::TurnEnded, Claim::Idle, 3), at(20_000)));
        push(a.observe_screen(&screen(AgentState::Idle, true), at(20_050)));
        assert_eq!(
            log,
            [
                (EventKind::TurnStarted, AgentState::Working, Source::Hook),
                (EventKind::Blocked, AgentState::Blocked, Source::Hook),
                (EventKind::Unblocked, AgentState::Working, Source::Screen),
                (EventKind::TurnEnded, AgentState::Idle, Source::Hook),
            ]
        );
        assert!(a.unseen_done());
    }
}
