//! Drawings and images end to end: live ink fan-out between two clients, op-log
//! convergence and reconnect resync, roles (a viewer cannot edit), "send to agent" into a
//! fake agent pane, canvas panes, anchors, exports, and persistence across a restart.

use std::time::{Duration, Instant};

use client_core::drawing::{self, InkPoint, Scene};
use client_core::grants::GrantSpec;
use client_core::proto::{
    AnchorRequest, AnchorState, ArtifactCreate, ArtifactError, ArtifactEvent, ArtifactId,
    ArtifactKind, Axis, CoordSpace, DetachReason, DrawOp, Element, ElementId, ElementKind,
    ExportFormat, InkLive, LayoutOp, OpOutcome, PaneId, PaneLaunch, Roles, Scope, SessionId,
    Stroke, Style, Tool, UnixMillis,
};
use client_core::{ArtifactEventQueue, ArtifactUpdate, ClientConfig, MultiplayerEvent, now_millis};
use daemon::{HookRequest, HookResponse};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TIMEOUT, TestClient, start, ticket};

const SESSION_START: &str =
    include_str!("../../../agents/tests/fixtures/claude/session_start_resume.json");

struct Drawer {
    client: TestClient,
    updates: UnboundedReceiver<ArtifactUpdate>,
    seen: Vec<ArtifactUpdate>,
}

impl Drawer {
    fn new(client: TestClient) -> Self {
        let (listener, updates) = ArtifactEventQueue::channel();
        client.client.set_artifact_listener(listener);
        Self {
            client,
            updates,
            seen: Vec::new(),
        }
    }

    /// Waits for an update matching `accepts`; returns it.
    async fn wait(
        &mut self,
        what: &str,
        accepts: impl Fn(&ArtifactUpdate) -> bool,
    ) -> ArtifactUpdate {
        if let Some(update) = self.seen.iter().find(|update| accepts(update)) {
            return update.clone();
        }
        let deadline = Instant::now() + TIMEOUT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "timed out waiting for {what}");
            match tokio::time::timeout(left, self.updates.recv()).await {
                Ok(Some(update)) => {
                    self.seen.push(update.clone());
                    if accepts(&update) {
                        return update;
                    }
                }
                _ => panic!("timed out waiting for {what}"),
            }
        }
    }

    fn session(&self) -> SessionId {
        self.client.layout.as_ref().expect("attached").session_id
    }

    /// Pumps updates until the cached Excalidraw scene `id` satisfies `accepts`.
    async fn until_ex(
        &mut self,
        id: ArtifactId,
        what: &str,
        accepts: impl Fn(&drawing::ExScene) -> bool,
    ) {
        let deadline = Instant::now() + TIMEOUT;
        loop {
            if self
                .client
                .client
                .excalidraw_scene(id)
                .is_some_and(|scene| accepts(&scene))
            {
                return;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            match tokio::time::timeout(left, self.updates.recv()).await {
                Ok(Some(update)) => self.seen.push(update),
                _ => panic!("timed out waiting for {what}"),
            }
        }
    }
}

fn is_event(update: &ArtifactUpdate, accepts: impl Fn(&ArtifactEvent) -> bool) -> bool {
    matches!(update, ArtifactUpdate::Event(event) if accepts(event))
}

fn stroke(id: u64, x: f32) -> DrawOp {
    let points: Vec<InkPoint> = (0..20)
        .map(|i| InkPoint::at(x + i as f32 * 0.5, 1.0 + (i as f32 / 3.0).sin(), i * 8))
        .collect();
    DrawOp::Add(Element {
        id: ElementId(id),
        z: 0,
        style: Style {
            color: 0xff33_33ff,
            width: 0.3,
        },
        kind: ElementKind::Stroke(Stroke {
            tool: Tool::Pen,
            points: drawing::pack(&points),
        }),
    })
}

fn drawing_request(session: SessionId, space: CoordSpace, ops: Vec<DrawOp>) -> ArtifactCreate {
    ArtifactCreate {
        session_id: session,
        kind: ArtifactKind::Drawing,
        title: "sketch".into(),
        space,
        anchor: None,
        image: None,
        ops,
    }
}

fn scene_eq(left: &Scene, right: &Scene) -> bool {
    left.version == right.version && left.elements() == right.elements()
}

async fn hook(socket: &std::path::Path, request: &HookRequest) -> HookResponse {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
}

/// Marks `pane` as a Claude pane through its hook socket (its program stays what it is).
async fn make_agent(daemon: &daemon::Daemon, dir: &std::path::Path, pane: PaneId) {
    hook(
        daemon.hook_socket(),
        &HookRequest {
            v: 1,
            token: std::fs::read_to_string(dir.join("hook.token")).unwrap(),
            pane: pane.0.to_string(),
            agent: "claude".into(),
            event: "SessionStart".into(),
            seq: 1,
            payload: serde_json::from_str(SESSION_START).unwrap(),
        },
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn live_ink_fans_out_and_op_logs_converge_after_reconnect() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut device_a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let pane = device_a.client.attach_and_follow().await;
    let mut device_b = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    device_b.client.client.attach(None);
    device_b
        .client
        .until("b layout", |client| client.layout.is_some())
        .await;
    let session = device_a.session();

    // A anchors a cell-space drawing to the row just above the prompt.
    device_a.client.type_line(pane, "echo anchor-me");
    device_a.client.wait_text(pane, "anchor-me\n").await;
    let seq = device_a.client.client.pane_seq(pane).unwrap();
    // The output row, counted from the bottom row of the screen (no scrollback yet).
    let rows = usize::from(device_a.client.metas[&pane].size.rows);
    let text = device_a.client.text(pane);
    let row = text.lines().position(|l| l == "anchor-me").unwrap();
    let mut create = drawing_request(session, CoordSpace::Cells, vec![stroke(1, 2.0)]);
    create.anchor = Some(AnchorRequest {
        pane_id: pane,
        at_seq: client_core::proto::Seq(seq),
        from_bottom: (rows - 1 - row) as u64,
    });
    let info = device_a
        .client
        .client
        .artifact_create(create)
        .await
        .unwrap();
    let id = info.artifact_id;
    assert_eq!(info.version, 1);
    let anchor = info.anchor.unwrap();
    assert_eq!(anchor.state, AnchorState::Live);
    device_b
        .wait("created on b", |update| {
            is_event(
                update,
                |event| matches!(event, ArtifactEvent::Created(info) if info.artifact_id == id),
            )
        })
        .await;
    device_b.wait(
        "b synced v1",
        |update| matches!(update, ArtifactUpdate::Synced { artifact_id, version: 1 } if *artifact_id == id),
    )
    .await;

    // Live ink: A streams 200 chunks at ~120 Hz; B sees every one, in order, from A.
    let me = device_a.client.client.me().unwrap().actor;
    let mut sent_at = Vec::new();
    let mut latencies = Vec::new();
    for chunk in 0..200u32 {
        let points = [InkPoint::at(chunk as f32 * 0.1, 3.0, chunk * 8)];
        sent_at.push(Instant::now());
        device_a.client.client.ink_live(InkLive {
            artifact_id: id,
            stroke_id: ElementId(77),
            actor: me,
            chunk,
            tool: Tool::Pen,
            style: Style {
                color: 0x00ff_00ff,
                width: 0.2,
            },
            points: drawing::pack(&points),
            done: chunk == 199,
        });
        let update = device_b
            .wait("ink chunk", |update| {
                is_event(
                    update,
                    |event| matches!(event, ArtifactEvent::Ink(ink) if ink.chunk == chunk),
                )
            })
            .await;
        latencies.push(sent_at[chunk as usize].elapsed());
        if let ArtifactUpdate::Event(event) = update
            && let ArtifactEvent::Ink(ink) = *event
        {
            assert_eq!(ink.actor, me);
            assert_eq!(drawing::unpack(&ink.points).unwrap().len(), 1);
        }
        tokio::time::sleep(Duration::from_millis(8)).await;
    }
    latencies.sort();
    println!(
        "ink fan-out A→daemon→B (loopback, debug): p50 {:.2} ms, p99 {:.2} ms, max {:.2} ms",
        latencies[100].as_secs_f64() * 1e3,
        latencies[198].as_secs_f64() * 1e3,
        latencies[199].as_secs_f64() * 1e3
    );
    // The sender never gets its own ink back.
    assert!(
        !device_a
            .seen
            .iter()
            .any(|update| is_event(update, |event| matches!(event, ArtifactEvent::Ink(_))))
    );

    // Committed batches from both sides converge on both clients.
    device_a
        .client
        .client
        .artifact_apply(id, 1, vec![stroke(2, 5.0)])
        .await
        .unwrap();
    device_b
        .client
        .client
        .artifact_apply(
            id,
            2,
            vec![stroke(3, 9.0), DrawOp::Delete { id: ElementId(1) }],
        )
        .await
        .unwrap();
    let version = device_a
        .client
        .client
        .artifact_apply(
            id,
            3,
            vec![DrawOp::Move {
                id: ElementId(2),
                dx: 1.0,
                dy: 0.0,
            }],
        )
        .await
        .unwrap();
    assert_eq!(version, 4);
    for drawer in [&mut device_a, &mut device_b] {
        drawer.wait("v4", |update| {
            is_event(
                update,
                |event| matches!(event, ArtifactEvent::Changed { batch, .. } if batch.version == 4),
            )
        })
        .await;
    }
    let (_, scene_a) = device_a.client.client.artifact_scene(id).unwrap();
    let (_, scene_b) = device_b.client.client.artifact_scene(id).unwrap();
    assert!(scene_eq(&scene_a, &scene_b));
    assert_eq!(scene_a.version, 4);
    assert_eq!(scene_a.elements().len(), 2);

    // B goes away; A keeps drawing; B comes back and catches up by itself.
    device_b.client.client.suspend();
    for i in 0..3 {
        device_a
            .client
            .client
            .artifact_apply(id, 4 + i, vec![stroke(10 + i, 12.0)])
            .await
            .unwrap();
    }
    device_b.seen.clear();
    device_b.client.client.reconnect();
    device_b.wait(
        "b resynced v7",
        |update| matches!(update, ArtifactUpdate::Synced { artifact_id, version: 7 } if *artifact_id == id),
    )
    .await;
    let (_, scene_a) = device_a.client.client.artifact_scene(id).unwrap();
    let (_, scene_b) = device_b.client.client.artifact_scene(id).unwrap();
    assert!(scene_eq(&scene_a, &scene_b), "{scene_a:?}\n{scene_b:?}");
    // A full fetch agrees with the incremental cache.
    let full = device_b.client.client.artifact_get(id, 0).await.unwrap();
    assert_eq!(full.elements.as_deref(), Some(scene_a.elements()));

    // The anchor detaches when the screen and scrollback are cleared.
    device_a
        .client
        .type_line(pane, "printf '\\033[H\\033[2J\\033[3J'");
    device_b.wait("anchor detached", |update| {
        is_event(update, |event| {
            matches!(event, ArtifactEvent::Info(info) if info.artifact_id == id
                && info.anchor.is_some_and(|anchor| anchor.state == AnchorState::Detached(DetachReason::RowGone)))
        })
    })
    .await;
    drop((device_a, device_b));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn viewer_sees_but_cannot_edit_send_or_ink() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let pane = owner.client.attach_and_follow().await;
    let session = owner.session();
    let info = owner
        .client
        .client
        .artifact_create(drawing_request(
            session,
            CoordSpace::Canvas,
            vec![stroke(1, 0.0)],
        ))
        .await
        .unwrap();
    let id = info.artifact_id;

    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    spec.label = "vic".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .client
        .create_invite(spec, "owner".into())
        .await
        .unwrap();
    let mut viewer = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    viewer.client.attach(None);
    viewer
        .until("viewer layout", |client| client.layout.is_some())
        .await;
    let mut viewer = Drawer::new(viewer);

    // Seeing is fine.
    let list = viewer.client.client.artifacts(session).await.unwrap();
    assert_eq!(list.len(), 1);
    let scene = viewer.client.client.artifact_get(id, 0).await.unwrap();
    assert_eq!(scene.elements.unwrap().len(), 1);
    let (_, svg) = viewer
        .client
        .client
        .artifact_export(id, None, ExportFormat::Svg)
        .await
        .unwrap();
    assert!(String::from_utf8(svg).unwrap().starts_with("<svg"));

    // Editing, creating, deleting, sending and uploading are not.
    fn forbidden<T>(result: &Result<T, ArtifactError>) -> bool {
        matches!(result, Err(ArtifactError::Forbidden(message)) if message.contains("prompter or driver"))
    }
    let result = viewer
        .client
        .client
        .artifact_apply(id, 1, vec![stroke(2, 1.0)])
        .await;
    assert!(forbidden(&result), "{result:?}");
    let result = viewer
        .client
        .client
        .artifact_create(drawing_request(session, CoordSpace::Canvas, vec![]))
        .await;
    assert!(forbidden(&result), "{result:?}");
    let result = viewer.client.client.artifact_delete(id).await;
    assert!(forbidden(&result), "{result:?}");
    let result = viewer
        .client
        .client
        .send_to_agent(pane, Some(id), None, None)
        .await;
    assert!(forbidden(&result), "{result:?}");
    let png = drawing::encode_png(&drawing::Rgba {
        width: 1,
        height: 1,
        data: vec![0; 4],
    });
    let result = viewer.client.client.blob_upload(session, png).await;
    assert!(
        matches!(result, Err(ArtifactError::Forbidden(_))),
        "{result:?}"
    );

    // Live ink from a viewer is refused and never reaches the owner.
    viewer.client.client.ink_live(InkLive {
        artifact_id: id,
        stroke_id: ElementId(5),
        actor: viewer.client.client.me().unwrap().actor,
        chunk: 0,
        tool: Tool::Pen,
        style: Style {
            color: 0xff,
            width: 1.0,
        },
        points: drawing::pack(&[InkPoint::at(1.0, 1.0, 0)]),
        done: true,
    });
    viewer.client
        .until("ink refused", |client| {
            client.mp.iter()
                .any(|event| matches!(event, MultiplayerEvent::Forbidden { what, .. } if what == "InkLive"))
        })
        .await;
    // The owner's own edit still reaches the viewer, live.
    owner
        .client
        .client
        .artifact_apply(id, 1, vec![stroke(3, 4.0)])
        .await
        .unwrap();
    viewer
        .wait("viewer sees v2", |update| {
            is_event(
                update,
                |event| matches!(event, ArtifactEvent::Changed { batch, .. } if batch.version == 2),
            )
        })
        .await;
    assert!(
        !owner
            .seen
            .iter()
            .any(|update| is_event(update, |event| matches!(event, ArtifactEvent::Ink(_))))
    );
    assert_eq!(
        owner
            .client
            .client
            .artifact_get(id, 0)
            .await
            .unwrap()
            .info
            .version,
        2
    );
    drop((owner, viewer));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn send_to_agent_pastes_an_escaped_path_without_enter() {
    // A state directory with a space, like macOS's "Application Support".
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("Application Support");
    std::fs::create_dir_all(&dir).unwrap();
    let daemon = start(&dir).await;
    let mut owner = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let shell = owner.client.attach_and_follow().await;
    let session = owner.session();

    // The fake agent: turns on bracketed paste and shows every byte it reads (`cat -v`).
    let OpOutcome::PaneCreated { pane_id: agent } = owner
        .client
        .op(LayoutOp::Split {
            pane_id: shell,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Command {
                argv: vec![
                    "sh".into(),
                    "-c".into(),
                    "stty -echo -icanon; printf '\\033[?2004hAGENT-READY\\n'; exec cat -v".into(),
                ],
                cwd: None,
            },
        })
        .await
    else {
        panic!("split failed")
    };
    owner.client.follow(agent).await;
    owner.client.wait_text(agent, "AGENT-READY").await;
    make_agent(&daemon, &dir, agent).await;

    let info = owner
        .client
        .client
        .artifact_create(drawing_request(
            session,
            CoordSpace::Canvas,
            vec![stroke(1, 0.0), stroke(2, 8.0)],
        ))
        .await
        .unwrap();
    let id = info.artifact_id;
    let png = drawing::encode_png(&drawing::rasterize(
        &owner.client.client.artifact_scene(id).unwrap().1,
        CoordSpace::Canvas,
        drawing::RasterOptions::default(),
    ));

    // Not into a shell.
    let result = owner
        .client
        .client
        .send_to_agent(shell, Some(id), None, Some(png.clone()))
        .await;
    assert_eq!(result, Err(ArtifactError::NotAgentPane));

    let sent = owner
        .client
        .client
        .send_to_agent(agent, Some(id), None, Some(png.clone()))
        .await
        .unwrap();
    assert_eq!(sent.version, 1);
    assert!(sent.bracketed);
    assert!(
        sent.path.ends_with(&format!("/send/{id}@1.png")),
        "{}",
        sent.path
    );
    assert!(sent.path.contains("Application Support"));
    assert!(
        sent.pasted.contains(r"Application\ Support"),
        "{}",
        sent.pasted
    );
    assert_eq!(std::fs::read(&sent.path).unwrap(), png);
    // Exactly the bracketed path, and no Enter after it.
    let expect = format!("^[[200~{}^[[201~", sent.pasted);
    owner.client.wait_flat(agent, &expect).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let flat = owner.client.flat_text(agent);
    let after = &flat[flat.find(&expect).unwrap() + expect.len()..];
    assert!(!after.contains("^M") && !after.contains("^J"), "{after:?}");

    // A bare image (a photo) becomes an image artifact; the daemon's own render works too.
    let photo = drawing::encode_png(&drawing::Rgba {
        width: 2,
        height: 2,
        data: vec![9; 16],
    });
    let bare = owner
        .client
        .client
        .send_to_agent(agent, None, None, Some(photo.clone()))
        .await
        .unwrap();
    let image = owner
        .client
        .client
        .artifacts(session)
        .await
        .unwrap()
        .into_iter()
        .find(|info| info.artifact_id == bare.artifact_id)
        .unwrap();
    assert_eq!(image.kind, ArtifactKind::Image);
    assert_eq!(std::fs::read(&bare.path).unwrap(), photo);
    let rendered = owner
        .client
        .client
        .send_to_agent(agent, Some(id), None, None)
        .await
        .unwrap();
    assert_eq!(
        drawing::sniff(&std::fs::read(&rendered.path).unwrap())
            .unwrap()
            .0,
        client_core::proto::MediaType::Png
    );
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn artifacts_canvases_and_blobs_survive_a_restart_and_export() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let pane = owner.client.attach_and_follow().await;
    let session = owner.session();

    // A canvas pane splits off the terminal showing a (Pencil) drawing; `None` would make
    // an Excalidraw scene.
    let pencil = owner
        .client
        .client
        .artifact_create(drawing_request(session, CoordSpace::Canvas, vec![]))
        .await
        .unwrap();
    let OpOutcome::PaneCreated { pane_id: canvas } = owner
        .client
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Canvas {
                artifact_id: Some(pencil.artifact_id),
            },
        })
        .await
    else {
        panic!("canvas split failed")
    };
    let created = owner
        .wait("canvases", |update| {
            is_event(update, |event| matches!(event, ArtifactEvent::Canvases { canvases, .. } if canvases.iter().any(|listed| listed.pane_id == canvas)))
        })
        .await;
    let ArtifactUpdate::Event(event) = created else {
        unreachable!()
    };
    let ArtifactEvent::Canvases { canvases, .. } = *event else {
        unreachable!()
    };
    let drawing_id: ArtifactId = canvases[0].artifact_id;
    owner
        .client
        .client
        .artifact_apply(
            drawing_id,
            0,
            vec![stroke(1, 0.0), DrawOp::SetTitle("arch".into())],
        )
        .await
        .unwrap();

    // An image blob, uploaded then made an artifact; a preview PNG for the drawing.
    let photo = drawing::encode_png(&drawing::Rgba {
        width: 3,
        height: 2,
        data: vec![200; 24],
    });
    let img = owner
        .client
        .client
        .blob_upload(session, photo.clone())
        .await
        .unwrap();
    assert_eq!((img.width, img.height), (3, 2));
    let image = owner
        .client
        .client
        .artifact_create(ArtifactCreate {
            session_id: session,
            kind: ArtifactKind::Image,
            title: "photo".into(),
            space: CoordSpace::Canvas,
            anchor: None,
            image: Some(img.hash),
            ops: vec![],
        })
        .await
        .unwrap();
    let preview = drawing::encode_png(&drawing::Rgba {
        width: 4,
        height: 4,
        data: vec![50; 64],
    });
    owner
        .client
        .client
        .artifact_set_preview(drawing_id, 1, preview.clone())
        .await
        .unwrap();

    // Exports: PNG passthrough of the image and of the preview; SVG from the vectors.
    let (_, png) = owner
        .client
        .client
        .artifact_export(image.artifact_id, None, ExportFormat::Png)
        .await
        .unwrap();
    assert_eq!(png, photo);
    let (v, png) = owner
        .client
        .client
        .artifact_export(drawing_id, None, ExportFormat::Png)
        .await
        .unwrap();
    assert_eq!((v, png), (1, preview.clone()));
    let (_, svg) = owner
        .client
        .client
        .artifact_export(drawing_id, None, ExportFormat::Svg)
        .await
        .unwrap();
    let (info, scene) = owner.client.client.artifact_scene(drawing_id).unwrap();
    assert_eq!(
        String::from_utf8(svg).unwrap(),
        drawing::to_svg(&scene, info.space, "arch", &|_| None)
    );
    let (_, data) = owner.client.client.blob_download(img.hash).await.unwrap();
    assert_eq!(data, photo);
    let before = owner.client.client.artifacts(session).await.unwrap();
    drop(owner);
    daemon.shutdown().await;

    // Restart: same artifacts, versions, scenes, canvas pane and blobs.
    let daemon = start(dir.path()).await;
    let mut owner = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    owner.client.client.attach(None);
    owner
        .client
        .until("layout", |client| client.layout.is_some())
        .await;
    assert!(crate::support::leaves(&owner.client.tab().root).contains(&canvas));
    owner
        .wait("canvases after restart", |update| {
            is_event(update, |event| matches!(event, ArtifactEvent::Canvases { canvases, .. } if canvases.iter().any(|listed| listed.pane_id == canvas && listed.artifact_id == drawing_id)))
        })
        .await;
    let after = owner.client.client.artifacts(session).await.unwrap();
    assert_eq!(after.len(), before.len());
    for (old, new) in before.iter().zip(&after) {
        assert_eq!(
            (
                old.artifact_id,
                old.version,
                old.elements,
                &old.title,
                old.image,
                old.preview
            ),
            (
                new.artifact_id,
                new.version,
                new.elements,
                &new.title,
                new.image,
                new.preview
            )
        );
    }
    let scene2 = owner
        .client
        .client
        .artifact_get(drawing_id, 0)
        .await
        .unwrap();
    assert_eq!(scene2.elements.as_deref(), Some(scene.elements()));
    let (_, data) = owner.client.client.blob_download(img.hash).await.unwrap();
    assert_eq!(data, photo);

    // Closing the canvas pane keeps the drawing; deleting the image frees it.
    assert_eq!(
        owner
            .client
            .op(LayoutOp::ClosePane { pane_id: canvas })
            .await,
        OpOutcome::Done
    );
    owner
        .wait("canvas gone", |update| {
            is_event(
                update,
                |event| matches!(event, ArtifactEvent::Canvases { canvases, .. } if canvases.is_empty()),
            )
        })
        .await;
    assert!(
        owner
            .client
            .client
            .artifact_get(drawing_id, 0)
            .await
            .is_ok()
    );
    owner
        .client
        .client
        .artifact_delete(image.artifact_id)
        .await
        .unwrap();
    assert!(matches!(
        owner.client.client.artifact_get(image.artifact_id, 0).await,
        Err(ArtifactError::NotFound(_))
    ));
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn caps_refuse_oversized_blobs_and_batches() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = crate::support::start_with(dir.path(), |client| {
        client.artifacts.blob_max = 1000;
        client.artifacts.batch_max = 2000;
    })
    .await;
    let mut owner = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    owner.client.attach_and_follow().await;
    let session = owner.session();
    let big = drawing::encode_png(&drawing::Rgba {
        width: 64,
        height: 64,
        data: {
            let mut seed = 0x9e37_79b9_u32;
            (0..64 * 64 * 4)
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 17;
                    seed ^= seed << 5;
                    seed as u8
                })
                .collect()
        },
    });
    assert!(big.len() > 1000);
    let result = owner.client.client.blob_upload(session, big).await;
    assert!(
        matches!(result, Err(ArtifactError::TooLarge(_))),
        "{result:?}"
    );
    let info = owner
        .client
        .client
        .artifact_create(drawing_request(session, CoordSpace::Canvas, vec![]))
        .await
        .unwrap();
    let ops: Vec<DrawOp> = (0..50).map(|i| stroke(i, i as f32)).collect();
    let result = owner
        .client
        .client
        .artifact_apply(info.artifact_id, 0, ops)
        .await;
    assert!(
        matches!(result, Err(ArtifactError::TooLarge(_))),
        "{result:?}"
    );
    let result = owner
        .client
        .client
        .artifact_apply(
            info.artifact_id,
            0,
            vec![DrawOp::Add(Element {
                id: ElementId(1),
                z: 0,
                style: Style {
                    color: 0,
                    width: 1.0,
                },
                kind: ElementKind::Stroke(Stroke {
                    tool: Tool::Pen,
                    points: client_core::proto::PackedPoints(vec![9, 9]),
                }),
            })],
        )
        .await;
    assert!(
        matches!(result, Err(ArtifactError::Invalid(_))),
        "{result:?}"
    );
    drop(owner);
    daemon.shutdown().await;
}

fn rect_at(
    id: &str,
    version: u64,
    nonce: u32,
    x: f32,
    label: &str,
) -> client_core::proto::ExElement {
    let json = format!(
        r##"{{"id":"{id}","type":"rectangle","x":{x},"y":0,"width":120,"height":60,"strokeColor":"#1e1e1e","backgroundColor":"transparent","strokeWidth":2,"opacity":100,"version":{version},"versionNonce":{nonce},"isDeleted":false,"customData":{{"label":"{label}"}}}}"##
    );
    client_core::proto::ExElement {
        id: id.into(),
        version,
        version_nonce: nonce,
        deleted: false,
        json,
    }
}

fn ex_state(client: &TestClient, id: ArtifactId) -> Vec<client_core::proto::ExElement> {
    client
        .client
        .excalidraw_scene(id)
        .map(|scene| scene.changed_since(0))
        .unwrap_or_default()
}

fn placed(
    update: &ArtifactUpdate,
    accepts: impl Fn(&client_core::proto::Placement) -> bool,
) -> bool {
    is_event(
        update,
        |event| matches!(event, ArtifactEvent::Placed(placement) if accepts(placement)),
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn excalidraw_scenes_reconcile_between_clients_and_export() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut device_a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let shell = device_a.client.attach_and_follow().await;
    let mut device_b = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    device_b.client.client.attach(None);
    device_b
        .client
        .until("b layout", |client| client.layout.is_some())
        .await;

    // A canvas pane with no artifact gets a new Excalidraw scene.
    let OpOutcome::PaneCreated { pane_id: canvas } = device_a
        .client
        .op(LayoutOp::Split {
            pane_id: shell,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Canvas { artifact_id: None },
        })
        .await
    else {
        panic!("canvas split failed")
    };
    let update = device_b
        .wait("canvas on b", |update| {
            is_event(update, |event| matches!(event, ArtifactEvent::Canvases { canvases, .. } if canvases.iter().any(|listed| listed.pane_id == canvas)))
        })
        .await;
    let ArtifactUpdate::Event(event) = update else {
        unreachable!()
    };
    let ArtifactEvent::Canvases { canvases, .. } = *event else {
        unreachable!()
    };
    let id = canvases
        .iter()
        .find(|listed| listed.pane_id == canvas)
        .unwrap()
        .artifact_id;
    let info = device_a
        .client
        .client
        .artifact_get(id, u64::MAX)
        .await
        .unwrap()
        .info;
    assert_eq!(info.kind, ArtifactKind::Excalidraw);

    // Both edit: disjoint elements merge; the same element at the same version goes to the
    // lower versionNonce on every replica; an older version loses and comes back as the
    // winner.
    let (_, rejected) = device_a
        .client
        .client
        .excalidraw_put(
            id,
            vec![
                rect_at("box-a", 1, 50, 0.0, "a1"),
                rect_at("same", 5, 10, 200.0, "from-a"),
            ],
            None,
            vec![],
        )
        .await
        .unwrap();
    assert!(rejected.is_empty());
    let (_, rejected) = device_b
        .client
        .client
        .excalidraw_put(
            id,
            vec![
                rect_at("box-b", 1, 1, 400.0, "b1"),
                rect_at("same", 5, 3, 200.0, "from-b"),
                rect_at("box-a", 0, 0, 0.0, "stale"),
            ],
            Some(r#"{"gridSize":20}"#.into()),
            vec![],
        )
        .await
        .unwrap();
    assert_eq!(rejected, vec![rect_at("box-a", 1, 50, 0.0, "a1")]);
    device_a.wait("b's elements on a", |update| {
        is_event(update, |event| matches!(event, ArtifactEvent::Excalidraw { elements, .. } if elements.iter().any(|element| element.id == "box-b")))
    })
    .await;
    device_b.wait("a's elements on b", |update| {
        is_event(update, |event| matches!(event, ArtifactEvent::Excalidraw { elements, .. } if elements.iter().any(|element| element.id == "box-a")))
    })
    .await;
    let scene_a = ex_state(&device_a.client, id);
    assert_eq!(scene_a, ex_state(&device_b.client, id));
    assert_eq!(scene_a.len(), 3);
    assert!(
        scene_a
            .iter()
            .any(|element| element.id == "same" && element.json.contains("from-b"))
    );
    let full = device_a.client.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(full.elements, scene_a);
    assert_eq!(full.app_state.as_deref(), Some(r#"{"gridSize":20}"#));

    // B away, A edits and deletes, B back: caught up.
    device_b.client.client.suspend();
    let mut gone = rect_at("box-b", 2, 9, 400.0, "b1");
    gone.deleted = true;
    gone.json = gone
        .json
        .replace(r#""isDeleted":false"#, r#""isDeleted":true"#);
    device_a
        .client
        .client
        .excalidraw_put(
            id,
            vec![rect_at("box-a", 2, 7, 10.0, "a2"), gone],
            None,
            vec![],
        )
        .await
        .unwrap();
    let rev = device_a
        .client
        .client
        .excalidraw_scene(id)
        .unwrap()
        .revision;
    device_b.seen.clear();
    device_b.client.client.reconnect();
    device_b.wait("b resynced", |update| {
        matches!(update, ArtifactUpdate::Synced { artifact_id, version } if *artifact_id == id && *version == rev)
    })
    .await;
    assert_eq!(
        ex_state(&device_a.client, id),
        ex_state(&device_b.client, id)
    );
    assert_eq!(
        device_b.client.client.excalidraw_scene(id).unwrap().live(),
        2
    );

    // Exports: ASCII box glyphs, SVG, PNG (the daemon's render).
    let (_, ascii) = device_b
        .client
        .client
        .artifact_export(id, None, ExportFormat::Ascii)
        .await
        .unwrap();
    let ascii = String::from_utf8(ascii).unwrap();
    assert!(ascii.contains('┌') && ascii.contains('┘'), "{ascii}");
    let (_, svg) = device_b
        .client
        .client
        .artifact_export(id, None, ExportFormat::Svg)
        .await
        .unwrap();
    assert_eq!(String::from_utf8(svg).unwrap().matches("<rect").count(), 2);
    let (_, png) = device_b
        .client
        .client
        .artifact_export(id, None, ExportFormat::Png)
        .await
        .unwrap();
    assert_eq!(
        drawing::sniff(&png).unwrap().0,
        client_core::proto::MediaType::Png
    );

    // A viewer may read the scene but not change it, place it or import.
    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = device_a
        .client
        .client
        .create_invite(spec, "owner".into())
        .await
        .unwrap();
    let mut viewer = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    viewer.client.attach(None);
    viewer
        .until("viewer layout", |client| client.layout.is_some())
        .await;
    assert_eq!(
        viewer
            .client
            .excalidraw_get(id, 0)
            .await
            .unwrap()
            .elements
            .len(),
        3
    );
    let result = viewer
        .client
        .excalidraw_put(id, vec![rect_at("v", 1, 1, 0.0, "v")], None, vec![])
        .await;
    assert!(
        matches!(result, Err(ArtifactError::Forbidden(_))),
        "{result:?}"
    );
    let result = viewer
        .client
        .import_to_pane(shell, "x.excalidraw".into(), b"{}".to_vec())
        .await;
    assert!(
        matches!(result, Err(ArtifactError::Forbidden(_))),
        "{result:?}"
    );
    drop((device_a, device_b, viewer));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn inline_placements_follow_output_and_survive_reattach() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut device_a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let pane = device_a.client.attach_and_follow().await;
    let session = device_a.session();
    device_a.client.type_line(pane, "echo before-the-sketch");
    device_a.client.wait_text(pane, "before-the-sketch\n").await;

    // "Done" on the overlay: the drawing goes inline at the cursor row.
    let sketch = device_a
        .client
        .client
        .artifact_create(drawing_request(
            session,
            CoordSpace::Cells,
            vec![stroke(1, 1.0)],
        ))
        .await
        .unwrap();
    let place = |replace| client_core::proto::PlaceRequest {
        pane_id: pane,
        artifact_id: sketch.artifact_id,
        version: None,
        anchor: None,
        col: 2,
        cols: 0,
        rows: 0,
        png: None,
        replace,
    };
    let first_placement = device_a.client.client.place(place(None)).await.unwrap();
    assert_eq!(first_placement.anchor.state, AnchorState::Live);
    assert_eq!(first_placement.col, 2);
    assert!(first_placement.cols >= 1 && first_placement.rows >= 1);
    let start_from_bottom = first_placement.anchor.from_bottom;

    // More output scrolls it up; the placement stays on its row.
    device_a.client.type_line(
        pane,
        "i=0; while [ $i -lt 40 ]; do echo line-$i; i=$((i+1)); done",
    );
    device_a.client.wait_text(pane, "line-39").await;
    let list = device_a.client.client.list_placements(pane).await.unwrap();
    let now = list
        .iter()
        .find(|placement| placement.placement_id == first_placement.placement_id)
        .unwrap();
    assert_eq!(now.anchor.state, AnchorState::Live);
    assert!(
        // 40 lines and two prompts below it (the screen had room for some at first).
        now.anchor.from_bottom > start_from_bottom && now.anchor.from_bottom >= 40,
        "{start_from_bottom} → {}",
        now.anchor.from_bottom
    );

    // A client attaching later (a new device, a resume after a snapshot) gets it too.
    let mut late = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    late.client.client.attach(None);
    late.wait("placement on attach", |update| {
        placed(update, |placement| {
            placement.placement_id == first_placement.placement_id
        })
    })
    .await;
    assert_eq!(late.client.client.placements(pane).len(), 1);

    // Re-opened and edited in place: the new version replaces the old placement.
    device_a
        .client
        .client
        .artifact_apply(sketch.artifact_id, 1, vec![stroke(2, 3.0)])
        .await
        .unwrap();
    let second_placement = device_a
        .client
        .client
        .place(place(Some(first_placement.placement_id)))
        .await
        .unwrap();
    assert_eq!(second_placement.version, 2);
    late.wait("unplaced old", |update| {
        is_event(update, |event| matches!(event, ArtifactEvent::Unplaced { placement_id, .. } if *placement_id == first_placement.placement_id))
    })
    .await;
    late.wait("placed new", |update| {
        placed(update, |placement| {
            placement.placement_id == second_placement.placement_id
        })
    })
    .await;

    let png = drawing::encode_png(&drawing::Rgba {
        width: 36,
        height: 36,
        data: vec![120; 36 * 36 * 4],
    });
    // A dropped .excalidraw file becomes an inline diagram; so does a dropped photo.
    let flow = include_bytes!("../../../drawing/tests/fixtures/flow.excalidraw");
    let imported = device_a
        .client
        .client
        .import_to_pane(pane, "flow.excalidraw".into(), flow.to_vec())
        .await
        .unwrap();
    let (_, ascii) = device_a
        .client
        .client
        .artifact_export(imported.artifact_id, None, ExportFormat::Ascii)
        .await
        .unwrap();
    let ascii = String::from_utf8(ascii).unwrap();
    assert!(ascii.contains("daemon") && ascii.contains('▶'), "{ascii}");
    let photo = device_a
        .client
        .client
        .import_to_pane(pane, "photo.png".into(), png.clone())
        .await
        .unwrap();
    assert_eq!(photo.image.width, 36);
    let screenshot = drawing::encode_png(&drawing::Rgba {
        width: 600,
        height: 600,
        data: vec![120; 600 * 600 * 4],
    });
    let preview = device_a
        .client
        .client
        .import_to_pane(pane, "screenshot.png".into(), screenshot)
        .await
        .unwrap();
    let grid = device_a.client.metas[&pane].size;
    assert!(preview.cols <= (grid.cols / 3).max(1));
    assert!(preview.rows <= (grid.rows / 3).max(1));
    let kinds: Vec<ArtifactKind> = device_a
        .client
        .client
        .artifacts(session)
        .await
        .unwrap()
        .iter()
        .map(|info| info.kind)
        .collect();
    assert!(kinds.contains(&ArtifactKind::Image));

    // Clearing the screen and scrollback detaches what was placed on the cleared rows.
    device_a
        .client
        .type_line(pane, "printf '\\033[H\\033[2J\\033[3J'");
    late.wait("placement detached", |update| {
        placed(update, |placement| {
            placement.placement_id == second_placement.placement_id
                && placement.anchor.state == AnchorState::Detached(DetachReason::RowGone)
        })
    })
    .await;

    // Removing a placement tells everyone.
    device_a
        .client
        .client
        .unplace(photo.placement_id)
        .await
        .unwrap();
    late.wait("unplaced photo", |update| {
        is_event(update, |event| matches!(event, ArtifactEvent::Unplaced { placement_id, .. } if *placement_id == photo.placement_id))
    })
    .await;
    let before = device_a
        .client
        .client
        .list_placements(pane)
        .await
        .unwrap()
        .len();
    drop((device_a, late));
    daemon.shutdown().await;

    // After a restart the placements are kept, detached (the terminal state is gone), and
    // the Excalidraw scene is intact.
    let daemon = start(dir.path()).await;
    let mut device_a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    device_a.client.client.attach(None);
    device_a
        .client
        .until("layout", |client| client.layout.is_some())
        .await;
    let after = device_a.client.client.list_placements(pane).await.unwrap();
    assert_eq!(after.len(), before);
    assert!(
        after
            .iter()
            .all(|placement| placement.anchor.state != AnchorState::Live)
    );
    let scene = device_a
        .client
        .client
        .excalidraw_get(imported.artifact_id, 0)
        .await
        .unwrap();
    assert_eq!(scene.elements.len(), 9);
    drop(device_a);
    daemon.shutdown().await;
}

/// An Excalidraw element as the editor emits it: the common fields plus `extra`.
fn ex_element(
    id: &str,
    kind: &str,
    version: u64,
    nonce: u32,
    extra: serde_json::Value,
) -> client_core::proto::ExElement {
    let mut json = serde_json::json!({
        "id": id, "type": kind, "x": 120.5, "y": 80.0, "width": 240.0, "height": 120.0,
        "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
        "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1,
        "opacity": 100, "groupIds": [], "frameId": null, "roundness": {"type": 3},
        "seed": 1_968_410_350u32, "version": version, "versionNonce": nonce,
        "isDeleted": false, "boundElements": null, "updated": 1_729_000_000_000u64,
        "link": null, "locked": false,
    });
    let fields = json.as_object_mut().unwrap();
    fields.extend(extra.as_object().unwrap().clone());
    drawing::parse_element(&json.to_string()).unwrap()
}

fn ex_rect(id: &str, version: u64, nonce: u32, label: &str) -> client_core::proto::ExElement {
    ex_element(
        id,
        "rectangle",
        version,
        nonce,
        serde_json::json!({"customData": {"label": label}}),
    )
}

/// A Pencil / finger stroke: `n` points with pressures.
fn ex_freedraw(id: &str, version: u64, nonce: u32, n: usize) -> client_core::proto::ExElement {
    let points: Vec<[f32; 2]> = (0..n)
        .map(|i| [i as f32 * 1.5, (i as f32 / 4.0).sin() * 12.0])
        .collect();
    let pressures: Vec<f32> = (0..n).map(|i| 0.3 + (i % 7) as f32 * 0.05).collect();
    ex_element(
        id,
        "freedraw",
        version,
        nonce,
        serde_json::json!({
            "roundness": null, "points": points, "pressures": pressures,
            "simulatePressure": false, "lastCommittedPoint": points.last(),
        }),
    )
}

fn ex_text(id: &str, version: u64, nonce: u32, text: &str) -> client_core::proto::ExElement {
    ex_element(
        id,
        "text",
        version,
        nonce,
        serde_json::json!({
            "roundness": null, "text": text, "originalText": text, "fontSize": 20,
            "fontFamily": 5, "textAlign": "left", "verticalAlign": "top", "containerId": null,
            "autoResize": true, "lineHeight": 1.25,
        }),
    )
}

/// `element` as a tombstone (Excalidraw keeps deleted elements with `isDeleted`).
fn ex_deleted(mut element: client_core::proto::ExElement) -> client_core::proto::ExElement {
    element.json = element
        .json
        .replace(r#""isDeleted":false"#, r#""isDeleted":true"#);
    element.deleted = true;
    element
}

/// The element `id` of a cached scene.
fn ex_find(scene: &drawing::ExScene, id: &str) -> Option<client_core::proto::ExElement> {
    scene
        .with_revisions()
        .find(|(element, _)| element.id == id)
        .map(|(element, _)| element.clone())
}

/// The canvas panes of the last `Canvases` push a drawer has seen.
fn last_canvases(drawer: &Drawer) -> Option<Vec<client_core::proto::CanvasPane>> {
    drawer.seen.iter().rev().find_map(|update| match update {
        ArtifactUpdate::Event(event) => match &**event {
            ArtifactEvent::Canvases { canvases, .. } => Some(canvases.clone()),
            _ => None,
        },
        ArtifactUpdate::Synced { .. } => None,
    })
}

/// Waits for a `Canvases` push that shows `pane` with `artifact`, or (`None`) without it.
async fn wait_canvas(drawer: &mut Drawer, what: &str, pane: PaneId, artifact: Option<ArtifactId>) {
    drawer.wait(what, |update| {
        is_event(update, |event| {
            matches!(event, ArtifactEvent::Canvases { canvases, .. }
                if canvases.iter().find(|listed| listed.pane_id == pane).map(|listed| listed.artifact_id) == artifact)
        })
    })
    .await;
}

fn all_leaves(client: &TestClient) -> Vec<PaneId> {
    client
        .layout
        .as_ref()
        .map(|layout| {
            layout
                .tabs
                .iter()
                .flat_map(|tab| crate::support::leaves(&tab.root))
                .collect()
        })
        .unwrap_or_default()
}

fn percentiles(mut latencies: Vec<Duration>) -> String {
    latencies.sort();
    let percentile = |fraction: f64| {
        latencies[((latencies.len() - 1) as f64 * fraction).round() as usize].as_secs_f64() * 1e3
    };
    format!(
        "p50 {:.2} ms, p99 {:.2} ms, max {:.2} ms (n={})",
        percentile(0.5),
        percentile(0.99),
        percentile(1.0),
        latencies.len()
    )
}

/// A canvas pane shared by the owner's two devices, a driver guest and a viewer.
#[tokio::test(flavor = "multi_thread")]
async fn canvas_pane_with_peers_syncs_inks_resyncs_and_closes() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    // A: the owner's Mac; B: the owner's iPad (a second paired device).
    let mut device_a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let shell = device_a.client.attach_and_follow().await;
    let session = device_a.session();
    let mut device_b = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    device_b.client.client.attach(None);
    device_b
        .client
        .until("b layout", |client| client.layout.is_some())
        .await;

    // A splits a canvas pane off the shell: the daemon makes an Excalidraw scene and both
    // devices learn which leaf it is.
    let OpOutcome::PaneCreated { pane_id: canvas } = device_a
        .client
        .op(LayoutOp::Split {
            pane_id: shell,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Canvas { artifact_id: None },
        })
        .await
    else {
        panic!("canvas split failed")
    };
    for drawer in [&mut device_a, &mut device_b] {
        drawer.wait("canvas created", |update| {
            is_event(
                update,
                |event| matches!(event, ArtifactEvent::Canvases { canvases, .. } if canvases.iter().any(|listed| listed.pane_id == canvas)),
            )
        })
        .await;
    }
    let id = device_a
        .client
        .client
        .canvas_panes(session)
        .iter()
        .find(|listed| listed.pane_id == canvas)
        .expect("canvas on a")
        .artifact_id;
    assert_eq!(
        device_a.client.client.canvas_panes(session),
        device_b.client.client.canvas_panes(session)
    );
    device_b
        .client
        .until("canvas leaf on b", |client| {
            all_leaves(client).contains(&canvas)
        })
        .await;
    let info = device_b
        .client
        .client
        .artifact_get(id, u64::MAX)
        .await
        .unwrap()
        .info;
    assert_eq!(info.kind, ArtifactKind::Excalidraw);
    assert_eq!(info.canvas_panes, vec![canvas]);

    // A driver guest joins and attaches later: the canvas list comes with the attach.
    let mut spec = GrantSpec::new(Roles::DRIVER, Scope::Daemon);
    spec.label = "dee".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = device_a
        .client
        .client
        .create_invite(spec, "owner".into())
        .await
        .unwrap();
    let mut driver = Drawer::new(TestClient::join(
        &invite.to_string(),
        ClientConfig::generate_key(),
    ));
    driver.client.client.attach(None);
    driver
        .client
        .until("driver layout", |client| client.layout.is_some())
        .await;
    wait_canvas(&mut driver, "canvases on attach", canvas, Some(id)).await;

    // A draws a box, a pressure stroke and a label; B gets each put live.
    let mut latencies = Vec::new();
    let first = [
        ex_rect("box", 1, 1_000, "a1"),
        ex_freedraw("ink", 1, 2_000, 40),
        ex_text("label", 1, 3_000, "auth service"),
    ];
    for element in &first {
        let sent = Instant::now();
        let (_, rejected) = device_a
            .client
            .client
            .excalidraw_put(id, vec![element.clone()], None, vec![])
            .await
            .unwrap();
        assert!(rejected.is_empty());
        device_b
            .until_ex(id, "a's element on b", |scene| {
                ex_find(scene, &element.id).as_ref() == Some(element)
            })
            .await;
        latencies.push(sent.elapsed());
    }
    // The stroke grows as the editor reports it (a put per ~50 ms onChange in the app).
    for version in 2..=40u64 {
        let element = ex_freedraw(
            "ink",
            version,
            2_000 + version as u32,
            40 + version as usize * 4,
        );
        let sent = Instant::now();
        device_a
            .client
            .client
            .excalidraw_put(id, vec![element], None, vec![])
            .await
            .unwrap();
        device_b
            .until_ex(id, "stroke growth on b", |scene| {
                ex_find(scene, "ink").is_some_and(|element| element.version == version)
            })
            .await;
        latencies.push(sent.elapsed());
    }
    println!(
        "canvas put A→daemon→B push (loopback, debug): {}",
        percentiles(latencies)
    );
    let full = device_a.client.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(full.elements, ex_state(&device_a.client, id));
    assert_eq!(full.elements, ex_state(&device_b.client, id));
    assert_eq!(full.info.elements, 3);

    // B moves A's box (a higher version) and adds its own; the driver adds a note.
    device_b
        .client
        .client
        .excalidraw_put(
            id,
            vec![
                ex_rect("box", 2, 1_001, "b-moved"),
                ex_rect("b-box", 1, 7, "b1"),
            ],
            None,
            vec![],
        )
        .await
        .unwrap();
    let (_, rejected) = driver
        .client
        .client
        .excalidraw_put(id, vec![ex_text("note", 1, 9, "LGTM")], None, vec![])
        .await
        .unwrap();
    assert!(rejected.is_empty());
    for drawer in [&mut device_a, &mut device_b, &mut driver] {
        drawer
            .until_ex(id, "everyone's edits", |scene| {
                ex_find(scene, "box").is_some_and(|element| element.json.contains("b-moved"))
                    && ex_find(scene, "b-box").is_some()
                    && ex_find(scene, "note").is_some()
            })
            .await;
    }

    // A conflict: A and B change the box at the same version at once. Excalidraw's rule
    // (a tie goes to the lower versionNonce) picks B's on every replica, in either order.
    let (result_a, result_b) = tokio::join!(
        device_a.client.client.excalidraw_put(
            id,
            vec![ex_rect("box", 3, 900, "a-loses")],
            None,
            vec![]
        ),
        device_b.client.client.excalidraw_put(
            id,
            vec![ex_rect("box", 3, 400, "b-wins")],
            None,
            vec![]
        ),
    );
    result_a.unwrap();
    result_b.unwrap();
    for drawer in [&mut device_a, &mut device_b, &mut driver] {
        drawer
            .until_ex(id, "the conflict settled", |scene| {
                ex_find(scene, "box").is_some_and(|element| element.version_nonce == 400)
            })
            .await;
    }
    let daemon_box = device_a
        .client
        .client
        .excalidraw_get(id, 0)
        .await
        .unwrap()
        .elements
        .into_iter()
        .find(|element| element.id == "box");
    assert_eq!(daemon_box, Some(ex_rect("box", 3, 400, "b-wins")));
    assert_eq!(
        ex_state(&device_a.client, id),
        ex_state(&device_b.client, id)
    );
    assert_eq!(ex_state(&device_a.client, id), ex_state(&driver.client, id));

    // Live ink on the canvas from A reaches B and the driver, stamped with A (whatever A
    // claims), never echoed to A.
    let me = device_a.client.client.me().unwrap().actor;
    let forged = driver.client.client.me().unwrap().actor;
    let mut latencies = Vec::new();
    for chunk in 0..60u32 {
        let sent = Instant::now();
        device_a.client.client.ink_live(InkLive {
            artifact_id: id,
            stroke_id: ElementId(9),
            actor: forged,
            chunk,
            tool: Tool::Pen,
            style: Style {
                color: 0x1e1e_1eff,
                width: 2.0,
            },
            points: drawing::pack(&[InkPoint::at(chunk as f32, 4.0, chunk * 16)]),
            done: chunk == 59,
        });
        for drawer in [&mut device_b, &mut driver] {
            let update = drawer
                .wait("ink chunk", |update| {
                    is_event(update, |event| {
                        matches!(event, ArtifactEvent::Ink(ink) if ink.artifact_id == id && ink.chunk == chunk)
                    })
                })
                .await;
            let ArtifactUpdate::Event(event) = update else {
                unreachable!()
            };
            let ArtifactEvent::Ink(ink) = *event else {
                unreachable!()
            };
            assert_eq!(ink.actor, me);
        }
        latencies.push(sent.elapsed());
    }
    println!(
        "canvas ink A→daemon→B and driver (loopback, debug): {}",
        percentiles(latencies)
    );

    // B deletes A's label: a tombstone at a higher version.
    device_b
        .client
        .client
        .excalidraw_put(
            id,
            vec![ex_deleted(ex_text("label", 2, 3_001, "auth service"))],
            None,
            vec![],
        )
        .await
        .unwrap();
    for drawer in [&mut device_a, &mut driver] {
        drawer
            .until_ex(id, "label deleted", |scene| {
                ex_find(scene, "label").is_some_and(|element| element.deleted)
            })
            .await;
    }
    assert_eq!(
        device_a.client.client.excalidraw_scene(id).unwrap().live(),
        4
    );
    assert!(
        !device_a
            .seen
            .iter()
            .any(|update| is_event(update, |event| matches!(event, ArtifactEvent::Ink(_))))
    );

    // B is suspended while A redraws the stroke, deletes B's box and changes the
    // background; B comes back caught up, with the canvas list again.
    device_b.client.client.suspend();
    device_a
        .client
        .client
        .excalidraw_put(
            id,
            vec![
                ex_freedraw("ink", 41, 5, 300),
                ex_deleted(ex_rect("b-box", 2, 8, "b1")),
            ],
            Some(r##"{"viewBackgroundColor":"#ffffff","gridSize":null}"##.into()),
            vec![],
        )
        .await
        .unwrap();
    let rev = device_a
        .client
        .client
        .excalidraw_scene(id)
        .unwrap()
        .revision;
    device_b.seen.clear();
    device_b.client.client.reconnect();
    device_b.wait("b resynced", |update| {
        matches!(update, ArtifactUpdate::Synced { artifact_id, version } if *artifact_id == id && *version == rev)
    })
    .await;
    wait_canvas(&mut device_b, "canvases after reconnect", canvas, Some(id)).await;
    assert_eq!(
        ex_state(&device_a.client, id),
        ex_state(&device_b.client, id)
    );
    let scene_b = device_b.client.client.excalidraw_scene(id).unwrap();
    assert_eq!(scene_b.live(), 3);
    assert!(scene_b.app_state.unwrap().contains("viewBackgroundColor"));

    // A viewer sees the canvas and the scene and follows live edits, but cannot put.
    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = device_a
        .client
        .client
        .create_invite(spec, "owner".into())
        .await
        .unwrap();
    let mut viewer = Drawer::new(TestClient::join(
        &invite.to_string(),
        ClientConfig::generate_key(),
    ));
    viewer.client.client.attach(None);
    viewer
        .client
        .until("viewer layout", |client| client.layout.is_some())
        .await;
    wait_canvas(&mut viewer, "canvases on the viewer", canvas, Some(id)).await;
    let seen = viewer.client.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(seen.elements, ex_state(&device_a.client, id));
    let result = viewer
        .client
        .client
        .excalidraw_put(id, vec![ex_rect("box", 99, 0, "vandal")], None, vec![])
        .await;
    assert!(
        matches!(result, Err(ArtifactError::Forbidden(_))),
        "{result:?}"
    );
    device_a
        .client
        .client
        .excalidraw_put(id, vec![ex_rect("box", 4, 1, "after-viewer")], None, vec![])
        .await
        .unwrap();
    for drawer in [&mut viewer, &mut device_b] {
        drawer
            .until_ex(id, "a's edit after the refused put", |scene| {
                ex_find(scene, "box").is_some_and(|element| element.json.contains("after-viewer"))
            })
            .await;
    }
    assert_eq!(ex_state(&viewer.client, id), ex_state(&device_a.client, id));

    // A second canvas pane on the same scene, in its own tab. Closing it keeps the scene.
    let OpOutcome::TabCreated {
        pane_id: tab_canvas,
        ..
    } = device_a
        .client
        .op(LayoutOp::NewTab {
            session_id: session,
            name: "board".into(),
            launch: PaneLaunch::Canvas {
                artifact_id: Some(id),
            },
        })
        .await
    else {
        panic!("canvas tab failed")
    };
    for drawer in [&mut device_a, &mut device_b, &mut driver, &mut viewer] {
        wait_canvas(drawer, "tab canvas", tab_canvas, Some(id)).await;
    }
    for drawer in [&mut device_a, &mut device_b, &mut driver, &mut viewer] {
        drawer.seen.clear();
    }
    assert_eq!(
        device_a
            .client
            .op(LayoutOp::ClosePane {
                pane_id: tab_canvas
            })
            .await,
        OpOutcome::Done
    );
    for drawer in [&mut device_a, &mut device_b, &mut driver, &mut viewer] {
        wait_canvas(drawer, "tab canvas closed", tab_canvas, None).await;
        let left = last_canvases(drawer).unwrap();
        assert!(left.iter().any(|listed| listed.pane_id == canvas));
    }
    let kept = device_b.client.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(kept.info.canvas_panes, vec![canvas]);
    assert_eq!(kept.elements, ex_state(&device_a.client, id));

    // Deleting the scene closes its canvas pane on every client.
    for drawer in [&mut device_a, &mut device_b, &mut driver, &mut viewer] {
        drawer.seen.clear();
    }
    device_b.client.client.artifact_delete(id).await.unwrap();
    for drawer in [&mut device_a, &mut device_b, &mut driver, &mut viewer] {
        drawer.wait("deleted", |update| {
            is_event(
                update,
                |event| matches!(event, ArtifactEvent::Deleted { artifact_id, .. } if *artifact_id == id),
            )
        })
        .await;
        wait_canvas(drawer, "canvas closed with its scene", canvas, None).await;
        drawer
            .client
            .until("canvas leaf gone", |client| {
                !all_leaves(client).contains(&canvas)
            })
            .await;
        assert!(drawer.client.client.canvas_panes(session).is_empty());
        assert!(drawer.client.client.excalidraw_scene(id).is_none());
    }
    assert!(matches!(
        device_a.client.client.excalidraw_get(id, 0).await,
        Err(ArtifactError::NotFound(_))
    ));
    drop((device_a, device_b, driver, viewer));
    daemon.shutdown().await;
}
