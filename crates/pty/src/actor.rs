//! The per-pane PTY actor: owns the master fd and the child, never blocks the async runtime.
//!
//! Two OS threads per pane, both outside tokio:
//!
//! - **I/O thread** (`pty-io-<pid>`): `poll(2)` over the non-blocking master and a self-pipe.
//!   It reads output into the [`OutputRing`], drains queued input with non-blocking writes, and
//!   re-reads the slave's [`EchoState`].
//! - **Wait thread** (`pty-wait-<pid>`): blocks in `waitid` until the child exits.
//!
//! Subscribers never receive pushed data. They hold a cursor into the ring and are woken through a
//! [`watch`] of the head offset, so a slow subscriber costs the reader nothing: it just falls
//! behind and, past the ring's capacity, gets [`RecvError::Evicted`].

mod io_loop;
mod wait;

use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::process::ExitStatusExt;
use std::process::{Command, ExitStatus};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};
use std::{fmt, thread};

use bytes::Bytes;
use rustix::process::{Pid, WaitId, WaitIdOptions};
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

struct Shared {
    ring: Mutex<OutputRing>,
    output: watch::Sender<OutputState>,
    echo: watch::Sender<EchoState>,
    shutdown: AtomicBool,
    /// Asks the I/O thread to stop for [`PtyActor::hand_off`].
    handing_off: AtomicBool,
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
    /// Set under `reaped` by [`PtyActor::hand_off`]: the child is left for the next process.
    handed_off: AtomicBool,
    exit: watch::Sender<Option<Result<ExitStatus, i32>>>,
}

impl Process {
    fn new(pid: Pid) -> Self {
        Self {
            pid,
            reaped: Mutex::new(false),
            handed_off: AtomicBool::new(false),
            exit: watch::Sender::new(None),
        }
    }

    fn reaped(&self) -> MutexGuard<'_, bool> {
        self.reaped.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn handed_off(&self) -> bool {
        self.handed_off.load(Ordering::Acquire)
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
    io_thread: Mutex<Option<thread::JoinHandle<Vec<u8>>>>,
}

/// A PTY stopped by [`PtyActor::hand_off`], for the program that replaces this process with
/// `exec` to continue with [`PtyActor::adopt`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HandedOff {
    /// The master, still open in this process (the actor's drop closes it if no `exec`
    /// follows).
    pub master: RawFd,
    /// The child: a session leader whose controlling terminal is the PTY.
    pub pid: u32,
    pub ring_capacity: usize,
    pub head: Seq,
    /// The ring's retained output, from its oldest offset to `head`.
    pub retained: Bytes,
    /// Input accepted but not yet taken by the child, in order.
    pub unsent_input: Vec<u8>,
    /// The child's raw wait status if it had already been reaped (its pid may be reused).
    pub exit_status: Option<i32>,
}

/// Why [`PtyActor::adopt`] refused a descriptor or process.
#[derive(Debug, thiserror::Error)]
pub enum AdoptError {
    /// The descriptor is not a PTY master.
    #[error("descriptor {0} is not a pseudo-terminal master")]
    NotAMaster(RawFd),
    /// The process is not a child of this one (it was reaped, or never was).
    #[error("process {0} is not a child of this process")]
    NotAChild(u32),
    /// The retained output does not fit the ring described.
    #[error("the output history does not match its ring")]
    Ring,
    /// A thread could not start, or a descriptor could not be set up.
    #[error(transparent)]
    Io(#[from] io::Error),
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
    /// Spawns `command` in a new PTY and starts its I/O and wait threads.
    ///
    /// `command` supplies argv, environment, and working directory as usual. Its stdin, stdout, and
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
    pub fn spawn(command: Command, options: SpawnOptions) -> io::Result<Self> {
        let ring = OutputRing::new(options.ring_capacity);
        let spawn::Spawned { master, child } = spawn::spawn(command, options.size)?;
        let pid = Pid::from_child(&child);
        Self::start(
            master,
            pid,
            ring,
            wait::Reap::Spawned(child),
            None,
            options.output_hook,
        )
    }

    /// Continues a PTY that the program this process ran before its `exec` stopped with
    /// [`hand_off`](Self::hand_off): `master` is the master descriptor, inherited across
    /// `exec`, and the child is still a child of this process (`exec` keeps the pid).
    ///
    /// Output offsets continue at `handed_off.head` with the same history, and the unsent
    /// input is written first. The master is made close-on-exec again at once, so programs
    /// this process starts later never inherit it.
    ///
    /// # Errors
    ///
    /// [`AdoptError::NotAMaster`] if `master` is not a PTY master; [`AdoptError::NotAChild`]
    /// if the pid is not an unreaped child of this process (it must then never be signalled,
    /// as it may belong to someone else); [`AdoptError::Ring`] if the history does not fit
    /// the ring; an I/O error if a thread cannot start. `master` is closed on error.
    ///
    /// # Panics
    ///
    /// Panics if `handed_off.ring_capacity` is zero.
    pub fn adopt(
        master: OwnedFd,
        handed_off: &HandedOff,
        output_hook: Option<OutputHook>,
    ) -> Result<Self, AdoptError> {
        let exit = handed_off.exit_status.map(ExitStatus::from_raw);
        let Some(pid) = child_pid(handed_off.pid).filter(|&pid| exit.is_some() || is_child(pid))
        else {
            return Err(AdoptError::NotAChild(handed_off.pid));
        };
        // From here on a running child is ours: if it cannot be continued, it ends like a
        // closed pane rather than running on unseen.
        let end_child_on = |error: AdoptError| {
            if exit.is_none() {
                give_up(pid, GIVE_UP_GRACE);
            }
            error
        };
        let raw = master.as_raw_fd();
        rustix::io::fcntl_setfd(&master, rustix::io::FdFlags::CLOEXEC)
            .map_err(|error| end_child_on(io::Error::from(error).into()))?;
        rustix::pty::ptsname(&master, Vec::new())
            .map_err(|_| end_child_on(AdoptError::NotAMaster(raw)))?;
        let ring = OutputRing::resume(
            handed_off.ring_capacity,
            handed_off.head,
            &handed_off.retained,
        )
        .ok_or_else(|| end_child_on(AdoptError::Ring))?;
        let actor = Self::start(master, pid, ring, wait::Reap::Adopted, exit, output_hook)
            .map_err(|error| end_child_on(error.into()))?;
        if !handed_off.unsent_input.is_empty() {
            let input = Bytes::copy_from_slice(&handed_off.unsent_input);
            if let Err(TryWriteError::Full(input) | TryWriteError::Closed(input)) =
                actor.try_write(input)
            {
                tracing::debug!(len = input.len(), "dropped input from before the hand-off");
            }
        }
        Ok(actor)
    }

    fn start(
        master: OwnedFd,
        pid: Pid,
        ring: OutputRing,
        reap: wait::Reap,
        exited: Option<ExitStatus>,
        output_hook: Option<OutputHook>,
    ) -> io::Result<Self> {
        rustix::fs::fcntl_setfl(&master, rustix::fs::OFlags::NONBLOCK)?;
        let master = Arc::new(master);
        let process = Arc::new(Process::new(pid));
        let initial_echo = EchoState::read(&*master).unwrap_or_default();
        let head = ring.head();
        let shared = Arc::new(Shared {
            ring: Mutex::new(ring),
            output: watch::Sender::new(OutputState {
                head,
                closed: false,
            }),
            echo: watch::Sender::new(initial_echo),
            shutdown: AtomicBool::new(false),
            handing_off: AtomicBool::new(false),
            input_budget: Semaphore::new(MAX_QUEUED_INPUT),
        });

        match exited {
            Some(status) => {
                *process.reaped() = true;
                process.exit.send_replace(Some(Ok(status)));
            }
            None => {
                thread::Builder::new()
                    .name(format!("pty-wait-{}", pid.as_raw_nonzero()))
                    .spawn({
                        let process = Arc::clone(&process);
                        move || wait::run(reap, &process)
                    })?;
            }
        }

        let (input, input_rx) = mpsc::channel(INPUT_QUEUE);
        let (waker, wake_rx) = io_loop::wake_pipe()?;
        let io_loop = io_loop::IoLoop::new(
            Arc::clone(&master),
            wake_rx,
            input_rx,
            Arc::clone(&shared),
            output_hook,
        );
        let started = thread::Builder::new()
            .name(format!("pty-io-{}", pid.as_raw_nonzero()))
            .spawn(move || io_loop.run());
        let io_thread = match started {
            Ok(handle) => handle,
            Err(err) => {
                if !*process.reaped() {
                    let _ = rustix::process::kill_process(pid, rustix::process::Signal::KILL);
                }
                return Err(err);
            }
        };

        Ok(Self {
            master,
            shared,
            process,
            input,
            waker,
            io_thread: Mutex::new(Some(io_thread)),
        })
    }

    /// Stops this PTY for the program that replaces this process with `exec`, which continues
    /// it with [`adopt`](Self::adopt), and returns what that needs.
    ///
    /// Reading and writing stop at once (new output waits in the kernel for the next reader)
    /// and the child is no longer reaped here, so its pid stays reserved until the next
    /// program reaps it. Nothing is closed: the master stays open and close-on-exec, and the
    /// caller clears `FD_CLOEXEC` on exactly the masters it passes on, right before `exec`.
    /// Writes fail from now on.
    ///
    /// # Errors
    ///
    /// Returns an error if the I/O thread had panicked; the PTY is stopped anyway.
    pub fn hand_off(&self) -> io::Result<HandedOff> {
        let exit_status = {
            let reaped = self.process.reaped();
            self.process.handed_off.store(true, Ordering::Release);
            if *reaped {
                self.process
                    .exit
                    .borrow()
                    .and_then(Result::ok)
                    .map(ExitStatusExt::into_raw)
            } else {
                None
            }
        };
        self.shared.handing_off.store(true, Ordering::Release);
        self.waker.wake();
        let io_thread = self
            .io_thread
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        let unsent_input = match io_thread.map(thread::JoinHandle::join) {
            Some(Ok(unsent)) => unsent,
            Some(Err(_)) => return Err(io::Error::other("the pty I/O thread panicked")),
            None => Vec::new(),
        };
        let ring = self.shared.ring();
        let retained = ring
            .read_from(ring.oldest())
            .expect("the oldest offset is always readable")
            .data;
        Ok(HandedOff {
            master: self.master.as_raw_fd(),
            pid: self.pid(),
            ring_capacity: ring.capacity(),
            head: ring.head(),
            retained,
            unsent_input,
            exit_status,
        })
    }

    /// Ends the child of a PTY stopped with [`hand_off`](Self::hand_off) when no `exec`
    /// follows after all: hangs up its session, kills the session's process group if it still
    /// runs after `grace`, and reaps it. Blocks until then; does nothing before a hand-off or
    /// once the child is reaped.
    pub fn end_handed_off(&self, grace: Duration) {
        let mut reaped = self.process.reaped();
        if *reaped || !self.process.handed_off() {
            return;
        }
        hang_up(self.process.pid);
        let status = end_child(self.process.pid, grace);
        *reaped = true;
        self.process
            .exit
            .send_replace(Some(status.ok_or(libc::ECHILD)));
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
        let output_rx = self.shared.output.subscribe();
        let next = self.head();
        Subscriber {
            shared: Arc::clone(&self.shared),
            output_rx,
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
            Ok(permit) => permit.forget(),
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
        let winsize = rustix::termios::tcgetwinsize(&*self.master)?;
        Ok(WinSize {
            rows: winsize.ws_row,
            cols: winsize.ws_col,
            pixel_width: winsize.ws_xpixel,
            pixel_height: winsize.ws_ypixel,
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

    /// Sends `signal` to the child's process group: the child leads its own session and group,
    /// so this reaches what it runs in the foreground of that group too.
    ///
    /// # Errors
    ///
    /// As for [`signal`](Self::signal).
    pub fn signal_group(&self, signal: Signal) -> Result<(), SignalError> {
        let reaped = self.process.reaped();
        if *reaped {
            return Err(SignalError::Exited);
        }
        rustix::process::kill_process_group(self.process.pid, signal.into())
            .map_err(io::Error::from)?;
        Ok(())
    }

    /// Waits for the child to exit and returns its status.
    ///
    /// # Errors
    ///
    /// Returns an error if the status could not be collected (for example because something
    /// else in this process reaped the child).
    pub async fn wait(&self) -> io::Result<ExitStatus> {
        let mut exit_rx = self.process.exit.subscribe();
        let result = *exit_rx
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

/// `pid` as a process id that could be a child: positive and not init.
fn child_pid(pid: u32) -> Option<Pid> {
    i32::try_from(pid)
        .ok()
        .filter(|&raw| raw > 1)
        .and_then(Pid::from_raw)
}

/// Whether `pid` is a child of this process that has not been reaped (running, stopped or a
/// zombie).
fn is_child(pid: Pid) -> bool {
    loop {
        match rustix::process::waitid(
            WaitId::Pid(pid),
            WaitIdOptions::EXITED
                | WaitIdOptions::STOPPED
                | WaitIdOptions::CONTINUED
                | WaitIdOptions::NOHANG
                | WaitIdOptions::NOWAIT,
        ) {
            Ok(_) => return true,
            Err(rustix::io::Errno::INTR) => continue,
            Err(_) => return false,
        }
    }
}

/// Ends a PTY handed off by the program this process ran before its `exec` that will not be
/// continued (it could not be adopted, or nothing wants it), as closing a pane would: hangs
/// up the child's session, closes the master and, after `grace`, kills the session's process
/// group if it still runs. The child is reaped, on a thread of its own, so no zombie stays.
/// Only an unreaped child of this process is ever signalled.
pub fn abandon(master: OwnedFd, pid: u32, grace: Duration) {
    let Some(pid) = child_pid(pid).filter(|&pid| is_child(pid)) else {
        drop(master);
        return;
    };
    drop(master);
    give_up(pid, grace);
}

/// How long a child that cannot be adopted may outlive its hangup.
const GIVE_UP_GRACE: Duration = Duration::from_secs(3);

/// Hangs up an unreaped child and ends and reaps it on a thread of its own.
fn give_up(pid: Pid, grace: Duration) {
    hang_up(pid);
    let raw = pid.as_raw_nonzero().get();
    if let Err(err) = thread::Builder::new()
        .name(format!("pty-abandon-{raw}"))
        .spawn(move || end_child(pid, grace))
    {
        tracing::warn!(pid = raw, %err, "no thread to reap an abandoned pane; killing it");
        let _ = rustix::process::kill_process_group(pid, rustix::process::Signal::KILL);
    }
}

fn hang_up(pid: Pid) {
    let _ = rustix::process::kill_process_group(pid, rustix::process::Signal::HUP);
    let _ = rustix::process::kill_process(pid, rustix::process::Signal::HUP);
}

/// Waits up to `grace` for an unreaped child that was hung up to exit, kills its process
/// group if it has not, and reaps it. Blocks until it is reaped.
fn end_child(pid: Pid, grace: Duration) -> Option<ExitStatus> {
    let raw = pid.as_raw_nonzero().get();
    let deadline = Instant::now() + grace;
    let mut status = 0;
    loop {
        // SAFETY: waitpid writes the status through a valid pointer to a local.
        match unsafe { libc::waitpid(raw, &mut status, libc::WNOHANG) } {
            0 => {}
            -1 if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted => continue,
            -1 => return None,
            _ => return Some(ExitStatus::from_raw(status)),
        }
        if Instant::now() >= deadline {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    // Still unreaped, so the pid is still the child's.
    let _ = rustix::process::kill_process_group(pid, rustix::process::Signal::KILL);
    let _ = rustix::process::kill_process(pid, rustix::process::Signal::KILL);
    loop {
        // SAFETY: as above.
        match unsafe { libc::waitpid(raw, &mut status, 0) } {
            -1 if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted => {}
            -1 => return None,
            _ => return Some(ExitStatus::from_raw(status)),
        }
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
    output_rx: watch::Receiver<OutputState>,
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
            let state = *self.output_rx.borrow_and_update();
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
            if self.output_rx.changed().await.is_err() {
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
