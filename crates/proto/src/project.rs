//! Projects: named, coloured groups of tabs. A client merges projects across daemons by id;
//! each daemon session stores the definitions its tabs use and which tabs belong to which.
//!
//! - Clients change them with [`LayoutOp::SetTabProject`](crate::LayoutOp::SetTabProject),
//!   [`PutProject`](crate::LayoutOp::PutProject) and
//!   [`RemoveProject`](crate::LayoutOp::RemoveProject) on daemons with
//!   [`DaemonFeatures::PROJECTS`](crate::DaemonFeatures::PROJECTS).
//! - The daemon pushes [`ServerCtl::Projects`](crate::ServerCtl::Projects) right after every
//!   [`ServerCtl::LayoutChanged`](crate::ServerCtl::LayoutChanged) to owner clients with
//!   [`Caps::PROJECTS`](crate::Caps::PROJECTS).
//! - A definition no tab uses any more is dropped.

use serde::{Deserialize, Serialize};

use crate::ids::{SessionId, TabId, UnixMillis};

/// Longest [`Project::id`] in bytes (it is never empty).
pub const MAX_PROJECT_ID_LEN: usize = 64;
/// Longest [`Project::name`] in bytes.
pub const MAX_PROJECT_NAME_LEN: usize = 128;
/// Highest [`Project::color`] (a palette index).
pub const MAX_PROJECT_COLOR: u8 = 7;
/// Most projects one session keeps.
pub const MAX_PROJECTS_PER_SESSION: usize = 256;

/// A project as one daemon session knows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Project {
    /// Client-chosen id, the same on every daemon (1..=[`MAX_PROJECT_ID_LEN`] bytes).
    pub id: String,
    /// Its name (up to [`MAX_PROJECT_NAME_LEN`] bytes).
    pub name: String,
    /// Palette index, `0..=`[`MAX_PROJECT_COLOR`].
    pub color: u8,
    /// Where it sorts among projects.
    pub order: i64,
    /// When the client last changed it; the newer definition wins.
    pub updated: UnixMillis,
}

/// One tab's membership in a project.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TabProject {
    /// The tab.
    pub tab_id: TabId,
    /// The project's id.
    pub project: String,
    /// Where the tab sorts within the project.
    pub rank: i64,
}

/// A session's projects, in [`ServerCtl::Projects`](crate::ServerCtl::Projects).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionProjects {
    /// The session.
    pub session_id: SessionId,
    /// The session's layout revision these belong to.
    pub revision: u64,
    /// Definitions of the projects `tabs` use.
    pub projects: Vec<Project>,
    /// Memberships of the tabs the client sees.
    pub tabs: Vec<TabProject>,
}

impl Project {
    /// Whether it is within the limits above.
    pub fn is_valid(&self) -> bool {
        is_valid_id(&self.id)
            && self.name.len() <= MAX_PROJECT_NAME_LEN
            && self.color <= MAX_PROJECT_COLOR
    }
}

/// Whether `id` is a valid [`Project::id`].
pub fn is_valid_id(id: &str) -> bool {
    (1..=MAX_PROJECT_ID_LEN).contains(&id.len())
}
