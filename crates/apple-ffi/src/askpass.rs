//! Native password prompts on [`DaemonClient`] (docs/DAEMON.md §9): a program in a pane asks
//! for a secret through the daemon's askpass helper (`sudo -A`, `ssh`, `git` over HTTPS), or
//! prints a password prompt with echo off.
//!
//! Connect with `ConnectOptions.askpass = true` to receive them. Pushes go to an
//! [`AskpassListener`]; the open prompts are also kept ([`DaemonClient::open_askpass`],
//! [`DaemonClient::detected_prompt`]). Secrets cross as `String` and are zeroed on the Rust
//! side once sent; the daemon never logs or stores them.

use std::sync::Arc;

use client_core::proto;

use crate::art_types::mirror_enum;
use crate::client::DaemonClient;
use crate::on_runtime;

/// Why an askpass request failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum AskpassError {
    /// The prompt closed first: answered elsewhere, cancelled, timed out or abandoned.
    #[error("the prompt is no longer open")]
    Gone,
    /// The connection's roles or scope do not allow it.
    #[error("not allowed: {message}")]
    Denied { message: String },
    /// The pane does not exist or is outside the grant's scope.
    #[error("no such pane")]
    UnknownPane,
    /// The pane echoes input now; nothing was typed.
    #[error("the pane is not at a hidden-input prompt")]
    NotHidden,
    #[error("{message}")]
    Failed { message: String },
    /// The connection dropped before the daemon answered.
    #[error("disconnected before the daemon answered")]
    Disconnected,
}

impl From<proto::AskpassError> for AskpassError {
    fn from(askpass_error: proto::AskpassError) -> Self {
        use proto::AskpassError as E;
        match askpass_error {
            E::Gone => Self::Gone,
            E::Denied(message) => Self::Denied { message },
            E::UnknownPane => Self::UnknownPane,
            E::NotHidden => Self::NotHidden,
            E::Failed(message) => Self::Failed { message },
            E::Disconnected => Self::Disconnected,
        }
    }
}

mirror_enum! {
    /// The kind of program asking.
    SecretSource = SecretSource {
        /// `sudo -A`.
        Sudo,
        /// `ssh`, `scp`, `sftp`, `ssh-add`.
        Ssh,
        /// `git` and its remote helpers.
        Git,
        /// `gpg`.
        Gpg,
        Other,
    }
}

/// A program in a pane asks for a secret.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SecretPrompt {
    /// Answer with this id.
    pub id: u64,
    /// The pane the program runs in.
    pub pane_id: u64,
    /// What kind of program asks.
    pub source: SecretSource,
    /// The program's prompt, cleaned of control and bidi characters.
    pub prompt: String,
    /// The asking program's command line (reported by the host, not verified); may be empty.
    pub program: String,
    /// The answer is not secret (a yes/no question): show it while typed.
    pub echo: bool,
    /// The same question came right after an answer: the last answer was probably wrong.
    pub retry: bool,
    /// When the daemon stops waiting (Unix ms).
    pub expires_at_ms: u64,
    /// The guest who held the pane's lease when the program asked (they may have typed the
    /// command): "Asked while <guest> is driving".
    #[uniffi(default = None)]
    pub guest_driving: Option<String>,
}

impl From<proto::SecretPrompt> for SecretPrompt {
    fn from(secret_prompt: proto::SecretPrompt) -> Self {
        Self {
            id: secret_prompt.id.0,
            pane_id: secret_prompt.pane_id.0,
            source: secret_prompt.source.into(),
            prompt: secret_prompt.prompt,
            program: secret_prompt.program,
            echo: secret_prompt.echo,
            retry: secret_prompt.retry,
            expires_at_ms: secret_prompt.expires_at.0,
            guest_driving: None,
        }
    }
}

fn driven(prompt: proto::SecretPrompt, guest: Option<String>) -> SecretPrompt {
    SecretPrompt {
        guest_driving: guest,
        ..prompt.into()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AskpassCloseReason {
    /// Someone answered it (`by` is their principal id, 16 bytes hex).
    Answered { by: String },
    /// Someone cancelled it (empty `by`: the daemon).
    Cancelled { by: String },
    /// Nobody answered in time.
    TimedOut,
    /// The program went away.
    Abandoned,
    /// Nobody could answer in the app any more; the terminal asks instead.
    MovedToTerminal,
}

fn hex(principal: proto::PrincipalId) -> String {
    principal.0.iter().map(|b| format!("{b:02x}")).collect()
}

impl From<proto::CloseReason> for AskpassCloseReason {
    fn from(close_reason: proto::CloseReason) -> Self {
        use proto::CloseReason as R;
        match close_reason {
            R::Answered { by } => Self::Answered { by: hex(by) },
            R::Cancelled { by } => Self::Cancelled {
                by: by.map(hex).unwrap_or_default(),
            },
            R::TimedOut => Self::TimedOut,
            R::Abandoned => Self::Abandoned,
            R::MovedToTerminal => Self::MovedToTerminal,
        }
    }
}

/// A password prompt a program printed itself, with echo off.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DetectedPrompt {
    pub pane_id: u64,
    pub prompt: String,
    /// Output offset at which it was seen.
    pub at_seq: u64,
}

impl From<proto::DetectedPrompt> for DetectedPrompt {
    fn from(detected_prompt: proto::DetectedPrompt) -> Self {
        Self {
            pane_id: detected_prompt.pane_id.0,
            prompt: detected_prompt.prompt,
            at_seq: detected_prompt.at_seq.0,
        }
    }
}

/// A change in a pane's password prompts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AskpassEvent {
    /// A program asks for a secret: show the secure prompt.
    Prompt { prompt: SecretPrompt },
    /// A prompt is over: close its sheet.
    Closed {
        id: u64,
        pane_id: u64,
        reason: AskpassCloseReason,
    },
    /// The pane shows a password prompt with echo off: offer "Enter password securely".
    Detected { prompt: DetectedPrompt },
    /// The detected prompt is gone.
    DetectedGone { pane_id: u64 },
    /// The connection dropped: forget every prompt. Prompts still open come again with the
    /// same ids after reconnecting.
    Reset,
}

impl From<client_core::AskpassEvent> for AskpassEvent {
    fn from(askpass_event: client_core::AskpassEvent) -> Self {
        use client_core::AskpassEvent as E;
        match askpass_event {
            E::Prompt(secret_prompt) => Self::Prompt {
                prompt: secret_prompt.into(),
            },
            E::PromptWhileGuestDrives { prompt, guest } => Self::Prompt {
                prompt: driven(prompt, Some(guest)),
            },
            E::Closed {
                id,
                pane_id,
                reason,
            } => Self::Closed {
                id: id.0,
                pane_id: pane_id.0,
                reason: reason.into(),
            },
            E::Detected(detected) => Self::Detected {
                prompt: detected.into(),
            },
            E::DetectedGone { pane_id } => Self::DetectedGone { pane_id: pane_id.0 },
            E::Reset => Self::Reset,
        }
    }
}

/// Receives [`AskpassEvent`]s; implemented in Swift.
///
/// Called on a runtime thread, in order, one at a time per client. Return quickly.
#[uniffi::export(foreign)]
pub trait AskpassListener: Send + Sync {
    fn on_askpass_event(&self, event: AskpassEvent);
}

struct AskpassForward(Arc<dyn AskpassListener>);

impl client_core::AskpassListener for AskpassForward {
    fn on_askpass_event(&self, event: client_core::AskpassEvent) {
        self.0.on_askpass_event(event.into());
    }
}

/// Moves `secret` into a [`proto::Secret`], zeroing the string's buffer.
fn take_secret(mut secret: String) -> proto::Secret {
    let out = proto::Secret::new(secret.as_bytes().to_vec());
    zeroize::Zeroize::zeroize(&mut secret);
    out
}

/// Whether a terminal line looks like a password prompt (the daemon's rule), for clients
/// that check their own screen.
#[uniffi::export]
pub fn looks_like_password_prompt(line: String) -> bool {
    proto::looks_like_password_prompt(&line)
}

#[uniffi::export]
impl DaemonClient {
    /// Sets the receiver of [`AskpassEvent`]s, replacing any previous one.
    pub fn set_askpass_listener(&self, listener: Arc<dyn AskpassListener>) {
        self.inner
            .set_askpass_listener(Arc::new(AskpassForward(listener)));
    }

    /// The prompts open now, oldest first (no round trip).
    pub fn open_askpass(&self) -> Vec<SecretPrompt> {
        self.inner
            .open_askpass()
            .into_iter()
            .map(|prompt| {
                let guest = self.inner.askpass_guest(prompt.id);
                driven(prompt, guest)
            })
            .collect()
    }

    /// The password prompt a pane shows with echo off, if any (no round trip).
    pub fn detected_prompt(&self, pane_id: u64) -> Option<DetectedPrompt> {
        self.inner
            .detected_prompt(proto::PaneId(pane_id))
            .map(Into::into)
    }

    /// Answers prompt `id`. The first answer from any device wins.
    ///
    /// # Errors
    ///
    /// [`AskpassError::Gone`] if it closed first, [`AskpassError::Denied`] without Driver.
    pub async fn answer_askpass(&self, id: u64, secret: String) -> Result<(), AskpassError> {
        let secret = take_secret(secret);
        let core = self.core();
        on_runtime(async move { core.answer_askpass(proto::AskpassId(id), secret).await })
            .await
            .map_err(Into::into)
    }

    /// Declines prompt `id`: the program gets no answer.
    ///
    /// # Errors
    ///
    /// As [`answer_askpass`](Self::answer_askpass).
    pub async fn cancel_askpass(&self, id: u64) -> Result<(), AskpassError> {
        let core = self.core();
        on_runtime(async move { core.cancel_askpass(proto::AskpassId(id)).await })
            .await
            .map_err(Into::into)
    }

    /// Types `secret` and Return into a pane at a detected password prompt, only while its
    /// terminal hides input (never echoed, never in the shell's history).
    ///
    /// # Errors
    ///
    /// [`AskpassError::NotHidden`] (nothing typed) if the pane echoes input now.
    pub async fn type_secret(&self, pane_id: u64, secret: String) -> Result<(), AskpassError> {
        let secret = take_secret(secret);
        let core = self.core();
        on_runtime(async move { core.type_secret(proto::PaneId(pane_id), secret).await })
            .await
            .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_prompt_asked_while_a_guest_drives_names_them() {
        let prompt = proto::SecretPrompt {
            id: proto::AskpassId(1),
            pane_id: proto::PaneId(2),
            source: proto::SecretSource::Sudo,
            prompt: "Password:".into(),
            program: "sudo ls".into(),
            echo: false,
            retry: false,
            expires_at: proto::UnixMillis(0),
        };
        let driven = AskpassEvent::from(client_core::AskpassEvent::PromptWhileGuestDrives {
            prompt: prompt.clone(),
            guest: "bob".into(),
        });
        let AskpassEvent::Prompt { prompt: shown } = driven else {
            panic!("{driven:?}");
        };
        assert_eq!(shown.guest_driving.as_deref(), Some("bob"));
        let AskpassEvent::Prompt { prompt: plain } =
            AskpassEvent::from(client_core::AskpassEvent::Prompt(prompt))
        else {
            panic!();
        };
        assert_eq!(plain.guest_driving, None);
    }
}
