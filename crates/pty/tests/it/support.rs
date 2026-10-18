use std::future::Future;
use std::process::Command;
use std::time::Duration;

use pty::{EchoState, PtyActor, RecvError, SpawnOptions, Subscriber};

pub const TIMEOUT: Duration = Duration::from_secs(10);

/// A command with a minimal, predictable environment.
pub fn command(argv: &[&str]) -> Command {
    let mut cmd = Command::new(argv[0]);
    cmd.args(&argv[1..])
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("TERM", "dumb")
        .env("LC_ALL", "C");
    cmd
}

pub fn spawn(argv: &[&str]) -> PtyActor {
    spawn_with(argv, SpawnOptions::default())
}

pub fn spawn_with(argv: &[&str], options: SpawnOptions) -> PtyActor {
    PtyActor::spawn(command(argv), options).expect("spawn")
}

pub async fn within<T>(what: &str, fut: impl Future<Output = T>) -> T {
    tokio::time::timeout(TIMEOUT, fut)
        .await
        .unwrap_or_else(|_| panic!("timed out: {what}"))
}

/// Receives until the output contains `needle`; returns the output up to and including it and
/// leaves the subscriber just past it.
pub async fn read_until(sub: &mut Subscriber, needle: &str) -> String {
    let start = sub.position();
    let mut seen = Vec::new();
    let found = tokio::time::timeout(TIMEOUT, async {
        loop {
            match sub.recv().await {
                Ok(chunk) => seen.extend_from_slice(&chunk.data),
                Err(RecvError::Closed) => return None,
                Err(err) => panic!("recv: {err}"),
            }
            if let Some(at) = seen
                .windows(needle.len())
                .position(|window| window == needle.as_bytes())
            {
                return Some(at + needle.len());
            }
        }
    })
    .await;
    let seen_text = String::from_utf8_lossy(&seen).into_owned();
    let Ok(Some(end)) = found else {
        panic!("never saw {needle:?}; output was {seen_text:?}");
    };
    // Rewind over whatever arrived after the needle so the next read sees it.
    sub.seek(start + end as u64).expect("still in the ring");
    String::from_utf8_lossy(&seen[..end]).into_owned()
}

/// Receives until output ends; returns everything received.
pub async fn read_to_end(sub: &mut Subscriber) -> String {
    let mut seen = String::new();
    within("read_to_end", async {
        loop {
            match sub.recv().await {
                Ok(chunk) => seen.push_str(&String::from_utf8_lossy(&chunk.data)),
                Err(RecvError::Closed) => break,
                Err(err) => panic!("recv: {err}"),
            }
        }
    })
    .await;
    seen
}

/// Waits until the reported echo state satisfies `pred`.
pub async fn wait_echo(pty: &PtyActor, pred: impl Fn(EchoState) -> bool) -> EchoState {
    let mut rx = pty.echo_updates();
    within("echo state", async {
        *rx.wait_for(|state| pred(*state))
            .await
            .expect("echo sender alive")
    })
    .await
}
