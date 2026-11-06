//! Never return an agent's unread native input to the fallback shell.

use std::io::{self, Read, Write};
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use daemon::agent_input::{AgentInputCall, AgentInputReply};
use rustix::event::{PollFd, PollFlags, Timespec};
use rustix::termios::{self, OptionalActions, QueueSelector, SpecialCodeIndex, Termios};

const WAIT: Duration = Duration::from_secs(7);
const MAX_REPLY: usize = 128;

pub(super) enum FenceAction {
    Arm,
    Close,
}

pub(super) fn main(arguments: &[String], action: FenceAction) -> i32 {
    match run(arguments, action) {
        Ok(()) => 0,
        Err(_) => {
            eprintln!(
                "{}: agent input fence failed; no fallback shell",
                brand::HOOK_BIN
            );
            1
        }
    }
}

fn run(arguments: &[String], action: FenceAction) -> io::Result<()> {
    let [launch] = arguments else {
        return Err(io::Error::other("expected one launch id"));
    };
    let env = |name| brand::var(name).ok_or_else(|| io::Error::other("missing pane environment"));
    let token = env("TOKEN")?;
    let pane = proto::PaneId(env("PANE_ID")?.parse().map_err(io::Error::other)?);
    let socket = brand::var("ENDPOINT_FILE")
        .and_then(|path| std::fs::read_to_string(path).ok())
        .map(|path| PathBuf::from(path.trim()))
        .or_else(|| brand::var("SOCK").map(PathBuf::from))
        .ok_or_else(|| io::Error::other("no hook endpoint"))?;
    let input = io::stdin();
    let call = if matches!(action, FenceAction::Close) {
        termios::tcgetattr(input.as_fd())?;
        AgentInputCall::Close {
            token,
            pane,
            launch: launch.clone(),
        }
    } else {
        AgentInputCall::Arm {
            token,
            pane,
            launch: launch.clone(),
        }
    };
    let stream = UnixStream::connect(socket)?;
    exchange(input.as_fd(), stream, &call, WAIT)
}

fn exchange(
    input: BorrowedFd<'_>,
    mut stream: UnixStream,
    call: &AgentInputCall,
    wait: Duration,
) -> io::Result<()> {
    let is_exit = matches!(call, AgentInputCall::Close { .. });
    let deadline = Instant::now() + wait;
    let modes = if is_exit {
        Some(TtyModes::discarding(input)?)
    } else {
        None
    };
    stream.set_write_timeout(Some(wait))?;
    let mut request = serde_json::to_vec(call)?;
    request.push(b'\n');
    stream.write_all(&request)?;
    stream.set_nonblocking(true)?;
    let mut reply = Vec::new();
    let mut scratch = [0u8; 8192];
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "agent input fence"))?;
        let timeout = Timespec::try_from(remaining).map_err(io::Error::other)?;
        let mut fds = [
            PollFd::new(&stream, PollFlags::IN),
            PollFd::new(
                &input,
                if is_exit {
                    PollFlags::IN
                } else {
                    PollFlags::empty()
                },
            ),
        ];
        match rustix::event::poll(&mut fds, Some(&timeout)) {
            Err(rustix::io::Errno::INTR) => continue,
            Err(error) => return Err(error.into()),
            Ok(_) => {}
        }
        if fds[1]
            .revents()
            .intersects(PollFlags::ERR | PollFlags::HUP | PollFlags::NVAL)
        {
            return Err(io::Error::other("terminal closed during agent input fence"));
        }
        if !fds[0].revents().is_empty() {
            match (&stream).read(&mut scratch[..MAX_REPLY]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "no agent input acknowledgement",
                    ));
                }
                Ok(count) => reply.extend_from_slice(&scratch[..count]),
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) =>
                {
                    continue;
                }
                Err(error) => return Err(error),
            }
            if reply.len() > MAX_REPLY {
                return Err(io::Error::other("oversized agent input acknowledgement"));
            }
            if let Some(end) = reply.iter().position(|byte| *byte == b'\n') {
                let reply: AgentInputReply = serde_json::from_slice(&reply[..end])?;
                let expected = if is_exit {
                    AgentInputReply::Closed
                } else {
                    AgentInputReply::Ready
                };
                if reply != expected {
                    return Err(io::Error::other("agent input fence refused"));
                }
                if let Some(modes) = modes {
                    modes.finish()?;
                }
                return Ok(());
            }
        }
        if is_exit && fds[1].revents().contains(PollFlags::IN) {
            match rustix::io::read(input, &mut scratch) {
                Ok(_) | Err(rustix::io::Errno::INTR | rustix::io::Errno::AGAIN) => {}
                Err(error) => return Err(error.into()),
            }
        }
    }
}

struct TtyModes<'a> {
    input: BorrowedFd<'a>,
    original: Termios,
    is_restored: bool,
}

impl<'a> TtyModes<'a> {
    fn discarding(input: BorrowedFd<'a>) -> io::Result<Self> {
        let original = termios::tcgetattr(input)?;
        let mut raw = original.clone();
        raw.make_raw();
        raw.special_codes[SpecialCodeIndex::VMIN] = 0;
        raw.special_codes[SpecialCodeIndex::VTIME] = 0;
        termios::tcsetattr(input, OptionalActions::Now, &raw)?;
        Ok(Self {
            input,
            original,
            is_restored: false,
        })
    }

    fn finish(mut self) -> io::Result<()> {
        termios::tcflush(self.input, QueueSelector::IFlush)?;
        termios::tcsetattr(self.input, OptionalActions::Now, &self.original)?;
        self.is_restored = true;
        termios::tcflush(self.input, QueueSelector::IFlush)?;
        Ok(())
    }
}

impl Drop for TtyModes<'_> {
    fn drop(&mut self) {
        if !self.is_restored {
            let _ = termios::tcflush(self.input, QueueSelector::IFlush);
            let _ = termios::tcsetattr(self.input, OptionalActions::Now, &self.original);
            let _ = termios::tcflush(self.input, QueueSelector::IFlush);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::fd::OwnedFd;

    fn terminal_pair() -> (OwnedFd, OwnedFd) {
        let master = (0..100)
            .find_map(|_| {
                let result = rustix::fs::open(
                    c"/dev/ptmx",
                    rustix::fs::OFlags::RDWR
                        | rustix::fs::OFlags::NOCTTY
                        | rustix::fs::OFlags::CLOEXEC
                        | rustix::fs::OFlags::NONBLOCK,
                    rustix::fs::Mode::empty(),
                );
                if result.is_err() {
                    std::thread::yield_now();
                }
                result.ok()
            })
            .expect("open test master");
        rustix::pty::grantpt(&master).unwrap();
        rustix::pty::unlockpt(&master).unwrap();
        let name = rustix::pty::ptsname(&master, Vec::new()).unwrap();
        let slave = rustix::fs::open(
            name.as_c_str(),
            rustix::fs::OFlags::RDWR | rustix::fs::OFlags::NOCTTY | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .unwrap();
        (master, slave)
    }

    fn assert_restored(slave: BorrowedFd<'_>, original: &Termios) {
        let after = termios::tcgetattr(slave).unwrap();
        assert_eq!(after.input_modes, original.input_modes);
        assert_eq!(after.output_modes, original.output_modes);
        assert_eq!(after.control_modes, original.control_modes);
        assert_eq!(after.local_modes, original.local_modes);
        assert_eq!(
            after.special_codes[SpecialCodeIndex::VMIN],
            original.special_codes[SpecialCodeIndex::VMIN]
        );
        assert_eq!(
            after.special_codes[SpecialCodeIndex::VTIME],
            original.special_codes[SpecialCodeIndex::VTIME]
        );
    }

    fn close_call() -> AgentInputCall {
        AgentInputCall::Close {
            token: "test-token".into(),
            pane: proto::PaneId(42),
            launch: "test-launch".into(),
        }
    }

    #[test]
    fn blocked_native_input_is_drained_before_a_zero_byte_fallback_read() {
        let (master, slave) = terminal_pair();
        let original = termios::tcgetattr(&slave).unwrap();
        let (client, mut server) = UnixStream::pair().unwrap();
        std::thread::scope(|scope| {
            let writer = scope.spawn(|| {
                server
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut request = String::new();
                BufReader::new(server.try_clone().unwrap())
                    .read_line(&mut request)
                    .unwrap();
                assert!(matches!(
                    serde_json::from_str::<AgentInputCall>(&request).unwrap(),
                    AgentInputCall::Close { .. }
                ));
                let data = b"NATIVE_PROMPT_MUST_NOT_REACH_A_SHELL\r".repeat(8192);
                let mut offset = 0;
                let deadline = Instant::now() + Duration::from_secs(2);
                while offset < data.len() {
                    assert!(Instant::now() < deadline, "native writer was not drained");
                    match rustix::io::write(&master, &data[offset..]) {
                        Ok(count) => offset += count,
                        Err(rustix::io::Errno::AGAIN | rustix::io::Errno::INTR) => {
                            std::thread::sleep(Duration::from_millis(1))
                        }
                        Err(error) => panic!("native write: {error}"),
                    }
                }
                server.write_all(b"\"closed\"\n").unwrap();
                offset
            });
            exchange(slave.as_fd(), client, &close_call(), Duration::from_secs(3)).unwrap();
            assert!(writer.join().unwrap() > 262_144);
        });
        assert_restored(slave.as_fd(), &original);
        let mut raw = original;
        raw.make_raw();
        raw.special_codes[SpecialCodeIndex::VMIN] = 0;
        raw.special_codes[SpecialCodeIndex::VTIME] = 0;
        termios::tcsetattr(&slave, OptionalActions::Now, &raw).unwrap();
        let mut fallback = [0u8; 8192];
        assert_eq!(
            rustix::io::read(&slave, &mut fallback).unwrap(),
            0,
            "fallback received native bytes"
        );
    }

    #[test]
    fn missing_wrong_or_malformed_acknowledgements_refuse_the_shell() {
        for answer in [
            b"\"refused\"\n".as_slice(),
            b"\"ready\"\n",
            b"{}\n",
            &[b'x'; MAX_REPLY + 1],
            b"",
        ] {
            let (_master, slave) = terminal_pair();
            let original = termios::tcgetattr(&slave).unwrap();
            let (client, mut server) = UnixStream::pair().unwrap();
            server.write_all(answer).unwrap();
            server.shutdown(std::net::Shutdown::Write).unwrap();
            assert!(
                exchange(
                    slave.as_fd(),
                    client,
                    &close_call(),
                    Duration::from_millis(100)
                )
                .is_err()
            );
            assert_restored(slave.as_fd(), &original);
        }
    }

    #[test]
    fn a_timed_out_acknowledgement_refuses_the_shell_and_restores_modes() {
        let (_master, slave) = terminal_pair();
        let original = termios::tcgetattr(&slave).unwrap();
        let (client, _server) = UnixStream::pair().unwrap();
        let error = exchange(
            slave.as_fd(),
            client,
            &close_call(),
            Duration::from_millis(20),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert_restored(slave.as_fd(), &original);
    }
}
