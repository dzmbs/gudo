//! Program status: what any program in a pane says it is doing, through OSC 7501 or the
//! `status_set` agent tool. Offered by daemons with
//! [`DaemonFeatures::PROGRAM_STATUS`](crate::DaemonFeatures) to clients announcing
//! [`Caps::PROGRAM_STATUS`](crate::Caps).
//!
//! - The daemon pushes [`ServerCtl::ProgramStatus`](crate::ServerCtl::ProgramStatus) when a
//!   pane's report changes, and the current report of every pane on joining and on attaching
//!   (`None` included on attach, so a client drops reports it missed being cleared).
//! - Only the program's own top-level report is sent; reports about sub-records (`id=`) feed
//!   the agent integrations instead.
//! - A blocked report is a status, not a request: there is nothing to answer with
//!   `ClientCtl::Decide`. Approvals stay in [`PaneMeta::agent`](crate::PaneMeta::agent).
//! - Visibility follows [`ServerCtl::PaneMeta`](crate::ServerCtl::PaneMeta).

use serde::{Deserialize, Serialize};

/// A program's last report about itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProgramReport {
    pub state: ProgramState,
    /// What it waits for, only when [`ProgramState::Blocked`] and the program said.
    pub kind: Option<ProgramKind>,
    /// The program's stable name (`pi`, `opencode`), if it gave one.
    pub app: Option<String>,
    /// One line for people.
    pub message: Option<String>,
    /// Percent complete (0–100), only for working and blocked.
    pub progress: Option<u8>,
}

/// What a program says it is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ProgramState {
    /// At rest, waiting for the user's next instruction.
    Idle,
    Working,
    /// Finished work the user hasn't looked at yet.
    Done,
    /// Waiting on the user.
    Blocked,
    /// Failed and stopped.
    Error,
}

/// What a blocked program waits for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ProgramKind {
    /// Approval to do something.
    Permission,
    /// An answer the user has to type.
    Question,
    /// A login or credential.
    Auth,
}
