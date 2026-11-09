use std::io::{Read, Write};
use std::time::{Duration, Instant};

use super::Fixture;

pub(super) async fn record(daemon: &crate::Daemon, fixture: &Fixture) -> Result<(), String> {
    let Some(listener) = daemon.core.hooks.display_http.as_ref() else {
        return Ok(());
    };
    let port = listener.port();
    let pane = proto::PaneId(1 << 62);
    let token = daemon.core.hooks.display.token(pane);
    let samples = tokio::task::spawn_blocking(move || {
        let mut samples = Vec::new();
        for _ in 0..25 {
            let started = Instant::now();
            let mut client = std::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))?;
            client.set_read_timeout(Some(Duration::from_secs(2)))?;
            client.write_all(format!("POST /claude/message-display HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {token}\r\nX-Gudo-Pane: {}\r\nContent-Length: 2\r\n\r\n{{}}", pane.0).as_bytes())?;
            let mut response = Vec::new();
            client.read_to_end(&mut response)?;
            if !response.ends_with(b"\r\n\r\n{}") { return Err(std::io::Error::other("invalid acknowledgement")); }
            samples.push(started.elapsed().as_secs_f64() * 1_000_000.0);
        }
        samples.sort_by(f64::total_cmp);
        Ok::<_, std::io::Error>(samples)
    }).await.map_err(|error| error.to_string())?.map_err(|error| error.to_string())?;
    let metrics = serde_json::json!({"samples":samples.len(),"receiver_round_trip_us":{"p50":samples[12],"p95":samples[23],"maximum":samples[24]},"note":"Loopback receiver round trips, not CLI end-to-end or Release acceptance"});
    std::fs::write(
        fixture.root.join("receiver-latency.json"),
        metrics.to_string(),
    )
    .map_err(|error| error.to_string())?;
    eprintln!("{metrics}");
    Ok(())
}
