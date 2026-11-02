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

    /// The options in order, with the labels every surface shows.
    pub const OPTIONS: [(OptionId, &'static str); 3] = [
        (Self::ALLOW_ONCE, "Allow once"),
        (Self::ALLOW_PANE, "Allow for this pane until it closes"),
        (Self::DENY, "Deny"),
    ];

    /// `Claude wants to type into ~/api · zsh`.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::{DriveAction, DriveAsk, PaneId, RequestId, UnixMillis};
    ///
    /// let ask = DriveAsk {
    ///     request_id: RequestId(1),
    ///     pane_id: PaneId(1),
    ///     target: PaneId(2),
    ///     agent: "Claude".into(),
    ///     target_label: "~/api · zsh".into(),
    ///     action: DriveAction::Run { command: "npm test".into() },
    ///     expires_at: UnixMillis(0),
    /// };
    /// assert_eq!(ask.title(), "Claude wants to run a command in ~/api · zsh");
    /// assert_eq!(ask.action.describe(), "Run $ npm test");
    /// ```
    pub fn title(&self) -> String {
        format!(
            "{} wants to {} {}",
            self.agent,
            self.action.verb(),
            self.target_label
        )
    }
}

impl DriveAction {
    /// `type into`, `run a command in`, `prompt the agent in`, `close`.
    pub fn verb(&self) -> &'static str {
        match self {
            Self::Type { .. } => "type into",
            Self::Run { .. } => "run a command in",
            Self::Prompt { .. } => "prompt the agent in",
            Self::Close => "close",
        }
    }

    /// The action exactly, in words. Control characters show as `^X`, line breaks as `⏎`
    /// and invisible formatting as `<U+…>`, so nothing typed can hide from the reader.
    pub fn describe(&self) -> String {
        match self {
            Self::Type { text, keys, submit } => {
                let mut parts = Vec::new();
                if let Some(text) = text.as_deref().filter(|t| !t.is_empty()) {
                    parts.push(format!("“{}”", visible(text)));
                }
                if !keys.is_empty() {
                    parts.push(format!("keys {}", visible(&keys.join(" "))));
                }
                if *submit {
                    parts.push("then Return".into());
                }
                if parts.is_empty() {
                    "Type nothing".into()
                } else {
                    format!("Type {}", parts.join(", "))
                }
            }
            Self::Run { command } => format!("Run $ {}", visible(command)),
            Self::Prompt { text } => format!("Prompt “{}”", visible(text)),
            Self::Close => "Close the pane".into(),
        }
    }
}

/// `text` with every character that could hide or reorder what is shown made visible.
fn visible(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\n' | '\r' => out.push('⏎'),
            '\t' => out.push('⇥'),
            c if (c as u32) < 0x20 => {
                out.push('^');
                out.push(char::from(c as u8 + b'@'));
            }
            '\u{7f}' => out.push_str("^?"),
            '\u{80}'..='\u{9f}'
            | '\u{200b}'..='\u{200f}'
            | '\u{202a}'..='\u{202e}'
            | '\u{2060}'..='\u{2069}'
            | '\u{feff}' => out.push_str(&format!("<U+{:04X}>", c as u32)),
            c => out.push(c),
        }
    }
    out
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
