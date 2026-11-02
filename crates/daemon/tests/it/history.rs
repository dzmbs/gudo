//! Drawing history: "done" records a version with its render, a restore brings an old
//! version back as a new one that every client converges on (open editors through the
//! ordinary Excalidraw pushes, placements with the old render), the history survives a
//! restart, and a scene exports as an `.excalidraw` file.

use std::time::Instant;

use client_core::drawing;
use client_core::proto::{
    ArtifactCreate, ArtifactError, ArtifactEvent, ArtifactId, ArtifactKind, CoordSpace,
    DaemonFeatures, ExElement, PlaceRequest,
};
use client_core::{ArtifactEventQueue, ArtifactUpdate, ClientConfig};
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TIMEOUT, TestClient, start, ticket};

fn element(id: &str, version: u64, x: f32, deleted: bool) -> ExElement {
    let json = format!(
        r##"{{"id":"{id}","type":"rectangle","x":{x},"y":0,"width":120,"height":60,"strokeColor":"#1e1e1e","backgroundColor":"transparent","strokeWidth":2,"opacity":100,"version":{version},"versionNonce":7,"isDeleted":{deleted}}}"##
    );
    drawing::parse_element(&json).unwrap()
}

fn png(shade: u8) -> Vec<u8> {
    drawing::encode_png(&drawing::Rgba {
        width: 4,
        height: 2,
        data: vec![shade; 4 * 2 * 4],
    })
}

/// Live elements of a cached scene as `(id, x)`, sorted.
fn live(client: &TestClient, id: ArtifactId) -> Vec<(String, f64)> {
    let mut elements: Vec<(String, f64)> = client
        .client
        .excalidraw_scene(id)
        .map(|scene| scene.changed_since(0))
        .unwrap_or_default()
        .into_iter()
        .filter(|element| !element.deleted)
        .map(|element| {
            let json: serde_json::Value = serde_json::from_str(&element.json).unwrap();
            (element.id, json["x"].as_f64().unwrap())
        })
        .collect();
    elements.sort_by(|a, b| a.0.cmp(&b.0));
    elements
}

async fn wait(
    updates: &mut UnboundedReceiver<ArtifactUpdate>,
    what: &str,
    matches: impl Fn(&ArtifactEvent) -> bool,
) {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "timed out waiting for {what}");
        match tokio::time::timeout(left, updates.recv()).await {
            Ok(Some(ArtifactUpdate::Event(event))) if matches(&event) => return,
            Ok(Some(_)) => {}
            _ => panic!("timed out waiting for {what}"),
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn finished_versions_restore_for_everyone_and_survive_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut laptop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = laptop.attach_and_follow().await;
    let session = laptop.layout.as_ref().unwrap().session_id;
    assert!(
        laptop
            .client
            .daemon_info()
            .unwrap()
            .features
            .contains(DaemonFeatures::ARTIFACT_HISTORY)
    );
    let mut tablet = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let (listener, mut tablet_updates) = ArtifactEventQueue::channel();
    tablet.client.set_artifact_listener(listener);
    tablet.client.attach(None);
    tablet
        .until("b layout", |client| client.layout.is_some())
        .await;

    let info = laptop
        .client
        .artifact_create(ArtifactCreate {
            session_id: session,
            kind: ArtifactKind::Excalidraw,
            title: "overlay".into(),
            space: CoordSpace::Canvas,
            anchor: None,
            image: None,
            ops: Vec::new(),
        })
        .await
        .unwrap();
    let id = info.artifact_id;
    assert!(laptop.client.artifact_history(id).await.unwrap().is_empty());

    // First "done": two boxes, placed with this device's render.
    laptop
        .client
        .excalidraw_put(
            id,
            vec![element("r1", 1, 0.0, false), element("r2", 1, 200.0, false)],
            None,
            vec![],
        )
        .await
        .unwrap();
    let place = |replace| PlaceRequest {
        pane_id: pane,
        artifact_id: id,
        version: None,
        anchor: None,
        col: 0,
        cols: 0,
        rows: 0,
        png: None,
        replace,
    };
    let first = laptop
        .client
        .place_png(place(None), png(0x40))
        .await
        .unwrap();

    // Edited again: r1 moves, r2 is deleted, r3 is added; "done" replaces the placement.
    laptop
        .client
        .excalidraw_put(
            id,
            vec![
                element("r1", 2, 50.0, false),
                element("r2", 2, 200.0, true),
                element("r3", 1, 400.0, false),
            ],
            None,
            vec![],
        )
        .await
        .unwrap();
    let second = laptop
        .client
        .place_png(place(Some(first.placement_id)), png(0xc0))
        .await
        .unwrap();
    let history = laptop.client.artifact_history(id).await.unwrap();
    let versions: Vec<u64> = history.iter().map(|entry| entry.version).collect();
    assert_eq!(versions, [second.version, first.version], "newest first");
    assert_eq!(history[0].image, Some(second.image));
    assert_eq!(history[1].image, Some(first.image));
    assert_eq!((history[0].elements, history[1].elements), (2, 2));

    // b has the scene open (its cache follows pushes).
    tablet.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(
        live(&tablet, id),
        [("r1".into(), 50.0), ("r3".into(), 400.0)]
    );

    // Restore the first version: a new version on top that everyone converges on.
    let (now, entry) = laptop
        .client
        .artifact_restore(id, first.version)
        .await
        .unwrap();
    assert!(now.version > second.version);
    assert_eq!(entry.version, now.version);
    assert_eq!(entry.restored_from, Some(first.version));
    assert_eq!(
        entry.image,
        Some(first.image),
        "the old render shows the same content"
    );
    let back = [("r1".to_owned(), 0.0), ("r2".to_owned(), 200.0)];
    wait(&mut tablet_updates, "the restored elements on b", |event| {
        matches!(event, ArtifactEvent::Excalidraw { artifact_id, version, .. } if *artifact_id == id && *version == now.version)
    })
    .await;
    assert_eq!(live(&tablet, id), back);
    let daemon_scene = laptop.client.excalidraw_get(id, 0).await.unwrap();
    let daemon_live = daemon_scene
        .elements
        .iter()
        .filter(|element| !element.deleted)
        .count();
    assert_eq!(daemon_live, 2);
    wait(&mut tablet_updates, "the placement showing the old render", |event| {
        matches!(event, ArtifactEvent::Placed(placement) if placement.placement_id == second.placement_id && placement.image == first.image)
    })
    .await;
    let history = laptop.client.artifact_history(id).await.unwrap();
    assert_eq!(history.len(), 3);
    assert_eq!(history[0].restored_from, Some(first.version));

    // A version that was never recorded.
    let result = laptop.client.artifact_restore(id, 999).await;
    assert!(
        matches!(result, Err(ArtifactError::NotFound(_))),
        "{result:?}"
    );

    // The scene as an `.excalidraw` file: what Excalidraw opens and a drop imports.
    let file = laptop.client.excalidraw_file(id).await.unwrap();
    let parsed = drawing::parse_file(&file).unwrap();
    let mut ids: Vec<&str> = parsed
        .elements
        .iter()
        .map(|element| element.id.as_str())
        .collect();
    ids.sort_unstable();
    assert_eq!(ids, ["r1", "r2"]);

    drop((laptop, tablet));
    daemon.shutdown().await;

    // The history is kept across a restart.
    let daemon = start(dir.path()).await;
    let mut laptop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    laptop.client.attach(None);
    laptop
        .until("layout", |client| client.layout.is_some())
        .await;
    let after = laptop.client.artifact_history(id).await.unwrap();
    assert_eq!(after, history);
    drop(laptop);
    daemon.shutdown().await;
}
