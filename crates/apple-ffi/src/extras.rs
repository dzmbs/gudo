//! Small helpers the app needs around pairing and diagnostics: reading a ticket without
//! dialling it, and routing the core's `tracing` output to the app's logger (os_log).

use std::io;
use std::sync::{Arc, OnceLock};

use client_core::proto;
use tracing_subscriber::fmt::MakeWriter;

use crate::client::ClientError;

/// What a pairing ticket says, read without dialling (for a confirmation sheet, a host
/// name, or rejecting an expired ticket before the network round trip).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PairTicketInfo {
    /// The daemon's endpoint id, lowercase hex (64 characters). Stable across daemon
    /// restarts and upgrades: the app keys paired hosts by it.
    pub daemon_id: String,
    /// How the daemon wants to be dialled (from the ticket's relay extras, docs/RELAYS.md).
    pub relays: TicketRelays,
    /// Direct addresses the ticket carries (`ip:port`).
    pub addrs: Vec<String>,
    /// The daemon's home relay, if any.
    pub relay_url: Option<String>,
    /// When the daemon stops accepting the ticket's one-time secret (Unix ms). Paired
    /// devices keep dialling with the ticket afterwards; only first pairing needs it valid.
    pub expires_unix_ms: u64,
}

/// Which relays a daemon uses, as its pairing ticket says.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TicketRelays {
    /// The product's default relays.
    Default,
    /// Only the daemon's self-hosted `iroh-relay` servers (a private CA goes into
    /// `ConnectOptions.relay_ca_der`).
    Custom {
        urls: Vec<String>,
        /// The relays need the shared token the ticket carries (not shown).
        has_auth_token: bool,
    },
    /// No relays: direct addresses only (LAN, Tailscale, VPN).
    Disabled,
}

/// Reads a `gudo://pair/…` ticket (the scheme is the brand's; surrounding whitespace is
/// ignored).
///
/// # Errors
///
/// [`ClientError::Ticket`] if it does not parse.
#[uniffi::export]
pub fn inspect_pair_ticket(ticket: String) -> Result<PairTicketInfo, ClientError> {
    let (parsed, extras) =
        proto::Ticket::parse_with_extras(ticket.trim()).map_err(|e: proto::TicketError| {
            ClientError::Ticket {
                message: e.to_string(),
            }
        })?;
    Ok(PairTicketInfo {
        relays: match extras.relays {
            proto::TicketRelays::Default => TicketRelays::Default,
            proto::TicketRelays::Custom { urls, auth_token } => TicketRelays::Custom {
                urls,
                has_auth_token: auth_token.is_some(),
            },
            proto::TicketRelays::Disabled => TicketRelays::Disabled,
        },
        daemon_id: parsed
            .daemon_id
            .0
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
        addrs: parsed.addrs.iter().map(ToString::to_string).collect(),
        relay_url: parsed.relay_url,
        expires_unix_ms: parsed.expires.0,
    })
}

/// Severity of a core log line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevel {
    /// `tracing::Level::ERROR`.
    Error,
    /// `WARN`.
    Warn,
    /// `INFO`.
    Info,
    /// `DEBUG`.
    Debug,
    /// `TRACE`.
    Trace,
}

impl From<tracing::Level> for LogLevel {
    fn from(level: tracing::Level) -> Self {
        match level {
            tracing::Level::ERROR => Self::Error,
            tracing::Level::WARN => Self::Warn,
            tracing::Level::INFO => Self::Info,
            tracing::Level::DEBUG => Self::Debug,
            tracing::Level::TRACE => Self::Trace,
        }
    }
}

/// Receives the core's log lines; implemented in Swift (os_log). Called on whatever thread
/// logged, so it must be cheap and thread-safe.
#[uniffi::export(foreign)]
pub trait LogSink: Send + Sync {
    /// One formatted event (`target: message key=value…`), without a timestamp.
    fn log(&self, level: LogLevel, target: String, message: String);
}

/// Formats one event into a buffer and hands it to the sink when the event is complete.
struct LineWriter {
    sink: Arc<dyn LogSink>,
    level: LogLevel,
    target: String,
    buffer: Vec<u8>,
}

impl io::Write for LineWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.buffer.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for LineWriter {
    fn drop(&mut self) {
        let text = String::from_utf8_lossy(&self.buffer);
        let line = text.trim_end();
        if !line.is_empty() {
            self.sink.log(
                self.level,
                std::mem::take(&mut self.target),
                line.to_owned(),
            );
        }
    }
}

struct SinkWriter(Arc<dyn LogSink>);

impl<'a> MakeWriter<'a> for SinkWriter {
    type Writer = LineWriter;

    fn make_writer(&'a self) -> Self::Writer {
        LineWriter {
            sink: Arc::clone(&self.0),
            level: LogLevel::Info,
            target: String::new(),
            buffer: Vec::new(),
        }
    }

    fn make_writer_for(&'a self, meta: &tracing::Metadata<'_>) -> Self::Writer {
        LineWriter {
            sink: Arc::clone(&self.0),
            level: (*meta.level()).into(),
            target: meta.target().to_owned(),
            buffer: Vec::new(),
        }
    }
}

/// Routes the core's `tracing` events at or above `filter` (an `EnvFilter` directive such
/// as `info` or `client_core=debug,iroh=warn`) to `sink`. Only the first call installs the
/// subscriber; later calls return `false` and change nothing.
#[uniffi::export]
pub fn install_log_sink(sink: Arc<dyn LogSink>, filter: String) -> bool {
    static INSTALLED: OnceLock<()> = OnceLock::new();
    let mut installed = false;
    INSTALLED.get_or_init(|| {
        let filter = tracing_subscriber::EnvFilter::try_new(&filter)
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
        installed = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_writer(SinkWriter(sink))
            .with_ansi(false)
            .without_time()
            .with_level(false)
            .try_init()
            .is_ok();
    });
    installed
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    #[test]
    fn tickets_are_read_without_dialling() {
        let ticket = proto::Ticket {
            v: proto::Ticket::VERSION,
            daemon_id: proto::DaemonId([0xab; 32]),
            addrs: vec!["127.0.0.1:4433".parse().unwrap()],
            relay_url: Some("https://relay.example/".into()),
            principal: proto::PrincipalId([1; 16]),
            secret: proto::PairingSecret([2; 16]),
            expires: proto::UnixMillis(1_800_000_000_000),
        };
        let info = inspect_pair_ticket(format!("  {ticket}\n")).unwrap();
        assert_eq!(info.daemon_id, "ab".repeat(32));
        assert_eq!(info.addrs, ["127.0.0.1:4433"]);
        assert_eq!(info.relay_url.as_deref(), Some("https://relay.example/"));
        assert_eq!(info.expires_unix_ms, 1_800_000_000_000);
        assert_eq!(info.relays, TicketRelays::Default);
        let custom = ticket.to_string_with(&proto::TicketExtras {
            v: proto::TicketExtras::VERSION,
            relays: proto::TicketRelays::Custom {
                urls: vec!["https://relay.example.com".into()],
                auth_token: Some("secret".into()),
            },
        });
        assert_eq!(
            inspect_pair_ticket(custom).unwrap().relays,
            TicketRelays::Custom {
                urls: vec!["https://relay.example.com".into()],
                has_auth_token: true,
            }
        );
        assert!(matches!(
            inspect_pair_ticket("gudo://pair/nope".into()),
            Err(ClientError::Ticket { .. })
        ));
    }

    #[derive(Default)]
    struct Collect(Mutex<Vec<(LogLevel, String, String)>>);

    impl LogSink for Collect {
        fn log(&self, level: LogLevel, target: String, message: String) {
            self.0.lock().unwrap().push((level, target, message));
        }
    }

    #[test]
    fn log_lines_reach_the_sink_once_installed() {
        let sink = Arc::new(Collect::default());
        assert!(install_log_sink(sink.clone(), "info".into()));
        assert!(!install_log_sink(sink.clone(), "debug".into()));
        tracing::warn!(peer = 7, "dial failed");
        tracing::debug!("filtered out");
        let lines = sink.0.lock().unwrap().clone();
        assert_eq!(lines.len(), 1, "{lines:?}");
        let (level, target, message) = &lines[0];
        assert_eq!(*level, LogLevel::Warn);
        assert!(target.contains("extras"), "{target}");
        assert!(
            message.contains("dial failed") && message.contains("peer=7"),
            "{message}"
        );
    }
}
