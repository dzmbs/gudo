//! Asking the owner before an agent drives one of the user's panes.
//!
//! An agent may type into, run in and close the panes it opened. For any other pane of its
//! session (the user's), the daemon asks the owner instead of refusing: the agent's pane shows
//! as blocked on an ordinary approval request ([`AgentState::Blocked`](crate::AgentState),
//! three options in the order of [`DriveAsk::ALLOW_ONCE`], [`DriveAsk::ALLOW_PANE`],
//! [`DriveAsk::DENY`]), with an attention item and a push notification, and the owner answers
//! with a signed [`Decide`](crate::Decide) or the notification's Approve (allow once) and
//! Deny. Only paired owner devices may answer; guests never can.
//!
//! Clients announcing [`Caps::DRIVE_ASKS`](crate::Caps::DRIVE_ASKS) also get
//! [`ApprovalPush::Drive`](crate::ApprovalPush::Drive) (with
//! [`Caps::APPROVALS`](crate::Caps::APPROVALS)): the exact action asked for, so the card
//! can show it and offer all three answers. Daemons that ask say
//! [`DaemonFeatures::DRIVE_ASKS`](crate::DaemonFeatures::DRIVE_ASKS).
//!
//! Same compatibility rules as the rest of the crate: append only.

use serde::{Deserialize, Serialize};

use crate::ids::{OptionId, PaneId, RequestId, UnixMillis};

/// What an agent asks to do in a pane it did not open.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DriveAction {
    /// Type text and keys (`pane_send`).
    Type {
        /// Text, pasted.
        text: Option<String>,
        /// Key names (`enter`, `ctrl+c`), pressed after the text.
        keys: Vec<String>,
        /// Press Return at the end.
        submit: bool,
    },
    /// Run a command at the pane's prompt (`cmd_run`).
    Run {
        /// The command line, exactly as it will be typed.
        command: String,
    },
    /// Prompt the agent in the pane (`agent_prompt`).
    Prompt {
        /// The prompt.
        text: String,
    },
    /// Close the pane (`pane_close`).
    Close,
}

/// An open request to drive a pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriveAsk {
    /// The request, as in the asking pane's `AgentState::Blocked`; answer it with `Decide`.
    pub request_id: RequestId,
    /// The asking agent's pane.
    pub pane_id: PaneId,
    /// The pane it wants to drive.
    pub target: PaneId,
    /// Who asks, for display (`Claude`, `Codex`, or the program's name).
    pub agent: String,
    /// The target pane for display: its directory and program (`~/api · zsh`).
    pub target_label: String,
    /// Exactly what will be done once allowed; nothing else is.
    pub action: DriveAction,
    /// When the request lapses unanswered (refused).
    pub expires_at: UnixMillis,
}

impl DriveAsk {
    /// Allows this one action.
    pub const ALLOW_ONCE: OptionId = OptionId(0);
    /// Allows this action and lets the agent drive the pane until the pane closes.
    pub const ALLOW_PANE: OptionId = OptionId(1);
    /// Refuses.
    pub const DENY: OptionId = OptionId(2);
}

/// A drive request opened or closed ([`ApprovalPush::Drive`](crate::ApprovalPush::Drive)).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DrivePush {
    /// A request opened (and, after attaching, every open one).
    Open(DriveAsk),
    /// A request was answered, expired or withdrawn.
    Closed {
        /// The request.
        request_id: RequestId,
    },
}
