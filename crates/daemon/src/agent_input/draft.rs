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

struct Ticket {
    id: u64,
    session: Option<String>,
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
}

pub(crate) enum Admission {
    Confirm(Offer),
    Ready(watch::Receiver<Receipt>),
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
        self.expire(now);
        if self.pending.is_some() || self.revision == u64::MAX {
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

    pub(crate) fn admit(
        &mut self,
        ticket: u64,
        session: Option<&str>,
        prompt: &str,
        confirmation: Option<u64>,
        now: Instant,
    ) -> Admission {
        self.expire(now);
        let Some(active) = self.ticket.as_ref() else {
            return Admission::Refused;
        };
        if active.id != ticket || active.session.as_deref() != session || self.pending.is_some() {
            return Admission::Refused;
        }
        let offer = self.offer(session);
        if self.revision == u64::MAX {
            return Admission::Refused;
        }
        if offer.needs_confirmation && confirmation != Some(self.revision) {
            return Admission::Confirm(offer);
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
        draft
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
