use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::time::Duration;

pub(super) fn main(arguments: &[String]) -> i32 {
    if run(arguments).is_err() {
        eprintln!(
            "Codex Chat could not start with this pane environment. No conversation was started."
        );
    }
    1
}

fn run(arguments: &[String]) -> io::Result<()> {
    let Some(socket) = arguments.first() else {
        return Err(io::Error::other("missing launch socket"));
    };
    let mut connection = UnixStream::connect(socket)?;
    connection.set_read_timeout(Some(Duration::from_secs(10)))?;
    connection.set_write_timeout(Some(Duration::from_secs(10)))?;
    if Command::new("codex").arg("--version").output()?.stdout != b"codex-cli 0.166.0\n" {
        return Err(io::Error::other("unsupported Codex version"));
    }
    let environment = agents::CodexPaneEnvironment {
        version: 1,
        variables: std::env::vars_os().collect(),
        cwd: std::env::current_dir()?,
    };
    let bytes = serde_json::to_vec(&environment).map_err(io::Error::other)?;
    if bytes.len() > agents::CODEX_ENVIRONMENT_LIMIT {
        return Err(io::Error::other("environment too large"));
    }
    connection.write_all(&(bytes.len() as u32).to_be_bytes())?;
    connection.write_all(&bytes)?;
    let mut ack = [0];
    connection.read_exact(&mut ack)?;
    if ack != [1] {
        return Err(io::Error::other("launch refused"));
    }
    drop(connection);
    let error = Command::new("codex").args(&arguments[1..]).exec();
    Err(error)
}
