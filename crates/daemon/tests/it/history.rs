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
fn live(c: &TestClient, id: ArtifactId) -> Vec<(String, f64)> {
    let mut out: Vec<(String, f64)> = c
        .client
        .excalidraw_scene(id)
        .map(|s| s.changed_since(0))
        .unwrap_or_default()
        .into_iter()
        .filter(|e| !e.deleted)
        .map(|e| {
            let v: serde_json::Value = serde_json::from_str(&e.json).unwrap();
            (e.id, v["x"].as_f64().unwrap())
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

async fn wait(
    updates: &mut UnboundedReceiver<ArtifactUpdate>,
    what: &str,
    pred: impl Fn(&ArtifactEvent) -> bool,
) {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "timed out waiting for {what}");
        match tokio::time::timeout(left, updates.recv()).await {
            Ok(Some(ArtifactUpdate::Event(e))) if pred(&e) => return,
            Ok(Some(_)) => {}
            _ => panic!("timed out waiting for {what}"),
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn finished_versions_restore_for_everyone_and_survive_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut a = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = a.attach_and_follow().await;
    let session = a.layout.as_ref().unwrap().session_id;
    assert!(
        a.client
            .daemon_info()
            .unwrap()
            .features
            .contains(DaemonFeatures::ARTIFACT_HISTORY)
    );
    let mut b = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let (listener, mut b_updates) = ArtifactEventQueue::channel();
    b.client.set_artifact_listener(listener);
    b.client.attach(None);
    b.until("b layout", |c| c.layout.is_some()).await;

    let info = a
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
    assert!(a.client.artifact_history(id).await.unwrap().is_empty());

    // First "done": two boxes, placed with this device's render.
    a.client
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
    let first = a.client.place_png(place(None), png(0x40)).await.unwrap();

    // Edited again: r1 moves, r2 is deleted, r3 is added; "done" replaces the placement.
    a.client
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
    let second = a
        .client
        .place_png(place(Some(first.placement_id)), png(0xc0))
        .await
        .unwrap();
    let history = a.client.artifact_history(id).await.unwrap();
    let versions: Vec<u64> = history.iter().map(|v| v.version).collect();
    assert_eq!(versions, [second.version, first.version], "newest first");
    assert_eq!(history[0].image, Some(second.image));
    assert_eq!(history[1].image, Some(first.image));
    assert_eq!((history[0].elements, history[1].elements), (2, 2));

    // b has the scene open (its cache follows pushes).
    b.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(live(&b, id), [("r1".into(), 50.0), ("r3".into(), 400.0)]);

    // Restore the first version: a new version on top that everyone converges on.
    let (now, entry) = a.client.artifact_restore(id, first.version).await.unwrap();
    assert!(now.version > second.version);
    assert_eq!(entry.version, now.version);
    assert_eq!(entry.restored_from, Some(first.version));
    assert_eq!(
        entry.image,
        Some(first.image),
        "the old render shows the same content"
    );
    let back = [("r1".to_owned(), 0.0), ("r2".to_owned(), 200.0)];
    wait(&mut b_updates, "the restored elements on b", |e| {
        matches!(e, ArtifactEvent::Excalidraw { artifact_id, version, .. } if *artifact_id == id && *version == now.version)
    })
    .await;
    assert_eq!(live(&b, id), back);
    let daemon_scene = a.client.excalidraw_get(id, 0).await.unwrap();
    let daemon_live = daemon_scene.elements.iter().filter(|e| !e.deleted).count();
    assert_eq!(daemon_live, 2);
    wait(&mut b_updates, "the placement showing the old render", |e| {
        matches!(e, ArtifactEvent::Placed(p) if p.placement_id == second.placement_id && p.image == first.image)
    })
    .await;
    let history = a.client.artifact_history(id).await.unwrap();
    assert_eq!(history.len(), 3);
    assert_eq!(history[0].restored_from, Some(first.version));

    // A version that was never recorded.
    let r = a.client.artifact_restore(id, 999).await;
    assert!(matches!(r, Err(ArtifactError::NotFound(_))), "{r:?}");

    // The scene as an `.excalidraw` file: what Excalidraw opens and a drop imports.
    let file = a.client.excalidraw_file(id).await.unwrap();
    let parsed = drawing::parse_file(&file).unwrap();
    let mut ids: Vec<&str> = parsed.elements.iter().map(|e| e.id.as_str()).collect();
    ids.sort_unstable();
    assert_eq!(ids, ["r1", "r2"]);

    drop((a, b));
    daemon.shutdown().await;

    // The history is kept across a restart.
    let daemon = start(dir.path()).await;
    let mut a = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    a.client.attach(None);
    a.until("layout", |c| c.layout.is_some()).await;
    let after = a.client.artifact_history(id).await.unwrap();
    assert_eq!(after, history);
    drop(a);
    daemon.shutdown().await;
}
