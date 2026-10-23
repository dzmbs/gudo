//! The Swift app's view of the Rust core (ARCHITECTURE D6): a UniFFI surface over
//! [`client_core`] (daemon connections) and [`ssh`] (plain SSH, bootstrap), built into
//! `UnnamedCore.xcframework` by `cargo xtask build-xcframework`. See docs/APPLE-FFI.md.
//!
//! - [`DaemonClient`]: dial a daemon by ticket; every client-core request; events through a
//!   Swift [`ClientEventListener`].
//! - [`SshSession`], [`SshPane`]: self-healing SSH and plain-SSH panes with the same events;
//!   [`SshSession::bootstrap`] installs the daemon and returns a ticket.
//! - [`SshConfigFile`], [`KnownHostsStore`], [`generate_ed25519_key`]: config, host keys
//!   and keys, with persistence left to the app.
//! - Drawings, images, Excalidraw scenes and inline placements (`artifacts.rs`, an
//!   [`ArtifactListener`]); input assistance for the mobile line editor (`assist.rs`, an
//!   [`AssistListener`]).
//! - [`inspect_pair_ticket`], [`install_log_sink`]: read a ticket offline; core logs to
//!   the app's logger.
//!
//! # Threading
//!
//! One multi-thread tokio runtime ([`runtime`]) runs everything: connections, SSH sessions,
//! panes. No exported function blocks: synchronous methods only queue work, and the
//! `async` ones await a task on that runtime, so Swift may call anything from the main
//! thread. Callbacks into Swift arrive on runtime threads (named `unnamed-core`), except
//! the SSH signer, keyboard-interactive and host-key callbacks, which arrive on the
//! runtime's blocking pool so they may wait for the user.
//!
//! Byte payloads cross as `Data` with bulk copies ([`Bytes`], not UniFFI's byte-by-byte
//! `Vec<u8>` converter), no serialization format. Input (`send_input`) is borrowed from Swift.

mod approvals;
mod art_types;
mod artifacts;
mod askpass;
mod assist;
mod browser;
mod bytes;
mod client;
mod editor;
mod extras;
mod mp;
mod mp2;
mod notify;
mod peer;
mod repo;
mod ssh_api;
mod types;
mod upgrade;
mod usage;
mod workflow;
mod workspace;
mod ws_types;

use std::sync::OnceLock;

use tokio::runtime::Runtime;

pub use approvals::{
    ApprovalError, ApprovalEvent, ApprovalInfo, ApprovalListener, ApprovalRuleMatch,
    AutoApproveRule, approval_like_this,
};
pub use art_types::*;
pub use artifacts::{
    ArtifactListener, DownloadedBlob, excalidraw_element, excalidraw_wins, pack_ink_points,
    render_ascii, render_excalidraw_ascii, render_png, render_svg, simplify_ink_points,
    sniff_image, unpack_ink_points,
};
pub use askpass::{
    AskpassCloseReason, AskpassError, AskpassEvent, AskpassListener, DetectedPrompt, SecretPrompt,
    SecretSource, looks_like_password_prompt,
};
pub use assist::{
    AssistError, AssistEvent, AssistListener, BlockedChoice, BlockedOption, BlockedPrompt,
    BlockedSource, Completion, CompletionKind, Completions, FileMatch, FileMatches, Foreground,
    HistoryEntry, HistoryQuery, InputDoubt, Keymap, PaneAssist, ProgramProfile, PromptInput,
    PromptPhase, PromptState, ShellKind, classify_program,
};
pub use bytes::Bytes;
pub use client::{
    ClientConfig, ClientError, ClientEvent, ClientEventListener, ClientStats, ConnectOptions,
    DaemonClient, PaneBytesBench, RelayMode, bench_pane_bytes, generate_device_key,
};
pub use editor::{
    EditorSession, VsCodeSshHost, microsoft_privacy_url, vscode_license_url, vscode_remote_ssh_uri,
    vscode_server_license_url, vscode_ssh_authority, vscode_ssh_config_entry, vscode_tunnel_uri,
    vscode_tunnel_web_url,
};
pub use extras::{
    LogLevel, LogSink, PairTicketInfo, TicketRelays, inspect_pair_ticket, install_log_sink,
};
pub use mp::{
    Actor, ApprovalAudit, AuditKind, AuditPage, AuditRecord, CreatedInvite, CursorPos, Decided,
    DeviceInfo, DeviceKind, Grant, GrantInfo, InputRejectReason, InviteInfo, InviteOptions,
    JoinInfo, Lease, LeaseMode, LeaseOutcome, MultiplayerError, MultiplayerEvent,
    MultiplayerListener, Participant, Presence, PresenceState, RevokeResult, RevokeTarget, Role,
    Scope, inspect_invite,
};
pub use mp2::{
    ApprovalMode, ApprovalPolicy, ApprovalStatus, ApprovalVote, Knock, KnockError, KnockListener,
    KnockOutcome, KnockResult, Risk, knock_invite, risk_of_tool,
};
pub use notify::{
    ApnsEnvironment, PushActionError, PushActionOffer, PushCapKind, PushDecision, PushError,
    PushKind, PushNotification, PushSealKey, default_push_relay_url, generate_push_seal_key,
    open_push_notification, push_action_token, push_relay_register_body, push_seal_public_key,
    send_push_action, send_push_action_blocking,
};
pub use peer::{DeviceClass, Draft, DraftSource, Peer, PeerList, PeerViewport};
pub use repo::*;
pub use ssh_api::{
    BootstrapListener, BootstrapReport, BootstrapStep, EnvVar, GeneratedSshKey, HostKeyDelegate,
    HostKeyInfo, HostKeyPolicy, HostKeyStatus, HostPlatform, HostdBinaries, HostdBinary,
    InstallAction, InteractivePrompt, KnownHostsListener, KnownHostsStore, ServiceMode,
    SignerError, SshAuth, SshConfigFile, SshConnectionState, SshDestination, SshError,
    SshExecOutput, SshHostConfig, SshHostSpec, SshInteractiveResponder, SshKeyInfo, SshOptions,
    SshPane, SshPaneOptions, SshSession, SshSessionListener, SshSigner, SshTarget,
    default_ssh_options, generate_ed25519_key, inspect_private_key, parse_ssh_destination,
    private_key_is_encrypted,
};
pub use types::*;
pub use upgrade::{
    DaemonInfo, UpgradeError, UpgradeFailureCode, min_daemon_protocol, protocol_level,
};
pub use usage::{AgentUsage, AgentUsageReport, UsageSource, UsageWindow};
pub use workflow::*;
pub use workspace::{AgentLaunch, AgentLaunched, TransferProgress, WorkspaceListener};
pub use ws_types::*;

uniffi::setup_scaffolding!();

/// The one runtime the FFI layer owns, started on first use: two workers (the app's
/// network work is I/O-bound) plus tokio's blocking pool.
pub fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("unnamed-core")
            .enable_all()
            .build()
            .expect("the core runtime starts")
    })
}

/// Runs `future` on [`runtime`] and waits for it from whatever executor polls the caller
/// (Swift's, for exported `async` functions).
pub(crate) async fn on_runtime<F>(future: F) -> F::Output
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    match runtime().spawn(future).await {
        Ok(out) => out,
        Err(e) => std::panic::resume_unwind(e.into_panic()),
    }
}

/// The core's version (`CARGO_PKG_VERSION` of this crate), for diagnostics.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}
