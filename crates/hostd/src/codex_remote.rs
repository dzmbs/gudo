use std::ffi::OsStr;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::time::Duration;

#[cfg(test)]
mod tests;

pub(super) fn main(arguments: &[String]) -> i32 {
    if run(arguments).is_err() {
        eprintln!(
            "Codex Chat could not start with this pane environment. No conversation was started."
        );
    }
    1
}

fn run(arguments: &[String]) -> io::Result<()> {
    let socket = arguments
        .first()
        .ok_or_else(|| io::Error::other("missing launch socket"))?;
    let mut connection = UnixStream::connect(socket)?;
    connection.set_read_timeout(Some(Duration::from_secs(10)))?;
    connection.set_write_timeout(Some(Duration::from_secs(10)))?;
    let mode = if supports_native(OsStr::new("codex"))? {
        agents::CodexPaneMode::Native
    } else {
        agents::CodexPaneMode::Terminal
    };
    let environment = agents::CodexPaneEnvironment {
        version: 1,
        mode,
        variables: std::env::vars_os().collect(),
        cwd: std::env::current_dir()?,
    };
    let bytes = serde_json::to_vec(&environment).map_err(io::Error::other)?;
    if bytes.len() > agents::CODEX_ENVIRONMENT_LIMIT {
        return Err(io::Error::other("environment too large"));
    }
    connection.write_all(&(bytes.len() as u32).to_be_bytes())?;
    connection.write_all(&bytes)?;
    let mut acknowledgement = [0];
    connection.read_exact(&mut acknowledgement)?;
    let mut command = Command::new("codex");
    match (mode, acknowledgement) {
        (agents::CodexPaneMode::Native, [1]) => {
            command.args(&arguments[1..]);
        }
        (agents::CodexPaneMode::Terminal, [2]) => {
            let mut length = [0; 4];
            connection.read_exact(&mut length)?;
            let length = u32::from_be_bytes(length) as usize;
            if length > agents::CODEX_ENVIRONMENT_LIMIT {
                return Err(io::Error::other("launch arguments too large"));
            }
            let mut bytes = vec![0; length];
            connection.read_exact(&mut bytes)?;
            let plan: agents::CodexTerminalLaunch =
                serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            apply_terminal(&mut command, plan);
            eprintln!("Codex Chat is unavailable for this version. Continuing in Terminal.");
        }
        _ => return Err(io::Error::other("launch refused")),
    }
    drop(connection);
    Err(command.exec())
}

fn apply_terminal(command: &mut Command, plan: agents::CodexTerminalLaunch) {
    // Named-account fences must also win over post-login shell changes on the legacy path.
    command.args(plan.arguments).envs(plan.env_pinned);
    for name in plan.env_remove {
        command.env_remove(name);
    }
}

fn supports_native(program: &OsStr) -> io::Result<bool> {
    Ok(super::cli_version::read(program)?.is_some_and(|bytes| bytes == b"codex-cli 0.166.0\n"))
}
