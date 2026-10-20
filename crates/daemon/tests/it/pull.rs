//! The MCP pull channel on the hook socket (docs/DAEMON.md §7.12): a pane's agent lists and
//! exports its session's drawings, and nothing of another session.

use std::path::Path;

use client_core::ClientConfig;
use client_core::drawing;
use client_core::proto::{
    ArtifactCreate, ArtifactKind, CoordSpace, DrawOp, Element, ElementId, ElementKind, LayoutOp,
    OpOutcome, PaneLaunch, Pt, SessionId, ShapeKind, Style,
};
use daemon::{PULL_VERSION, PullCall, PullOp, PullReply};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start, ticket};

async fn pull(socket: &Path, token: &str, pane: impl ToString, op: PullOp) -> PullReply {
    let call = PullCall {
        v: PULL_VERSION,
        token: token.into(),
        pane: pane.to_string(),
        pull: op,
    };
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(&call).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
}

fn get(id: Option<u64>, format: &str) -> PullOp {
    PullOp::Get {
        id,
        format: Some(format.into()),
        version: None,
    }
}

fn boxed(session: SessionId, title: &str) -> ArtifactCreate {
    ArtifactCreate {
        session_id: session,
        kind: ArtifactKind::Drawing,
        title: title.into(),
        space: CoordSpace::Canvas,
        anchor: None,
        image: None,
        ops: vec![DrawOp::Add(Element {
            id: ElementId(1),
            z: 0,
            style: Style {
                color: 0x2233_44ff,
                width: 2.0,
            },
            kind: ElementKind::Shape {
                shape: ShapeKind::Rect,
                from: Pt { x: 10.0, y: 10.0 },
                to: Pt { x: 120.0, y: 60.0 },
                filled: false,
            },
        })],
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn agents_pull_their_sessions_drawings_and_nothing_else() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let socket = daemon.hook_socket().to_owned();
    let token = std::fs::read_to_string(dir.path().join("hook.token")).unwrap();
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = c.attach_and_follow().await;
    let session = c.layout.as_ref().unwrap().session_id;

    // Nothing yet.
    let PullReply::List { artifacts, .. } = pull(&socket, &token, pane.0, PullOp::List).await
    else {
        panic!("list failed")
    };
    assert!(artifacts.is_empty());
    assert_eq!(
        pull(&socket, &token, pane.0, get(None, "png")).await,
        PullReply::Error("no drawings in this session".into())
    );

    let old = c
        .client
        .artifact_create(boxed(session, "old"))
        .await
        .unwrap();
    let png = drawing::encode_png(&drawing::Rgba {
        width: 4,
        height: 3,
        data: vec![90; 48],
    });
    let image = c.client.blob_upload(session, png.clone()).await.unwrap();
    let photo = c
        .client
        .artifact_create(ArtifactCreate {
            session_id: session,
            kind: ArtifactKind::Image,
            title: "photo".into(),
            space: CoordSpace::Canvas,
            anchor: None,
            image: Some(image.hash),
            ops: vec![],
        })
        .await
        .unwrap();
    let arch = c
        .client
        .artifact_create(boxed(session, "arch"))
        .await
        .unwrap();

    // Another session's drawing.
    let OpOutcome::SessionCreated {
        session_id: other,
        pane_id: other_pane,
        ..
    } = c
        .op(LayoutOp::CreateSession {
            name: "other".into(),
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("session not created")
    };
    let secret = c
        .client
        .artifact_create(boxed(other, "secret"))
        .await
        .unwrap();

    let PullReply::List {
        session: listed,
        artifacts,
    } = pull(&socket, &token, pane.0, PullOp::List).await
    else {
        panic!("list failed")
    };
    assert_eq!(listed, session.0);
    let ids: Vec<u64> = artifacts.iter().map(|a| a.id).collect();
    assert_eq!(ids.len(), 3, "{artifacts:?}");
    assert_eq!(ids[0], arch.artifact_id.0, "newest first");
    assert!(ids.contains(&old.artifact_id.0) && ids.contains(&photo.artifact_id.0));
    assert!(!ids.contains(&secret.artifact_id.0));
    let p = artifacts.iter().find(|a| a.kind == "image").unwrap();
    assert_eq!((p.width, p.height), (Some(4), Some(3)));
    assert_eq!(artifacts[0].elements, 1);

    // The newest drawing by default, as a PNG the daemon rasterises.
    let PullReply::Export(e) = pull(&socket, &token, pane.0, get(None, "png")).await else {
        panic!("png export failed")
    };
    assert_eq!((e.id, e.title.as_str()), (arch.artifact_id.0, "arch"));
    assert_eq!((e.mime.as_str(), e.base64), ("image/png", true));
    let bytes = data_encoding::BASE64.decode(e.data.as_bytes()).unwrap();
    assert!(bytes.starts_with(b"\x89PNG"));

    let PullReply::Export(e) = pull(
        &socket,
        &token,
        pane.0,
        get(Some(arch.artifact_id.0), "svg"),
    )
    .await
    else {
        panic!("svg export failed")
    };
    assert!(e.data.contains("<svg") && !e.base64, "{}", e.data);
    let PullReply::Export(e) = pull(
        &socket,
        &token,
        pane.0,
        get(Some(arch.artifact_id.0), "ascii"),
    )
    .await
    else {
        panic!("ascii export failed")
    };
    assert!(e.data.contains('┌'), "{}", e.data);
    let PullReply::Export(e) = pull(
        &socket,
        &token,
        pane.0,
        get(Some(photo.artifact_id.0), "png"),
    )
    .await
    else {
        panic!("image export failed")
    };
    assert_eq!(
        data_encoding::BASE64.decode(e.data.as_bytes()).unwrap(),
        png
    );

    // Refusals carry no data.
    let refused = |r: PullReply| matches!(r, PullReply::Error(_));
    assert!(refused(
        pull(
            &socket,
            &token,
            pane.0,
            get(Some(secret.artifact_id.0), "png")
        )
        .await
    ));
    assert!(refused(pull(&socket, "wrong", pane.0, PullOp::List).await));
    assert!(refused(pull(&socket, &token, 9999, PullOp::List).await));
    assert!(refused(pull(&socket, &token, "x", PullOp::List).await));
    assert!(refused(
        pull(&socket, &token, pane.0, get(None, "gif")).await
    ));

    // The other session's pane sees only its own.
    let PullReply::List { artifacts, .. } = pull(&socket, &token, other_pane.0, PullOp::List).await
    else {
        panic!("list failed")
    };
    let ids: Vec<u64> = artifacts.iter().map(|a| a.id).collect();
    assert_eq!(ids, [secret.artifact_id.0]);
    daemon.shutdown().await;
}
