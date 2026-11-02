//! The editor on [`DaemonClient`] (docs/DAEMON.md §5.3) and desktop VS Code links.
//!
//! **Default path, never a sign-in**: [`DaemonClient::open_editor`]
//! makes sure the host has Microsoft's `code` CLI (installing it from Microsoft's update
//! service only with the user's licence acceptance from the app), starts `code serve-web` on
//! the host's `127.0.0.1` with a random connection token, forwards a local port to it over
//! the direct iroh link, and returns the `http://localhost:<port>/?tkn=…&folder=…` URL for a
//! `WKWebView`. No GitHub or Microsoft account is involved.
//!
//! The app offers no editor choice. When Microsoft's CLI cannot be obtained (download blocked,
//! no build for the host's OS/arch/libc) or cannot run there, the same call falls back, with
//! no prompt, to VSCodium's Web Host (MIT, Open VSX extensions) and says so in
//! [`EditorSession::fallback_reason`].
//!
//! The VS Code Remote Tunnel (vscode.dev, device-code sign-in) is the opt-in fallback:
//! `vscode_tunnel_*`, with the device code pushed as `WorkspaceEvent.vsCodeTunnel`
//! (`TunnelState.needsLogin`).

use client_core::proto;

use crate::client::DaemonClient;
use crate::ws_types::{
    EditorChoice, EditorInstance, EditorKind, EditorLaunch, EditorList, EditorOpened,
    ForwardTarget, VsCodeTunnelOpen, VsCodeTunnelOpened, VsCodeTunnelStart, VsCodeTunnelStatus,
    WorkspaceError,
};

/// The editor running for a folder, reachable from this device.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorSession {
    /// Load this in a `WKWebView`: `http://localhost:<local_port>/?tkn=…&folder=…` (the
    /// server answers with the token cookie and a redirect).
    pub url: String,
    /// The forwarded local port (the host's port when it was free here, so the editor's
    /// own `localhost:<port>` URLs stay valid).
    pub local_port: u16,
    /// The server on the host (`instance.kind` says which editor it is).
    pub instance: EditorInstance,
    /// The `code` CLI was installed on the host by this call.
    pub installed_cli: bool,
    /// Set when VS Code could not be obtained or run on the host and VSCodium serves the
    /// folder instead: why (for a quiet note, not a prompt).
    #[uniffi(default = None)]
    pub fallback_reason: Option<String>,
}

/// `http://localhost:<port><path>`: a path the editor returned, on the forwarded port.
fn local_url(local_port: u16, url_path: &str) -> String {
    format!("http://localhost:{local_port}{url_path}")
}

fn error_message(error: &WorkspaceError) -> String {
    match error {
        WorkspaceError::Denied { message }
        | WorkspaceError::NotFound { message }
        | WorkspaceError::Conflict { message }
        | WorkspaceError::Invalid { message }
        | WorkspaceError::Unavailable { message }
        | WorkspaceError::Failed { message } => message.clone(),
        WorkspaceError::Disconnected => "disconnected".to_owned(),
    }
}

#[uniffi::export]
impl DaemonClient {
    /// The default editor flow: `code serve-web` on the host, a local forward, and the URL to
    /// load. Never asks for a GitHub or Microsoft sign-in. In Swift `openEditor(folder:)`
    /// (`acceptVscodeLicense` defaults to `false`).
    ///
    /// `accept_vscode_license`: the user accepted, in the app, the Visual Studio Code licence
    /// ([`vscode_license_url`], covers installing the `code` CLI) and the VS Code Server
    /// licence ([`vscode_server_license_url`], covers `serve-web`). Without it nothing of
    /// Microsoft's is installed or started. A server already running for the folder is
    /// reused, and so is an existing forward to it.
    ///
    /// With the licence accepted, when Microsoft's CLI cannot be obtained (download blocked,
    /// no build for the host) or `serve-web` cannot run there, this falls back automatically
    /// to VSCodium's Web Host (MIT, no licence prompt, no sign-in), which the host downloads
    /// from VSCodium's GitHub releases; [`EditorSession::fallback_reason`] says why.
    ///
    /// # Errors
    ///
    /// - `Unavailable` when the host has no `code` CLI and the licence was not accepted; the
    ///   message says what to do.
    /// - `Denied` when the licence was not accepted, or the grant is not the owner's.
    /// - `Failed` with both messages when VS Code and the VSCodium fallback both failed.
    /// - `Failed` if the local port cannot be bound.
    #[uniffi::method(default(accept_vscode_license = false))]
    pub async fn open_editor(
        &self,
        folder: String,
        accept_vscode_license: bool,
    ) -> Result<EditorSession, WorkspaceError> {
        self.open_editor_with(folder, accept_vscode_license, None)
            .await
    }
}

impl DaemonClient {
    /// [`open_editor`](Self::open_editor) with an explicit editor, for tests and internal
    /// use; the app offers no choice. `None` is the host's default with the automatic
    /// VSCodium fallback; `Some(kind)` launches exactly that editor (VSCodium: no licence,
    /// and the `code` CLI is never installed).
    ///
    /// # Errors
    ///
    /// As [`open_editor`](Self::open_editor).
    #[doc(hidden)]
    pub async fn open_editor_with(
        &self,
        folder: String,
        accept_vscode_license: bool,
        provider: Option<EditorKind>,
    ) -> Result<EditorSession, WorkspaceError> {
        let launch = EditorLaunch {
            folder,
            choice: provider.map_or(EditorChoice::Auto, |kind| EditorChoice::Only { kind }),
            accept_vscode_license,
        };
        let mut installed_cli = false;
        let vscode = match self.editor_launch(launch.clone()).await {
            Err(WorkspaceError::Unavailable { message }) if provider.is_none() => {
                if !accept_vscode_license {
                    return Err(WorkspaceError::Unavailable {
                        message: format!(
                            "the VS Code `code` CLI is not installed on the host. Accept the \
                             Visual Studio Code licence ({}) in the app to have the host \
                             download it from Microsoft, or install VS Code there ({message})",
                            proto::VSCODE_LICENSE_URL
                        ),
                    });
                }
                match self.vscode_cli_install(true).await {
                    Ok(_) => {
                        installed_cli = true;
                        self.editor_launch(launch.clone()).await
                    }
                    Err(e) => Err(e),
                }
            }
            other => other,
        };
        let mut fallback_reason = None;
        let instance = match vscode {
            Ok(instance) => instance,
            // Microsoft's CLI could not be obtained (no build for this host, download
            // blocked) or could not run: VSCodium, never a prompt. Not when the licence was
            // refused (`Denied`, or `Unavailable` without acceptance, returned above).
            Err(e @ (WorkspaceError::Unavailable { .. } | WorkspaceError::Failed { .. }))
                if provider.is_none() && accept_vscode_license =>
            {
                let reason = error_message(&e);
                let codium = EditorLaunch {
                    choice: EditorChoice::Only {
                        kind: EditorKind::Vscodium,
                    },
                    ..launch
                };
                match self.editor_launch(codium).await {
                    Ok(instance) => {
                        fallback_reason = Some(reason);
                        instance
                    }
                    Err(f) => {
                        return Err(WorkspaceError::Failed {
                            message: format!(
                                "VS Code: {reason}; the VSCodium fallback failed too: {}",
                                error_message(&f)
                            ),
                        });
                    }
                }
            }
            Err(e) => return Err(e),
        };
        let target = ForwardTarget::Tcp {
            port: instance.port,
        };
        let existing = self
            .forwards()
            .into_iter()
            .find(|forward| forward.target == target)
            .map(|forward| forward.local_port);
        let local_port = match existing {
            Some(port) => port,
            None => self
                .forward(instance.port, target.clone())
                .or_else(|_| self.forward(0, target))
                .map_err(|e| WorkspaceError::Failed {
                    message: e.to_string(),
                })?,
        };
        Ok(EditorSession {
            url: local_url(local_port, &instance.url_path),
            local_port,
            instance,
            installed_cli,
            fallback_reason,
        })
    }
}

#[uniffi::export]
impl DaemonClient {
    /// Closes what [`open_editor`](Self::open_editor) opened: the local forward, and the
    /// server on the host too if `stop_server`.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`] when stopping the server.
    pub async fn close_editor(
        &self,
        session: EditorSession,
        stop_server: bool,
    ) -> Result<(), WorkspaceError> {
        self.stop_forward(session.local_port);
        if stop_server {
            self.editor_stop(session.instance.folder).await?;
        }
        Ok(())
    }

    /// The URL that opens `path` at a line in an [`EditorSession`]'s editor, or `nil` when the
    /// file was opened in the window already showing (just show the editor).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn editor_open_in_session(
        &self,
        session: EditorSession,
        path: String,
        line: Option<u32>,
        column: Option<u32>,
    ) -> Result<Option<String>, WorkspaceError> {
        let opened = self
            .editor_open(Some(session.instance.folder), path, line, column)
            .await?;
        Ok((!opened.in_window).then(|| local_url(session.local_port, &opened.url_path)))
    }

    /// Editors the host can run, and the running ones. Without a `code` CLI on the host the
    /// VS Code entry has `installed: false`.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn editor_status(&self) -> Result<EditorList, WorkspaceError> {
        self.ws_call(|client| async move { client.editor_status().await })
            .await
    }

    /// Starts (or reuses) an editor server for a folder (owner only). Prefer
    /// [`open_editor`](Self::open_editor), which also forwards and builds the URL.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn editor_launch(
        &self,
        launch: EditorLaunch,
    ) -> Result<EditorInstance, WorkspaceError> {
        self.ws_call(|client| async move { client.editor_launch(launch.into()).await })
            .await
    }

    /// Stops the editor serving `folder`.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn editor_stop(&self, folder: String) -> Result<(), WorkspaceError> {
        self.ws_call(|client| async move { client.editor_stop(folder).await })
            .await
    }

    /// Opens `path` at a line in the running editor (`folder` `nil`: the editor whose folder
    /// contains it).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn editor_open(
        &self,
        folder: Option<String>,
        path: String,
        line: Option<u32>,
        column: Option<u32>,
    ) -> Result<EditorOpened, WorkspaceError> {
        self.ws_call(|client| async move { client.editor_open(folder, path, line, column).await })
            .await
    }

    /// The host's VS Code tunnel and `code` CLI.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn vscode_tunnel_status(&self) -> Result<VsCodeTunnelStatus, WorkspaceError> {
        self.ws_call(|client| async move { client.vscode_tunnel_status().await })
            .await
    }

    /// Has the host download Microsoft's `code` CLI from Microsoft (show
    /// [`vscode_license_url`] first; `accept_license` records the acceptance).
    ///
    /// # Errors
    ///
    /// `Denied` without the acceptance; the daemon's other [`WorkspaceError`]s.
    pub async fn vscode_cli_install(
        &self,
        accept_license: bool,
    ) -> Result<VsCodeTunnelStatus, WorkspaceError> {
        self.ws_call(|client| async move { client.vscode_cli_install(accept_license).await })
            .await
    }

    /// Starts (or adopts) the host's tunnel. **Needs a GitHub or Microsoft sign-in**: the
    /// device code arrives as `WorkspaceEvent.vsCodeTunnel` with `TunnelState.needsLogin`.
    /// Only on the user's explicit choice; [`open_editor`](Self::open_editor) is the default.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn vscode_tunnel_start(
        &self,
        start: VsCodeTunnelStart,
    ) -> Result<VsCodeTunnelStatus, WorkspaceError> {
        let start = proto::VsCodeTunnelStart {
            accept_server_license: start.accept_server_license,
            provider: start.provider.into(),
            name: start.name,
        };
        self.ws_call(|client| async move { client.vscode_tunnel_start(start).await })
            .await
    }

    /// Stops the tunnel the daemon runs.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn vscode_tunnel_stop(&self) -> Result<VsCodeTunnelStatus, WorkspaceError> {
        self.ws_call(|client| async move { client.vscode_tunnel_stop().await })
            .await
    }

    /// The vscode.dev URL and desktop URI for a folder or file through the running tunnel.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn vscode_tunnel_open(
        &self,
        open: VsCodeTunnelOpen,
    ) -> Result<VsCodeTunnelOpened, WorkspaceError> {
        let open = proto::VsCodeTunnelOpen {
            folder: open.folder,
            path: open.path,
            line: open.line,
            column: open.column,
        };
        self.ws_call(|client| async move { client.vscode_tunnel_open(open).await })
            .await
    }
}

/// A Remote - SSH host for desktop VS Code links.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VsCodeSshHost {
    /// Host name, address or `~/.ssh/config` alias.
    pub host: String,
    #[uniffi(default = None)]
    pub user: Option<String>,
    #[uniffi(default = None)]
    pub port: Option<u16>,
}

impl From<VsCodeSshHost> for client_core::vscode::SshHost {
    fn from(host_config: VsCodeSshHost) -> Self {
        Self {
            host: host_config.host,
            user: host_config.user,
            port: host_config.port,
        }
    }
}

/// The `ssh-remote+…` authority Remote - SSH uses for `host` (hex JSON for a user, port or
/// unusual name).
#[uniffi::export]
pub fn vscode_ssh_authority(host: VsCodeSshHost) -> String {
    client_core::vscode::ssh_authority(&host.into())
}

/// `vscode://vscode-remote/ssh-remote+…/<path>[:line[:col]]`: desktop VS Code with Remote -
/// SSH. For an iroh-only host, forward a local port to its sshd
/// (`forward(…, .tcp(port: 22))`) and use `VsCodeSshHost(host: "127.0.0.1", user:, port:)`.
#[uniffi::export]
pub fn vscode_remote_ssh_uri(
    host: VsCodeSshHost,
    path: String,
    line: Option<u32>,
    column: Option<u32>,
) -> String {
    client_core::vscode::remote_ssh_uri(&host.into(), &path, line, column)
}

/// `vscode://vscode-remote/tunnel+<name>/<path>[:line[:col]]`: desktop VS Code with Remote -
/// Tunnels.
#[uniffi::export]
pub fn vscode_tunnel_uri(
    name: String,
    path: String,
    line: Option<u32>,
    column: Option<u32>,
) -> String {
    client_core::vscode::tunnel_uri(&name, &path, line, column)
}

/// `https://vscode.dev/tunnel/<name>/<folder>`.
#[uniffi::export]
pub fn vscode_tunnel_web_url(name: String, folder: String) -> String {
    client_core::vscode::tunnel_web_url(&name, &folder)
}

/// An `~/.ssh/config` entry reaching the host's sshd through the daemon link (`gudo ssh-proxy`
/// as `ProxyCommand`).
#[uniffi::export]
pub fn vscode_ssh_config_entry(
    alias: String,
    user: String,
    gudo: String,
    ticket_arg: Option<String>,
) -> String {
    client_core::vscode::ssh_config_entry(&alias, &user, &gudo, ticket_arg.as_deref())
}

/// The Visual Studio Code licence (covers the `code` CLI); show it before
/// `open_editor(accept_vscode_license: true)` or `vscode_cli_install`.
#[uniffi::export]
pub fn vscode_license_url() -> String {
    proto::VSCODE_LICENSE_URL.to_owned()
}

/// The VS Code Server licence (covers `serve-web` and the tunnel).
#[uniffi::export]
pub fn vscode_server_license_url() -> String {
    proto::VSCODE_SERVER_LICENSE_URL.to_owned()
}

/// The Microsoft Privacy Statement, shown with the server licence.
#[uniffi::export]
pub fn microsoft_privacy_url() -> String {
    proto::MICROSOFT_PRIVACY_URL.to_owned()
}
