//! Floating panes: windows of panes shown as cards over their tab's split tree.
//!
//! A floating window's panes stay a subtree of its tab's tree: where it docks back to, where its
//! own splits live, and where clients without [`Caps::FLOATS`](crate::Caps::FLOATS) keep
//! showing it as an ordinary split. What floats, and where, is pushed separately as [`ServerCtl::Floats`](crate::ServerCtl::Floats)
//! right after every [`ServerCtl::LayoutChanged`](crate::ServerCtl::LayoutChanged), so the
//! layout message itself is unchanged.
//!
//! - Frames are fractions of the tab's area, so a float keeps its place across window sizes
//!   and on clients of different sizes.
//! - A tab always keeps at least one tiled pane: floating the last one is refused, and when
//!   the last tiled pane closes the topmost float docks.
//! - Clients change floats with [`LayoutOp::NewFloat`](crate::LayoutOp::NewFloat),
//!   [`FloatPane`](crate::LayoutOp::FloatPane), [`SetFloat`](crate::LayoutOp::SetFloat) and
//!   [`DockPane`](crate::LayoutOp::DockPane) on daemons with
//!   [`DaemonFeatures::FLOATS`](crate::DaemonFeatures::FLOATS). Focusing a float raises it.

use serde::{Deserialize, Serialize};

use crate::ids::{PaneId, SessionId};
use crate::layout::Direction;

/// Most floating windows one tab holds.
pub const MAX_FLOATS_PER_TAB: usize = 16;
/// Smallest width or height of a float, as a fraction of its tab.
pub const MIN_FLOAT_SIDE: f32 = 0.1;

/// Where a float sits, in fractions of its tab's area (`0,0` is the top left).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct FloatFrame {
    /// Left edge.
    pub x: f32,
    /// Top edge.
    pub y: f32,
    /// Width.
    pub w: f32,
    /// Height.
    pub h: f32,
}

impl FloatFrame {
    /// The frame a float gets when none is given: centred, three fifths of the tab.
    pub const DEFAULT: Self = Self {
        x: 0.2,
        y: 0.2,
        w: 0.6,
        h: 0.6,
    };

    /// The frame moved and sized to lie wholly inside the tab, or `None` if any value is not
    /// finite.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::FloatFrame;
    ///
    /// let frame = FloatFrame { x: 0.9, y: -0.2, w: 0.5, h: 2.0 }.clamped().unwrap();
    /// assert_eq!(frame, FloatFrame { x: 0.5, y: 0.0, w: 0.5, h: 1.0 });
    /// assert!(FloatFrame { x: f32::NAN, ..frame }.clamped().is_none());
    /// ```
    pub fn clamped(self) -> Option<Self> {
        let Self { x, y, w, h } = self;
        if ![x, y, w, h].iter().all(|value| value.is_finite()) {
            return None;
        }
        let w = w.clamp(MIN_FLOAT_SIDE, 1.0);
        let h = h.clamp(MIN_FLOAT_SIDE, 1.0);
        Some(Self {
            x: x.clamp(0.0, 1.0 - w),
            y: y.clamp(0.0, 1.0 - h),
            w,
            h,
        })
    }
}

/// When the daemon closes a float by itself.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CloseWhen {
    /// Only when its process exits, like any pane.
    #[default]
    Never,
    /// Also when its work is done: an agent's turn ends (done or failed), or the first
    /// command run in a shell finishes. It stays a moment so the outcome can be seen.
    Done,
}

/// Identifies a floating window within its session. Never reused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct FloatId(pub u64);

/// A floating window: a card over its tab holding one or more panes, split like a tab.
///
/// Its panes are exactly the leaves of one subtree of the tab's tree; that subtree is the
/// window's own layout, and the tab's tiled layout is the tree without it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FloatWindow {
    pub id: FloatId,
    /// Its panes, in the order of the tab's tree.
    pub panes: Vec<PaneId>,
    pub frame: FloatFrame,
    /// Stacking order within the session; higher is in front.
    pub z: u32,
    /// Shown as a chip in the tab's tray instead of a card.
    pub minimized: bool,
    /// Shown over every tab of the session, not only its own.
    pub pinned: bool,
    /// When the daemon closes it by itself.
    pub close: CloseWhen,
}

/// Where [`LayoutOp::DockPane`](crate::LayoutOp::DockPane) puts a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct DockTarget {
    /// The tiled pane it goes beside (in the same session).
    pub pane_id: PaneId,
    pub side: Direction,
}

/// A session's floating panes, in [`ServerCtl::Floats`](crate::ServerCtl::Floats).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionFloats {
    pub session_id: SessionId,
    /// The session's layout revision these belong to.
    pub revision: u64,
    /// The windows of the panes the client sees, back to front.
    pub floats: Vec<FloatWindow>,
}
