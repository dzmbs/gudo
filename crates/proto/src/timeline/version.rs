use std::fmt;

use crate::{DaemonFeatures, PaneId, WorkspaceRequest};

/// The timeline schema selected by one pane watch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum TimelineVersion {
    V1 = 1,
}

impl TimelineVersion {
    pub const SUPPORTED: &[Self] = &[Self::V1];
    pub const CURRENT: Self = Self::SUPPORTED[Self::SUPPORTED.len() - 1];

    pub fn negotiate(maximum: u16) -> Result<Self, UnsupportedTimelineVersion> {
        Self::SUPPORTED
            .iter()
            .rev()
            .copied()
            .find(|version| version.as_u16() <= maximum)
            .ok_or(UnsupportedTimelineVersion(maximum))
    }

    pub fn watch_request(self, pane_id: PaneId, features: DaemonFeatures) -> WorkspaceRequest {
        if features.contains(DaemonFeatures::VERSIONED_TIMELINE) {
            WorkspaceRequest::TimelineWatchVersioned {
                pane_id,
                version: self.as_u16(),
            }
        } else {
            WorkspaceRequest::TimelineWatch { pane_id }
        }
    }

    pub const fn as_u16(self) -> u16 {
        self as u16
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UnsupportedTimelineVersion(u16);

impl fmt::Display for UnsupportedTimelineVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "Chat version {} is not supported", self.0)
    }
}

impl std::error::Error for UnsupportedTimelineVersion {}
