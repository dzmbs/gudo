//! `agent-typed <program> <args>…`: the shell function around a typed agent asks the daemon to
//! start it as one it launches. Prints the launch to run and exits 0, or exits 1 and the
//! function runs the program as typed.

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use daemon::typed_agent::{TypedAgent, TypedAgentCall, TypedAgentReply};

/// Past this the agent starts as typed: a busy or gone daemon must not hold the prompt up.
const WAIT: Duration = Duration::from_secs(2);
const MAX_REPLY: u64 = 4096;

pub(super) fn main(arguments: &[String]) -> i32 {
    match ask(arguments) {
        Ok(TypedAgentReply::Launch { launch }) => {
            println!("{launch}");
            0
        }
        Ok(TypedAgentReply::Declined) | Err(_) => 1,
    }
}

fn ask(arguments: &[String]) -> io::Result<TypedAgentReply> {
    let (program, args) = arguments
        .split_first()
        .ok_or_else(|| io::Error::other("expected the program"))?;
    let env = |name| brand::var(name).ok_or_else(|| io::Error::other("missing pane environment"));
    let call = TypedAgentCall {
        typed_agent: TypedAgent {
            program: program.clone(),
            args: args.to_vec(),
            cwd: std::env::current_dir()?,
        },
        token: env("TOKEN")?,
        pane: proto::PaneId(env("PANE_ID")?.parse().map_err(io::Error::other)?),
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
