//! daemon, delivered through the same [`ClientListener`] events as daemon panes, so the app
//! renders it with the same code.
//!
//! The pane's bytes form one continuous stream ([`ClientEvent::PaneBytes`] with a running
//! `seq`). The SSH [`Session`](ssh::Session) underneath redials on its own; after a drop the
//! pane opens a new shell and writes a dim "connection lost, new shell" line into the
//! [`SshPaneOptions::tmux_session`] the shell runs inside `tmux new -A`, so a reconnect
//! re-attaches the same session instead.
//!
//! Input typed while disconnected is dropped, not queued: a plain shell restarts on
//! reconnect, and replaying keystrokes into a different shell could run them somewhere
//! unexpected.

use std::sync::{Arc, OnceLock};

use proto::{PaneId, PaneSize};
use ssh::{ConnectionState, PtyRequest, ShellEvent};
use tokio::sync::mpsc;

use crate::{ClientEvent, ClientListener};

/// Line written into the stream when a dropped connection forced a new shell.
pub const RESTART_MARKER: &[u8] = b"\r\n\x1b[2m[connection lost \xe2\x80\x94 new shell]\x1b[0m\r\n";

/// Settings for an [`SshPane`].
#[derive(Debug, Clone)]
pub struct SshPaneOptions {
    /// The id events carry. Pick one that cannot clash with the host's daemon panes.
    pub pane_id: PaneId,
    /// Initial terminal size.
    pub size: PaneSize,
    /// `TERM` for the remote side.
    pub term: String,
    /// Environment to request (servers accept only their `AcceptEnv` names).
    pub env: Vec<(String, String)>,
    /// A command instead of the login shell.
    pub command: Option<String>,
    /// Run inside `tmux new -A -s <name>` when tmux exists on the host, so reconnects
    pub tmux_session: Option<String>,
}

impl SshPaneOptions {
    /// A login shell of `size` with `TERM=xterm-256color`.
    pub fn new(pane_id: PaneId, size: PaneSize) -> Self {
        Self {
            pane_id,
            size,
            term: "xterm-256color".into(),
            env: Vec::new(),
            command: None,
            tmux_session: None,
        }
    }

    fn pty_request(&self, size: PaneSize) -> PtyRequest {
        let command = match (&self.tmux_session, &self.command) {
            (Some(name), _) => Some(format!(
                "sh -c {}",
                ssh::shell_quote(&format!(
                    "command -v tmux >/dev/null 2>&1 && exec tmux new-session -A -s {} || exec \"${{SHELL:-/bin/sh}}\" -l",
                    ssh::shell_quote(name)
                ))
            )),
            (None, command) => command.clone(),
        };
        PtyRequest {
            term: self.term.clone(),
            cols: u32::from(size.cols),
            rows: u32::from(size.rows),
            env: self.env.clone(),
            command,
        }
    }
}

enum Command {
    Input(Vec<u8>),
    Resize(PaneSize),
    Close,
}

/// A terminal pane backed by a plain SSH PTY. Dropping it closes the remote shell.
pub struct SshPane {
    pane_id: PaneId,
    tx: mpsc::UnboundedSender<Command>,
}

/// A small shared runtime for SSH work driven from non-async code (the app, via FFI).
pub fn ssh_runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("client-ssh")
            .enable_all()
            .build()
            .expect("the SSH runtime starts")
    })
}

impl SshPane {
    /// Opens a pane on `session` (shared with other panes on the same host: one SSH
    /// connection, one channel per pane) and starts delivering events to `listener`.
    ///
    /// Must be called within a tokio runtime, or use [`ssh_runtime`]`().enter()`.
    pub fn open(
        session: ssh::Session,
        options: SshPaneOptions,
        listener: Arc<dyn ClientListener>,
    ) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        let pane_id = options.pane_id;
        tokio::spawn(drive(session, options, listener, rx));
        Self { pane_id, tx }
    }

    /// The pane's id.
    pub fn pane_id(&self) -> PaneId {
        self.pane_id
    }

    /// Sends keystrokes or paste. Dropped while disconnected.
    pub fn send_input(&self, data: Vec<u8>) {
        let _ = self.tx.send(Command::Input(data));
    }

    /// Resizes the remote PTY; a [`ClientEvent::PaneResized`] marks the point in the stream.
    pub fn resize(&self, size: PaneSize) {
        let _ = self.tx.send(Command::Resize(size));
    }

    /// Closes the remote shell; [`ClientEvent::PaneClosed`] follows.
    pub fn close(&self) {
        let _ = self.tx.send(Command::Close);
    }
}

impl Drop for SshPane {
    fn drop(&mut self) {
        let _ = self.tx.send(Command::Close);
    }
}

/// How one shell's life ended.
enum Ended {
    /// The user closed the pane, or the remote process exited.
    Closed,
    /// The connection died; reconnect and start again.
    Lost(String),
}

async fn drive(
    session: ssh::Session,
    options: SshPaneOptions,
    listener: Arc<dyn ClientListener>,
    mut rx: mpsc::UnboundedReceiver<Command>,
) {
    let pane_id = options.pane_id;
    let mut size = options.size;
    let mut seq: u64 = 0;
    let mut shells = 0u64;
    let mut states = session.subscribe();
    loop {
        let conn = tokio::select! {
            c = session.connected() => c,
            cmd = rx.recv() => match cmd {
                Some(Command::Resize(s)) => { size = s; continue; }
                Some(Command::Input(_)) => continue,
                Some(Command::Close) | None => break,
            },
        };
        let conn = match conn {
            Ok(conn) => conn,
            Err(ssh::SshError::Closed) => break,
            Err(e) => {
                listener.on_event(ClientEvent::Refused {
                    reason: e.to_string(),
                });
                // Wait for the user to fix it (`reconnect_now`) or to close the pane.
                tokio::select! {
                    _ = states.wait_for(|s| !matches!(s, ConnectionState::NeedsAttention { .. })) => continue,
                    cmd = rx.recv() => match cmd {
                        Some(Command::Close) | None => break,
                        _ => continue,
                    },
                }
            }
        };
        let (shell, mut output) = match conn.open_shell(&options.pty_request(size)).await {
            Ok(s) => s,
            Err(e) => {
                listener.on_event(ClientEvent::Disconnected {
                    reason: format!("opening the shell: {e}"),
                });
                // A refused shell on a live connection would loop; wait for the next one.
                tokio::select! {
                    _ = conn.closed() => {}
                    () = tokio::time::sleep(std::time::Duration::from_secs(2)) => {}
                }
                continue;
            }
        };
        shells += 1;
        listener.on_event(ClientEvent::Connected {
            epoch: shells,
            resumed: shells > 1,
        });
        if shells > 1 && options.tmux_session.is_none() {
            emit_bytes(&*listener, pane_id, &mut seq, RESTART_MARKER.to_vec());
        }

        let mut exited = false;
        let ended = loop {
            tokio::select! {
                event = output.next() => match event {
                    Some(ShellEvent::Data(data) | ShellEvent::Stderr(data)) => {
                        emit_bytes(&*listener, pane_id, &mut seq, data);
                    }
                    Some(ShellEvent::Exit { .. }) => exited = true,
                    None if exited || !conn.is_dead() => break Ended::Closed,
                    None => break Ended::Lost(conn.closed().await),
                },
                cmd = rx.recv() => match cmd {
                    Some(Command::Input(data)) => {
                        if let Err(e) = shell.write(&data).await {
                            tracing::debug!("ssh pane input lost: {e}");
                        }
                    }
                    Some(Command::Resize(s)) => {
                        size = s;
                        if shell
                            .resize(u32::from(s.cols), u32::from(s.rows))
                            .await
                            .is_ok()
                        {
                            listener.on_event(ClientEvent::PaneResized { pane_id, seq, size: s });
                        }
                    }
                    Some(Command::Close) | None => {
                        shell.close().await;
                        break Ended::Closed;
                    }
                },
            }
        };
        match ended {
            Ended::Closed => break,
            Ended::Lost(reason) => listener.on_event(ClientEvent::Disconnected { reason }),
        }
    }
    listener.on_event(ClientEvent::PaneClosed { pane_id });
}

fn emit_bytes(listener: &dyn ClientListener, pane_id: PaneId, seq: &mut u64, data: Vec<u8>) {
    let at = *seq;
    *seq += data.len() as u64;
    listener.on_event(ClientEvent::PaneBytes {
        pane_id,
        seq: at,
        data,
    });
}
