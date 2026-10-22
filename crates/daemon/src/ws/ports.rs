//! process tree, plus URLs the pane printed (`Local: http://localhost:5173/`).
//!
//! Attribution is exact because the daemon owns the PTYs: a port belongs to the pane whose
//! every [`Config::port_scan_interval`](crate::Config::port_scan_interval) while a client is
//! connected, and at once when a pane prints a new URL or a command starts or ends; nothing
//! is scanned while no client is connected. The kind of a port is guessed from the printed
//! URL, else from one `HEAD /` probe per (process, port) (`HTTP/` → HTTP, a TLS record →
//! HTTPS), skipping well-known database and mail ports. Agent CLIs' own listeners are left out.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{PaneId, PortInfo, PortKind};
use regex::Regex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Notify;

use crate::core::{Core, Event, lock};
use crate::procinfo;

/// Ports never probed (they do not speak HTTP and a stray request can log noise).
const NO_PROBE: &[u16] = &[
    22, 25, 53, 110, 143, 465, 587, 993, 995, 1433, 1521, 3306, 5432, 5672, 6379, 9042, 11211,
    27017,
];
const PROBE_TIMEOUT: Duration = Duration::from_millis(400);

#[derive(Default)]
struct State {
    /// Last published list, sorted by port.
    ports: Vec<PortInfo>,
    /// Printed URLs per pane: port → URL.
    urls: HashMap<PaneId, BTreeMap<u16, String>>,
    /// Probe results per (pid, port).
    kinds: HashMap<(u32, u16), PortKind>,
}

/// Port detection state, owned by the core.
pub(crate) struct Ports {
    state: Mutex<State>,
    /// Wakes the scanner early.
    pub trigger: Notify,
    url_re: Regex,
}

impl Ports {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
            trigger: Notify::new(),
            url_re: Regex::new(
                r"(?i)\b(https?)://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|[a-z0-9.-]+\.localhost|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|100\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d{2,5})(/[^\s'\x22<>)\]]*)?",
            )
            .expect("valid regex"),
        }
    }

    /// The last published list.
    pub fn current(&self) -> Vec<PortInfo> {
        lock(&self.state).ports.clone()
    }

    /// Looks for dev-server URLs in a pane's screen text; triggers a scan when one is new.
    pub fn observe_screen(&self, pane: PaneId, screen: &str) {
        let mut found = Vec::new();
        for cap in self.url_re.captures_iter(screen) {
            let Some(port) = cap.get(3).and_then(|p| p.as_str().parse::<u16>().ok()) else {
                continue;
            };
            let host = cap.get(2).map_or("", |h| h.as_str()).to_ascii_lowercase();
            // 0.0.0.0 means "all interfaces"; a browser wants localhost.
            let host = if host == "0.0.0.0" || host == "[::]" {
                "localhost".to_owned()
            } else {
                host
            };
            let scheme = cap
                .get(1)
                .map_or("http", |s| s.as_str())
                .to_ascii_lowercase();
            let path = cap.get(4).map_or("/", |p| p.as_str());
            let url = format!("{scheme}://{host}:{port}{path}");
            found.push((port, is_loopback_url(&url), url));
        }
        if found.is_empty() {
            return;
        }
        let mut new = false;
        {
            let mut state = lock(&self.state);
            let urls = state.urls.entry(pane).or_default();
            for (port, loopback, url) in found {
                // The first URL printed for a port wins (Vite prints `Local:` before
                // `Network:`; python prints its own line after ours), except that a loopback
                // URL replaces a LAN one.
                let replace = match urls.get(&port) {
                    None => true,
                    Some(old) => loopback && !is_loopback_url(old),
                };
                if replace {
                    urls.insert(port, url);
                    new = true;
                }
            }
        }
        if new {
            self.trigger.notify_one();
        }
    }

    pub fn forget_pane(&self, pane: PaneId) {
        lock(&self.state).urls.remove(&pane);
    }
}

fn is_loopback_url(url: &str) -> bool {
    let host = url.split("://").nth(1).unwrap_or_default();
    host.starts_with("localhost:")
        || host.starts_with("127.")
        || host.starts_with("[::1]")
        || host
            .split(':')
            .next()
            .is_some_and(|h| h.ends_with(".localhost"))
}

/// Scans now and returns the list (also published if it changed).
pub(crate) async fn scan(core: &Arc<Core>) -> Vec<PortInfo> {
    let panes: Vec<(PaneId, u32)> = core
        .pane_entries()
        .into_iter()
        .map(|(id, e)| (id, e.pane.pty().pid()))
        .collect();
    let found = tokio::task::spawn_blocking(move || listeners_by_pane(&panes))
        .await
        .unwrap_or_default();
    let ws = &core.ws.ports;
    let (urls, mut kinds) = {
        let state = lock(&ws.state);
        (state.urls.clone(), state.kinds.clone())
    };
    let mut ports: Vec<PortInfo> = Vec::new();
    for (pane, listener, process) in found {
        let url = urls.get(&pane).and_then(|u| u.get(&listener.port)).cloned();
        let key = (listener.pid, listener.port);
        let kind = match (&url, kinds.get(&key)) {
            (Some(u), _) if u.starts_with("https:") => PortKind::Https,
            (Some(_), _) => PortKind::Http,
            (None, Some(k)) => *k,
            (None, None) => {
                let k = probe(listener.port).await;
                kinds.insert(key, k);
                k
            }
        };
        ports.push(PortInfo {
            port: listener.port,
            loopback_only: listener.loopback,
            pane_id: Some(pane),
            pid: listener.pid,
            process,
            kind,
            url,
        });
    }
    ports.sort_by_key(|p| p.port);
    ports.dedup_by_key(|p| p.port);
    let changed = {
        let mut state = lock(&ws.state);
        // Forget probes of sockets that went away, so a restarted server is probed again.
        let live: Vec<(u32, u16)> = ports.iter().map(|p| (p.pid, p.port)).collect();
        kinds.retain(|k, _| live.contains(k));
        state.kinds = kinds;
        let changed = state.ports != ports;
        state.ports.clone_from(&ports);
        changed
    };
    if changed {
        core.emit(Event::Ports);
    }
    ports
}

/// `(pane, listener, process name)` for every listening socket in a pane's tree. A socket
/// shared by a pre-forking server is reported once, by the process nearest the pane's shell.
fn listeners_by_pane(panes: &[(PaneId, u32)]) -> Vec<(PaneId, procinfo::Listener, String)> {
    let roots: Vec<u32> = panes.iter().map(|&(_, pid)| pid).collect();
    let trees = procinfo::process_trees(&roots);
    let mut out = Vec::new();
    for (&(pane, _), tree) in panes.iter().zip(&trees) {
        let mut seen = Vec::new();
        for listener in procinfo::listening_ports(tree) {
            if seen.contains(&listener.port) {
                continue;
            }
            seen.push(listener.port);
            if is_agent_cli(listener.pid) {
                continue;
            }
            let name = procinfo::process_name(listener.pid).unwrap_or_default();
            out.push((pane, listener, name));
        }
    }
    out
}

/// An agent CLI's own sockets (its sign-in callback, editor bridges) are not dev servers:
/// their `/` is an empty 404, and a sign-in callback only works at the URL the CLI built.
fn is_agent_cli(pid: u32) -> bool {
    pty::ForegroundProcess::of(pid)
        .is_some_and(|p| AGENT_CLIS.contains(&p.program()) || AGENT_CLIS.contains(&p.name.as_str()))
}

const AGENT_CLIS: &[&str] = &["claude", "codex"];

/// Sends `HEAD /` and classifies the first bytes of the answer.
async fn probe(port: u16) -> PortKind {
    if NO_PROBE.contains(&port) {
        return PortKind::Other;
    }
    let attempt = async {
        let mut tcp = match tokio::net::TcpStream::connect(("127.0.0.1", port)).await {
            Ok(t) => t,
            Err(_) => tokio::net::TcpStream::connect(("::1", port)).await.ok()?,
        };
        tcp.write_all(b"HEAD / HTTP/1.0\r\nHost: localhost\r\nUser-Agent: port-probe\r\n\r\n")
            .await
            .ok()?;
        let mut buf = [0u8; 5];
        let mut got = 0;
        while got < buf.len() {
            match tcp.read(&mut buf[got..]).await {
                Ok(0) | Err(_) => break,
                Ok(n) => got += n,
            }
        }
        Some((buf, got))
    };
    match tokio::time::timeout(PROBE_TIMEOUT, attempt).await {
        Ok(Some((buf, got))) if got >= 5 && &buf == b"HTTP/" => PortKind::Http,
        // A TLS record (alert or handshake) in answer to plaintext.
        Ok(Some((buf, got))) if got >= 2 && matches!(buf[0], 0x15 | 0x16) && buf[1] == 3 => {
            PortKind::Https
        }
        Ok(Some((_, got))) if got > 0 => PortKind::Other,
        _ => PortKind::Unknown,
    }
}

/// Rescans while clients are connected: on the interval, and early when triggered.
pub(crate) async fn run(core: Arc<Core>) {
    let interval = core.cfg.port_scan_interval;
    loop {
        let _ = tokio::time::timeout(interval, core.ws.ports.trigger.notified()).await;
        if core.connected_clients() == 0 {
            continue;
        }
        // Let a burst of triggers (a server printing several lines) settle.
        tokio::time::sleep(Duration::from_millis(50)).await;
        scan(&core).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_dev_server_urls() {
        let ports = Ports::new();
        let pane = PaneId(1);
        ports.observe_screen(
            pane,
            "  VITE v5  ready in 300 ms\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: http://192.168.1.4:5173/\n\
             ready - started server on 0.0.0.0:3000, url: http://0.0.0.0:3000\n\
             see https://example.com:8443/ and http://127.0.0.1:8080/api",
        );
        let state = lock(&ports.state);
        let urls = &state.urls[&pane];
        assert_eq!(urls[&5173], "http://localhost:5173/");
        assert_eq!(urls[&3000], "http://localhost:3000/");
        assert_eq!(urls[&8080], "http://127.0.0.1:8080/api");
        assert!(!urls.contains_key(&8443), "public URLs are not dev servers");
    }
}
