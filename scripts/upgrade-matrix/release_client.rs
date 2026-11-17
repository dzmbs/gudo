//! A client as a released app connects: built against that release's client-core by
//! `scripts/upgrade-matrix.sh`, it pairs with a ticket, attaches, and finds `text` in a pane's
//! scrollback. Exits 0 when found, 2 when refused, 1 when nothing came within 30 s.
//!
//!   release_client <ticket> <pane id> <text>

use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use client_core::proto::{CaseMode, PaneId, SearchMode, SearchQuery};
use client_core::{Client, ClientConfig, ClientEvent, ClientListener, ConnectOptions, RelayMode};

const WAIT: Duration = Duration::from_secs(30);

struct Events(Mutex<mpsc::Sender<ClientEvent>>);

impl ClientListener for Events {
    fn on_event(&self, event: ClientEvent) {
        if let Ok(sender) = self.0.lock() {
            let _ = sender.send(event);
        }
    }
}

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    let [_, ticket, pane, text] = arguments.as_slice() else {
        eprintln!("usage: release_client <ticket> <pane id> <text>");
        std::process::exit(64);
    };
    let pane = PaneId(pane.parse().expect("a pane id"));
    let (sender, events) = mpsc::channel();
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    let client = Client::connect_with(
        ticket,
        config,
        ConnectOptions::default(),
        Arc::new(Events(Mutex::new(sender))),
    )
    .expect("client starts");
    client.attach(None);
    let query = || SearchQuery {
        pattern: text.clone(),
        mode: SearchMode::Plain,
        case: CaseMode::Sensitive,
    };
    let deadline = Instant::now() + WAIT;
    let mut search = None;
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        let Ok(event) = events.recv_timeout(left.min(Duration::from_millis(250))) else {
            if search.is_some() {
                search = Some(client.search(pane, query(), 0, 10));
            }
            continue;
        };
        match event {
            ClientEvent::Refused { reason } | ClientEvent::Incompatible { reason } => {
                eprintln!("refused: {reason}");
                std::process::exit(2);
            }
            ClientEvent::Layout { .. } if search.is_none() => {
                client.subscribe(pane);
                search = Some(client.search(pane, query(), 0, 10));
            }
            ClientEvent::SearchResult { req_id, result, .. } if Some(req_id) == search => {
                if result.is_ok_and(|page| page.total > 0) {
                    println!("found");
                    return;
                }
            }
            _ => {}
        }
    }
    eprintln!("not found within {} s", WAIT.as_secs());
    std::process::exit(1);
}
