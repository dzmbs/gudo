//! Self-hosted relays and local-only mode: the pairing ticket carries the daemon's relay
//! choice, and a client with default settings dials the way the ticket says.

use std::net::Ipv4Addr;
use std::time::Duration;

use client_core::proto::{Ticket, TicketExtras, TicketRelays};
use client_core::{ClientConfig, ConnectOptions, RelayMode};
use daemon::CustomRelays;
use iroh_relay::server::{CertConfig, RelayConfig, Server, ServerConfig, TlsConfig};

use crate::support::{TestClient, start_with};

/// A local `iroh-relay` with a self-signed certificate for 127.0.0.1; returns the server, its
/// URL and the certificate (DER).
async fn spawn_relay() -> (Server, String, Vec<u8>) {
    let (certs, server_config) = iroh_relay::server::testing::self_signed_tls_certs_and_config();
    let mut relay = RelayConfig::new((Ipv4Addr::LOCALHOST, 0));
    relay.tls = Some(TlsConfig::new(
        (Ipv4Addr::LOCALHOST, 0),
        CertConfig::Manual { server_config },
    ));
    relay.key_cache_capacity = Some(1024);
    let mut config = ServerConfig::default();
    config.relay = Some(relay);
    let server = Server::spawn(config).await.expect("relay starts");
    let url = format!("https://{}", server.https_addr().expect("https"));
    (server, url, certs[0].to_vec())
}

fn pem(der: &[u8]) -> String {
    let encoded = data_encoding::BASE64.encode(der);
    let lines: Vec<&str> = encoded
        .as_bytes()
        .chunks(64)
        .map(|chunk| std::str::from_utf8(chunk).unwrap())
        .collect();
    format!(
        "-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n",
        lines.join("\n")
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn daemon_and_client_connect_through_a_self_hosted_relay() {
    let (_server, url, cert) = spawn_relay().await;
    let state = tempfile::tempdir().unwrap();
    let ca = state.path().join("relay-ca.pem");
    std::fs::write(&ca, pem(&cert)).unwrap();
    let relay_url = url.clone();
    let daemon = start_with(state.path(), move |config| {
        config.relay = daemon::RelayMode::Custom(CustomRelays {
            urls: vec![relay_url],
            auth_token: None,
            ca_files: vec![ca],
        });
    })
    .await;
    daemon.wait_online(Duration::from_secs(10)).await;

    let link = daemon.pairing_link(daemon::PAIRING_TTL).unwrap();
    let (ticket, extras) = Ticket::parse_with_extras(&link).unwrap();
    assert_eq!(
        extras.relays,
        TicketRelays::Custom {
            urls: vec![url.clone()],
            auth_token: None
        }
    );
    let home = ticket.relay_url.clone().expect("home relay recorded");
    assert!(home.starts_with(&url), "{home} vs {url}");
    let status = daemon::endpoint_info(state.path()).unwrap().unwrap();
    assert_eq!(status.relays, extras.relays);

    // Strip the direct addresses: the only way to the daemon is through the relay.
    let relayed_only = Ticket {
        addrs: vec![],
        ..ticket
    }
    .to_string_with(&extras);
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Default; // the ticket decides
    let mut client = TestClient::connect_with(
        &relayed_only,
        config,
        ConnectOptions {
            relay_ca_der: vec![cert],
            ..ConnectOptions::default()
        },
    );
    client
        .until("connected through the relay", |client| client.connected > 0)
        .await;
    let pane = client.attach_and_follow().await;
    client.type_line(pane, "echo via-$((40+2))-relay");
    client.wait_text(pane, "via-42-relay").await;
    drop(client);
    daemon.shutdown().await;
}

/// The app's "Custom relay" setting: a ticket that names no relay at all (and no direct
/// addresses) still reaches the daemon through the relay the device was told to use.
#[tokio::test(flavor = "multi_thread")]
async fn the_devices_own_relay_replaces_the_tickets() {
    let (_server, url, cert) = spawn_relay().await;
    let state = tempfile::tempdir().unwrap();
    let ca = state.path().join("relay-ca.pem");
    std::fs::write(&ca, pem(&cert)).unwrap();
    let relay_url = url.clone();
    let daemon = start_with(state.path(), move |config| {
        config.relay = daemon::RelayMode::Custom(CustomRelays {
            urls: vec![relay_url],
            auth_token: None,
            ca_files: vec![ca],
        });
    })
    .await;
    daemon.wait_online(Duration::from_secs(10)).await;

    let link = daemon.pairing_link(daemon::PAIRING_TTL).unwrap();
    let (ticket, _) = Ticket::parse_with_extras(&link).unwrap();
    // A classic ticket: default relays, no home relay, no addresses.
    let bare = Ticket {
        addrs: vec![],
        relay_url: None,
        ..ticket
    }
    .to_string();
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Default;
    let mut client = TestClient::connect_with(
        &bare,
        config,
        ConnectOptions {
            relay_ca_der: vec![cert],
            relay_urls: vec![url],
            ..ConnectOptions::default()
        },
    );
    client
        .until("connected through the device's relay", |client| {
            client.connected > 0
        })
        .await;
    let pane = client.attach_and_follow().await;
    client.type_line(pane, "echo own-$((40+2))-relay");
    client.wait_text(pane, "own-42-relay").await;
    drop(client);
    daemon.shutdown().await;
}

/// The settings change while a client runs (`Client::set_relays`): a client that cannot reach
/// the daemon (no address, no relay) gets the device's relay and connects on a new endpoint.
#[tokio::test(flavor = "multi_thread")]
async fn relay_settings_apply_to_a_running_client() {
    let (_server, url, cert) = spawn_relay().await;
    let state = tempfile::tempdir().unwrap();
    let ca = state.path().join("relay-ca.pem");
    std::fs::write(&ca, pem(&cert)).unwrap();
    let relay_url = url.clone();
    let daemon = start_with(state.path(), move |config| {
        config.relay = daemon::RelayMode::Custom(CustomRelays {
            urls: vec![relay_url],
            auth_token: None,
            ca_files: vec![ca],
        });
    })
    .await;
    daemon.wait_online(Duration::from_secs(10)).await;
    let link = daemon.pairing_link(daemon::PAIRING_TTL).unwrap();
    let (ticket, _) = Ticket::parse_with_extras(&link).unwrap();
    let bare = Ticket {
        addrs: vec![],
        relay_url: None,
        ..ticket
    }
    .to_string();

    // Direct only, and the ticket has no address: nothing to dial.
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    let mut client = TestClient::connect_with(&bare, config, ConnectOptions::default());
    client
        .until("the first dial fails", |client| {
            client
                .log
                .iter()
                .any(|line| line.starts_with("Disconnected"))
        })
        .await;
    assert_eq!(client.connected, 0, "unreachable without a relay");

    client.client.set_relays(
        RelayMode::Default,
        &ConnectOptions {
            relay_ca_der: vec![cert],
            relay_urls: vec![url],
            ..ConnectOptions::default()
        },
    );
    client
        .until("connected after the settings changed", |client| {
            client.connected > 0
        })
        .await;
    let pane = client.attach_and_follow().await;
    client.type_line(pane, "echo switched-$((40+2))");
    client.wait_text(pane, "switched-42").await;
    drop(client);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn local_only_daemons_hand_out_direct_tickets() {
    let state = tempfile::tempdir().unwrap();
    // The test daemon runs with relays disabled (local-only).
    let daemon = start_with(state.path(), |_| {}).await;
    let link = daemon.pairing_link(daemon::PAIRING_TTL).unwrap();
    let (ticket, extras) = Ticket::parse_with_extras(&link).unwrap();
    assert_eq!(extras.relays, TicketRelays::Disabled);
    assert!(ticket.relay_url.is_none());
    assert!(!ticket.addrs.is_empty());
    assert_ne!(link, ticket.to_string(), "the extras are in the link");
    assert_eq!(
        ticket.to_string_with(&TicketExtras::default()),
        ticket.to_string()
    );

    // A client left on default relays follows the ticket and dials directly.
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Default;
    let mut client = TestClient::connect_with(&link, config, ConnectOptions::default());
    client
        .until("connected directly", |client| client.connected > 0)
        .await;
    drop(client);
    daemon.shutdown().await;
}

#[test]
fn relay_settings_come_from_config_toml() {
    let state = tempfile::tempdir().unwrap();
    let write = |text: &str| std::fs::write(state.path().join("config.toml"), text).unwrap();
    let load = || {
        let mut config = daemon::Config::new(state.path());
        config.apply_user_file().map(|()| config)
    };

    write(
        "[relay]\nurls = [\"https://relay.example.com\"]\nauth_token = \"t\"\n[push]\nenabled = false\nrelay = \"https://push.example.com\"\ndelay_ms = 250\n",
    );
    let config = load().unwrap();
    assert_eq!(
        config.relay,
        daemon::RelayMode::Custom(CustomRelays {
            urls: vec!["https://relay.example.com".into()],
            auth_token: Some("t".into()),
            ca_files: vec![],
        })
    );
    assert!(!config.push.enabled);
    assert_eq!(config.push.relay_url, "https://push.example.com");
    assert_eq!(config.push.delay, Duration::from_millis(250));

    write("[relay]\nmode = \"local-only\"\n");
    assert_eq!(load().unwrap().relay, daemon::RelayMode::Disabled);
    write("[relay]\nmode = \"custom\"\n");
    assert!(load().is_err(), "custom needs urls");
    write("[relay]\nurls = [\"relay.example.com\"]\n");
    assert!(load().is_err(), "urls need a scheme");

    // `--no-relay` (set before the file is read) wins.
    write("[relay]\nurls = [\"https://relay.example.com\"]\n");
    let mut config = daemon::Config::new(state.path());
    config.relay = daemon::RelayMode::Disabled;
    config.apply_user_file().unwrap();
    assert_eq!(config.relay, daemon::RelayMode::Disabled);

    // Defaults: the brand's push relay, on.
    std::fs::remove_file(state.path().join("config.toml")).unwrap();
    let config = load().unwrap();
    assert_eq!(config.push.relay_url, brand::PUSH_RELAY_URL);
    assert!(config.push.enabled);
}
