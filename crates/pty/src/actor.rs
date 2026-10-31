//! The per-pane PTY actor: owns the master fd and the child, never blocks the async runtime.
//!
//! Two OS threads per pane, both outside tokio:
//!
//! - **I/O thread** (`pty-io-<pid>`): `poll(2)` over the non-blocking master and a self-pipe.
//!   It reads output into the [`OutputRing`], drains queued input with non-blocking writes, and
//!   (Apache-2.0): one poll thread per PTY plus a wake pipe.
//! - **Wait thread** (`pty-wait-<pid>`): blocks in `waitid` until the child exits.
//!
//! Subscribers never receive pushed data. They hold a cursor into the ring and are woken through a
//! [`watch`] of the head offset, so a slow subscriber costs the reader nothing: it just falls
//! behind and, past the ring's capacity, gets [`RecvError::Evicted`].

mod io_loop;
mod wait;

use std::io;
use std::os::fd::OwnedFd;
use std::process::{Command, ExitStatus};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::{fmt, thread};

use bytes::Bytes;
use rustix::process::Pid;
use tokio::sync::{Semaphore, mpsc, watch};

use crate::foreground::{self, ForegroundProcess};
use crate::ring::{Chunk, DEFAULT_RING_CAPACITY, OutputRing, ReadError, Seq};
use crate::spawn;
use crate::termios::{self, EchoState, WinSize};

/// Most bytes a [`Subscriber`] receives per [`recv`](Subscriber::recv).
const MAX_SUBSCRIBER_CHUNK: usize = 64 * 1024;
/// Queued input writes before [`PtyActor::write`] waits.
const INPUT_QUEUE: usize = 256;
/// Input bytes accepted but not yet taken by the child before [`PtyActor::write`] waits: a
/// program that stops reading its input (or is stopped) holds at most this much.
pub const MAX_QUEUED_INPUT: usize = 8 << 20;

/// A callback run on the I/O thread with each run of output before subscribers see it.
///
/// Use it for consumers that must never lag, such as the daemon's authoritative VT parser. It
/// runs on the PTY's reader thread while the ring lock is held, so [`PtyActor::head`] never
/// disagrees with what the hook has consumed; it must be fast, must not block, and must not call
/// back into the actor.
pub type OutputHook = Box<dyn FnMut(Seq, &[u8]) + Send + 'static>;

/// Options for [`PtyActor::spawn`].
pub struct SpawnOptions {
    size: WinSize,
    ring_capacity: usize,
    output_hook: Option<OutputHook>,
}

impl SpawnOptions {
    /// Options for a PTY of `size` with the default 1 MiB ring and no hook.
    pub fn new(size: WinSize) -> Self {
        Self {
            size,
            ring_capacity: DEFAULT_RING_CAPACITY,
            output_hook: None,
        }
    }

    /// Sets how many bytes of output history to retain for resuming subscribers.
    ///
    /// # Panics
    ///
    /// [`PtyActor::spawn`] panics if this is zero.
    pub fn ring_capacity(mut self, bytes: usize) -> Self {
        self.ring_capacity = bytes;
        self
    }

    /// Sets a hook that sees every byte of output, in order, on the I/O thread.
    pub fn output_hook(mut self, hook: impl FnMut(Seq, &[u8]) + Send + 'static) -> Self {
        self.output_hook = Some(Box::new(hook));
        self
    }
}

impl Default for SpawnOptions {
    fn default() -> Self {
        Self::new(WinSize::new(24, 80))
    }
}

impl fmt::Debug for SpawnOptions {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SpawnOptions")
            .field("size", &self.size)
            .field("ring_capacity", &self.ring_capacity)
            .field("output_hook", &self.output_hook.is_some())
            .finish()
    }
}

/// A signal deliverable to the child with [`PtyActor::signal`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Signal {
    /// `SIGHUP`
    Hangup,
    /// `SIGINT`
    Interrupt,
    /// `SIGQUIT`
    Quit,
    /// `SIGKILL`
    Kill,
    /// `SIGTERM`
    Terminate,
    /// `SIGSTOP`
    Stop,
    /// `SIGCONT`
    Continue,
    /// `SIGUSR1`
    User1,
    /// `SIGUSR2`
    User2,
    /// `SIGWINCH`
    WindowChange,
}

impl From<Signal> for rustix::process::Signal {
    fn from(signal: Signal) -> Self {
        use rustix::process::Signal as S;
        match signal {
            Signal::Hangup => S::HUP,
            Signal::Interrupt => S::INT,
            Signal::Quit => S::QUIT,
            Signal::Kill => S::KILL,
            Signal::Terminate => S::TERM,
            Signal::Stop => S::STOP,
            Signal::Continue => S::CONT,
            Signal::User1 => S::USR1,
            Signal::User2 => S::USR2,
            Signal::WindowChange => S::WINCH,
        }
    }
}

/// The PTY's I/O thread has stopped (the child side hung up or the actor is shutting down).
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
#[error("pty is closed")]
pub struct Closed;

/// Error from [`PtyActor::try_write`]; carries back the unsent bytes.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum TryWriteError {
    /// The input queue is full; retry later or use [`PtyActor::write`].
    #[error("pty input queue is full")]
    Full(Bytes),
    /// The PTY is closed.
    #[error("pty is closed")]
    Closed(Bytes),
}

/// Error from [`PtyActor::signal`].
#[derive(Debug, thiserror::Error)]
pub enum SignalError {
    /// The child has exited and been reaped; its pid may already belong to another process.
    #[error("child has already exited")]
    Exited,
    /// `kill(2)` failed.
    #[error("kill failed")]
    Io(#[from] io::Error),
}

/// Error from [`Subscriber::recv`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum RecvError {
    /// The subscriber fell more than the ring's capacity behind. Its cursor is unchanged; the
    /// caller needs a terminal snapshot and then [`Subscriber::seek`].
    #[error("subscriber at {requested} fell behind; oldest retained offset is {oldest}")]
    Evicted {
        /// The subscriber's cursor.
        requested: Seq,
        /// The oldest offset still retained.
        oldest: Seq,
    },
    /// Output has ended and the subscriber has received all of it.
    #[error("pty output has ended")]
    Closed,
}

#[derive(Clone, Copy, Debug)]
struct OutputState {
    head: Seq,
    closed: bool,
}

/// State shared between the actor handle, its threads, and subscribers.
struct Shared {
    ring: Mutex<OutputRing>,
    output: watch::Sender<OutputState>,
    echo: watch::Sender<EchoState>,
    shutdown: AtomicBool,
    /// One permit per input byte that may still be queued ([`MAX_QUEUED_INPUT`]); the I/O
    /// thread gives them back as the child takes the bytes.
    input_budget: Semaphore,
}

impl Shared {
    fn ring(&self) -> MutexGuard<'_, OutputRing> {
        // The ring is consistent after every individual call, so a panic elsewhere while the lock
        // was held cannot leave it torn.
        self.ring.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The child's lifecycle. `reaped` serialises `kill` against reaping so that we never signal a
/// recycled pid.
struct Process {
    pid: Pid,
    reaped: Mutex<bool>,
    exit: watch::Sender<Option<Result<ExitStatus, i32>>>,
}

impl Process {
    fn reaped(&self) -> MutexGuard<'_, bool> {
        self.reaped.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// A child process running in its own PTY, with buffered, resumable output.
///
/// Dropping the actor stops its I/O thread and closes the master, which sends `SIGHUP` to the
/// child's session. The child is reaped in the background either way.
///
/// # Examples
///
/// ```no_run
/// # async fn demo() -> std::io::Result<()> {
/// use std::process::Command;
/// use pty::{PtyActor, Seq, SpawnOptions, WinSize};
///
/// let pty = PtyActor::spawn(Command::new("/bin/sh"), SpawnOptions::new(WinSize::new(24, 80)))?;
/// let mut output = pty.subscribe_from(Seq::ZERO).expect("nothing evicted yet");
/// pty.write("echo hi; exit\n").await.expect("pty open");
/// while let Ok(chunk) = output.recv().await {
///     print!("{}", String::from_utf8_lossy(&chunk.data));
/// }
/// println!("{:?}", pty.wait().await?);
/// # Ok(())
/// # }
/// ```
pub struct PtyActor {
    master: Arc<OwnedFd>,
    shared: Arc<Shared>,
    process: Arc<Process>,
    input: mpsc::Sender<Input>,
    waker: io_loop::Waker,
}

/// Queued input and the budget permits it holds.
struct Input {
    data: Bytes,
    permits: u32,
}

/// Permits a write of `len` bytes takes: all of them, or the whole budget for a bigger one.
fn permits_for(len: usize) -> u32 {
    len.min(MAX_QUEUED_INPUT) as u32
}

impl PtyActor {
    /// Spawns `cmd` in a new PTY and starts its I/O and wait threads.
    ///
    /// `cmd` supplies argv, environment, and working directory as usual. Its stdin, stdout, and
    /// stderr are replaced by the PTY slave, and it becomes a session leader with the PTY as its
    /// controlling terminal. Nothing is added to the environment; set `TERM` yourself.
    ///
    /// # Errors
    ///
    /// Returns an error if the PTY cannot be opened, the child cannot be spawned, or a thread
    /// cannot be started (the child is then killed).
    ///
    /// # Panics
    ///
    /// Panics if the ring capacity in `options` is zero.
    pub fn spawn(cmd: Command, options: SpawnOptions) -> io::Result<Self> {
        let ring = OutputRing::new(options.ring_capacity);
        let spawn::Spawned { master, child } = spawn::spawn(cmd, options.size)?;
        rustix::fs::fcntl_setfl(&master, rustix::fs::OFlags::NONBLOCK)?;
        let master = Arc::new(master);

        let pid = Pid::from_child(&child);
        let process = Arc::new(Process {
            pid,
            reaped: Mutex::new(false),
            exit: watch::Sender::new(None),
        });
        let initial_echo = EchoState::read(&*master).unwrap_or_default();
        let shared = Arc::new(Shared {
            ring: Mutex::new(ring),
            output: watch::Sender::new(OutputState {
                head: Seq::ZERO,
                closed: false,
            }),
            echo: watch::Sender::new(initial_echo),
            shutdown: AtomicBool::new(false),
            input_budget: Semaphore::new(MAX_QUEUED_INPUT),
        });

        thread::Builder::new()
            .name(format!("pty-wait-{}", pid.as_raw_nonzero()))
            .spawn({
                let process = Arc::clone(&process);
                move || wait::run(child, &process)
            })?;

        let (input, input_rx) = mpsc::channel(INPUT_QUEUE);
        let (waker, wake_rx) = io_loop::wake_pipe()?;
        let io = io_loop::IoLoop::new(
            Arc::clone(&master),
            wake_rx,
            input_rx,
            Arc::clone(&shared),
            options.output_hook,
        );
        let started = thread::Builder::new()
            .name(format!("pty-io-{}", pid.as_raw_nonzero()))
            .spawn(move || io.run());
        if let Err(err) = started {
            let _ = rustix::process::kill_process(pid, rustix::process::Signal::KILL);
            return Err(err);
        }

        Ok(Self {
            master,
            shared,
            process,
            input,
            waker,
        })
    }

    /// Returns the child's process id.
    pub fn pid(&self) -> u32 {
        self.process.pid.as_raw_nonzero().get() as u32
    }

    /// Returns the offset one past the newest output byte.
    pub fn head(&self) -> Seq {
        self.shared.ring().head()
    }

    /// Returns the oldest output offset still retained.
    pub fn oldest(&self) -> Seq {
        self.shared.ring().oldest()
    }

    /// Returns all retained output from `seq` to the head, for a client resuming at `seq`.
    ///
    /// # Errors
    ///
    /// Returns [`ReadError::Evicted`] or [`ReadError::Ahead`] when `seq` is outside the ring;
    /// the client then needs a terminal snapshot.
    pub fn read_from(&self, seq: Seq) -> Result<Chunk, ReadError> {
        self.shared.ring().read_from(seq)
    }

    /// Returns a subscriber positioned at the current head (new output only).
    pub fn subscribe(&self) -> Subscriber {
        let rx = self.shared.output.subscribe();
        let next = self.head();
        Subscriber {
            shared: Arc::clone(&self.shared),
            rx,
            next,
        }
    }

    /// Returns a subscriber that first replays retained output from `seq`.
    ///
    /// # Errors
    ///
    /// Returns a [`ReadError`] if `seq` is outside the ring.
    pub fn subscribe_from(&self, seq: Seq) -> Result<Subscriber, ReadError> {
        let mut subscriber = self.subscribe();
        subscriber.seek(seq)?;
        Ok(subscriber)
    }

    /// Queues `data` to be written to the child's input, waiting while the queue is full
    /// ([`MAX_QUEUED_INPUT`] bytes the child has not taken yet).
    ///
    /// Writes are applied in order. The bytes are written without blocking the I/O thread even if
    /// the child is not reading.
    ///
    /// # Errors
    ///
    /// Returns [`Closed`] if the I/O thread has stopped.
    pub async fn write(&self, data: impl Into<Bytes>) -> Result<(), Closed> {
        let data = data.into();
        let permits = permits_for(data.len());
        self.shared
            .input_budget
            .acquire_many(permits)
            .await
            .map_err(|_| Closed)?
            .forget();
        let input = Input { data, permits };
        if let Err(err) = self.input.send(input).await {
            self.shared.input_budget.add_permits(err.0.permits as usize);
            return Err(Closed);
        }
        self.waker.wake();
        Ok(())
    }

    /// Queues `data` without waiting.
    ///
    /// # Errors
    ///
    /// Returns [`TryWriteError::Full`] if the input queue is full and
    /// [`TryWriteError::Closed`] if the I/O thread has stopped.
    pub fn try_write(&self, data: impl Into<Bytes>) -> Result<(), TryWriteError> {
        let data = data.into();
        let permits = permits_for(data.len());
        match self.shared.input_budget.try_acquire_many(permits) {
            Ok(p) => p.forget(),
            Err(tokio::sync::TryAcquireError::NoPermits) => return Err(TryWriteError::Full(data)),
            Err(tokio::sync::TryAcquireError::Closed) => return Err(TryWriteError::Closed(data)),
        }
        self.input
            .try_send(Input { data, permits })
            .map_err(|err| {
                let (input, full) = match err {
                    mpsc::error::TrySendError::Full(input) => (input, true),
                    mpsc::error::TrySendError::Closed(input) => (input, false),
                };
                self.shared.input_budget.add_permits(input.permits as usize);
                if full {
                    TryWriteError::Full(input.data)
                } else {
                    TryWriteError::Closed(input.data)
                }
            })?;
        self.waker.wake();
        Ok(())
    }

    /// Sets the terminal size (`TIOCSWINSZ`); the foreground job receives `SIGWINCH`.
    ///
    /// # Errors
    ///
    /// Returns the `ioctl` error.
    pub fn resize(&self, size: WinSize) -> io::Result<()> {
        termios::set_size(&*self.master, size)
    }

    /// Returns the current terminal size.
    ///
    /// # Errors
    ///
    /// Returns the `ioctl` error.
    pub fn size(&self) -> io::Result<WinSize> {
        let ws = rustix::termios::tcgetwinsize(&*self.master)?;
        Ok(WinSize {
            rows: ws.ws_row,
            cols: ws.ws_col,
            pixel_width: ws.ws_xpixel,
            pixel_height: ws.ws_ypixel,
        })
    }

    /// Sends `signal` to the child process.
    ///
    /// # Errors
    ///
    /// Returns [`SignalError::Exited`] once the child has been reaped, so a recycled pid is never
    /// signalled, and [`SignalError::Io`] if `kill(2)` fails.
    pub fn signal(&self, signal: Signal) -> Result<(), SignalError> {
        let reaped = self.process.reaped();
        if *reaped {
            return Err(SignalError::Exited);
        }
        rustix::process::kill_process(self.process.pid, signal.into()).map_err(io::Error::from)?;
        Ok(())
    }

    /// Waits for the child to exit and returns its status.
    ///
    /// # Errors
    ///
    /// Returns an error if the status could not be collected (for example because something
    /// else in this process reaped the child).
    pub async fn wait(&self) -> io::Result<ExitStatus> {
        let mut rx = self.process.exit.subscribe();
        let result = *rx
            .wait_for(Option::is_some)
            .await
            .expect("the sender lives in `self.process`");
        exit_result(result.expect("waited for Some"))
    }

    /// Returns the exit status if the child has exited, without waiting.
    pub fn try_wait(&self) -> Option<io::Result<ExitStatus>> {
        let result = *self.process.exit.borrow();
        result.map(exit_result)
    }

    /// Returns the slave's echo and canonical-mode flags as last observed.
    ///
    /// The I/O thread re-reads them after every burst of output or input, every 25 ms for half
    /// a second after activity, once a second for the next 30 seconds, and after that only on
    /// [`refresh_echo`](Self::refresh_echo).
    pub fn echo_state(&self) -> EchoState {
        *self.shared.echo.borrow()
    }

    /// Asks the I/O thread to re-read the echo flags now, for a terminal that has been quiet
    /// long enough that it stopped polling them (before someone starts typing into it).
    pub fn refresh_echo(&self) {
        self.waker.wake();
    }

    /// Returns a receiver that is notified whenever the [`EchoState`] changes.
    pub fn echo_updates(&self) -> watch::Receiver<EchoState> {
        self.shared.echo.subscribe()
    }

    /// Identifies the leader of the terminal's foreground process group.
    ///
    /// This makes a few cheap synchronous syscalls (and on Linux reads `/proc`). Returns `None`
    /// if the group or its leader has gone away.
    pub fn foreground_process(&self) -> Option<ForegroundProcess> {
        foreground::foreground_process(&*self.master, self.pid())
    }

    /// Returns the terminal's foreground process group id: one syscall, for telling cheaply
    /// whether [`foreground_process`](Self::foreground_process) may have changed.
    pub fn foreground_pgid(&self) -> Option<u32> {
        foreground::foreground_pgid(&*self.master, self.pid())
    }
}

fn exit_result(result: Result<ExitStatus, i32>) -> io::Result<ExitStatus> {
    result.map_err(io::Error::from_raw_os_error)
}

impl Drop for PtyActor {
    fn drop(&mut self) {
        self.shared.shutdown.store(true, Ordering::Release);
        self.waker.wake();
    }
}

impl fmt::Debug for PtyActor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PtyActor")
            .field("pid", &self.pid())
            .field("ring", &*self.shared.ring())
            .finish_non_exhaustive()
    }
}

/// A cursor over a PTY's output that is woken when new bytes arrive.
///
/// Created by [`PtyActor::subscribe`] or [`PtyActor::subscribe_from`]. It outlives the actor and
/// can drain the remaining retained output after the child exits.
pub struct Subscriber {
    shared: Arc<Shared>,
    rx: watch::Receiver<OutputState>,
    next: Seq,
}

impl Subscriber {
    /// Returns the offset of the next byte this subscriber will receive.
    pub fn position(&self) -> Seq {
        self.next
    }

    /// Moves the cursor to `seq`, for example to the offset of a snapshot just sent.
    ///
    /// # Errors
    ///
    /// Returns a [`ReadError`] if `seq` is outside the ring; the cursor is then unchanged.
    pub fn seek(&mut self, seq: Seq) -> Result<(), ReadError> {
        self.shared.ring().read_at_most(seq, 0)?;
        self.next = seq;
        Ok(())
    }

    /// Waits for and returns the next run of output (at most 64 KiB).
    ///
    /// # Errors
    ///
    /// Returns [`RecvError::Evicted`] if this subscriber fell behind the ring, and
    /// [`RecvError::Closed`] once output has ended and everything has been received.
    pub async fn recv(&mut self) -> Result<Chunk, RecvError> {
        loop {
            // Mark the current head as seen *before* reading, so a push after the read always
            // wakes `changed` below.
            let state = *self.rx.borrow_and_update();
            let read = self
                .shared
                .ring()
                .read_at_most(self.next, MAX_SUBSCRIBER_CHUNK);
            match read {
                Ok(chunk) if !chunk.data.is_empty() => {
                    self.next = chunk.end();
                    return Ok(chunk);
                }
                Ok(_) | Err(ReadError::Ahead { .. }) => {}
                Err(ReadError::Evicted { requested, oldest }) => {
                    return Err(RecvError::Evicted { requested, oldest });
                }
            }
            if state.closed {
                return Err(RecvError::Closed);
            }
            if self.rx.changed().await.is_err() {
                return Err(RecvError::Closed);
            }
        }
    }
}

impl fmt::Debug for Subscriber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Subscriber")
            .field("next", &self.next)
            .finish_non_exhaustive()
    }
}
