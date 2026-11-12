//! The daemon on this computer (the Mac app's own helper) is reached over loopback alone, so the
//! app never needs the network to reach its own machine: the Wi-Fi address and the relay in
//! its ticket may be long gone.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use client_core::proto::{PaneId, TicketExtras, TicketRelays};
use client_core::{Client, ClientConfig, ClientEvent, ConnectOptions, EventQueue, RelayMode};
use tokio::sync::mpsc::UnboundedReceiver;

use super::next_matching;

/// A Wi-Fi address this computer had on another network (TEST-NET-1: never one of its own).
const GONE_WIFI_ADDRESS: IpAddr = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1));
/// A relay nothing answers on, as when the internet is down.
const UNREACHABLE_RELAY: &str = "https://127.0.0.1:1";

async fn helper(state: &std::path::Path) -> daemon::Daemon {
    let mut config = daemon::Config::new(state);
    config.bind = Some((Ipv4Addr::LOCALHOST, 0).into());
    config.relay = daemon::RelayMode::Disabled;
    config.shell = Some("/bin/sh".into());
    config.pane_env = vec![("PS1".into(), "$ ".into()), ("ENV".into(), String::new())];
    daemon::Daemon::start(config).await.unwrap()
}

/// The helper's ticket as the app saved it on another network: the helper's ports at the Wi-Fi
/// address it had there, and a relay that cannot be reached now.
fn ticket_from_another_network(helper: &daemon::Daemon) -> String {
    let mut ticket = helper.pairing_ticket(daemon::PAIRING_TTL).unwrap();
    ticket.addrs = helper
        .bound_sockets()
        .iter()
        .filter(|address| address.is_ipv4())
        .map(|address| SocketAddr::new(GONE_WIFI_ADDRESS, address.port()))
        .collect();
    ticket.relay_url = Some(UNREACHABLE_RELAY.into());
    ticket.to_string_with(&TicketExtras {
        v: TicketExtras::VERSION,
        relays: TicketRelays::Custom {
            urls: vec![UNREACHABLE_RELAY.into()],
            auth_token: None,
        },
    })
}

fn connect_this_computer(ticket: &str) -> (Client, UnboundedReceiver<ClientEvent>) {
    let (listener, events) = EventQueue::channel();
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Default;
    let options = ConnectOptions {
        this_computer: true,
        ..ConnectOptions::default()
    };
    let client = Client::connect_with(ticket, config, options, listener).unwrap();
    (client, events)
}

async fn first_pane(client: &Client, events: &mut UnboundedReceiver<ClientEvent>) -> PaneId {
    client.attach(None);
    let ClientEvent::Layout { layout } =
        next_matching(events, |event| matches!(event, ClientEvent::Layout { .. })).await
    else {
        unreachable!()
    };
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    pane
}

async fn echoes(
    client: &Client,
    events: &mut UnboundedReceiver<ClientEvent>,
    pane: PaneId,
    word: &str,
) {
    client.send_input(pane, format!("echo {word}-$((6*7))\r").into_bytes());
    let needle = format!("{word}-42").into_bytes();
    let mut seen = Vec::new();
    next_matching(events, |event| {
        if let ClientEvent::PaneBytes { data, .. } = event {
            seen.extend_from_slice(data);
        }
        seen.windows(needle.len()).any(|window| window == needle)
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn this_computer_is_reached_over_loopback_when_its_network_is_gone() {
    let state = tempfile::tempdir().unwrap();
    let helper = helper(state.path()).await;
    let (client, mut events) = connect_this_computer(&ticket_from_another_network(&helper));
    let connected = tokio::time::timeout(
        Duration::from_secs(10),
        next_matching(&mut events, |event| {
            matches!(event, ClientEvent::Connected { .. })
        }),
    )
    .await;
    assert!(
        connected.is_ok(),
        "this computer's daemon was never reached"
    );
    let pane = first_pane(&client, &mut events).await;
    echoes(&client, &mut events, pane, "first").await;

    client.network_changed();
    echoes(&client, &mut events, pane, "roamed").await;

    client.reconnect();
    next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Connected { .. })
    })
    .await;
    echoes(&client, &mut events, pane, "redialled").await;
    drop(client);
    helper.shutdown().await;
}
