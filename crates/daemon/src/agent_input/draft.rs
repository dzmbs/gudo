//! Ephemeral input accounting and single-use native-send admission, not screen inference.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use tokio::sync::watch;

static NEXT_TICKET: AtomicU64 = AtomicU64::new(0);
const INPUT_BYTES: usize = crate::mp::prompt::MAX_PROMPT;
pub(super) const CONFIRMATION_WAIT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Receipt {
    Waiting,
    Confirmed,
    NotConfirmed,
    Expired,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Offer {
    pub ticket: u64,
    pub revision: u64,
    pub needs_confirmation: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Intent {
    Prompt,
    Interrupt(u64),
}

struct Ticket {
    id: u64,
    session: Option<String>,
    intent: Intent,
}

struct Pending {
    session: String,
    prompt: String,
    revision: u64,
    deadline: Instant,
    receipt: watch::Sender<Receipt>,
}

#[derive(Default)]
pub(crate) struct Draft {
    revision: u64,
    baseline: Option<String>,
    // Never written to disk or exposed through the API. Overflow stays dirty, not truncated-clean.
    input: Vec<u8>,
    byte_count: u64,
    tainted_submission: bool,
    ticket: Option<Ticket>,
    pending: Option<Pending>,
    active_turn: Option<String>,
    turn_seq: u64,
    interrupted_turn: Option<u64>,
}

pub(crate) enum Admission<T = watch::Receiver<Receipt>> {
    Confirm(Offer),
    Ready(T),
    Refused,
}

impl Draft {
    #[cfg(test)]
    pub(super) fn is_pending(&self) -> bool {
        self.pending.is_some()
    }

    pub(crate) fn input(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.revision = self.revision.saturating_add(1);
        self.byte_count = self.byte_count.saturating_add(bytes.len() as u64);
        let retained = bytes
            .len()
            .min(INPUT_BYTES.saturating_sub(self.input.len()));
        self.input.extend_from_slice(&bytes[..retained]);
        self.tainted_submission |= self.pending.is_some();
        self.finish(Receipt::NotConfirmed);
    }

    pub(crate) fn prepare(&mut self, session: Option<&str>, now: Instant) -> Option<Offer> {
        self.prepare_for(Intent::Prompt, session, now)
    }

    pub(crate) fn record_turn(&mut self, session: Option<&str>, seq: u64) {
        if seq <= self.turn_seq {
            return;
        }
        self.turn_seq = seq;
        self.active_turn = session
            .filter(|session| !session.is_empty())
            .map(str::to_owned);
    }

    fn interrupt_intent(&self, session: Option<&str>) -> Option<Intent> {
        (session.is_some()
            && self.active_turn.as_deref() == session
            && self.interrupted_turn != Some(self.turn_seq))
        .then_some(Intent::Interrupt(self.turn_seq))
    }

    pub(crate) fn prepare_interrupt(
        &mut self,
        session: Option<&str>,
        now: Instant,
    ) -> Option<Offer> {
        self.prepare_for(self.interrupt_intent(session)?, session, now)
    }

    fn prepare_for(
        &mut self,
        intent: Intent,
        session: Option<&str>,
        now: Instant,
    ) -> Option<Offer> {
        self.expire(now);
        if (intent == Intent::Prompt && self.pending.is_some()) || self.revision == u64::MAX {
            return None;
        }
        // Neither a replacement pane nor a new daemon process on this boot may recycle a ticket.
        NEXT_TICKET.fetch_max(crate::hook_seq(), Ordering::Relaxed);
        let previous = NEXT_TICKET
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .ok()?;
        self.ticket = Some(Ticket {
            id: previous + 1,
            session: session.map(str::to_owned),
            intent,
        });
        Some(self.offer(session))
    }

    fn offer(&self, session: Option<&str>) -> Offer {
        Offer {
            ticket: self.ticket.as_ref().map_or(0, |ticket| ticket.id),
            revision: self.revision,
            needs_confirmation: session.is_none()
                || self.baseline.as_deref() != session
                || self.byte_count != 0,
        }
    }

    fn authorize(
        &mut self,
        intent: Intent,
        ticket: u64,
        session: Option<&str>,
        confirmation: Option<u64>,
        now: Instant,
    ) -> Admission<()> {
        self.expire(now);
        let Some(active) = self.ticket.as_ref() else {
            return Admission::Refused;
        };
        if active.id != ticket
            || active.session.as_deref() != session
            || active.intent != intent
            || (intent == Intent::Prompt && self.pending.is_some())
        {
            return Admission::Refused;
        }
        let offer = self.offer(session);
        if self.revision == u64::MAX {
            return Admission::Refused;
        }
        if offer.needs_confirmation && confirmation != Some(self.revision) {
            return Admission::Confirm(offer);
        }
        Admission::Ready(())
    }

    pub(crate) fn admit_interrupt(
        &mut self,
        ticket: u64,
        session: Option<&str>,
        confirmation: Option<u64>,
        now: Instant,
    ) -> Admission<()> {
        let Some(intent) = self.interrupt_intent(session) else {
            return Admission::Refused;
        };
        let admission = self.authorize(intent, ticket, session, confirmation, now);
        if matches!(admission, Admission::Ready(())) {
            self.ticket = None;
            self.interrupted_turn = Some(self.turn_seq);
            self.input(b"\x1b");
        }
        admission
    }

    pub(crate) fn admit(
        &mut self,
        ticket: u64,
        session: Option<&str>,
        prompt: &str,
        confirmation: Option<u64>,
        now: Instant,
    ) -> Admission {
        match self.authorize(Intent::Prompt, ticket, session, confirmation, now) {
            Admission::Confirm(offer) => return Admission::Confirm(offer),
            Admission::Refused => return Admission::Refused,
            Admission::Ready(()) => {}
        }
        let Some(prompt) = normalize(prompt) else {
            return Admission::Refused;
        };
        self.ticket = None;
        let (receipt, receiver) = watch::channel(Receipt::Waiting);
        self.pending = Some(Pending {
            session: session.unwrap_or_default().to_owned(),
            prompt,
            revision: self.revision,
            deadline: now + CONFIRMATION_WAIT,
            receipt,
        });
        // An enqueue is not a new clean baseline, even if the transport later reports success.
        self.baseline = None;
        Admission::Ready(receiver)
    }

    pub(crate) fn submitted(
        &mut self,
        session: &str,
        prompt: &str,
        writes_pending: bool,
        now: Instant,
    ) {
        self.expire(now);
        if let Some(pending) = &self.pending {
            let receipt = if !writes_pending
                && !session.is_empty()
                && pending.session == session
                && normalize(prompt).as_deref() == Some(pending.prompt.as_str())
                && pending.revision == self.revision
            {
                Receipt::Confirmed
            } else {
                Receipt::NotConfirmed
            };
            self.finish(receipt);
        }
        self.revision = self.revision.saturating_add(1);
        self.input.clear();
        self.byte_count = 0;
        self.baseline = (!writes_pending && !self.tainted_submission && !session.is_empty())
            .then(|| session.to_owned());
        self.tainted_submission = false;
    }

    pub(crate) fn expire(&mut self, now: Instant) {
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| now >= pending.deadline)
        {
            self.finish(Receipt::Expired);
        }
    }

    pub(crate) fn finish(&mut self, receipt: Receipt) {
        if let Some(pending) = self.pending.take() {
            let _ = pending.receipt.send(receipt);
        }
    }

    pub(crate) fn close(&mut self) {
        self.finish(Receipt::NotConfirmed);
        self.ticket = None;
        self.baseline = None;
        self.active_turn = None;
        self.input.clear();
        self.byte_count = 0;
        self.revision = self.revision.saturating_add(1);
    }
}

fn normalize(text: &str) -> Option<String> {
    let mut normalized = String::with_capacity(text.len().min(INPUT_BYTES));
    for word in text.split_whitespace() {
        let separator = usize::from(!normalized.is_empty());
        if word.len()
            > INPUT_BYTES
                .saturating_sub(normalized.len())
                .saturating_sub(separator)
        {
            return None;
        }
        if separator != 0 {
            normalized.push(' ');
        }
        normalized.push_str(word);
    }
    Some(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clean() -> Draft {
        let mut draft = Draft::default();
        draft.submitted("session", "previous", false, Instant::now());
        draft.record_turn(Some("session"), 1);
        draft
    }

    #[test]
    fn an_interrupt_needs_a_hook_turn_and_cannot_cancel_a_new_turn_in_the_same_session() {
        let mut draft = Draft::default();
        let now = Instant::now();
        draft.submitted("session", "baseline alone is not working proof", false, now);
        assert!(draft.prepare_interrupt(Some("session"), now).is_none());
        draft.record_turn(Some("session"), 10);
        let offer = draft.prepare_interrupt(Some("session"), now).unwrap();
        draft.record_turn(Some("session"), 20);
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), None, now),
            Admission::Refused
        ));
        let offer = draft.prepare_interrupt(Some("session"), now).unwrap();
        draft.record_turn(None, 19);
        assert!(draft.interrupt_intent(Some("session")).is_some());
        draft.record_turn(None, 21);
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), None, now),
            Admission::Refused
        ));
        assert!(draft.prepare_interrupt(Some("session"), now).is_none());
    }

    #[test]
    fn an_interrupt_is_once_only_and_dirties_the_next_prompt() {
        let mut draft = clean();
        let now = Instant::now();
        let offer = draft.prepare_interrupt(Some("session"), now).unwrap();
        assert!(!offer.needs_confirmation);
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), None, now),
            Admission::Ready(())
        ));
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), None, now),
            Admission::Refused
        ));
        assert!(draft.prepare_interrupt(Some("session"), now).is_none());
        assert!(
            draft
                .prepare(Some("session"), now)
                .unwrap()
                .needs_confirmation
        );
    }

    #[test]
    fn interrupt_confirmation_tracks_the_current_draft_revision() {
        let mut draft = clean();
        let now = Instant::now();
        draft.input(b"Mac draft");
        let offer = draft.prepare_interrupt(Some("session"), now).unwrap();
        assert!(offer.needs_confirmation);
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), None, now),
            Admission::Confirm(_)
        ));
        draft.input(b"more");
        let current =
            match draft.admit_interrupt(offer.ticket, Some("session"), Some(offer.revision), now) {
                Admission::Confirm(current) => current,
                _ => panic!("a stale warning cannot authorize Escape"),
            };
        assert!(current.revision > offer.revision);
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), Some(current.revision), now),
            Admission::Ready(())
        ));
    }

    #[test]
    fn interrupt_tickets_are_not_prompt_tickets_or_replacement_session_authority() {
        let mut draft = clean();
        let now = Instant::now();
        let offer = draft.prepare(Some("session"), now).unwrap();
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), None, now),
            Admission::Refused
        ));
        let offer = draft.prepare_interrupt(Some("session"), now).unwrap();
        assert!(matches!(
            draft.admit(offer.ticket, Some("session"), "hello", None, now),
            Admission::Refused
        ));
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("replacement"), None, now),
            Admission::Refused
        ));
        draft.close();
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), None, now),
            Admission::Refused
        ));
    }

    #[test]
    fn an_explicit_interrupt_can_cancel_a_pending_receipt_without_making_a_late_hook_clean() {
        let mut draft = clean();
        let receipt = send(&mut draft);
        let now = Instant::now();
        let offer = draft.prepare_interrupt(Some("session"), now).unwrap();
        assert!(offer.needs_confirmation);
        assert!(matches!(
            draft.admit_interrupt(offer.ticket, Some("session"), Some(offer.revision), now),
            Admission::Ready(())
        ));
        assert_eq!(*receipt.borrow(), Receipt::NotConfirmed);
        draft.submitted("session", "hello world", false, now);
        assert_eq!(*receipt.borrow(), Receipt::NotConfirmed);
        assert!(
            draft
                .prepare(Some("session"), now)
                .unwrap()
                .needs_confirmation
        );
    }

    fn send(draft: &mut Draft) -> watch::Receiver<Receipt> {
        let now = Instant::now();
        let offer = draft.prepare(Some("session"), now).unwrap();
        match draft.admit(offer.ticket, Some("session"), "hello world", None, now) {
            Admission::Ready(receipt) => receipt,
            _ => panic!("clean draft must admit"),
        }
    }

    #[test]
    fn clean_send_waits_for_matching_session_and_normalized_text() {
        let mut draft = clean();
        let receipt = send(&mut draft);
        assert_eq!(*receipt.borrow(), Receipt::Waiting);
        draft.submitted("session", " hello\n  world\t", false, Instant::now());
        assert_eq!(*receipt.borrow(), Receipt::Confirmed);
    }

    #[test]
    fn dirty_unknown_and_interrupted_drafts_require_current_explicit_confirmation() {
        for bytes in [b"typed".as_slice(), b"\x1b", b"\x03", b"\x7f"] {
            let mut draft = clean();
            draft.input(bytes);
            let offer = draft.prepare(Some("session"), Instant::now()).unwrap();
            assert!(offer.needs_confirmation);
            assert!(matches!(
                draft.admit(offer.ticket, Some("session"), "hi", None, Instant::now()),
                Admission::Confirm(_)
            ));
            draft.input(b"new typing");
            assert!(matches!(
                draft.admit(
                    offer.ticket,
                    Some("session"),
                    "hi",
                    Some(offer.revision),
                    Instant::now()
                ),
                Admission::Confirm(_)
            ));
            assert!(matches!(
                draft.admit(
                    offer.ticket,
                    Some("session"),
                    "hi",
                    Some(draft.revision),
                    Instant::now()
                ),
                Admission::Ready(_)
            ));
        }
        let offer = Draft::default().prepare(None, Instant::now()).unwrap();
        assert!(offer.needs_confirmation);
    }

    #[test]
    fn typing_during_send_and_mismatched_hook_never_confirm_or_resend() {
        for (session, prompt, typing) in [
            ("other", "hello world", false),
            ("session", "different", false),
            ("session", "hello world", true),
        ] {
            let mut draft = clean();
            let receipt = send(&mut draft);
            if typing {
                draft.input(b"x");
            }
            draft.submitted(session, prompt, false, Instant::now());
            assert_eq!(*receipt.borrow(), Receipt::NotConfirmed);
            assert!(matches!(
                draft.admit(1, Some("session"), "hello world", None, Instant::now()),
                Admission::Refused
            ));
        }
    }

    #[test]
    fn timeout_and_exit_are_terminal_even_if_a_matching_hook_arrives_later() {
        for exit in [false, true] {
            let mut draft = clean();
            let receipt = send(&mut draft);
            if exit {
                draft.close();
            } else {
                draft.expire(Instant::now() + CONFIRMATION_WAIT);
            }
            draft.submitted("session", "hello world", false, Instant::now());
            assert_eq!(
                *receipt.borrow(),
                if exit {
                    Receipt::NotConfirmed
                } else {
                    Receipt::Expired
                }
            );
        }
    }

    #[test]
    fn prompt_normalization_is_bounded_without_a_word_vector() {
        assert!(normalize(&"x".repeat(INPUT_BYTES + 1)).is_none());
        assert_eq!(
            normalize(&"x".repeat(INPUT_BYTES)).unwrap().len(),
            INPUT_BYTES
        );
        assert_eq!(
            normalize(&format!("hello{}world", " ".repeat(INPUT_BYTES * 8))).as_deref(),
            Some("hello world")
        );
    }

    #[test]
    fn input_journal_is_bounded_and_overflow_never_becomes_clean() {
        let mut draft = clean();
        draft.input(&vec![b'x'; INPUT_BYTES * 3]);
        assert_eq!(draft.input.len(), INPUT_BYTES);
        assert_eq!(draft.byte_count, (INPUT_BYTES * 3) as u64);
        assert!(
            draft
                .prepare(Some("session"), Instant::now())
                .unwrap()
                .needs_confirmation
        );
        draft.submitted("session", "x", true, Instant::now());
        assert!(
            draft
                .prepare(Some("session"), Instant::now())
                .unwrap()
                .needs_confirmation
        );
    }

    #[test]
    fn a_replacement_launch_cannot_reuse_the_previous_launchs_ticket() {
        let previous = clean().prepare(Some("session"), Instant::now()).unwrap();
        let mut replacement = clean();
        let current = replacement
            .prepare(Some("session"), Instant::now())
            .unwrap();
        assert_ne!(previous.ticket, current.ticket);
        assert!(matches!(
            replacement.admit(previous.ticket, Some("session"), "hi", None, Instant::now()),
            Admission::Refused
        ));
    }

    #[test]
    fn consumed_and_superseded_tickets_never_replay() {
        let mut draft = clean();
        let first = draft.prepare(Some("session"), Instant::now()).unwrap();
        let second = draft.prepare(Some("session"), Instant::now()).unwrap();
        assert!(matches!(
            draft.admit(first.ticket, Some("session"), "hi", None, Instant::now()),
            Admission::Refused
        ));
        assert!(matches!(
            draft.admit(second.ticket, Some("session"), "hi", None, Instant::now()),
            Admission::Ready(_)
        ));
        assert!(draft.prepare(Some("session"), Instant::now()).is_none());
        draft.finish(Receipt::Expired);
        assert!(matches!(
            draft.admit(second.ticket, Some("session"), "hi", None, Instant::now()),
            Admission::Refused
        ));
    }
}
