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
        history_task: Mutex::new(None),
        controls: Mutex::new(None),
        control_task: Mutex::new(None),
        history_result: Mutex::new(None),
        observations: Mutex::new(None),
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

fn server_frame(message: &str) -> Vec<u8> {
    let mut frame = vec![0x81, 127];
    frame.extend_from_slice(&(message.len() as u64).to_be_bytes());
    frame.extend_from_slice(message.as_bytes());
    frame
}

#[test]
fn an_oversized_turn_completion_still_ends_the_turn() {
    let mut state = State::new();
    state.observe(r#"{"id":1,"method":"thread/start"}"#, Direction::FromTui);
    state.observe(
        r#"{"id":1,"result":{"thread":{"id":"primary"}}}"#,
        Direction::FromServer,
    );
    let started = |turn: &str| {
        serde_json::json!({"method":"turn/started","params":{"threadId":"primary","turn":{"id":turn,"items":[],"status":"inProgress"}}}).to_string()
    };
    state.observe(&started("first"), Direction::FromServer);
    state.effects.clear();
    let output = "x".repeat(agents::CODEX_FRAME_LIMIT);
    let completed = serde_json::json!({
        "method": "turn/completed",
        "params": {
            "threadId": "primary",
            "turn": {
                "id": "first",
                "items": [{"type": "agentMessage", "id": "message", "text": output}],
                "status": "completed",
                "error": null,
            },
        },
    })
    .to_string();
    let mut decoder = frames::Decoder::new(Direction::FromServer);
    let mut bytes = b"HTTP/1.1 101 Switching Protocols\r\n\r\n".to_vec();
    bytes.extend(server_frame(&completed));
    for chunk in bytes.chunks(64 * 1024) {
        decoder
            .feed(chunk, |observed| match observed {
                frames::Observed::Text(frame) => state.observe(frame, Direction::FromServer),
                frames::Observed::Skipped(outline) => state.skipped(Direction::FromServer, outline),
            })
            .unwrap();
    }
    assert!(!state.closed);
    assert!(
        state.effects.iter().any(|effect| matches!(
            effect,
            super::super::runtime::Effect::Completed(agents::CodexTurnOutcome::Completed)
        )),
        "the turn never ended"
    );
    assert_eq!(state.events.as_ref().unwrap().active_turn(), None);
    state.observe(&started("second"), Direction::FromServer);
    assert_eq!(state.events.as_ref().unwrap().active_turn(), Some("second"));
}
