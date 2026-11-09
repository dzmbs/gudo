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
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, Weak};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

type Observations = tokio::sync::mpsc::Sender<(bool, Vec<u8>)>;

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
    let (observations, receiver) = tokio::sync::mpsc::channel(64);
    let (controls, commands) = tokio::sync::mpsc::channel(8);
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
    let observer = weak.clone();
    tokio::task::spawn_blocking(move || observe(observer, receiver));
    let task = tokio::spawn(async move {
        let result = async {
            let owner = owner_ready
                .wait_for(|owner| owner.is_some())
                .await
                .map_err(io::Error::other)?
                .clone();
            let peers = bootstrap::start(
                environment_listener,
                recipe.server,
                expected,
                &weak,
                owner.ok_or_else(|| io::Error::other("pane closed"))?.root,
            )
            .await?;
            run(relay_listener, server, weak.clone(), observations, peers).await
        }
        .await;
        if let Some(source) = weak.upgrade() {
            source.fault.store(true, Ordering::Release);
            lock(&source.state).fail();
            if let Some(sender) = lock(&source.observations).as_ref() {
                let _ = sender.try_send((false, Vec::new()));
            }
            let process = lock(&source.process).take();
            if let Some(mut process) = process {
                let _ =
                    tokio::time::timeout(std::time::Duration::from_secs(2), process.kill()).await;
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
    let upstream = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            match tokio::net::UnixStream::connect(&server).await {
                Ok(stream) => return Ok::<_, io::Error>(stream),
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                    ) =>
                {
                    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
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

async fn forward(
    mut tui: tokio::net::UnixStream,
    mut upstream: tokio::net::UnixStream,
    source: Weak<Live>,
    observations: Observations,
) -> io::Result<()> {
    let mut from_tui = [0u8; 16384];
    let mut from_server = [0u8; 16384];
    loop {
        tokio::select! {
            count = tui.read(&mut from_tui) => {
                let count = count?;
                if count == 0 { return Ok(()); }
                enqueue(&source, &observations, &from_tui[..count], true);
                upstream.write_all(&from_tui[..count]).await?;
            }
            count = upstream.read(&mut from_server) => {
                let count = count?;
                if count == 0 { return Ok(()); }
                enqueue(&source, &observations, &from_server[..count], false);
                tui.write_all(&from_server[..count]).await?;
            }
        }
    }
}

fn enqueue(source: &Weak<Live>, sender: &Observations, bytes: &[u8], outgoing: bool) {
    if let Some(source) = source.upgrade()
        && !source.fault.load(Ordering::Acquire)
        && sender.try_send((outgoing, bytes.to_vec())).is_err()
    {
        source.fault.store(true, Ordering::Release);
    }
}

fn observe(source: Weak<Live>, mut receiver: tokio::sync::mpsc::Receiver<(bool, Vec<u8>)>) {
    let mut outgoing = frames::Decoder::new(true);
    let mut incoming = frames::Decoder::new(false);
    while let Some((from_tui, bytes)) = receiver.blocking_recv() {
        let Some(source) = source.upgrade() else {
            return;
        };
        let history = lock(&source.history_result).take();
        let (effects, closed) = {
            let mut state = lock(&source.state);
            if source.fault.load(Ordering::Acquire) {
                state.fail();
            } else {
                let decoder = if from_tui {
                    &mut outgoing
                } else {
                    &mut incoming
                };
                if decoder
                    .feed(&bytes, |frame| state.observe(frame, from_tui))
                    .is_err()
                {
                    state.fail();
                }
            }
            if !state.closed
                && let Some((binding, result)) = history
                && state.binding.is_current(&binding)
                && result
                    .and_then(|frame| {
                        super::history::install(&mut state, &frame).map_err(io::Error::other)
                    })
                    .is_err()
            {
                state.fail();
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
