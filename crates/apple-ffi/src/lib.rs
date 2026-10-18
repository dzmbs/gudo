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

mod bytes;
mod client;
mod ssh_api;
mod types;

use std::sync::OnceLock;

use tokio::runtime::Runtime;

pub use bytes::Bytes;
pub use client::{
    ClientConfig, ClientError, ClientEvent, ClientEventListener, ClientStats, DaemonClient,
    PaneBytesBench, RelayMode, bench_pane_bytes, generate_device_key,
};
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
