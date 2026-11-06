//! The host daemon's PTY layer (macOS and Linux).
//!
//! - [`PtyActor`] spawns a child in a new PTY and runs its I/O on dedicated threads, so the async
//!   daemon never blocks on the terminal.
//! - Output lands in a per-pane [`OutputRing`] addressed by absolute byte offset ([`Seq`]). A
//!   resuming client either replays from the ring or, on [`ReadError`], needs a snapshot.
//! - [`Subscriber`]s follow output with per-subscriber backpressure that never stalls the reader.
//! - [`EchoState`] reports the slave's `ECHO`/`ICANON` flags for client-side echo prediction.
//! - [`PtyActor::hand_off`] stops a PTY without closing it, so the daemon can `exec` a new
//!   build that continues it with [`PtyActor::adopt`]; [`abandon`] ends one nobody continues.
//! - [`PtyActor::foreground_process`] names the foreground job so the agents layer can spot
//!   `claude` or `codex`.

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
compile_error!("the pty crate supports macOS and Linux only");

mod actor;
mod foreground;
mod ring;
mod spawn;
mod termios;

pub use actor::{
    AdoptError, Closed, HandedOff, MAX_QUEUED_INPUT, MAX_QUEUED_WRITES, OutputHook, PtyActor,
    RecvError, Signal, SignalError, SpawnOptions, Subscriber, TryWriteError, abandon,
};
pub use foreground::ForegroundProcess;
pub use ring::{Chunk, DEFAULT_RING_CAPACITY, OutputRing, ReadError, Seq};
pub use termios::{EchoState, WinSize};
