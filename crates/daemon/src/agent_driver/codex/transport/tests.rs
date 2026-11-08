use super::*;

#[tokio::test]
async fn failed_native_queue_never_truncates_official_terminal_bytes() {
    let source = Arc::new(Live {
        owner: tokio::sync::watch::channel(None).0,
        fault: std::sync::atomic::AtomicBool::new(false),
        state: Mutex::new(State::new()),
        runtime: Mutex::new(super::super::runtime::Runtime::default()),
        process: Mutex::new(None),
        task: Mutex::new(None),
        directory: crate::fsutil::create_private_temp_dir("gudo-codex-forward").unwrap(),
    });
    let (sender, receiver) = tokio::sync::mpsc::channel(1);
    drop(receiver);
    let (mut tui, relay_tui) = tokio::net::UnixStream::pair().unwrap();
    let (mut server, relay_server) = tokio::net::UnixStream::pair().unwrap();
    let relay = tokio::spawn(forward(
        relay_tui,
        relay_server,
        Arc::downgrade(&source),
        sender,
    ));
    let expected: Vec<_> = (0..512 * 1024).map(|index| (index % 256) as u8).collect();
    let bytes = expected.clone();
    let writer = tokio::spawn(async move {
        server.write_all(&bytes).await.unwrap();
        server.shutdown().await.unwrap();
    });
    let mut received = Vec::new();
    tokio::time::timeout(
        std::time::Duration::from_secs(5),
        tui.read_to_end(&mut received),
    )
    .await
    .unwrap()
    .unwrap();
    writer.await.unwrap();
    relay.await.unwrap().unwrap();
    assert_eq!(received, expected);
    assert!(!source.is_running());
}
