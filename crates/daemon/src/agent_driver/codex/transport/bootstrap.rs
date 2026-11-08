use super::super::Live;
use crate::core::lock;
#[cfg(test)]
mod tests;

use std::ffi::OsString;
use std::io;
use std::sync::Weak;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub(super) struct Peers {
    pub tui: u32,
    pub server: u32,
}

pub(super) async fn start(
    listener: std::os::unix::net::UnixListener,
    spec: agents::LaunchSpec,
    expected: Vec<(String, OsString)>,
    source: &Weak<Live>,
    owner: u32,
) -> io::Result<Peers> {
    let listener = tokio::net::UnixListener::from_std(listener)?;
    let (mut connection, _) = listener.accept().await?;
    let tui = super::peer::pid(&connection)?;
    if !super::peer::in_tree(tui, owner).await {
        return Err(invalid());
    }
    let bytes = tokio::time::timeout(std::time::Duration::from_secs(10), receive(&mut connection))
        .await
        .map_err(io::Error::other)??;
    let environment = tokio::task::spawn_blocking(move || decode(&bytes, &expected))
        .await
        .map_err(io::Error::other)??;
    let cwd = environment.cwd.clone();
    let mut command = tokio::process::Command::new(&spec.program);
    command
        .args(&spec.args)
        .env_clear()
        .envs(environment.variables)
        .envs(spec.env)
        .envs(spec.env_pinned)
        .current_dir(environment.cwd)
        .kill_on_drop(true)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    for name in spec.env_remove {
        command.env_remove(name);
    }
    let process = command.spawn()?;
    let server = process.id().ok_or_else(invalid)?;
    let source = source
        .upgrade()
        .ok_or_else(|| io::Error::other("pane closed"))?;
    *lock(&source.process) = Some(process);
    source.capture_context(cwd, tui);
    drop(source);
    connection.write_all(&[1]).await?;
    Ok(Peers { tui, server })
}

async fn receive(connection: &mut tokio::net::UnixStream) -> io::Result<Vec<u8>> {
    let length = connection.read_u32().await? as usize;
    if length > agents::CODEX_ENVIRONMENT_LIMIT {
        return Err(invalid());
    }
    let mut bytes = vec![0; length];
    connection.read_exact(&mut bytes).await?;
    Ok(bytes)
}

fn decode(
    bytes: &[u8],
    expected: &[(String, OsString)],
) -> io::Result<agents::CodexPaneEnvironment> {
    let environment: agents::CodexPaneEnvironment =
        serde_json::from_slice(bytes).map_err(|_| invalid())?;
    if environment.version != 1
        || environment.variables.len() > 4096
        || !environment.cwd.is_absolute()
    {
        return Err(invalid());
    }
    let mut names = std::collections::HashSet::new();
    if environment
        .variables
        .iter()
        .any(|(name, _)| !names.insert(name))
    {
        return Err(invalid());
    }
    for (name, value) in expected {
        if !environment
            .variables
            .iter()
            .any(|(key, actual)| key == name.as_str() && actual == value)
        {
            return Err(invalid());
        }
    }
    Ok(environment)
}

fn invalid() -> io::Error {
    io::Error::other("invalid Codex pane environment")
}
