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
    let b64 = data_encoding::BASE64.encode(der);
    let lines: Vec<&str> = b64
        .as_bytes()
        .chunks(64)
        .map(|c| std::str::from_utf8(c).unwrap())
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
    let daemon = start_with(state.path(), move |c| {
        c.relay = daemon::RelayMode::Custom(CustomRelays {
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
    let mut c = TestClient::connect_with(
        &relayed_only,
        config,
        ConnectOptions {
            relay_ca_der: vec![cert],
        },
    );
    c.until("connected through the relay", |c| c.connected > 0)
        .await;
    let pane = c.attach_and_follow().await;
    c.type_line(pane, "echo via-$((40+2))-relay");
    c.wait_text(pane, "via-42-relay").await;
    drop(c);
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
    let mut c = TestClient::connect_with(&link, config, ConnectOptions::default());
    c.until("connected directly", |c| c.connected > 0).await;
    drop(c);
    daemon.shutdown().await;
}

#[test]
fn relay_settings_come_from_config_toml() {
    let state = tempfile::tempdir().unwrap();
    let write = |text: &str| std::fs::write(state.path().join("config.toml"), text).unwrap();
    let load = || {
        let mut c = daemon::Config::new(state.path());
        c.apply_user_file().map(|()| c)
    };

    write(
        "[relay]\nurls = [\"https://relay.example.com\"]\nauth_token = \"t\"\n[push]\nenabled = false\nrelay = \"https://push.example.com\"\ndelay_ms = 250\n",
    );
    let c = load().unwrap();
    assert_eq!(
        c.relay,
        daemon::RelayMode::Custom(CustomRelays {
            urls: vec!["https://relay.example.com".into()],
            auth_token: Some("t".into()),
            ca_files: vec![],
        })
    );
    assert!(!c.push.enabled);
    assert_eq!(c.push.relay_url, "https://push.example.com");
    assert_eq!(c.push.delay, Duration::from_millis(250));

    write("[relay]\nmode = \"local-only\"\n");
    assert_eq!(load().unwrap().relay, daemon::RelayMode::Disabled);
    write("[relay]\nmode = \"custom\"\n");
    assert!(load().is_err(), "custom needs urls");
    write("[relay]\nurls = [\"relay.example.com\"]\n");
    assert!(load().is_err(), "urls need a scheme");

    // `--no-relay` (set before the file is read) wins.
    write("[relay]\nurls = [\"https://relay.example.com\"]\n");
    let mut c = daemon::Config::new(state.path());
    c.relay = daemon::RelayMode::Disabled;
    c.apply_user_file().unwrap();
    assert_eq!(c.relay, daemon::RelayMode::Disabled);

    // Defaults: the brand's push relay, on.
    std::fs::remove_file(state.path().join("config.toml")).unwrap();
    let c = load().unwrap();
    assert_eq!(c.push.relay_url, brand::PUSH_RELAY_URL);
    assert!(c.push.enabled);
}
