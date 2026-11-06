//! The local exit fence for daemon-launched agent PTYs.

use std::sync::Arc;
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
pub(crate) enum AgentInputGate {
    #[default]
    Disabled,
    Pending(String),
    Open(String),
}

impl AgentInputGate {
    fn arm(&mut self, launch: &str) -> bool {
        if matches!(self, Self::Pending(active) if active == launch) {
            *self = Self::Open(launch.to_owned());
            true
        } else {
            false
        }
    }

    fn close(&mut self, launch: &str) -> bool {
        if matches!(self, Self::Pending(active) | Self::Open(active) if active == launch) {
            *self = Self::Disabled;
            true
        } else {
            false
        }
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
    let gate = lock(&entry.native_input_launch);
    if !matches!(&*gate, AgentInputGate::Open(_)) || !core.agent_has_terminal(pane) {
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
        return if lock(&entry.native_input_launch).arm(launch) {
            AgentInputReply::Ready
        } else {
            AgentInputReply::Refused
        };
    }
    if !lock(&entry.native_input_launch).close(launch) {
        return AgentInputReply::Refused;
    }
    match tokio::time::timeout(Duration::from_secs(5), entry.pane.pty().flush_writes()).await {
        Ok(Ok(())) => AgentInputReply::Closed,
        _ => AgentInputReply::Refused,
    }
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

    #[test]
    fn only_this_pending_launch_can_arm_and_close() {
        let mut gate = AgentInputGate::Pending("current".into());
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
        let mut gate = AgentInputGate::Pending("current".into());
        assert!(gate.close("current"));
        assert!(!gate.arm("current"));
    }
}
