//! The launch script's restart loop for Claude Code: `claude-relaunch-pending <launch>` exits 0
//! while the daemon waits to start Claude again with new settings, and `claude-relaunch
//! <launch>` starts it with the arguments the daemon gives.

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::time::Duration;

use daemon::agent_config::{RelaunchCall, RelaunchReply, RelaunchStep};

const WAIT: Duration = Duration::from_secs(5);
const MAX_REPLY: u64 = 256 * 1024;

pub(super) fn pending(arguments: &[String]) -> i32 {
    match ask(arguments, RelaunchStep::Pending) {
        Ok(RelaunchReply::Waiting) => 0,
        _ => 1,
    }
}

pub(super) fn relaunch(arguments: &[String]) -> i32 {
    let error = match ask(arguments, RelaunchStep::Take) {
        Ok(RelaunchReply::Launch {
            args,
            display,
            notice,
        }) => {
            if let Some(notice) = notice {
                eprintln!("{notice}");
            }
            if display {
                return super::claude_display::main(&args);
            }
            std::process::Command::new("claude").args(args).exec()
        }
        Ok(_) => return 1,
        Err(error) => error,
    };
    eprintln!(
        "{}",
        super::launch_failure::describe("Claude Code", "claude", &error)
    );
    1
}

fn ask(arguments: &[String], step: RelaunchStep) -> io::Result<RelaunchReply> {
    let [launch] = arguments else {
        return Err(io::Error::other("expected one launch id"));
    };
    let env = |name| brand::var(name).ok_or_else(|| io::Error::other("missing pane environment"));
    let call = RelaunchCall {
        claude_relaunch: step,
        token: env("TOKEN")?,
        pane: proto::PaneId(env("PANE_ID")?.parse().map_err(io::Error::other)?),
        launch: launch.clone(),
    };
    let socket = brand::var("ENDPOINT_FILE")
        .and_then(|path| std::fs::read_to_string(path).ok())
        .map(|path| PathBuf::from(path.trim()))
        .or_else(|| brand::var("SOCK").map(PathBuf::from))
        .ok_or_else(|| io::Error::other("no hook endpoint"))?;
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(WAIT))?;
    stream.set_write_timeout(Some(WAIT))?;
    let mut request = serde_json::to_vec(&call)?;
    request.push(b'\n');
    stream.write_all(&request)?;
    let mut answer = String::new();
    BufReader::new(io::Read::take(stream, MAX_REPLY)).read_line(&mut answer)?;
    Ok(serde_json::from_str(&answer)?)
}
