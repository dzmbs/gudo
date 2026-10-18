//! on it.
//!
//! one pane degrade keystroke→echo latency in the focused pane, and does the per-pane unacked
//! budget from §5.3 ("stop bytes, send a snapshot when the client catches up") keep it flat?
//!
//! A fake daemon ([`server`]) and a fake client ([`client`]) speak the real [`proto`] messages
//! over an iroh connection with relays and address lookup disabled, dialled by direct address.
//! [`link`] optionally puts a shaped UDP hop (rate limit, delay, drop-tail queue) between them,
//! because loopback has no bottleneck and therefore no queue to wait in. Results are written up

pub mod budget;
pub mod client;
pub mod link;
pub mod net;
pub mod scenario;
pub mod server;
pub mod stats;

use proto::PaneId;

/// The pane the user is typing into.
pub const FOCUSED_PANE: PaneId = PaneId(1);
/// The pane running `cat bigfile`.
pub const FLOOD_PANE: PaneId = PaneId(2);
