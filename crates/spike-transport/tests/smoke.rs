//! budgeted flood pane falls back to snapshots.

use std::time::Duration;

use spike_transport::client::ClientConfig;
use spike_transport::scenario::{self, Link, Scenario};
use spike_transport::server::{FloodMode, Priorities};

#[test]
fn budgeted_flood_echoes_every_key_and_sends_snapshots() {
    let scenario = Scenario {
        link: Link::Loopback,
        server: scenario::server_config(FloodMode::Budgeted, Priorities::Spec),
        client: ClientConfig {
            keys: 30,
            key_interval: Duration::from_millis(5),
            warmup: Duration::from_millis(200),
            priorities: Priorities::Spec,
        },
    };
    let outcome = scenario::run(&scenario).unwrap();
    assert_eq!(outcome.client.lost, 0);
    assert_eq!(outcome.client.latencies.len(), 30);
    assert!(
        outcome.client.snapshots > 0,
        "flood never exceeded its budget"
    );
    assert!(
        outcome.client.path.contains("direct"),
        "{}",
        outcome.client.path
    );
}
