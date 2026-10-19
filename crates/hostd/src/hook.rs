//! `un-hook`: the agent hook shim. Agents launched by the daemon run
//! `un-hook <agent> <Event>` with the hook payload on stdin; the shim relays it to the
//! daemon's hook socket and prints the daemon's answer (for example a permission decision).
//!
//! It never fails the agent: any error prints nothing and exits 0, so a missing daemon only
//! means the agent falls back to its own prompts.
//!
//! `un-hook askpass <prompt>` is the askpass helper instead (see `askpass.rs`).

mod askpass;

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use daemon::{HookRequest, HookResponse};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "askpass") {
        std::process::exit(askpass::main(&args[1..]));
    }
    if let Err(e) = relay()
        && std::env::var_os(brand::env_var("HOOK_DEBUG")).is_some()
    {
        eprintln!("{}: {e}", brand::HOOK_BIN);
    }
}

fn relay() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let agent = args.next().ok_or("usage: un-hook <agent> <event>")?;
    let event = args.next().ok_or("usage: un-hook <agent> <event>")?;
    let env = |name: &str| std::env::var(brand::env_var(name));

    let mut payload = Vec::new();
    std::io::stdin().take(4 << 20).read_to_end(&mut payload)?;
    let payload = serde_json::from_slice(&payload).unwrap_or(serde_json::Value::Null);

    // The endpoint file wins over UN_SOCK so a pane outlives a daemon restart that moved it.
    let socket = env("ENDPOINT_FILE")
        .ok()
        .and_then(|f| std::fs::read_to_string(f).ok())
        .map(|s| PathBuf::from(s.trim()))
        .or_else(|| env("SOCK").ok().map(PathBuf::from))
        .ok_or("no hook socket")?;
    let request = HookRequest {
        v: 1,
        token: env("TOKEN")?,
        pane: env("PANE_ID")?,
        agent,
        seq: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos() as u64),
        payload,
        event: event.clone(),
    };
    let mut stream = UnixStream::connect(socket)?;
    let wait = if event == "PermissionRequest" {
        daemon::PERMISSION_WAIT + Duration::from_secs(2)
    } else {
        Duration::from_secs(5)
    };
    stream.set_read_timeout(Some(wait))?;
    let mut line = serde_json::to_vec(&request)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer)?;
    let response: HookResponse = serde_json::from_str(&answer)?;
    if let Some(stdout) = response.stdout {
        println!("{stdout}");
    }
    Ok(())
}
