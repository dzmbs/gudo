//! Without a link: transfers and forwards give up instead of waiting forever, and dropping a
//! client lets go of everything it bound.

use std::time::{Duration, Instant};

use client_core::proto::ForwardTarget;
use client_core::{Client, ClientConfig, ClientEvent, EventQueue, RelayMode};

use super::{Host, connect, next_matching};

/// How long a transfer may wait for a link that is not coming back.
const TRANSFER_GIVES_UP_WITHIN: Duration = Duration::from_secs(30);

async fn connected(events: &mut tokio::sync::mpsc::UnboundedReceiver<ClientEvent>) {
    next_matching(events, |event| {
        matches!(event, ClientEvent::Connected { .. })
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn transfers_on_a_suspended_client_fail_at_once() {
    let mut host = Host::start().await;
    let (client, mut events) = connect(&host.ticket(), false);
    connected(&mut events).await;
    client.suspend();

    let started = Instant::now();
    let upload = tokio::time::timeout(
        Duration::from_secs(10),
        client.upload_bytes(b"hello".to_vec(), host.write_target("up.txt")),
    )
    .await
    .expect("the upload returned");
    assert!(upload.is_err(), "{upload:?}");
    let download = tokio::time::timeout(
        Duration::from_secs(10),
        client.download_file(
            host.home.join("missing").to_string_lossy().into_owned(),
            host.state.join("down").to_string_lossy().into_owned(),
            0,
            None,
            None,
        ),
    )
    .await
    .expect("the download returned");
    assert!(download.is_err(), "{download:?}");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "a suspended client held transfers for {:?}",
        started.elapsed()
    );
    drop(client);
    host.go_down().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_transfer_while_the_host_is_down_fails_within_its_deadline() {
    let mut host = Host::start().await;
    let (client, mut events) = connect(&host.ticket(), false);
    connected(&mut events).await;
    host.go_down().await;

    let upload = tokio::time::timeout(
        TRANSFER_GIVES_UP_WITHIN,
        client.upload_bytes(b"hello".to_vec(), host.write_target("up.txt")),
    )
    .await
    .expect("the upload gave up in time");
    assert!(upload.is_err(), "{upload:?}");

    host.come_back().await;
    connected(&mut events).await;
    let upload = client
        .upload_bytes(b"hello".to_vec(), host.write_target("up.txt"))
        .await;
    assert!(upload.is_ok(), "{upload:?}");
    drop(client);
    host.go_down().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_forwarded_connection_while_the_host_is_down_is_closed_in_time() {
    let mut host = Host::start().await;
    let (client, mut events) = connect(&host.ticket(), false);
    connected(&mut events).await;
    let local_port = client
        .forward(0, ForwardTarget::Tcp { port: 9 })
        .expect("bound");
    host.go_down().await;

    let mut local = tokio::net::TcpStream::connect(("127.0.0.1", local_port))
        .await
        .expect("the forward listens");
    let mut ignored = [0; 16];
    let ended = tokio::time::timeout(
        TRANSFER_GIVES_UP_WITHIN,
        tokio::io::AsyncReadExt::read(&mut local, &mut ignored),
    )
    .await;
    assert!(ended.is_ok(), "the forwarded connection hung");
}

#[test]
fn dropping_a_client_on_a_shared_runtime_frees_its_forwarded_ports() {
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let mut host = runtime.block_on(Host::start());
    let (listener, _events) = EventQueue::channel();
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    let client = Client::connect_on(runtime.handle(), &host.ticket(), config, listener).unwrap();
    let forwarded = client
        .forward(0, ForwardTarget::Tcp { port: 9 })
        .expect("bound");
    let port_forwarded = client.forward_port(0, 9).expect("bound");
    drop(client);

    let deadline = Instant::now() + Duration::from_secs(5);
    for port in [forwarded, port_forwarded] {
        while std::net::TcpListener::bind(("127.0.0.1", port)).is_err() {
            assert!(
                Instant::now() < deadline,
                "port {port} is still bound after the client was dropped"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    runtime.block_on(host.go_down());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_transfer_its_caller_gave_up_on_never_runs_once_the_host_is_back() {
    let mut host = Host::start().await;
    let (client, mut events) = connect(&host.ticket(), false);
    connected(&mut events).await;
    host.go_down().await;

    let gave_up = tokio::time::timeout(
        Duration::from_millis(500),
        client.upload_bytes(b"stale".to_vec(), host.write_target("abandoned.txt")),
    )
    .await;
    assert!(gave_up.is_err(), "the upload ended on its own: {gave_up:?}");
    host.come_back().await;
    connected(&mut events).await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(
        !host.home.join("abandoned.txt").exists(),
        "an upload its caller dropped ran after all"
    );
    drop(client);
    host.go_down().await;
}
