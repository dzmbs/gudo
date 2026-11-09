//! The local exit fence for daemon-launched agent PTYs.

mod chat;
#[cfg(test)]
pub(crate) mod chat_tests;
mod draft;
mod hooks;
mod interrupt;

pub(crate) use chat::request as chat_request;
pub(crate) use draft::Receipt;
pub(crate) use hooks::record as record_hook;
pub(crate) use interrupt::request as interrupt_request;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::core::{Core, lock};

/// Calls from the trusted shim before and after the live agent process.
#[derive(Serialize, Deserialize)]
#[serde(tag = "agent_input", rename_all = "snake_case")]
pub enum AgentInputCall {
    Arm {
        token: String,
        pane: proto::PaneId,
        launch: String,
    },
    Close {
        token: String,
        pane: proto::PaneId,
        launch: String,
    },
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentInputReply {
    Ready,
    Closed,
    Refused,
}

/// Native enqueue must hold the same mutex that protects these transitions.
/// A delayed agent hook or arm request cannot reopen a closed launch.
#[derive(Default)]
pub(crate) struct AgentInputGate {
    phase: AgentInputPhase,
    revision: u64,
    pending_unproven_writes: u64,
    pending_user_writes: u64,
    draft: draft::Draft,
    last_user_input_seq: u64,
    last_prompt_seq: u64,
}

#[derive(Default)]
enum AgentInputPhase {
    #[default]
    Disabled,
    Pending(String),
    Open(String),
}

impl AgentInputGate {
    pub(crate) fn has_launch(&self) -> bool {
        !matches!(self.phase, AgentInputPhase::Disabled)
    }

    pub(crate) fn active_launch(&self) -> Option<&str> {
        match &self.phase {
            AgentInputPhase::Open(launch) => Some(launch),
            _ => None,
        }
    }

    pub(crate) fn control_revision(&self) -> Option<u64> {
        (matches!(self.phase, AgentInputPhase::Open(_)) && self.pending_unproven_writes == 0)
            .then_some(self.revision)
    }

    pub(crate) fn native_turn(&mut self, session: &str) {
        self.draft.record_turn(Some(session), crate::hook_seq());
    }

    pub(crate) fn pending(launch: String) -> Self {
        Self {
            phase: AgentInputPhase::Pending(launch),
            ..Self::default()
        }
    }

    fn advance_revision(&mut self) {
        self.revision = self.revision.saturating_add(1);
        if self.revision == u64::MAX {
            self.phase = AgentInputPhase::Disabled;
        }
    }

    fn arm(&mut self, launch: &str) -> bool {
        if matches!(&self.phase, AgentInputPhase::Pending(active) if active == launch) {
            self.phase = AgentInputPhase::Open(launch.to_owned());
            true
        } else {
            false
        }
    }

    fn close(&mut self, launch: &str) -> bool {
        if matches!(&self.phase, AgentInputPhase::Pending(active) | AgentInputPhase::Open(active) if active == launch)
        {
            self.phase = AgentInputPhase::Disabled;
            self.draft.close();
            self.advance_revision();
            true
        } else {
            false
        }
    }
}

/// Covers enqueue/backpressure/cancellation, not kernel delivery or the child's reads.
/// Even a later Stop hook cannot prove that all buffered raw input has been consumed.
pub(crate) struct UnprovenWrite<'a> {
    gate: &'a Mutex<AgentInputGate>,
    user: bool,
}

pub(crate) fn begin_unproven_write<'a>(
    gate: &'a Mutex<AgentInputGate>,
    bytes: &[u8],
) -> UnprovenWrite<'a> {
    let mut state = lock(gate);
    if !matches!(state.phase, AgentInputPhase::Disabled) {
        state.draft.input(bytes);
        if !bytes.is_empty() {
            state.last_user_input_seq = crate::hook_seq();
        }
    }
    state.advance_revision();
    state.pending_unproven_writes = state.pending_unproven_writes.saturating_add(1);
    let user = !bytes.is_empty();
    if user {
        state.pending_user_writes = state.pending_user_writes.saturating_add(1);
    }
    UnprovenWrite { gate, user }
}

impl Drop for UnprovenWrite<'_> {
    fn drop(&mut self) {
        let mut state = lock(self.gate);
        state.pending_unproven_writes = state.pending_unproven_writes.saturating_sub(1);
        if self.user {
            state.pending_user_writes = state.pending_user_writes.saturating_sub(1);
        }
        state.advance_revision();
    }
}

pub(crate) enum EnqueueError {
    Unavailable,
    Busy,
}

pub(crate) fn enqueue(
    core: &Core,
    pane: proto::PaneId,
    bytes: Vec<u8>,
) -> Result<(), EnqueueError> {
    let entry = core.pane(pane).ok_or(EnqueueError::Unavailable)?;
    let mut gate = lock(&entry.pane.agent_input_gate);
    if !matches!(&gate.phase, AgentInputPhase::Open(_)) || !core.agent_has_terminal(pane) {
        return Err(EnqueueError::Unavailable);
    }
    if gate.pending_unproven_writes != 0 {
        return Err(EnqueueError::Busy);
    }
    gate.draft.input(&bytes);
    if !bytes.is_empty() {
        gate.last_user_input_seq = crate::hook_seq();
    }
    gate.advance_revision();
    if !matches!(&gate.phase, AgentInputPhase::Open(_)) {
        return Err(EnqueueError::Unavailable);
    }
    entry
        .pane
        .pty()
        .try_write(bytes)
        .map_err(|_| EnqueueError::Busy)
}

pub(crate) async fn serve(core: &Arc<Core>, call: AgentInputCall) -> AgentInputReply {
    let (token, pane, launch) = match &call {
        AgentInputCall::Arm {
            token,
            pane,
            launch,
        }
        | AgentInputCall::Close {
            token,
            pane,
            launch,
        } => (token, *pane, launch),
    };
    if !core.hooks.verify(token, &pane.0.to_string()) {
        return AgentInputReply::Refused;
    }
    let entry = if matches!(call, AgentInputCall::Arm { .. }) {
        tokio::time::timeout(Duration::from_millis(500), async {
            loop {
                if let Some(entry) = core.pane(pane) {
                    return entry;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .ok()
    } else {
        core.pane(pane)
    };
    let Some(entry) = entry else {
        return AgentInputReply::Refused;
    };
    if matches!(call, AgentInputCall::Arm { .. }) {
        return if lock(&entry.pane.agent_input_gate).arm(launch) {
            AgentInputReply::Ready
        } else {
            AgentInputReply::Refused
        };
    }
    if !lock(&entry.pane.agent_input_gate).close(launch) {
        return AgentInputReply::Refused;
    }
    match tokio::time::timeout(Duration::from_secs(5), entry.pane.pty().flush_writes()).await {
        Ok(Ok(())) => AgentInputReply::Closed,
        _ => AgentInputReply::Refused,
    }
}

#[cfg(test)]
pub(crate) fn submitted(pane: &crate::pane::Pane, session: &str, prompt: &str, seq: u64) {
    submitted_locked(&mut lock(&pane.agent_input_gate), session, prompt, seq);
}

fn submitted_locked(gate: &mut AgentInputGate, session: &str, prompt: &str, seq: u64) {
    // A delayed pre-write hook or replay cannot clear a newer draft or acknowledge a new send.
    if seq <= gate.last_prompt_seq || seq <= gate.last_user_input_seq {
        return;
    }
    gate.last_prompt_seq = seq;
    let writes_pending = gate.pending_user_writes != 0;
    gate.draft
        .submitted(session, prompt, writes_pending, std::time::Instant::now());
}

pub(crate) fn agent_exited(pane: &crate::pane::Pane) {
    lock(&pane.agent_input_gate).draft.close();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_fence_messages_have_stable_tagged_json() {
        let call = AgentInputCall::Arm {
            token: "token".into(),
            pane: proto::PaneId(42),
            launch: "launch".into(),
        };
        assert_eq!(
            serde_json::to_string(&call).unwrap(),
            r#"{"agent_input":"arm","token":"token","pane":42,"launch":"launch"}"#
        );
        let call = AgentInputCall::Close {
            token: "token".into(),
            pane: proto::PaneId(42),
            launch: "launch".into(),
        };
        assert_eq!(
            serde_json::to_string(&call).unwrap(),
            r#"{"agent_input":"close","token":"token","pane":42,"launch":"launch"}"#
        );
        for (reply, json) in [
            (AgentInputReply::Ready, "\"ready\""),
            (AgentInputReply::Closed, "\"closed\""),
            (AgentInputReply::Refused, "\"refused\""),
        ] {
            assert_eq!(serde_json::to_string(&reply).unwrap(), json);
            assert_eq!(
                serde_json::from_str::<AgentInputReply>(json).unwrap(),
                reply
            );
        }
    }

    #[tokio::test]
    async fn cancelling_an_unproven_write_advances_revision_and_releases_its_pending_count() {
        let gate = Mutex::new(AgentInputGate::pending("current".into()));
        assert!(lock(&gate).arm("current"));
        let result = tokio::time::timeout(Duration::from_millis(10), async {
            let _input = begin_unproven_write(&gate, b"input");
            assert_eq!(lock(&gate).revision, 1);
            assert_eq!(lock(&gate).pending_unproven_writes, 1);
            std::future::pending::<()>().await;
        })
        .await;
        assert!(result.is_err());
        let state = lock(&gate);
        assert_eq!(state.revision, 2);
        assert_eq!(state.pending_unproven_writes, 0);
    }

    #[test]
    fn closing_with_an_unproven_write_pending_cannot_be_undone_by_its_completion() {
        let gate = Mutex::new(AgentInputGate::pending("current".into()));
        assert!(lock(&gate).arm("current"));
        let input = begin_unproven_write(&gate, b"input");
        assert!(lock(&gate).close("current"));
        drop(input);
        let mut state = lock(&gate);
        assert_eq!(state.pending_unproven_writes, 0);
        assert_eq!(state.revision, 3);
        assert!(!state.arm("current"));
    }

    #[test]
    fn exhausted_revisions_never_wrap_or_reopen_native_input() {
        let gate = Mutex::new(AgentInputGate::pending("current".into()));
        assert!(lock(&gate).arm("current"));
        lock(&gate).revision = u64::MAX - 1;
        let input = begin_unproven_write(&gate, b"input");
        drop(input);
        let mut state = lock(&gate);
        assert_eq!(state.revision, u64::MAX);
        assert_eq!(state.pending_unproven_writes, 0);
        assert!(matches!(state.phase, AgentInputPhase::Disabled));
        assert!(!state.arm("current"));
    }

    #[test]
    fn only_this_pending_launch_can_arm_and_close() {
        let mut gate = AgentInputGate::pending("current".into());
        assert!(!gate.arm("other"));
        assert!(!gate.close("other"));
        assert!(gate.arm("current"));
        assert!(!gate.arm("current"));
        assert!(gate.close("current"));
        assert!(!gate.arm("current"));
        assert!(!gate.close("current"));
    }

    #[test]
    fn closing_before_a_delayed_arm_never_reopens_the_gate() {
        let mut gate = AgentInputGate::pending("current".into());
        assert!(gate.close("current"));
        assert!(!gate.arm("current"));
    }
}
