use super::*;

fn headers(host: &str, token: &str, length: usize) -> String {
    format!(
        "POST /claude/message-display HTTP/1.1\r\nHost: {host}\r\nAuthorization: Bearer {token}\r\nX-Gudo-Pane: 1\r\nContent-Length: {length}\r\n\r\n"
    )
}

#[test]
fn headers_refuse_rebinding_browser_origins_and_ambiguous_framing() {
    let host = "localhost:1234";
    let valid = headers(host, "display-token", 2);
    assert_eq!(parse_headers(valid.as_bytes(), host).unwrap().length, 2);
    for invalid in [
        valid.replace(host, "localhost.evil:1234"),
        valid.replace("POST ", "GET "),
        valid.replace(
            "Content-Length: 2",
            "Content-Length: 2\r\nContent-Length: 2",
        ),
        valid.replace(
            "Content-Length: 2",
            "Content-Length: 2\r\nTransfer-Encoding: chunked",
        ),
        valid.replace(
            "Content-Length: 2",
            "Content-Length: 2\r\nOrigin: https://untrusted.invalid",
        ),
        valid.replace(
            "Content-Length: 2",
            "Content-Length: 2\r\nReferer: https://untrusted.invalid",
        ),
        valid.replace(
            "Content-Length: 2",
            "Content-Length: 2\r\nContent-Encoding: gzip",
        ),
        valid.replace(
            "Authorization: Bearer display-token",
            "Authorization: Bearer display-token\r\nAuthorization: Bearer another-token",
        ),
    ] {
        assert!(parse_headers(invalid.as_bytes(), host).is_none());
    }
    let enormous = headers(host, "display-token", usize::MAX);
    let parsed = parse_headers(enormous.as_bytes(), host).unwrap();
    assert!(parsed.body.is_empty());
    assert_eq!(parsed.length, usize::MAX);
}

#[test]
fn empty_acknowledgement_precedes_a_blocked_consumer() {
    use std::io::{Read, Write};
    let capture = Arc::new(super::super::Capture::new(b"fixture-secret"));
    let token = capture.token(PaneId(1));
    let (ready, address_receive) = std::sync::mpsc::sync_channel(1);
    let (entered, entered_receive) = std::sync::mpsc::sync_channel(1);
    let (release, released) = std::sync::mpsc::channel();
    // The official CLI is external to the daemon's executor. Use an independent OS client
    // too: deliberately blocking its own Tokio I/O driver would not test HTTP delivery.
    let server = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async move {
                let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
                let address = listener.local_addr().unwrap();
                ready.send(address).unwrap();
                let (stream, _) = listener.accept().await.unwrap();
                serve(&capture, stream, &address.to_string(), move |request| {
                    assert_eq!(request.body, b"{}");
                    let _ = entered.send(());
                    // Only the client (or test unwinding) can release this barrier, not a timer.
                    let _ = released.recv();
                })
                .await;
            });
    });
    let address = address_receive
        .recv_timeout(Duration::from_secs(5))
        .unwrap();
    let mut client = std::net::TcpStream::connect(address).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    client
        .write_all(format!("{}{{}}", headers(&address.to_string(), &token, 2)).as_bytes())
        .unwrap();
    entered_receive
        .recv_timeout(Duration::from_secs(5))
        .unwrap();
    let mut response = Vec::new();
    client.read_to_end(&mut response).unwrap();
    assert_eq!(response, RESPONSE);
    assert!(!String::from_utf8_lossy(&response).contains("displayContent"));
    release.send(()).unwrap();
    server.join().unwrap();
}

#[tokio::test]
async fn listener_reuses_its_private_port_after_recreation() {
    let directory = tempfile::tempdir().unwrap();
    let first = HttpListener::bind(directory.path()).unwrap();
    let address = first.address;
    assert!(address.ip().is_loopback());
    drop(first);
    let restored = HttpListener::bind(directory.path()).unwrap();
    assert_eq!(restored.address, address);
}

#[tokio::test]
async fn a_saved_port_taken_by_another_program_falls_back_to_a_new_one() {
    let directory = tempfile::tempdir().unwrap();
    let taken = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let port = taken.local_addr().unwrap().port();
    std::fs::write(directory.path().join(PORT_FILE), port.to_string()).unwrap();
    let listener = HttpListener::bind(directory.path()).unwrap();
    assert_ne!(listener.port(), port);
    assert_eq!(
        std::fs::read_to_string(directory.path().join(PORT_FILE)).unwrap(),
        listener.port().to_string()
    );
}

#[test]
fn display_tokens_are_pane_and_purpose_scoped() {
    let capture = super::super::Capture::new(b"fixture-secret");
    let token = capture.token(PaneId(1));
    assert!(capture.verify(PaneId(1), &token));
    assert!(!capture.verify(PaneId(2), &token));
    assert!(!capture.verify(PaneId(1), "fixture-secret"));
    let hook_token = crate::fsutil::hex(
        ring::hmac::sign(
            &ring::hmac::Key::new(ring::hmac::HMAC_SHA256, b"fixture-secret"),
            b"1",
        )
        .as_ref(),
    );
    assert!(!capture.verify(PaneId(1), &hook_token));
}
