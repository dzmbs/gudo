//! Knock to join: with an invite whose owner wants to be asked first, the
//! guest dials the daemon, waits in the lobby while an owner decides, and on admission gets a
//! grant of its own to join with. A one-shot connection like [`crate::push::send_action`]:
//! nothing is attached or streamed while waiting.

use std::time::Duration;

use iroh::endpoint::Connection;
use proto::{
    Caps, ClientCtl, Hello, Invite, KnockAnswer, KnockId, LinkClass, MpRequest, ServerCtl,
    SignedGrant, Ticket,
};

use crate::conn::{Route, connect_daemon, endpoint_builder, recv, send, ticket_addr};
use crate::{ClientConfig, ConnectOptions};

/// How often the waiting connection pings, so idle timeouts and NATs keep it open.
const KEEPALIVE: Duration = Duration::from_secs(10);

/// How a knock ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KnockOutcome {
    /// Let in. Join with this invite: the same host, with a grant bound to this device.
    Admitted(Invite),
    /// Turned away (or the invite was revoked while waiting).
    Denied,
}

/// Why knocking failed.
#[derive(Debug, thiserror::Error)]
pub enum KnockError {
    /// The invite does not parse, or the key is bad.
    #[error(transparent)]
    Client(#[from] crate::ClientError),
    /// The daemon could not be reached, or the connection dropped while waiting.
    #[error("cannot reach the host: {0}")]
    Unreachable(String),
    /// The daemon refused the invite outright (expired, revoked, too many waiting).
    #[error("refused: {0:?}")]
    Refused(proto::RefuseReason),
}

/// Knocks with `invite` and waits until an owner answers. `name` is shown to the owner;
/// `on_waiting` runs once the owner has been asked. Waits as long as it takes: drop the future
/// to stop waiting (the owner's request then goes away).
///
/// An invite that is not a knock invite (or was already answered for this device) is
/// [`KnockOutcome::Admitted`] at once with the invite unchanged.
///
/// # Errors
///
/// [`KnockError`].
pub async fn knock(
    invite: &str,
    config: ClientConfig,
    options: ConnectOptions,
    name: Option<String>,
    on_waiting: impl FnOnce(KnockId),
) -> Result<KnockOutcome, KnockError> {
    let invite: Invite = invite.parse().map_err(crate::ClientError::from)?;
    let key: [u8; 32] = config
        .secret_key
        .as_slice()
        .try_into()
        .map_err(|_| crate::ClientError::Key)?;
    let secret = iroh::SecretKey::from_bytes(&key);
    let device = proto::DeviceId(*secret.public().as_bytes());
    let unreachable = |err: &dyn std::fmt::Display| KnockError::Unreachable(err.to_string());
    // Invites carry no relay extras: the daemon's home relay, unless this device's own
    // network settings say otherwise.
    let route = Route::new(config.relay, &proto::TicketRelays::default(), &options);
    let endpoint = endpoint_builder(&route, &options)
        .map_err(|err| unreachable(&err))?
        .secret_key(secret)
        .bind()
        .await
        .map_err(|err| unreachable(&err))?;
    let ticket = Ticket {
        v: Ticket::VERSION,
        daemon_id: invite.daemon_id,
        addrs: invite.addrs.clone(),
        relay_url: invite.relay_url.clone(),
        principal: grants::guest_principal(device),
        secret: proto::PairingSecret([0; 16]),
        expires: proto::UnixMillis(0),
    };
    let result = async {
        let daemon_addr = ticket_addr(&ticket, &route).map_err(|err| unreachable(&err))?;
        let connection = connect_daemon(&endpoint, daemon_addr)
            .await
            .map_err(|err| unreachable(&err))?;
        // Dropping the future (the user stopped waiting) hangs up at once, so the owner's
        // request goes away now rather than after an idle timeout.
        let hangup = Hangup {
            connection,
            endpoint: endpoint.clone(),
        };
        wait(&hangup.connection, &invite, device, name, on_waiting).await
    }
    .await;
    endpoint.close().await;
    result
}

/// Hangs up when dropped: closes the connection and lets the endpoint send the close before
/// it goes away (on the runtime, since `Drop` cannot wait).
struct Hangup {
    connection: Connection,
    endpoint: iroh::Endpoint,
}

impl Drop for Hangup {
    fn drop(&mut self) {
        self.connection.close(0u32.into(), b"done");
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let endpoint = self.endpoint.clone();
            runtime.spawn(async move { endpoint.close().await });
        }
    }
}

async fn wait(
    connection: &Connection,
    invite: &Invite,
    device: proto::DeviceId,
    name: Option<String>,
    on_waiting: impl FnOnce(KnockId),
) -> Result<KnockOutcome, KnockError> {
    let unreachable = |err: &dyn std::fmt::Display| KnockError::Unreachable(err.to_string());
    let (mut send_stream, mut recv_stream) = connection
        .open_bi()
        .await
        .map_err(|err| unreachable(&err))?;
    let hello = Hello {
        device_id: device,
        principal_id: grants::guest_principal(device),
        grant: SignedGrant {
            v: SignedGrant::CHAIN,
            grant_id: invite.chain.grant_id(),
            token: invite.chain.to_token(),
        },
        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
        resume: Vec::new(),
        caps: Caps::KNOCK | Caps::DAEMON_INFO,
        link: LinkClass::Constrained,
        resume_token: None,
    };
    send(&mut send_stream, &ClientCtl::Hello(hello))
        .await
        .map_err(|err| unreachable(&err))?;
    // Who is knocking, before the owner is asked (the daemon waits a moment for it).
    if let Some(name) = name.as_ref().filter(|name| !name.trim().is_empty()) {
        let request = MpRequest::SetName { name: name.clone() };
        send(
            &mut send_stream,
            &ClientCtl::Multiplayer {
                req_id: 1,
                req: request,
            },
        )
        .await
        .map_err(|err| unreachable(&err))?;
    }
    let mut on_waiting = Some(on_waiting);
    let mut keepalive = tokio::time::interval(KEEPALIVE);
    keepalive.tick().await;
    let mut nonce = 0;
    loop {
        let message = tokio::select! {
            message = recv::<ServerCtl>(&mut recv_stream) => message.map_err(|err| unreachable(&err))?,
            _ = keepalive.tick() => {
                nonce += 1;
                send(&mut send_stream, &ClientCtl::Ping { nonce }).await.map_err(|err| unreachable(&err))?;
                continue;
            }
        };
        match message {
            Some(ServerCtl::KnockAnswer(KnockAnswer::Waiting { knock_id })) => {
                if let Some(on_waiting) = on_waiting.take() {
                    on_waiting(knock_id);
                }
            }
            Some(ServerCtl::KnockAnswer(KnockAnswer::Admitted(chain))) => {
                return Ok(KnockOutcome::Admitted(Invite {
                    chain,
                    ..invite.clone()
                }));
            }
            Some(ServerCtl::KnockAnswer(KnockAnswer::Denied)) => return Ok(KnockOutcome::Denied),
            // Not a knock invite after all: it joins as it is.
            Some(ServerCtl::Welcome(_)) => {
                let _ = send(
                    &mut send_stream,
                    &ClientCtl::Bye {
                        reason: proto::ByeReason::Quit,
                    },
                )
                .await;
                return Ok(KnockOutcome::Admitted(invite.clone()));
            }
            Some(ServerCtl::Refused { reason }) => return Err(KnockError::Refused(reason)),
            Some(_) => {}
            None => return Err(KnockError::Unreachable("the host hung up".into())),
        }
    }
}
