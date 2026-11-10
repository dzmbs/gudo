//! Per-pane arbitration of hook, in-band and screen evidence.
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
//!    and has not worked since. Subagents and turns the user interrupted never notify.
//! 7. **Single-response approvals.** The first valid [`Decision`] for a request wins; later ones
//!    get [`DecisionError::AlreadyDecided`] naming the winner.

use std::collections::HashMap;
use std::fmt;
use std::time::Duration;

use crate::adapter::HookCoverage;
use crate::event::{
    ActorId, AgentEvent, AgentState, AnswerPath, ApprovalChoice, Blocked, BlockedReason, Blocker,
    Confidence, Decided, Decision, EventKind, PaneId, RequestId, SchemaVersion, Seq, SessionInfo,
    Source, Status, TurnOutcome, UnixMillis,
};
use crate::manifest::{ScreenMatch, ScreenVerdict};
use crate::signal::{Claim, Signal};

/// Timing and trust settings for an [`Arbiter`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArbiterConfig {
    pub coverage: HookCoverage,
    /// How long a non-authoritative blocker must persist before it notifies. Default 1.5 s.
    pub blocked_debounce: Duration,
    /// How long a visible idle prompt must persist to override a stale claim. Default 2 s.
    pub idle_override: Duration,
    /// How long a `working` claim survives with no PTY output or newer signal. Default 30 min.
    pub stale_after: Duration,
    /// A launch-owned live source excludes other evidence and owns its claim until release.
    pub exclusive_source: Option<Source>,
}

impl ArbiterConfig {
    /// Returns the default timings for the given hook coverage.
    pub fn new(coverage: HookCoverage) -> Self {
        Self {
            coverage,
            blocked_debounce: Duration::from_millis(1500),
            idle_override: Duration::from_secs(2),
            stale_after: Duration::from_secs(30 * 60),
            exclusive_source: None,
        }
    }
}

/// Something the user should be told about, typically by push.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notify {
    /// The agent needs the user.
    Blocked { request_id: RequestId },
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
    AlreadyDecided { by: ActorId, choice: ApprovalChoice },
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
    /// A turn is under way: the agent worked or stopped to ask since it was last idle.
    in_turn: bool,
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
            in_turn: false,
            last_activity: now,
        }
    }

    /// Creates an arbiter for a session resumed after a daemon restart. It starts `idle` and never
    /// reports "done" until it has been seen working.
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
        if self.process == Process::Exited
            || self
                .config
                .exclusive_source
                .is_some_and(|source| source != signal.source)
        {
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
                    if self.claim.as_ref().is_some_and(|current| {
                        current.source == signal.source || signal.confidence >= current.confidence
                    }) {
                        self.claim = None;
                    }
                }
                Some(claim) => {
                    let accept = self.claim.as_ref().is_none_or(|current| {
                        signal.confidence >= current.confidence || shim_newer(current, &signal)
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
        if self.config.exclusive_source.is_some() {
            return Update::default();
        }
        let ScreenVerdict::State(matched) = verdict else {
            return Update::default();
        };
        if self.process == Process::Exited {
            return Update::default();
        }
        self.record_screen(matched, now);
        let cause = Cause::quiet(
            matched.source,
            if matched.is_visible() {
                Confidence::Strong
            } else {
                Confidence::Weak
            },
        );
        self.refresh(cause, false, now)
    }

    /// Re-evaluates time-based rules. Call it at [`Arbiter::next_deadline`].
    pub fn tick(&mut self, now: UnixMillis) -> Update {
        let source = self
            .screen
            .as_ref()
            .map_or(Source::Process, |screen| screen.source);
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
        if let Some(earlier) = self
            .decided
            .as_ref()
            .filter(|earlier| earlier.request_id == decision.request_id)
        {
            return Err(DecisionError::AlreadyDecided {
                by: earlier.decided_by.clone(),
                choice: earlier.choice,
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
            .any(|option| option.id == decision.choice)
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

    /// Forgets the decision on `request_id` when it could not be delivered, so it can be
    /// answered again.
    pub fn withdraw(&mut self, request_id: &RequestId) {
        if self
            .decided
            .as_ref()
            .is_some_and(|decided| &decided.request_id == request_id)
        {
            self.decided = None;
        }
    }

    /// Returns when [`Arbiter::tick`] should next run, if any time-based rule is armed.
    pub fn next_deadline(&self) -> Option<UnixMillis> {
        let mut deadlines = Vec::new();
        if let BlockedNotify::Pending { since } = self.blocked_notify {
            deadlines.push(since.saturating_add(self.config.blocked_debounce));
        }
        if let Some(claim) = &self.claim {
            if let Some(screen) = self.screen.as_ref().filter(|screen| {
                screen.visible
                    && screen.state == AgentState::Idle
                    && screen.since > claim.at
                    && matches!(claim.state(), AgentState::Working | AgentState::Blocked)
            }) {
                deadlines.push(screen.since.saturating_add(self.config.idle_override));
            }
            if claim.state() == AgentState::Working
                && self.config.exclusive_source != Some(claim.source)
            {
                deadlines.push(
                    self.last_activity
                        .max(claim.at)
                        .saturating_add(self.config.stale_after),
                );
            }
        }
        deadlines.into_iter().min()
    }

    fn record_screen(&mut self, matched: &ScreenMatch, now: UnixMillis) {
        if matched.state == AgentState::Unknown {
            self.screen = None;
            return;
        }
        let same = self.screen.as_ref().is_some_and(|screen| {
            screen.state == matched.state && screen.visible == matched.is_visible()
        });
        if same {
            if let Some(screen) = &mut self.screen {
                screen.source = matched.source;
            }
        } else {
            self.screen = Some(ScreenRecord {
                state: matched.state,
                visible: matched.is_visible(),
                source: matched.source,
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
            if let Some(screen) = self.screen.as_ref().filter(|screen| screen.visible) {
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
                && self.config.exclusive_source != Some(claim.source)
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
        let number = self.next_request;
        self.next_request += 1;
        let scope = self
            .pane_id
            .as_ref()
            .map(PaneId::as_str)
            .or(self.session.native_id.as_ref().map(|id| id.as_str()))
            .unwrap_or("session");
        RequestId::new(format!("{scope}/r{number}"))
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
        let stopped_by_user = cause.kind == Some(EventKind::Interrupted)
            || cause.signal.as_ref().is_some_and(|signal| {
                signal
                    .turn
                    .as_ref()
                    .is_some_and(|turn| turn.outcome == TurnOutcome::Cancelled)
            });
        // A turn ends finished whether it was working or still waiting on a request answered
        // elsewhere (the terminal); not when that request was refused.
        let refused = old_state == AgentState::Blocked
            && self
                .decided
                .as_ref()
                .is_some_and(|decided| decided.choice == ApprovalChoice::Deny);
        let turn_ended = self.in_turn && old_state != new_state && !refused;
        self.in_turn = match new_state {
            AgentState::Working | AgentState::Blocked => true,
            AgentState::Idle | AgentState::Error => false,
            AgentState::Unknown => self.in_turn && self.process != Process::Exited,
        };
        if turn_ended
            && matches!(new_state, AgentState::Idle | AgentState::Error)
            && !self.restored_unconfirmed
            && !self.viewed
            && !stopped_by_user
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
        let (turn, subagent) = cause
            .signal
            .map_or((None, None), |signal| (signal.turn, signal.subagent));
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
        self.status.blocked().map(|blocked| Notify::Blocked {
            request_id: blocked.request_id.clone(),
        })
    }
}

/// Hook socket reports and OSC 7501 reports come from the same shim and share its clock, so their
/// sequence numbers order them even though the sources differ.
fn shim_newer(current: &ClaimRecord, signal: &Signal) -> bool {
    let from_shim = |source: Source| matches!(source, Source::Hook | Source::Osc7501);
    from_shim(current.source)
        && from_shim(signal.source)
        && matches!((current.seq, signal.seq), (Some(current_seq), Some(signal_seq)) if signal_seq > current_seq)
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
#[path = "arbiter/exclusive_tests.rs"]
mod exclusive_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{AgentKind, ApprovalOption, Lane, NativeSessionId, Subagent, SubagentId};
    use crate::signal::SessionUpdate;

    const T0: UnixMillis = UnixMillis(1_000_000);

    fn at(millis: u64) -> UnixMillis {
        UnixMillis(T0.0 + millis)
    }

    fn new_arbiter(coverage: HookCoverage) -> Arbiter {
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
        let mut blocker = Blocker::new(BlockedReason::Permission);
        blocker.tool = Some(tool.into());
        blocker.options = vec![
            ApprovalOption::new(ApprovalChoice::AllowOnce, "Yes"),
            ApprovalOption::new(ApprovalChoice::Deny, "No"),
        ];
        blocker.answer_paths = vec![AnswerPath::HookDecision];
        blocker
    }

    fn screen(state: AgentState, visible: bool) -> ScreenVerdict {
        ScreenVerdict::State(ScreenMatch::new(
            state,
            Source::Screen,
            Some("r".into()),
            visible,
        ))
    }

    fn request_id(arbiter: &Arbiter) -> RequestId {
        arbiter
            .status()
            .blocked()
            .expect("blocked")
            .request_id
            .clone()
    }

    fn decision(arbiter: &Arbiter, choice: ApprovalChoice, actor: &str) -> Decision {
        Decision {
            request_id: request_id(arbiter),
            choice,
            actor: ActorId::new(actor),
        }
    }

    #[test]
    fn starts_unknown_and_follows_hooks() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        assert_eq!(arbiter.status(), &Status::Unknown);
        let update = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(10));
        let event = update.event.unwrap();
        assert_eq!(event.kind, EventKind::TurnStarted);
        assert_eq!(event.status, Status::Working);
        assert_eq!(event.source, Source::Hook);
        assert_eq!(event.seq, Some(Seq(1)));
        assert_eq!(event.ts, at(10));
        assert_eq!(event.pane_id, Some(PaneId::new("p1")));
    }

    #[test]
    fn unchanged_state_emits_nothing() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let update = arbiter.apply(hook(EventKind::ToolStarted, Claim::Working, 2), at(5));
        assert_eq!(update, Update::default());
    }

    #[test]
    fn process_truth_wins() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let update = arbiter.process_exited(at(5));
        let event = update.event.unwrap();
        assert_eq!(event.status, Status::Unknown);
        assert_eq!(event.kind, EventKind::SessionEnded);
        assert_eq!(event.source, Source::Process);

        // Late hooks and screens from the dead process change nothing.
        assert_eq!(
            arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 2), at(6)),
            Update::default()
        );
        assert_eq!(
            arbiter.observe_screen(&screen(AgentState::Idle, true), at(7)),
            Update::default()
        );
        assert_eq!(arbiter.status(), &Status::Unknown);

        // A new process starts from a clean slate.
        arbiter.process_started(at(10));
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 3), at(11));
        assert_eq!(arbiter.status(), &Status::Working);
    }

    #[test]
    fn out_of_order_seq_is_dropped() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 20), at(0));
        let late = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 10), at(1));
        assert_eq!(late, Update::default());
        let dup = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 20), at(2));
        assert_eq!(dup, Update::default());
        assert_eq!(arbiter.status(), &Status::Idle);
    }

    #[test]
    fn seq_is_per_source() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 100), at(0));
        let osc = Signal::new(Source::Osc7501, Confidence::Strong, EventKind::TurnStarted)
            .with_claim(Claim::Working)
            .with_seq(Seq(5));
        let _ = arbiter.apply(osc.clone(), at(1));
        // A repeated OSC seq is dropped even though the hook stream is far ahead.
        assert_eq!(arbiter.apply(osc, at(2)), Update::default());
    }

    #[test]
    fn weaker_claims_do_not_override_stronger_ones() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let weak_idle = Signal::new(Source::Osc9, Confidence::Weak, EventKind::TurnEnded)
            .with_claim(Claim::Idle);
        assert_eq!(arbiter.apply(weak_idle, at(1)), Update::default());
        assert_eq!(arbiter.status().state(), AgentState::Blocked);
    }

    #[test]
    fn shim_seq_orders_osc7501_against_hooks() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 50), at(0));
        // An OSC 7501 report written before the hook (older seq) arrives late through the PTY.
        let old = Signal::new(Source::Osc7501, Confidence::Strong, EventKind::TurnStarted)
            .with_claim(Claim::Working)
            .with_seq(Seq(40));
        let _ = arbiter.apply(old, at(1));
        assert_eq!(arbiter.status(), &Status::Idle);
        // A newer one (socket down, shim fell back to the tty) is believed.
        let newer = Signal::new(Source::Osc7501, Confidence::Strong, EventKind::TurnStarted)
            .with_claim(Claim::Working)
            .with_seq(Seq(60));
        let _ = arbiter.apply(newer, at(2));
        assert_eq!(arbiter.status(), &Status::Working);
    }

    #[test]
    fn release_withdraws_a_claim() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let osc = |claim| {
            Signal::new(Source::Osc7501, Confidence::Strong, EventKind::TurnStarted)
                .with_claim(claim)
        };
        let _ = arbiter.apply(osc(Claim::Working), at(0));
        let _ = arbiter.observe_screen(&screen(AgentState::Idle, false), at(1));
        assert_eq!(arbiter.status(), &Status::Working);
        let _ = arbiter.apply(osc(Claim::Release), at(2));
        assert_eq!(arbiter.status(), &Status::Idle, "falls back to the screen");
    }

    #[test]
    fn authoritative_blocker_notifies_at_once() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let update = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let id = request_id(&arbiter);
        assert_eq!(id.as_str(), "p1/r1");
        assert_eq!(update.notify, Some(Notify::Blocked { request_id: id }));
        assert_eq!(update.event.unwrap().kind, EventKind::Blocked);
        assert_eq!(arbiter.next_deadline(), None);
    }

    #[test]
    fn non_authoritative_blocker_is_debounced() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let update = arbiter.observe_screen(&screen(AgentState::Blocked, true), at(0));
        assert!(update.event.is_some());
        assert_eq!(update.notify, None);
        assert_eq!(arbiter.next_deadline(), Some(at(1500)));
        assert_eq!(arbiter.tick(at(1499)).notify, None);
        let update = arbiter.tick(at(1500));
        assert_eq!(
            update.notify,
            Some(Notify::Blocked {
                request_id: request_id(&arbiter)
            })
        );
        assert_eq!(update.event, None);
        assert_eq!(arbiter.tick(at(5000)).notify, None, "notifies once");
    }

    #[test]
    fn momentary_blocker_never_notifies() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.observe_screen(&screen(AgentState::Working, true), at(0));
        let _ = arbiter.observe_screen(&screen(AgentState::Blocked, true), at(100));
        let _ = arbiter.observe_screen(&screen(AgentState::Working, true), at(900));
        assert_eq!(arbiter.tick(at(2000)).notify, None);
        assert_eq!(arbiter.next_deadline(), None);
    }

    #[test]
    fn visible_blocker_overrides_a_working_claim() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let update = arbiter.observe_screen(&screen(AgentState::Blocked, true), at(100));
        assert_eq!(update.event.unwrap().source, Source::Screen);
        assert_eq!(arbiter.status().state(), AgentState::Blocked);
        // When the dialog closes, the still-valid hook claim is back in charge.
        let _ = arbiter.observe_screen(&screen(AgentState::Idle, false), at(200));
        assert_eq!(arbiter.status(), &Status::Working);
    }

    #[test]
    fn invisible_screen_never_overrides_a_claim() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = arbiter.observe_screen(&screen(AgentState::Idle, false), at(100));
        assert_eq!(arbiter.tick(at(60_000)).event, None);
        assert_eq!(arbiter.status(), &Status::Working);
    }

    #[test]
    fn visible_idle_prompt_overrides_a_stale_working_claim_after_two_seconds() {
        // Claude sends no hook when the user cancels with Esc.
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = arbiter.observe_screen(&screen(AgentState::Working, true), at(50));
        assert_eq!(
            arbiter
                .observe_screen(&screen(AgentState::Idle, true), at(5000))
                .event,
            None
        );
        assert_eq!(arbiter.next_deadline(), Some(at(7000)));
        assert_eq!(arbiter.tick(at(6999)).event, None);
        let update = arbiter.tick(at(7000));
        let event = update.event.unwrap();
        assert_eq!(event.status, Status::Idle);
        assert_eq!(event.kind, EventKind::TurnEnded);
        assert_eq!(event.source, Source::Screen);
        assert_eq!(update.notify, Some(Notify::Done));
    }

    #[test]
    fn idle_prompt_seen_before_the_claim_does_not_override_it() {
        // The hook fires before the TUI redraws, so an idle prompt already on screen is older
        // evidence than the claim.
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.observe_screen(&screen(AgentState::Idle, true), at(0));
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(100));
        let _ = arbiter.observe_screen(&screen(AgentState::Idle, true), at(200));
        assert_eq!(arbiter.tick(at(10_000)).event, None);
        assert_eq!(arbiter.status(), &Status::Working);
    }

    #[test]
    fn partial_coverage_leaves_blocked_when_the_screen_shows_work() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.observe_screen(&screen(AgentState::Working, true), at(0));
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(100),
        );
        // The spinner that was already showing is older than the claim: still blocked.
        let _ = arbiter.observe_screen(&screen(AgentState::Working, true), at(150));
        assert_eq!(arbiter.status().state(), AgentState::Blocked);
        let _ = arbiter.observe_screen(&screen(AgentState::Blocked, true), at(200));
        // Answered in the terminal: the spinner comes back.
        let update = arbiter.observe_screen(&screen(AgentState::Working, true), at(3000));
        let event = update.event.unwrap();
        assert_eq!(event.kind, EventKind::Unblocked);
        assert_eq!(event.status, Status::Working);
    }

    #[test]
    fn full_lifecycle_hooks_are_not_overridden_by_screen_work() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let _ = arbiter.observe_screen(&screen(AgentState::Working, true), at(500));
        assert_eq!(arbiter.status().state(), AgentState::Blocked);
    }

    #[test]
    fn answered_in_terminal_falls_back_to_idle_prompt() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let _ = arbiter.observe_screen(&screen(AgentState::Blocked, true), at(100));
        let _ = arbiter.observe_screen(&screen(AgentState::Idle, true), at(4000));
        assert_eq!(arbiter.status().state(), AgentState::Blocked);
        let update = arbiter.tick(at(6000));
        assert_eq!(update.event.unwrap().kind, EventKind::Unblocked);
        assert_eq!(arbiter.status(), &Status::Idle);
    }

    #[test]
    fn screen_blocker_after_turn_end_wins() {
        // E.g. Codex's update dialog after a turn, which no hook reports.
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 1), at(0));
        let _ = arbiter.observe_screen(&screen(AgentState::Blocked, true), at(100));
        assert_eq!(arbiter.status().state(), AgentState::Blocked);
    }

    #[test]
    fn hook_and_screen_share_one_request() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.observe_screen(&screen(AgentState::Blocked, true), at(0));
        let first = request_id(&arbiter);
        let update = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(50),
        );
        assert_eq!(request_id(&arbiter), first, "same dialog, same request");
        let blocked = arbiter.status().blocked().unwrap();
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
        assert_eq!(
            update.event.unwrap().kind,
            EventKind::Blocked,
            "enriched card"
        );
    }

    #[test]
    fn a_different_tool_is_a_new_request() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let first = request_id(&arbiter);
        let update = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Write")), 2),
            at(10),
        );
        assert_ne!(request_id(&arbiter), first);
        assert!(matches!(update.notify, Some(Notify::Blocked { .. })));
    }

    #[test]
    fn a_turn_that_ends_while_still_blocked_is_a_finished_turn() {
        // Answered in the terminal: the next signal is the turn's end, with no working claim
        // in between.
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 2),
            at(10),
        );
        let update = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 3), at(20));
        assert_eq!(update.notify, Some(Notify::Done));
    }

    #[test]
    fn an_approval_that_lets_the_agent_carry_on_is_no_finished_turn() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 2),
            at(10),
        );
        let update = arbiter.apply(hook(EventKind::ToolStarted, Claim::Working, 3), at(20));
        assert_eq!(update.notify, None);
    }

    #[test]
    fn a_denied_request_that_ends_the_turn_is_no_finished_turn() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 2),
            at(10),
        );
        let deny = decision(&arbiter, ApprovalChoice::Deny, "alice");
        arbiter.decide(deny, at(15)).unwrap();
        let update = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 3), at(20));
        assert_eq!(update.notify, None);
    }

    #[test]
    fn first_decision_wins() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let alice = decision(&arbiter, ApprovalChoice::AllowOnce, "alice");
        let bob = decision(&arbiter, ApprovalChoice::Deny, "bob");
        let decided = arbiter.decide(alice, at(100)).unwrap();
        assert_eq!(decided.decided_by, ActorId::new("alice"));
        assert_eq!(decided.choice, ApprovalChoice::AllowOnce);
        assert_eq!(decided.at, at(100));
        assert_eq!(
            arbiter.decide(bob, at(101)),
            Err(DecisionError::AlreadyDecided {
                by: ActorId::new("alice"),
                choice: ApprovalChoice::AllowOnce
            })
        );
        assert_eq!(
            arbiter.status().state(),
            AgentState::Blocked,
            "until evidence arrives"
        );
    }

    #[test]
    fn late_deciders_still_learn_who_won_after_unblock() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let late = decision(&arbiter, ApprovalChoice::Deny, "bob");
        arbiter
            .decide(
                decision(&arbiter, ApprovalChoice::AllowOnce, "alice"),
                at(1),
            )
            .unwrap();
        let _ = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 2), at(2));
        assert!(matches!(
            arbiter.decide(late, at(3)),
            Err(DecisionError::AlreadyDecided { .. })
        ));
    }

    #[test]
    fn decisions_are_validated() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let stray = Decision {
            request_id: RequestId::new("p1/r9"),
            choice: ApprovalChoice::AllowOnce,
            actor: ActorId::new("alice"),
        };
        assert_eq!(
            arbiter.decide(stray.clone(), at(0)),
            Err(DecisionError::NotPending)
        );
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        assert_eq!(arbiter.decide(stray, at(1)), Err(DecisionError::NotPending));
        let session = decision(&arbiter, ApprovalChoice::AllowSession, "alice");
        assert_eq!(
            arbiter.decide(session, at(1)),
            Err(DecisionError::NotOffered)
        );

        // Screen-only blockers offer no options: "open the terminal".
        let mut screen_only = new_arbiter(HookCoverage::Partial);
        let _ = screen_only.observe_screen(&screen(AgentState::Blocked, true), at(0));
        let any = decision(&screen_only, ApprovalChoice::AllowOnce, "alice");
        assert_eq!(
            screen_only.decide(any, at(1)),
            Err(DecisionError::NotOffered)
        );
    }

    #[test]
    fn same_dialog_after_a_decision_keeps_its_id_but_a_new_hook_request_does_not() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        let first = request_id(&arbiter);
        arbiter
            .decide(
                decision(&arbiter, ApprovalChoice::AllowOnce, "alice"),
                at(10),
            )
            .unwrap();
        // The dialog is still drawn for a moment after the answer.
        let _ = arbiter.observe_screen(&screen(AgentState::Blocked, true), at(20));
        assert_eq!(request_id(&arbiter), first);
        // A second PermissionRequest for the same tool is a new request.
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 2),
            at(30),
        );
        assert_ne!(request_id(&arbiter), first);
        assert_eq!(arbiter.decided(), None);
    }

    #[test]
    fn unseen_done_is_set_only_when_nobody_is_viewing() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        arbiter.viewed();
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let update = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 2), at(10));
        assert_eq!(update.notify, None);
        assert!(!arbiter.unseen_done());

        arbiter.unviewed();
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 3), at(20));
        let update = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 4), at(30));
        assert_eq!(update.notify, Some(Notify::Done));
        assert!(arbiter.unseen_done());

        arbiter.viewed();
        assert!(!arbiter.unseen_done());
    }

    #[test]
    fn an_interrupted_turn_does_not_notify() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let update = arbiter.apply(hook(EventKind::Interrupted, Claim::Idle, 2), at(10));
        assert_eq!(update.notify, None);
        assert!(!arbiter.unseen_done());
        assert_eq!(arbiter.status(), &Status::Idle);
    }

    #[test]
    fn a_new_turn_clears_unseen_done() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 2), at(10));
        assert!(arbiter.unseen_done());
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 3), at(20));
        assert!(!arbiter.unseen_done());
    }

    #[test]
    fn failed_turns_notify_as_failed() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let update = arbiter.apply(hook(EventKind::Error, Claim::Error, 2), at(10));
        assert_eq!(update.notify, Some(Notify::Failed));
        assert_eq!(update.event.unwrap().kind, EventKind::Error);
    }

    #[test]
    fn idle_without_prior_work_is_not_done() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let update = arbiter.observe_screen(&screen(AgentState::Idle, true), at(0));
        assert_eq!(update.notify, None);
        assert!(!arbiter.unseen_done());
    }

    #[test]
    fn restored_sessions_never_report_done_until_they_work() {
        let mut arbiter = Arbiter::restored(
            ArbiterConfig::new(HookCoverage::Partial),
            Some(PaneId::new("p1")),
            SessionInfo::new(AgentKind::Claude, Lane::Pty),
            T0,
        );
        assert_eq!(arbiter.status(), &Status::Idle);
        assert!(arbiter.is_restored_unconfirmed());
        assert_eq!(
            arbiter.tick(at(10)),
            Update::default(),
            "no evidence keeps idle"
        );
        let _ = arbiter.observe_screen(&screen(AgentState::Idle, true), at(20));
        assert!(!arbiter.unseen_done());
        let _ = arbiter.observe_screen(&screen(AgentState::Working, true), at(30));
        assert!(!arbiter.is_restored_unconfirmed());
        let update = arbiter.observe_screen(&screen(AgentState::Idle, true), at(40));
        assert_eq!(update.notify, Some(Notify::Done));
    }

    #[test]
    fn working_claims_go_stale_without_output() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let thirty_min = 30 * 60 * 1000;
        arbiter.pty_output(at(1000));
        assert_eq!(arbiter.next_deadline(), Some(at(1000 + thirty_min)));
        assert_eq!(arbiter.tick(at(thirty_min)).event, None);
        let update = arbiter.tick(at(1000 + thirty_min));
        let event = update.event.unwrap();
        assert_eq!(event.kind, EventKind::Stale);
        assert_eq!(event.status, Status::Unknown);
    }

    #[test]
    fn a_turn_that_went_stale_still_notifies_when_it_finishes() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let thirty_min = 30 * 60 * 1000;
        assert_eq!(
            arbiter.tick(at(thirty_min)).event.unwrap().kind,
            EventKind::Stale
        );
        let update = arbiter.apply(
            hook(EventKind::TurnEnded, Claim::Idle, 2),
            at(thirty_min + 1),
        );
        assert_eq!(update.notify, Some(Notify::Done));
    }

    #[test]
    fn a_stale_turn_ends_with_its_agent() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let thirty_min = 30 * 60 * 1000;
        let _ = arbiter.tick(at(thirty_min));
        let _ = arbiter.process_exited(at(thirty_min + 1));
        arbiter.process_started(at(thirty_min + 2));
        let update = arbiter.apply(
            hook(EventKind::TurnEnded, Claim::Idle, 2),
            at(thirty_min + 3),
        );
        assert_eq!(update.notify, None);
    }

    #[test]
    fn blocked_never_goes_stale() {
        let mut arbiter = new_arbiter(HookCoverage::FullLifecycle);
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        assert_eq!(arbiter.tick(at(10 * 60 * 60 * 1000)).event, None);
        assert_eq!(arbiter.status().state(), AgentState::Blocked);
    }

    #[test]
    fn session_facts_are_merged_and_force_an_event() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
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
        let update = arbiter.apply(start, at(0));
        let event = update.event.unwrap();
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
        let event = arbiter.apply(changed, at(1)).event.unwrap();
        assert_eq!(event.kind, EventKind::SessionIdChanged);
        assert_eq!(
            arbiter.session().native_id,
            Some(NativeSessionId::new("def"))
        );
        assert_eq!(
            arbiter.session().cwd.as_deref(),
            Some(std::path::Path::new("/src"))
        );
    }

    #[test]
    fn subagent_signals_pass_through_without_changing_state() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let mut subagent = hook(EventKind::TurnEnded, Claim::Idle, 2);
        subagent.subagent = Some(Subagent {
            id: SubagentId::new("def456"),
            agent_type: Some("Explore".into()),
        });
        let update = arbiter.apply(subagent, at(10));
        let event = update.event.unwrap();
        assert_eq!(event.status, Status::Working);
        assert!(event.subagent.is_some());
        assert_eq!(update.notify, None);
        assert_eq!(arbiter.status(), &Status::Working);
    }

    #[test]
    fn turn_details_arriving_after_the_screen_still_emit() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0));
        let _ = arbiter.observe_screen(&screen(AgentState::Idle, true), at(1000));
        let _ = arbiter.tick(at(3000));
        assert_eq!(arbiter.status(), &Status::Idle);
        let mut stop = hook(EventKind::TurnEnded, Claim::Idle, 2);
        stop.turn = Some(crate::Turn {
            outcome: crate::TurnOutcome::Completed,
            last_message: Some("done".into()),
        });
        let event = arbiter.apply(stop, at(3100)).event.unwrap();
        assert_eq!(event.kind, EventKind::TurnEnded);
        assert_eq!(event.turn.unwrap().last_message.as_deref(), Some("done"));
    }

    #[test]
    fn freeze_verdicts_are_ignored() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let _ = arbiter.observe_screen(&screen(AgentState::Working, true), at(0));
        let freeze = ScreenVerdict::Freeze {
            rule_id: "transcript_viewer".into(),
        };
        assert_eq!(arbiter.observe_screen(&freeze, at(10)), Update::default());
        assert_eq!(arbiter.status(), &Status::Working);
    }

    #[test]
    fn request_ids_fall_back_to_the_native_session() {
        let mut session = SessionInfo::new(AgentKind::Kimi, Lane::Acp);
        session.native_id = Some(NativeSessionId::new("k1"));
        let mut arbiter = Arbiter::new(
            ArbiterConfig::new(HookCoverage::FullLifecycle),
            None,
            session,
            T0,
        );
        let _ = arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 1),
            at(0),
        );
        assert_eq!(request_id(&arbiter).as_str(), "k1/r1");
    }

    /// A deterministic replay of a full Claude turn mixing every source.
    #[test]
    fn claude_turn_scenario() {
        let mut arbiter = new_arbiter(HookCoverage::Partial);
        let mut log = Vec::new();
        let mut push = |update: Update| {
            if let Some(event) = update.event {
                log.push((event.kind, event.status.state(), event.source));
            }
        };
        push(arbiter.apply(hook(EventKind::TurnStarted, Claim::Working, 1), at(0)));
        push(arbiter.observe_screen(&screen(AgentState::Working, true), at(100)));
        push(arbiter.apply(
            hook(EventKind::Blocked, Claim::Blocked(permission("Bash")), 2),
            at(5000),
        ));
        push(arbiter.observe_screen(&screen(AgentState::Blocked, true), at(5100)));
        arbiter
            .decide(
                decision(&arbiter, ApprovalChoice::AllowOnce, "alice"),
                at(8000),
            )
            .unwrap();
        push(arbiter.observe_screen(&screen(AgentState::Working, true), at(8100)));
        push(arbiter.apply(hook(EventKind::TurnEnded, Claim::Idle, 3), at(20_000)));
        push(arbiter.observe_screen(&screen(AgentState::Idle, true), at(20_050)));
        assert_eq!(
            log,
            [
                (EventKind::TurnStarted, AgentState::Working, Source::Hook),
                (EventKind::Blocked, AgentState::Blocked, Source::Hook),
                (EventKind::Unblocked, AgentState::Working, Source::Screen),
                (EventKind::TurnEnded, AgentState::Idle, Source::Hook),
            ]
        );
        assert!(arbiter.unseen_done());
    }
}
