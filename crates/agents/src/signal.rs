//! Raw evidence from one source, before arbitration.

use std::path::PathBuf;

use crate::event::{Blocker, Confidence, EventKind, NativeSessionId, Seq, Source, Subagent, Turn};

/// The state a source claims the agent is in.
#[derive(Debug, Clone, PartialEq)]
pub enum Claim {
    /// The agent is running a turn.
    Working,
    /// The agent is waiting on the user.
    Blocked(Blocker),
    /// The agent is at rest.
    Idle,
    /// The last turn failed.
    Error,
    /// The source withdraws its earlier claim (OSC 7501 `clear`, session end).
    Release,
}

/// Session facts a signal carries, e.g. from a `SessionStart` hook.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SessionUpdate {
    /// The agent's session id.
    pub native_id: Option<NativeSessionId>,
    /// The transcript file.
    pub transcript: Option<PathBuf>,
    /// The working directory.
    pub cwd: Option<PathBuf>,
}

impl SessionUpdate {
    /// Returns whether no field is set.
    pub fn is_empty(&self) -> bool {
        self.native_id.is_none() && self.transcript.is_none() && self.cwd.is_none()
    }
}

/// One piece of evidence about an agent, produced by an adapter parser and consumed by
/// [`Arbiter::apply`](crate::Arbiter::apply).
#[derive(Debug, Clone, PartialEq)]
pub struct Signal {
    /// Where it came from.
    pub source: Source,
    /// How far it is trusted.
    pub confidence: Confidence,
    /// The source's sequence number. The arbiter drops signals that are not newer than the last
    /// one accepted from the same source.
    pub seq: Option<Seq>,
    /// What happened.
    pub kind: EventKind,
    /// The state the source claims, or `None` if the signal carries no state (e.g. `SessionStart`
    /// during an auto-compact, which can fire mid-turn).
    pub claim: Option<Claim>,
    /// Turn details on turn end.
    pub turn: Option<Turn>,
    /// Set when the signal is about a subagent; it then never changes the lead's state.
    pub subagent: Option<Subagent>,
    /// Session facts.
    pub session: SessionUpdate,
}

impl Signal {
    /// Creates a signal with no claim, turn, subagent or session facts.
    pub fn new(source: Source, confidence: Confidence, kind: EventKind) -> Self {
        Self {
            source,
            confidence,
            seq: None,
            kind,
            claim: None,
            turn: None,
            subagent: None,
            session: SessionUpdate::default(),
        }
    }

    /// Sets the claim.
    #[must_use]
    pub fn with_claim(mut self, claim: Claim) -> Self {
        self.claim = Some(claim);
        self
    }

    /// Sets the sequence number.
    #[must_use]
    pub fn with_seq(mut self, seq: Seq) -> Self {
        self.seq = Some(seq);
        self
    }
}
