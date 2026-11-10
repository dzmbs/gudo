use super::super::Live;
use crate::core::lock;
#[cfg(test)]
mod tests;

use std::ffi::OsString;
use std::io;
use std::sync::Weak;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// The pane's launcher reports its environment as soon as the login shell hands over.
const LAUNCHER_CONNECT_WAIT: Duration = Duration::from_secs(120);
const ENVIRONMENT_WAIT: Duration = Duration::from_secs(10);
const MAX_ENVIRONMENT_VARIABLES: usize = 4096;
const ENVIRONMENT_VERSION: u8 = 1;
const NATIVE: u8 = 1;
const TERMINAL: u8 = 2;

pub(super) struct Peers {
    pub tui: u32,
    pub server: u32,
}

pub(super) enum Started {
    Native(Peers),
    Terminal,
}

pub(super) async fn start(
    listener: std::os::unix::net::UnixListener,
    spec: agents::LaunchSpec,
    expected: Vec<(String, OsString)>,
    fallback: agents::LaunchSpec,
    source: &Weak<Live>,
    owner: u32,
) -> io::Result<Started> {
    let listener = tokio::net::UnixListener::from_std(listener)?;
    let (mut connection, _) = tokio::time::timeout(LAUNCHER_CONNECT_WAIT, listener.accept())
        .await
        .map_err(io::Error::other)??;
    let tui = super::peer::pid(&connection)?;
    if !super::peer::in_tree(tui, owner).await {
        return Err(invalid());
    }
    let bytes = tokio::time::timeout(ENVIRONMENT_WAIT, receive(&mut connection))
        .await
        .map_err(io::Error::other)??;
    let environment = tokio::task::spawn_blocking(move || decode(&bytes, &expected))
        .await
        .map_err(io::Error::other)??;
    if environment.mode == agents::CodexPaneMode::Terminal {
        let plan = agents::CodexTerminalLaunch {
            arguments: fallback.args,
            env_remove: fallback.env_remove,
            env_pinned: fallback.env_pinned,
        };
        let bytes = serde_json::to_vec(&plan).map_err(io::Error::other)?;
        if bytes.len() > agents::CODEX_ENVIRONMENT_LIMIT {
            return Err(invalid());
        }
        let source = source.upgrade().ok_or_else(invalid)?;
        terminal(&source, tui)?;
        connection.write_all(&[TERMINAL]).await?;
        connection.write_u32(bytes.len() as u32).await?;
        connection.write_all(&bytes).await?;
        return Ok(Started::Terminal);
    }
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
    super::super::process::isolate(&mut command);
    let process = command.spawn()?;
    let server = process.id().ok_or_else(invalid)?;
    let source = source
        .upgrade()
        .ok_or_else(|| io::Error::other("pane closed"))?;
    *lock(&source.process) = Some(process);
    source.capture_context(cwd, tui);
    drop(source);
    connection.write_all(&[NATIVE]).await?;
    Ok(Started::Native(Peers { tui, server }))
}

fn terminal(source: &std::sync::Arc<Live>, tui: u32) -> io::Result<()> {
    let (core, entry) = source.target().ok_or_else(invalid)?;
    if lock(&source.process).is_some() || lock(&source.state).current.is_some() {
        return Err(invalid());
    }
    let mut installed = lock(&entry.codex);
    if !installed
        .as_ref()
        .is_some_and(|current| std::sync::Arc::ptr_eq(current, source))
    {
        return Err(invalid());
    }
    let mut runtime = crate::agent::AgentRuntime::new(
        proto::AgentKind::Codex,
        entry.pane.id,
        Box::new(agents::Codex::new()),
        true,
    );
    runtime.note_process(tui);
    *lock(&entry.agent) = Some(runtime);
    source
        .fault
        .store(true, std::sync::atomic::Ordering::Release);
    *installed = None;
    drop(installed);
    core.emit(crate::core::Event::PaneMeta(entry.pane.id));
    Ok(())
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
    if environment.version != ENVIRONMENT_VERSION
        || environment.variables.len() > MAX_ENVIRONMENT_VARIABLES
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
