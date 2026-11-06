//! The I/O thread: one `poll(2)` loop per PTY over the master and a wake pipe.

use std::collections::VecDeque;
use std::os::fd::OwnedFd;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use bytes::Buf;
use rustix::event::{PollFd, PollFlags, Timespec};
use rustix::io::Errno;
use tokio::sync::mpsc::{self, error::TryRecvError};

use super::{Input, OutputHook, Shared};
use crate::termios::EchoState;

const READ_CHUNK: usize = 64 * 1024;
/// Most bytes read per loop iteration, so a flooding child cannot starve input.
const READ_BUDGET: usize = 1024 * 1024;
/// A macOS PTY hands out at most ~1 KiB per read, so a flooding child leaves the master empty
/// between reads for a moment. After a full read, retry this many times before going back to
/// `poll`: most gaps close within a few retries, which saves a sleep and a wakeup per KiB
/// (Ghostty's `bridge_spin_max`, src/termio/Exec.zig).
const BRIDGE_RETRIES: u32 = 16;
/// A read at least this big suggests more is coming.
const FULL_READ: usize = 1024;
/// After output or input, re-check the echo flags this often...
const ACTIVE_POLL: Duration = Duration::from_millis(25);
/// ...for this long...
const ACTIVE_WINDOW: Duration = Duration::from_millis(500);
/// ...then this often...
const IDLE_POLL: Duration = Duration::from_secs(1);
/// ...for this long, and then not at all until the next activity or an explicit refresh
/// ([`PtyActor::refresh_echo`](super::PtyActor::refresh_echo)). Programs change modes around
/// their own output or the user's input, both of which re-check at once: a quiet terminal
/// costs no wakeups.
const IDLE_WINDOW: Duration = Duration::from_secs(30);

/// The write end of the self-pipe that interrupts the I/O thread's `poll`.
pub(super) struct Waker(OwnedFd);

impl Waker {
    pub(super) fn wake(&self) {
        // A full pipe already guarantees a wake-up, so EAGAIN (and anything else) is ignorable.
        let _ = rustix::io::write(&self.0, &[1]);
    }
}

pub(super) fn wake_pipe() -> std::io::Result<(Waker, OwnedFd)> {
    let (read, write) = rustix::pipe::pipe()?;
    for fd in [&read, &write] {
        rustix::io::fcntl_setfd(fd, rustix::io::FdFlags::CLOEXEC)?;
        rustix::fs::fcntl_setfl(fd, rustix::fs::OFlags::NONBLOCK)?;
    }
    Ok((Waker(write), read))
}

enum ReadOutcome {
    /// Some bytes were read (or none were ready).
    Open { read_any: bool },
    /// The slave side is gone and everything has been read.
    Eof,
}

pub(super) struct IoLoop {
    master: Arc<OwnedFd>,
    wake: OwnedFd,
    input: mpsc::Receiver<Input>,
    shared: Arc<Shared>,
    hook: Option<OutputHook>,
    pending: VecDeque<Input>,
}

impl IoLoop {
    pub(super) fn new(
        master: Arc<OwnedFd>,
        wake: OwnedFd,
        input: mpsc::Receiver<Input>,
        shared: Arc<Shared>,
        hook: Option<OutputHook>,
    ) -> Self {
        Self {
            master,
            wake,
            input,
            shared,
            hook,
            pending: VecDeque::new(),
        }
    }

    /// Runs until the child side hangs up, the actor is dropped or the PTY is handed off.
    /// Returns the input it was handed but could not write yet, for the hand-off.
    pub(super) fn run(mut self) -> Vec<u8> {
        let mut read_buf = vec![0u8; READ_CHUNK];
        let mut last_activity = Instant::now();
        let mut echo_read: Option<Instant> = None;
        loop {
            if self.shared.handing_off.load(Ordering::Acquire) {
                return self.stop_for_hand_off();
            }
            if self.shared.shutdown.load(Ordering::Acquire) || !self.take_input() {
                break;
            }
            let typed = !self.pending.is_empty();
            if typed {
                last_activity = Instant::now();
                self.flush_input();
            }
            // Input (and wakes) re-read at once; a stream of output at most every ACTIVE_POLL,
            // not once per read.
            if typed || echo_read.is_none_or(|read_at| read_at.elapsed() >= ACTIVE_POLL) {
                self.refresh_echo();
                echo_read = Some(Instant::now());
            }

            let timeout = poll_interval(last_activity.elapsed());
            let ready = match self.poll(timeout) {
                Ok(ready) => ready,
                Err(err) => {
                    tracing::warn!(%err, "pty poll failed; closing");
                    break;
                }
            };
            if ready.wake {
                drain(&self.wake);
                // `refresh_echo` asked for a fresh read.
                echo_read = None;
            }
            if ready.writable {
                self.flush_input();
            }
            if ready.readable || ready.hangup {
                match self.read_output(&mut read_buf, ready.hangup) {
                    ReadOutcome::Open { read_any } => {
                        if read_any {
                            last_activity = Instant::now();
                        }
                    }
                    ReadOutcome::Eof => {
                        self.refresh_echo();
                        break;
                    }
                }
            }
        }
        // Refuse further writes before announcing the end, so that anyone who has seen the end
        // also sees writes fail.
        self.input.close();
        self.shared.input_budget.close();
        self.shared.input_slots.close();
        self.shared.output.send_modify(|state| state.closed = true);
        Vec::new()
    }

    /// Stops reading and writing without closing anything: output stays in the kernel's
    /// buffer for the next reader, and input not yet written is returned in order.
    fn stop_for_hand_off(mut self) -> Vec<u8> {
        self.input.close();
        self.shared.input_budget.close();
        self.shared.input_slots.close();
        self.take_input();
        self.flush_input();
        self.pending
            .drain(..)
            .flat_map(|input| input.data)
            .collect()
    }

    /// Moves queued input into `pending`. Returns `false` once the actor handle is gone.
    fn take_input(&mut self) -> bool {
        loop {
            match self.input.try_recv() {
                Ok(input) => self.pending.push_back(input),
                Err(TryRecvError::Empty) => return true,
                Err(TryRecvError::Disconnected) => return false,
            }
        }
    }

    fn flush_input(&mut self) {
        while let Some(front) = self.pending.front_mut() {
            match rustix::io::write(&*self.master, &front.data) {
                Ok(written) => {
                    front.data.advance(written);
                    if front.data.is_empty() {
                        self.pending.pop_front();
                    }
                }
                Err(Errno::INTR) => {}
                Err(Errno::AGAIN) => return,
                Err(err) => {
                    // Typically EIO once the child side is gone; output EOF follows.
                    tracing::debug!(%err, "pty write failed; dropping queued input");
                    self.pending.clear();
                    return;
                }
            }
        }
    }

    fn read_output(&mut self, buf: &mut [u8], hangup: bool) -> ReadOutcome {
        let mut total = 0;
        let mut last_read = 0;
        let mut retries = 0;
        while total < READ_BUDGET {
            match rustix::io::read(&*self.master, &mut *buf) {
                // Linux reports a closed slave as EIO, macOS as a 0-byte read.
                Ok(0) | Err(Errno::IO) => return ReadOutcome::Eof,
                Ok(read) => {
                    self.publish(&buf[..read]);
                    total += read;
                    last_read = read;
                    retries = 0;
                }
                Err(Errno::INTR) => {}
                Err(Errno::AGAIN) if hangup && total == 0 => return ReadOutcome::Eof,
                Err(Errno::AGAIN) if last_read >= FULL_READ && retries < BRIDGE_RETRIES => {
                    retries += 1;
                    std::hint::spin_loop();
                }
                Err(Errno::AGAIN) => break,
                Err(err) => {
                    tracing::warn!(%err, "pty read failed; closing");
                    return ReadOutcome::Eof;
                }
            }
        }
        ReadOutcome::Open {
            read_any: total > 0,
        }
    }

    fn publish(&mut self, data: &[u8]) {
        let head = {
            let mut ring = self.shared.ring();
            if let Some(hook) = &mut self.hook {
                // Called under the ring lock so that a hook consumer (the daemon's VT) and the
                // ring agree on `head` for anyone who holds the lock, e.g. to take a snapshot.
                hook(ring.head(), data);
            }
            ring.push(data);
            ring.head()
        };
        self.shared.output.send_modify(|state| state.head = head);
    }

    fn refresh_echo(&self) {
        // tcgetattr on the master returns the slave's termios on macOS and Linux.
        let Ok(current) = EchoState::read(&*self.master) else {
            return;
        };
        self.shared.echo.send_if_modified(|echo| {
            let changed = *echo != current;
            *echo = current;
            changed
        });
    }

    fn poll(&self, timeout: Option<Duration>) -> rustix::io::Result<Ready> {
        let mut master_events = PollFlags::IN;
        if !self.pending.is_empty() {
            master_events |= PollFlags::OUT;
        }
        let mut fds = [
            PollFd::new(&*self.master, master_events),
            PollFd::new(&self.wake, PollFlags::IN),
        ];
        let timeout = timeout.map(|timeout| {
            Timespec::try_from(timeout).expect("constant timeouts fit in a timespec")
        });
        match rustix::event::poll(&mut fds, timeout.as_ref()) {
            Ok(_) => {}
            Err(Errno::INTR) => return Ok(Ready::default()),
            Err(err) => return Err(err),
        }
        let master_revents = fds[0].revents();
        if master_revents.contains(PollFlags::NVAL) {
            return Err(Errno::BADF);
        }
        Ok(Ready {
            readable: master_revents.contains(PollFlags::IN),
            writable: master_revents.contains(PollFlags::OUT),
            hangup: master_revents.intersects(PollFlags::HUP | PollFlags::ERR),
            wake: !fds[1].revents().is_empty(),
        })
    }
}

/// How long to wait for I/O before re-reading the echo flags, by time since activity; `None`
/// waits for I/O or a wake.
fn poll_interval(since_activity: Duration) -> Option<Duration> {
    if since_activity < ACTIVE_WINDOW {
        Some(ACTIVE_POLL)
    } else if since_activity < IDLE_WINDOW {
        Some(IDLE_POLL)
    } else {
        None
    }
}

#[derive(Default)]
struct Ready {
    readable: bool,
    writable: bool,
    hangup: bool,
    wake: bool,
}

fn drain(fd: &OwnedFd) {
    let mut scratch = [0u8; 64];
    while matches!(rustix::io::read(fd, &mut scratch), Ok(read) if read > 0) {}
}
