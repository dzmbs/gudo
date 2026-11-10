//! What the client sends, held while there is no connection. Requests and input wait for the
//! next one; state the next connection replays from [`Wanted`](crate::Wanted) is held once,
//! newest only; what only matters now (pings, presence, live ink) is not held at all.

use std::collections::VecDeque;
use std::sync::Mutex;

use proto::{ClientCtl, InputPayload, PaneId};
use tokio::sync::Notify;

use crate::lock;

/// Something for the live connection to send.
#[derive(Debug)]
pub(crate) enum Outgoing {
    Ctl(ClientCtl),
    Input {
        pane_id: PaneId,
        payload: InputPayload,
    },
}

/// Whether a connection is up to take what is pushed now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Link {
    Up,
    Down,
}

/// The most items held while there is no connection.
pub(crate) const MAX_HELD: usize = 4096;
/// The most input bytes held while there is no connection: far more than anyone types offline,
/// far less than a phone notices.
pub(crate) const MAX_HELD_INPUT_BYTES: usize = 8 << 20;

#[derive(Default)]
pub(crate) struct OutgoingQueue {
    held: Mutex<Held>,
    added: Notify,
}

#[derive(Default)]
struct Held {
    items: VecDeque<Outgoing>,
    input_bytes: usize,
}

impl OutgoingQueue {
    /// Queues `item`. With the link down, requests `is_live` says nobody waits for any more
    /// are dropped first, and past the limits `item` is dropped rather than held.
    pub(crate) fn push(&self, item: Outgoing, link: Link, is_live: impl Fn(&ClientCtl) -> bool) {
        {
            let mut held = lock(&self.held);
            if link == Link::Down {
                if let Outgoing::Ctl(control) = &item {
                    if is_momentary(control) {
                        return;
                    }
                    held.forget_superseded_by(control);
                }
                held.retain_live(&is_live);
                if held.items.len() >= MAX_HELD
                    || held.input_bytes + input_bytes(&item) > MAX_HELD_INPUT_BYTES
                {
                    tracing::debug!("no connection and too much waiting for one: dropping");
                    return;
                }
            }
            held.input_bytes += input_bytes(&item);
            held.items.push_back(item);
        }
        self.added.notify_one();
    }

    /// The oldest item, waiting for one. Cancellation safe.
    pub(crate) async fn next(&self) -> Outgoing {
        loop {
            let added = self.added.notified();
            if let Some(item) = lock(&self.held).pop() {
                return item;
            }
            added.await;
        }
    }

    /// Drops the op `op_id` if it is still waiting to be sent; returns whether it was.
    pub(crate) fn withdraw_op(&self, op_id: u64) -> bool {
        let mut held = lock(&self.held);
        let before = held.items.len();
        held.items.retain(|item| {
            !matches!(item, Outgoing::Ctl(ClientCtl::Op { op_id: queued, .. }) if *queued == op_id)
        });
        held.items.len() != before
    }

    pub(crate) fn len(&self) -> usize {
        lock(&self.held).items.len()
    }
}

impl Held {
    fn pop(&mut self) -> Option<Outgoing> {
        let item = self.items.pop_front()?;
        self.input_bytes -= input_bytes(&item);
        Some(item)
    }

    fn forget_superseded_by(&mut self, newer: &ClientCtl) {
        self.retain(|item| !matches!(item, Outgoing::Ctl(older) if supersedes(newer, older)));
    }

    fn retain_live(&mut self, is_live: impl Fn(&ClientCtl) -> bool) {
        self.retain(|item| match item {
            Outgoing::Ctl(control) => is_live(control),
            Outgoing::Input { .. } => true,
        });
    }

    fn retain(&mut self, mut keep: impl FnMut(&Outgoing) -> bool) {
        let mut input_bytes_left = 0;
        self.items.retain(|item| {
            let kept = keep(item);
            if kept {
                input_bytes_left += input_bytes(item);
            }
            kept
        });
        self.input_bytes = input_bytes_left;
    }
}

fn input_bytes(item: &Outgoing) -> usize {
    match item {
        Outgoing::Input {
            payload: InputPayload::Bytes(bytes) | InputPayload::GeneratedBytes(bytes),
            ..
        } => bytes.len(),
        Outgoing::Input {
            payload: InputPayload::Paste(text),
            ..
        } => text.len(),
        _ => 0,
    }
}

/// Worth nothing by the time a connection is back.
fn is_momentary(control: &ClientCtl) -> bool {
    matches!(
        control,
        ClientCtl::Ping { .. }
            | ClientCtl::Presence(_)
            | ClientCtl::InkLive(_)
            | ClientCtl::Peer(_)
            | ClientCtl::Ack { .. }
    )
}

/// Whether sending `newer` makes `older` pointless: both set the same state.
fn supersedes(newer: &ClientCtl, older: &ClientCtl) -> bool {
    use ClientCtl as Ctl;
    match (newer, older) {
        (Ctl::Resize { pane_id: a, .. }, Ctl::Resize { pane_id: b, .. })
        | (Ctl::PaneActivity { pane_id: a, .. }, Ctl::PaneActivity { pane_id: b, .. })
        | (Ctl::ClaimSize { pane_id: a }, Ctl::ClaimSize { pane_id: b })
        | (Ctl::SetSizePolicy { pane_id: a, .. }, Ctl::SetSizePolicy { pane_id: b, .. })
        | (
            Ctl::Subscribe { pane_id: a, .. } | Ctl::Unsubscribe { pane_id: a },
            Ctl::Subscribe { pane_id: b, .. } | Ctl::Unsubscribe { pane_id: b },
        ) => a == b,
        (Ctl::Visible { .. }, Ctl::Visible { .. })
        | (Ctl::Focus { .. }, Ctl::Focus { .. })
        | (Ctl::TerminalColors(_), Ctl::TerminalColors(_))
        | (Ctl::Attach { .. }, Ctl::Attach { .. })
        | (Ctl::ListSessions, Ctl::ListSessions)
        | (Ctl::WatchRunAgain, Ctl::WatchRunAgain) => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use proto::PaneSize;

    use super::*;

    fn resize(pane: u64, cols: u16) -> Outgoing {
        Outgoing::Ctl(ClientCtl::Resize {
            pane_id: PaneId(pane),
            size: PaneSize {
                cols,
                rows: 24,
                width_px: 0,
                height_px: 0,
            },
        })
    }

    fn drain(queue: &OutgoingQueue) -> Vec<Outgoing> {
        let mut items = Vec::new();
        while let Some(item) = lock(&queue.held).pop() {
            items.push(item);
        }
        items
    }

    #[test]
    fn offline_only_the_newest_size_of_each_pane_is_held() {
        let queue = OutgoingQueue::default();
        for cols in 1..=1000 {
            queue.push(resize(1, cols), Link::Down, |_| true);
            queue.push(resize(2, cols), Link::Down, |_| true);
        }
        let held = drain(&queue);
        assert_eq!(held.len(), 2);
        assert!(matches!(
            held[0],
            Outgoing::Ctl(ClientCtl::Resize { pane_id: PaneId(1), size }) if size.cols == 1000
        ));
    }

    #[test]
    fn online_every_size_is_sent() {
        let queue = OutgoingQueue::default();
        for cols in 1..=3 {
            queue.push(resize(1, cols), Link::Up, |_| true);
        }
        assert_eq!(queue.len(), 3);
    }

    #[test]
    fn offline_requests_nobody_waits_for_are_dropped() {
        let queue = OutgoingQueue::default();
        let request = |req_id| {
            Outgoing::Ctl(ClientCtl::Workspace {
                req_id,
                req: proto::WorkspaceRequest::ListPorts,
            })
        };
        let waited_for = |control: &ClientCtl| !matches!(control, ClientCtl::Workspace { req_id, .. } if *req_id < 10);
        for req_id in 0..20 {
            queue.push(request(req_id), Link::Down, waited_for);
        }
        assert_eq!(queue.len(), 10);
    }

    #[test]
    fn offline_input_is_held_up_to_its_limit() {
        let queue = OutgoingQueue::default();
        for _ in 0..100 {
            queue.push(
                Outgoing::Input {
                    pane_id: PaneId(1),
                    payload: InputPayload::Bytes(vec![b'x'; 1 << 20]),
                },
                Link::Down,
                |_| true,
            );
        }
        let held: usize = drain(&queue).iter().map(input_bytes).sum();
        assert!(held <= MAX_HELD_INPUT_BYTES, "{held} bytes held");
        assert!(held > 0);
    }

    #[test]
    fn a_withdrawn_op_is_never_sent() {
        let queue = OutgoingQueue::default();
        queue.push(
            Outgoing::Ctl(ClientCtl::Op {
                op_id: 7,
                op: proto::LayoutOp::ClosePane { pane_id: PaneId(1) },
            }),
            Link::Down,
            |_| true,
        );
        assert!(queue.withdraw_op(7));
        assert!(!queue.withdraw_op(7));
        assert_eq!(queue.len(), 0);
    }
}
