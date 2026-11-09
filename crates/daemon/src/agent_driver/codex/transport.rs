mod bootstrap;
pub(super) mod control;
mod frames;
mod history;
mod peer;
mod rpc;
#[cfg(test)]
mod tests;

use super::{Live, State};
use crate::core::lock;
pub(super) use frames::Direction;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

type Observations = tokio::sync::mpsc::Sender<Observation>;

const OBSERVATION_QUEUE: usize = 64;
const CONTROL_QUEUE: usize = 8;
const RELAY_BUFFER_BYTES: usize = 16 * 1024;
/// A wedged observer gives up observation rather than holding Terminal bytes longer.
const OBSERVATION_STALL: Duration = Duration::from_secs(2);
const PROCESS_EXIT_WAIT: Duration = Duration::from_secs(2);
const SERVER_CONNECT_WAIT: Duration = Duration::from_secs(5);
const SERVER_CONNECT_RETRY: Duration = Duration::from_millis(20);

/// What the relay hands the observer, in the order it read it.
pub(in crate::agent_driver::codex) enum Observation {
    Bytes(Direction, Vec<u8>),
    HistoryReady,
    Closed,
}

impl Live {
    pub(crate) fn start(
        context: &agents::LaunchContext,
        mode: &agents::LaunchMode,
    ) -> io::Result<(Arc<Self>, agents::LaunchSpec)> {
        let directory = crate::fsutil::create_private_temp_dir("gudo-codex")?;
        match prepare(context, mode, &directory) {
            Ok(result) => Ok(result),
            Err(error) => {
                let _ = std::fs::remove_dir_all(directory);
                Err(error)
            }
        }
    }
}

fn listener(path: &Path) -> io::Result<std::os::unix::net::UnixListener> {
    let listener = std::os::unix::net::UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    Ok(listener)
}

fn prepare(
    context: &agents::LaunchContext,
    mode: &agents::LaunchMode,
    directory: &Path,
) -> io::Result<(Arc<Live>, agents::LaunchSpec)> {
    let server = directory.join("server.sock");
    let relay = directory.join("tui.sock");
    let environment = directory.join("environment.sock");
    let relay_listener = listener(&relay)?;
    let environment_listener = listener(&environment)?;
    let mut recipe =
        agents::Codex::live_launch(context, mode, &server, &relay).map_err(io::Error::other)?;
    recipe.tui.args.insert(0, environment.into_os_string());
    recipe.tui.args.insert(0, "codex-remote".into());
    recipe.tui.program = context.hook_bin.clone().into_os_string();
    let (owner, mut owner_ready) = tokio::sync::watch::channel(None);
    let (observations, receiver) = tokio::sync::mpsc::channel(OBSERVATION_QUEUE);
    let (controls, commands) = tokio::sync::mpsc::channel(CONTROL_QUEUE);
    let source = Arc::new(Live {
        owner,
        fault: std::sync::atomic::AtomicBool::new(false),
        state: Mutex::new(State::new()),
        runtime: Mutex::new(super::runtime::Runtime::default()),
        process: Mutex::new(None),
        task: Mutex::new(None),
        history_task: Mutex::new(None),
        controls: Mutex::new(Some(controls)),
        control_task: Mutex::new(None),
        history_result: Mutex::new(None),
        observations: Mutex::new(Some(observations.clone())),
        directory: directory.to_owned(),
    });
    let weak = Arc::downgrade(&source);
    let control = tokio::spawn(control::run(weak.clone(), commands));
    *lock(&source.control_task) = Some(control.abort_handle());
    let expected = agents::pane_env(context);
    let fallback = agents::AgentAdapter::launch(&agents::Codex::new(), context, mode);
    let observer = weak.clone();
    tokio::spawn(observe(observer, receiver));
    let task = tokio::spawn(async move {
        let result = async {
            let owner = owner_ready
                .wait_for(|owner| owner.is_some())
                .await
                .map_err(io::Error::other)?
                .clone();
            let started = bootstrap::start(
                environment_listener,
                recipe.server,
                expected,
                fallback,
                &weak,
                owner.ok_or_else(|| io::Error::other("pane closed"))?.root,
            )
            .await?;
            match started {
                bootstrap::Started::Native(peers) => {
                    run(relay_listener, server, weak.clone(), observations, peers).await
                }
                bootstrap::Started::Terminal => Ok(()),
            }
        }
        .await;
        if let Some(source) = weak.upgrade() {
            source.fault.store(true, Ordering::Release);
            lock(&source.state).fail();
            if let Some(sender) = lock(&source.observations).as_ref() {
                let _ = sender.try_send(Observation::Closed);
            }
            let process = lock(&source.process).take();
            if let Some(mut process) = process {
                let _ = tokio::time::timeout(PROCESS_EXIT_WAIT, process.kill()).await;
            }
            if let Err(error) = result {
                tracing::debug!(%error, "Codex live relay closed");
            }
        }
    });
    *lock(&source.task) = Some(task.abort_handle());
    Ok((source, recipe.tui))
}

async fn run(
    listener: std::os::unix::net::UnixListener,
    server: std::path::PathBuf,
    source: Weak<Live>,
    observations: Observations,
    peers: bootstrap::Peers,
) -> io::Result<()> {
    let listener = tokio::net::UnixListener::from_std(listener)?;
    let (tui, _) = listener.accept().await?;
    let native_tui = peer::in_tree(peer::pid(&tui)?, peers.tui).await;
    let upstream = tokio::time::timeout(SERVER_CONNECT_WAIT, async {
        loop {
            match tokio::net::UnixStream::connect(&server).await {
                Ok(stream) => return Ok::<_, io::Error>(stream),
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                    ) =>
                {
                    tokio::time::sleep(SERVER_CONNECT_RETRY).await;
                }
                Err(error) => return Err(error),
            }
        }
    })
    .await
    .map_err(io::Error::other)??;
    let native_server = peer::in_tree(peer::pid(&upstream)?, peers.server).await;
    if (!native_tui || !native_server)
        && let Some(source) = source.upgrade()
    {
        source.fault.store(true, Ordering::Release);
        lock(&source.state).fail();
    }
    std::fs::set_permissions(&server, std::fs::Permissions::from_mode(0o600))?;
    forward(tui, upstream, source, observations).await
}

pub(super) async fn forward(
    tui: tokio::net::UnixStream,
    upstream: tokio::net::UnixStream,
    source: Weak<Live>,
    observations: Observations,
) -> io::Result<()> {
    let (tui_reader, tui_writer) = tui.into_split();
    let (server_reader, server_writer) = upstream.into_split();
    let to_server = relay(
        tui_reader,
        server_writer,
        Direction::FromTui,
        &source,
        observations.clone(),
    );
    let to_tui = relay(
        server_reader,
        tui_writer,
        Direction::FromServer,
        &source,
        observations,
    );
    tokio::select! {
        result = to_server => result,
        result = to_tui => result,
    }
}

async fn relay(
    mut reader: impl AsyncRead + Unpin,
    mut writer: impl AsyncWrite + Unpin,
    direction: Direction,
    source: &Weak<Live>,
    observations: Observations,
) -> io::Result<()> {
    let mut buffer = vec![0u8; RELAY_BUFFER_BYTES];
    let mut tap = Some(observations);
    loop {
        let count = reader.read(&mut buffer).await?;
        if count == 0 {
            return Ok(());
        }
        if let Some(sender) = &tap
            && !observed(source, sender, direction, &buffer[..count]).await
        {
            tap = None;
        }
        writer.write_all(&buffer[..count]).await?;
    }
}

async fn observed(
    source: &Weak<Live>,
    sender: &Observations,
    direction: Direction,
    bytes: &[u8],
) -> bool {
    let Some(live) = source.upgrade() else {
        return false;
    };
    if live.fault.load(Ordering::Acquire) {
        return false;
    }
    drop(live);
    let observation = Observation::Bytes(direction, bytes.to_vec());
    if matches!(
        tokio::time::timeout(OBSERVATION_STALL, sender.send(observation)).await,
        Ok(Ok(()))
    ) {
        return true;
    }
    if let Some(live) = source.upgrade() {
        live.fault.store(true, Ordering::Release);
    }
    false
}

async fn observe(source: Weak<Live>, mut receiver: tokio::sync::mpsc::Receiver<Observation>) {
    let mut from_tui = frames::Decoder::new(Direction::FromTui);
    let mut from_server = frames::Decoder::new(Direction::FromServer);
    while let Some(observation) = receiver.recv().await {
        let Some(source) = source.upgrade() else {
            return;
        };
        let history = lock(&source.history_result).take();
        let (effects, closed) = {
            let mut state = lock(&source.state);
            if source.fault.load(Ordering::Acquire) {
                state.fail();
            } else if let Observation::Bytes(direction, bytes) = observation {
                let decoder = match direction {
                    Direction::FromTui => &mut from_tui,
                    Direction::FromServer => &mut from_server,
                };
                let fed = decoder.feed(&bytes, |observed| match observed {
                    frames::Observed::Text(frame) => state.observe(frame, direction),
                    frames::Observed::Skipped => state.skipped(direction),
                });
                if fed.is_err() {
                    state.fail();
                }
            }
            if !state.closed
                && !state.projection_lost
                && let Some((binding, result)) = history
                && state.binding.is_current(&binding)
                && result
                    .and_then(|frame| {
                        super::history::install(&mut state, &frame).map_err(io::Error::other)
                    })
                    .is_err()
            {
                state.lose_projection();
            }
            (std::mem::take(&mut state.effects), state.closed)
        };
        source.publish(effects);
        if closed {
            source.fault.store(true, Ordering::Release);
            return;
        }
    }
    if let Some(source) = source.upgrade() {
        source.fault.store(true, Ordering::Release);
        let effects = {
            let mut state = lock(&source.state);
            state.fail();
            std::mem::take(&mut state.effects)
        };
        source.publish(effects);
    }
}
