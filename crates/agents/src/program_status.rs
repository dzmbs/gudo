//! `src/terminal/osc/parsers/program_status.zig`).
//!
//! A report body is a list of `key=value` pairs separated by colons:
//!
//! ```text
//! ESC ] 7501 ; state=blocked:kind=permission:app=claude-code:msg=<base64> ESC \
//! ```
//!
//! This module parses the body (everything after `7501;`) with the spec's rules, encodes bodies for
//! the hook shim, and maps a report to a [`Signal`]. Besides the spec keys it reads one extension,
//! `seq=<u64>`, which our shim writes so the arbiter can order a report against the same event sent
//! over the socket. Terminals that follow the spec ignore unknown keys.

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};

use crate::event::{
    BlockedReason, Blocker, Confidence, EventKind, Seq, Source, Subagent, SubagentId, Turn,
    TurnOutcome,
};
use crate::signal::{Claim, Signal};

const MAX_BODY_BYTES: usize = 4096 - "\x1b]7501;".len() - "\x1b\\".len();
const MAX_KEY_BYTES: usize = 16;
const MAX_MSG_ENCODED_BYTES: usize = 2732;
const MAX_MSG_BYTES: usize = 2048;
const MAX_TITLE_ENCODED_BYTES: usize = 256;
const MAX_TITLE_BYTES: usize = 192;
const MAX_APP_BYTES: usize = 32;
const MAX_ID_BYTES: usize = 128;
const MAX_ID_SEGMENT_BYTES: usize = 32;
const MAX_ID_DEPTH: usize = 8;

/// The `state` of a report.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProgramState {
    /// At rest, waiting for the user's next instruction.
    Idle,
    /// Running.
    Working,
    /// Finished work the user hasn't looked at yet.
    Done,
    /// Waiting on the user; `kind` says for what.
    Blocked,
    /// Failed and stopped.
    Error,
    /// Not a state: removes the record.
    Clear,
}

impl ProgramState {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "idle" => Self::Idle,
            "working" => Self::Working,
            "done" => Self::Done,
            "blocked" => Self::Blocked,
            "error" => Self::Error,
            "clear" => Self::Clear,
            _ => return None,
        })
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Done => "done",
            Self::Blocked => "blocked",
            Self::Error => "error",
            Self::Clear => "clear",
        }
    }
}

/// What a blocked program needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProgramKind {
    /// Approval to do something.
    Permission,
    /// An answer the user has to type.
    Question,
    /// A login or credential.
    Auth,
}

impl ProgramKind {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "permission" => Self::Permission,
            "question" => Self::Question,
            "auth" => Self::Auth,
            _ => return None,
        })
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Permission => "permission",
            Self::Question => "question",
            Self::Auth => "auth",
        }
    }
}

/// A valid OSC 7501 report.
///
/// # Examples
///
/// ```
/// use agents::{ProgramState, ProgramStatus};
///
/// let report = ProgramStatus::parse("state=working:app=claude-code:msg=UnVubmluZyB0ZXN0cw")
///     .unwrap();
/// assert_eq!(report.state, ProgramState::Working);
/// assert_eq!(report.msg.as_deref(), Some("Running tests"));
/// assert_eq!(ProgramStatus::parse(&report.to_body()), Some(report));
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgramStatus {
    /// What the program is doing.
    pub state: ProgramState,
    /// What a blocked program needs. Only set when `state` is blocked.
    pub kind: Option<ProgramKind>,
    /// The record this report is about; `None` is the program itself.
    pub id: Option<String>,
    /// A stable program name, e.g. `claude-code`.
    pub app: Option<String>,
    /// Percent complete, only for working and blocked.
    pub progress: Option<u8>,
    /// A short decoded label.
    pub title: Option<String>,
    /// One decoded line for people.
    pub msg: Option<String>,
    /// Our `seq` extension.
    pub seq: Option<Seq>,
}

fn is_name(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b))
}

fn is_value(s: &str) -> bool {
    s.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b"_.+-,/=".contains(&b))
}

fn valid_id(id: &str) -> bool {
    id.len() <= MAX_ID_BYTES
        && id.split('/').count() <= MAX_ID_DEPTH
        && id
            .split('/')
            .all(|seg| seg.len() <= MAX_ID_SEGMENT_BYTES && is_name(seg))
}

/// Decodes base64 (padding optional) to text with no control characters.
fn decode_text(encoded: &str, max: usize) -> Result<String, ()> {
    let engine = if encoded.ends_with('=') {
        &STANDARD
    } else {
        &STANDARD_NO_PAD
    };
    let bytes = engine.decode(encoded).map_err(|_| ())?;
    if bytes.len() > max {
        return Err(());
    }
    let text = String::from_utf8(bytes).map_err(|_| ())?;
    if text.chars().any(char::is_control) {
        return Err(());
    }
    Ok(text)
}

impl ProgramStatus {
    /// Creates a report with only a state.
    pub fn new(state: ProgramState) -> Self {
        Self {
            state,
            kind: None,
            id: None,
            app: None,
            progress: None,
            title: None,
            msg: None,
            seq: None,
        }
    }

    /// Parses a report body (the text after `7501;`).
    ///
    /// Follows the spec: a malformed pair or unknown key is skipped, the last value of a repeated
    /// key wins, and the whole report is discarded (returns `None`) when `state` is missing or
    /// unknown, any key or value exceeds its limit, an `id` is malformed, or `title`/`msg` is not
    /// base64 of control-free UTF-8. The support query `?` also returns `None`.
    pub fn parse(body: &str) -> Option<Self> {
        if body.len() > MAX_BODY_BYTES || body == "?" {
            return None;
        }
        let mut state = None;
        let mut report = Self::new(ProgramState::Idle);
        let mut kind = None;
        let mut progress = None;
        for pair in body.split(':') {
            let Some((key, value)) = pair.split_once('=') else {
                continue;
            };
            let key = key.trim();
            if key.len() > MAX_KEY_BYTES {
                return None;
            }
            let value = value.trim();
            // libghostty skips values outside the alphabet before any other check, ids included.
            if !is_value(value) {
                continue;
            }
            match key {
                "id" => {
                    // A bad id discards the report rather than falling back to the root record.
                    if !valid_id(value) {
                        return None;
                    }
                    report.id = Some(value.to_owned());
                }
                "state" => state = Some(value),
                "kind" => kind = Some(value),
                "progress" => progress = Some(value),
                "app" => {
                    if value.len() > MAX_APP_BYTES {
                        return None;
                    }
                    report.app = is_name(value).then(|| value.to_owned());
                }
                "title" => {
                    if value.len() > MAX_TITLE_ENCODED_BYTES {
                        return None;
                    }
                    report.title = Some(value.to_owned());
                }
                "msg" => {
                    if value.len() > MAX_MSG_ENCODED_BYTES {
                        return None;
                    }
                    report.msg = Some(value.to_owned());
                }
                "seq" => report.seq = value.parse().ok().map(Seq),
                _ => {}
            }
        }
        report.state = ProgramState::parse(state?)?;
        report.title = match report.title.filter(|t| !t.is_empty()) {
            Some(t) => Some(decode_text(&t, MAX_TITLE_BYTES).ok()?),
            None => None,
        };
        report.msg = match report.msg.filter(|m| !m.is_empty()) {
            Some(m) => Some(decode_text(&m, MAX_MSG_BYTES).ok()?),
            None => None,
        };
        if report.state == ProgramState::Blocked {
            report.kind = kind.and_then(ProgramKind::parse);
        }
        if matches!(report.state, ProgramState::Working | ProgramState::Blocked) {
            report.progress = progress
                .filter(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
                .and_then(|p| p.parse().ok())
                .filter(|&p| p <= 100);
        }
        Some(report)
    }

    /// Encodes the report as a body for `ESC ] 7501 ; <body> ESC \`.
    ///
    /// `title` and `msg` are base64-encoded. Callers must keep them within the spec limits
    /// (192 and 2048 bytes); a terminal discards longer reports.
    pub fn to_body(&self) -> String {
        let mut body = format!("state={}", self.state.as_str());
        let mut push = |key: &str, value: &str| {
            body.push(':');
            body.push_str(key);
            body.push('=');
            body.push_str(value);
        };
        if let Some(kind) = self.kind {
            push("kind", kind.as_str());
        }
        if let Some(progress) = self.progress {
            push("progress", &progress.to_string());
        }
        if let Some(id) = &self.id {
            push("id", id);
        }
        if let Some(app) = &self.app {
            push("app", app);
        }
        if let Some(title) = &self.title {
            push("title", &STANDARD.encode(title));
        }
        if let Some(msg) = &self.msg {
            push("msg", &STANDARD.encode(msg));
        }
        if let Some(Seq(seq)) = self.seq {
            push("seq", &seq.to_string());
        }
        body
    }

    /// Maps the report to a signal, or `None` if it is not from `app`.
    ///
    /// Any program in the pane may emit OSC 7501 (`cargo`, `terraform`), so only reports whose
    /// `app` matches the agent's are trusted. A report with an `id` describes a sub-record and
    /// becomes a subagent signal that never changes the lead's state.
    pub fn to_signal(&self, app: &str) -> Option<Signal> {
        if self.app.as_deref() != Some(app) {
            return None;
        }
        let (kind, claim) = match self.state {
            ProgramState::Idle => (EventKind::TurnEnded, Claim::Idle),
            ProgramState::Working => (EventKind::TurnStarted, Claim::Working),
            ProgramState::Done => (EventKind::TurnEnded, Claim::Idle),
            ProgramState::Blocked => {
                let reason = match self.kind {
                    Some(ProgramKind::Permission) => BlockedReason::Permission,
                    Some(ProgramKind::Question) => BlockedReason::Question,
                    Some(ProgramKind::Auth) => BlockedReason::Auth,
                    None => BlockedReason::Other,
                };
                let mut blocker = Blocker::new(reason);
                blocker.summary = self.msg.clone();
                (EventKind::Blocked, Claim::Blocked(blocker))
            }
            ProgramState::Error => (EventKind::Error, Claim::Error),
            ProgramState::Clear => (EventKind::SessionEnded, Claim::Release),
        };
        let mut signal = Signal::new(Source::Osc7501, Confidence::Strong, kind);
        signal.seq = self.seq;
        if self.state == ProgramState::Done {
            signal.turn = Some(Turn {
                outcome: TurnOutcome::Completed,
                last_message: self.msg.clone(),
            });
        }
        match &self.id {
            Some(id) => {
                signal.subagent = Some(Subagent {
                    id: SubagentId::new(id.clone()),
                    agent_type: None,
                })
            }
            None => signal.claim = Some(claim),
        }
        Some(signal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_key() {
        // The fixture from libghostty's own parser test.
        let report = ProgramStatus::parse(
            "state=blocked:kind=permission:progress=42:id=tf/plan:app=terraform\
             :title=UGxhbg==:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/",
        )
        .unwrap();
        assert_eq!(report.state, ProgramState::Blocked);
        assert_eq!(report.kind, Some(ProgramKind::Permission));
        assert_eq!(report.progress, Some(42));
        assert_eq!(report.id.as_deref(), Some("tf/plan"));
        assert_eq!(report.app.as_deref(), Some("terraform"));
        assert_eq!(report.title.as_deref(), Some("Plan"));
        assert_eq!(
            report.msg.as_deref(),
            Some("Apply 3 to add, 1 to change, 0 to destroy?")
        );
    }

    #[test]
    fn is_forgiving_about_pairs() {
        let report = ProgramStatus::parse("state=idle:future=yes:oops").unwrap();
        assert_eq!(report, ProgramStatus::new(ProgramState::Idle));
        let last_wins = ProgramStatus::parse("state=working:state=idle").unwrap();
        assert_eq!(last_wins.state, ProgramState::Idle);
    }

    #[test]
    fn ignores_kind_and_progress_on_other_states() {
        let report = ProgramStatus::parse("state=idle:kind=permission:progress=10").unwrap();
        assert_eq!((report.kind, report.progress), (None, None));
        let out_of_range = ProgramStatus::parse("state=working:progress=101").unwrap();
        assert_eq!(out_of_range.progress, None);
    }

    #[test]
    fn discards_invalid_reports() {
        for body in [
            "",
            "?",
            "kind=permission",
            "state=sleeping",
            "state=clear:id=a//b",
            "state=idle:msg=A",  // not base64
            "state=idle:msg=AA", // decodes to a NUL control byte
            "state=idle:averyveryverylongkey=1",
        ] {
            assert_eq!(ProgramStatus::parse(body), None, "{body:?}");
        }
        let skipped_id = ProgramStatus::parse("state=idle:id=bad id").unwrap();
        assert_eq!(
            skipped_id.id, None,
            "a value outside the alphabet is skipped, as in libghostty"
        );
        let long_app = format!("state=idle:app={}", "a".repeat(33));
        assert_eq!(ProgramStatus::parse(&long_app), None);
    }

    #[test]
    fn round_trips_through_the_encoder() {
        let mut report = ProgramStatus::new(ProgramState::Blocked);
        report.kind = Some(ProgramKind::Question);
        report.app = Some("claude-code".into());
        report.msg = Some("Which framework?".into());
        report.seq = Some(Seq(42));
        assert_eq!(ProgramStatus::parse(&report.to_body()), Some(report));
    }

    #[test]
    fn maps_to_signals_for_the_right_app_only() {
        let report =
            ProgramStatus::parse("state=blocked:kind=permission:app=claude-code:seq=7").unwrap();
        assert_eq!(report.to_signal("codex"), None);
        let signal = report.to_signal("claude-code").unwrap();
        assert_eq!(signal.source, Source::Osc7501);
        assert_eq!(signal.seq, Some(Seq(7)));
        assert_eq!(
            signal.claim,
            Some(Claim::Blocked(Blocker::new(BlockedReason::Permission)))
        );

        let sub = ProgramStatus::parse("state=working:app=claude-code:id=agent1")
            .unwrap()
            .to_signal("claude-code")
            .unwrap();
        assert_eq!(sub.claim, None);
        assert_eq!(sub.subagent.unwrap().id.as_str(), "agent1");

        let clear = ProgramStatus::parse("state=clear:app=claude-code")
            .unwrap()
            .to_signal("claude-code")
            .unwrap();
        assert_eq!(clear.claim, Some(Claim::Release));
    }
}
