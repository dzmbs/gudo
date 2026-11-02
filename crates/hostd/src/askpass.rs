//! The askpass helper (`gudo-hook askpass <prompt>`, also `gudo-hostd askpass <prompt>`):
//! what `SUDO_ASKPASS`, `SSH_ASKPASS` and `GIT_ASKPASS` run in a pane (docs/DAEMON.md §9).
//!
//! It asks the daemon over the hook socket, which shows the prompt in the app, and prints the
//! answer on stdout. When no app can answer (or the daemon is not reachable) it asks on the
//! terminal itself, with echo off, so nothing gets worse than without it. `--available`
//! only asks whether an app could answer (exit 0) or not (exit 1); the `sudo` wrapper uses it.
//!
//! Exit status: 0 with the secret on stdout, 1 when cancelled, timed out or unanswerable.

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use daemon::{ASKPASS_VERSION, AskpassCall, HelperQuery, HelperReply};

/// Runs the helper with the arguments after `askpass`; returns the exit status.
pub fn main(args: &[String]) -> i32 {
    let probe = args.first().is_some_and(|a| a == "--available");
    let prompt = if probe {
        String::new()
    } else {
        args.first().cloned().unwrap_or_else(|| "Password:".into())
    };
    let ssh_hint = std::env::var("SSH_ASKPASS_PROMPT").unwrap_or_default();
    if !probe && ssh_hint == "none" {
        // ssh only shows a notice ("Confirm user presence for key …") and kills us when done.
        notice(&prompt);
        return 0;
    }
    let query = HelperQuery {
        prompt: prompt.clone(),
        program: parent_command(),
        confirm: ssh_hint == "confirm",
        probe,
    };
    match ask_daemon(query, probe) {
        Some(HelperReply::Available(yes)) => i32::from(!yes),
        Some(HelperReply::Answer(ref secret)) => {
            let mut out = std::io::stdout().lock();
            let mut line = Vec::with_capacity(secret.len() + 1);
            line.extend_from_slice(secret.as_bytes());
            line.push(b'\n');
            let ok = out.write_all(&line).and_then(|()| out.flush()).is_ok();
            zeroize::Zeroize::zeroize(&mut line);
            i32::from(!ok)
        }
        Some(HelperReply::Cancelled) => 1,
        _ if probe => 1,
        _ => ask_terminal(&prompt, ssh_hint == "confirm" || is_question(&prompt)),
    }
}

/// One request on the hook socket; `None` when the daemon cannot be reached.
fn ask_daemon(query: HelperQuery, probe: bool) -> Option<HelperReply> {
    let env = |name: &str| brand::var(name);
    // The endpoint file wins over GUDO_SOCK so a pane outlives a daemon restart that moved it.
    let socket = env("ENDPOINT_FILE")
        .and_then(|f| std::fs::read_to_string(f).ok())
        .map(|s| PathBuf::from(s.trim()))
        .or_else(|| env("SOCK").map(PathBuf::from))?;
    let call = AskpassCall {
        v: ASKPASS_VERSION,
        token: env("TOKEN")?,
        pane: env("PANE_ID")?,
        askpass: query,
    };
    let mut stream = UnixStream::connect(socket).ok()?;
    if probe {
        stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    }
    let mut line = serde_json::to_vec(&call).ok()?;
    line.push(b'\n');
    stream.write_all(&line).ok()?;
    // The daemon times the prompt out; the write side stays open so it notices if we are
    // killed (the program gave up).
    let mut answer = String::new();
    let read = BufReader::new(&stream).read_line(&mut answer);
    let reply = read
        .ok()
        .filter(|&n| n > 0)
        .and_then(|_| serde_json::from_str(&answer).ok());
    zeroize::Zeroize::zeroize(&mut answer);
    reply
}

/// Asks on the controlling terminal with echo off (on for a yes/no question).
fn ask_terminal(prompt: &str, echo: bool) -> i32 {
    let Ok(tty) = OpenOptions::new().read(true).write(true).open("/dev/tty") else {
        return 1;
    };
    let mut out = &tty;
    let _ = out.write_all(prompt.as_bytes());
    let _ = out.flush();
    let saved = rustix::termios::tcgetattr(&tty).ok();
    if !echo && let Some(saved) = &saved {
        let mut quiet = saved.clone();
        quiet.local_modes.remove(rustix::termios::LocalModes::ECHO);
        quiet
            .local_modes
            .insert(rustix::termios::LocalModes::ECHONL);
        let _ = rustix::termios::tcsetattr(&tty, rustix::termios::OptionalActions::Flush, &quiet);
    }
    let mut line = Vec::new();
    let read = read_line(&tty, &mut line);
    if !echo && let Some(saved) = &saved {
        let _ = rustix::termios::tcsetattr(&tty, rustix::termios::OptionalActions::Now, saved);
    }
    let status = if read {
        let mut stdout = std::io::stdout().lock();
        line.push(b'\n');
        i32::from(
            stdout
                .write_all(&line)
                .and_then(|()| stdout.flush())
                .is_err(),
        )
    } else {
        1
    };
    zeroize::Zeroize::zeroize(&mut line);
    status
}

/// Reads one line (without its newline) byte by byte, so nothing past it is consumed.
fn read_line(mut tty: &File, line: &mut Vec<u8>) -> bool {
    let mut byte = [0u8; 1];
    loop {
        match tty.read(&mut byte) {
            Ok(0) => return !line.is_empty(),
            Ok(_) if byte[0] == b'\n' || byte[0] == b'\r' => return true,
            Ok(_) => line.push(byte[0]),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return false,
        }
    }
}

/// Shows a notice on the terminal and waits to be killed (at most ten minutes).
fn notice(text: &str) {
    if let Ok(mut tty) = OpenOptions::new().write(true).open("/dev/tty") {
        let _ = writeln!(tty, "{text}");
    }
    std::thread::sleep(Duration::from_secs(600));
}

/// A yes/no question rather than a secret (ssh's host key confirmation).
fn is_question(prompt: &str) -> bool {
    let lower = prompt.to_lowercase();
    lower.contains("(yes/no") || lower.starts_with("username")
}

/// The command line of the program that ran us, for the prompt's "who asks" line.
fn parent_command() -> String {
    let ppid = rustix::process::getppid().map_or(0, |p| p.as_raw_nonzero().get());
    if ppid <= 1 {
        return String::new();
    }
    if let Ok(raw) = std::fs::read(format!("/proc/{ppid}/cmdline")) {
        let args: Vec<String> = raw
            .split(|&b| b == 0)
            .filter(|a| !a.is_empty())
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        if !args.is_empty() {
            return args.join(" ");
        }
    }
    std::process::Command::new("ps")
        .args(["-o", "args=", "-p", &ppid.to_string()])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default()
}
