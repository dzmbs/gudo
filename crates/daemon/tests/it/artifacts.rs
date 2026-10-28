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
    c: TestClient,
    updates: UnboundedReceiver<ArtifactUpdate>,
    seen: Vec<ArtifactUpdate>,
}

impl Drawer {
    fn new(c: TestClient) -> Self {
        let (listener, updates) = ArtifactEventQueue::channel();
        c.client.set_artifact_listener(listener);
        Self {
            c,
            updates,
            seen: Vec::new(),
        }
    }

    /// Waits for an update matching `pred`; returns it.
    async fn wait(&mut self, what: &str, pred: impl Fn(&ArtifactUpdate) -> bool) -> ArtifactUpdate {
        if let Some(u) = self.seen.iter().find(|u| pred(u)) {
            return u.clone();
        }
        let deadline = Instant::now() + TIMEOUT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "timed out waiting for {what}");
            match tokio::time::timeout(left, self.updates.recv()).await {
                Ok(Some(u)) => {
                    self.seen.push(u.clone());
                    if pred(&u) {
                        return u;
                    }
                }
                _ => panic!("timed out waiting for {what}"),
            }
        }
    }

    fn session(&self) -> SessionId {
        self.c.layout.as_ref().expect("attached").session_id
    }

    /// Pumps updates until the cached Excalidraw scene `id` satisfies `pred`.
    async fn until_ex(
        &mut self,
        id: ArtifactId,
        what: &str,
        pred: impl Fn(&drawing::ExScene) -> bool,
    ) {
        let deadline = Instant::now() + TIMEOUT;
        loop {
            if self.c.client.excalidraw_scene(id).is_some_and(|s| pred(&s)) {
                return;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            match tokio::time::timeout(left, self.updates.recv()).await {
                Ok(Some(u)) => self.seen.push(u),
                _ => panic!("timed out waiting for {what}"),
            }
        }
    }
}

fn is_event(u: &ArtifactUpdate, f: impl Fn(&ArtifactEvent) -> bool) -> bool {
    matches!(u, ArtifactUpdate::Event(e) if f(e))
}

fn stroke(id: u64, x: f32) -> DrawOp {
    let pts: Vec<InkPoint> = (0..20)
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
            points: drawing::pack(&pts),
        }),
    })
}

fn drawing_req(session: SessionId, space: CoordSpace, ops: Vec<DrawOp>) -> ArtifactCreate {
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

fn scene_eq(a: &Scene, b: &Scene) -> bool {
    a.version == b.version && a.elements() == b.elements()
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
    let mut a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let pane = a.c.attach_and_follow().await;
    let mut b = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    b.c.client.attach(None);
    b.c.until("b layout", |c| c.layout.is_some()).await;
    let session = a.session();

    // A anchors a cell-space drawing to the row just above the prompt.
    a.c.type_line(pane, "echo anchor-me");
    a.c.wait_text(pane, "anchor-me\n").await;
    let seq = a.c.client.pane_seq(pane).unwrap();
    // The output row, counted from the bottom row of the screen (no scrollback yet).
    let rows = usize::from(a.c.metas[&pane].size.rows);
    let text = a.c.text(pane);
    let row = text.lines().position(|l| l == "anchor-me").unwrap();
    let mut create = drawing_req(session, CoordSpace::Cells, vec![stroke(1, 2.0)]);
    create.anchor = Some(AnchorRequest {
        pane_id: pane,
        at_seq: client_core::proto::Seq(seq),
        from_bottom: (rows - 1 - row) as u64,
    });
    let info = a.c.client.artifact_create(create).await.unwrap();
    let id = info.artifact_id;
    assert_eq!(info.version, 1);
    let anchor = info.anchor.unwrap();
    assert_eq!(anchor.state, AnchorState::Live);
    b.wait("created on b", |u| {
        is_event(
            u,
            |e| matches!(e, ArtifactEvent::Created(i) if i.artifact_id == id),
        )
    })
    .await;
    b.wait(
        "b synced v1",
        |u| matches!(u, ArtifactUpdate::Synced { artifact_id, version: 1 } if *artifact_id == id),
    )
    .await;

    // Live ink: A streams 200 chunks at ~120 Hz; B sees every one, in order, from A.
    let me = a.c.client.me().unwrap().actor;
    let mut sent_at = Vec::new();
    let mut lat = Vec::new();
    for chunk in 0..200u32 {
        let pts = [InkPoint::at(chunk as f32 * 0.1, 3.0, chunk * 8)];
        sent_at.push(Instant::now());
        a.c.client.ink_live(InkLive {
            artifact_id: id,
            stroke_id: ElementId(77),
            actor: me,
            chunk,
            tool: Tool::Pen,
            style: Style {
                color: 0x00ff_00ff,
                width: 0.2,
            },
            points: drawing::pack(&pts),
            done: chunk == 199,
        });
        let u = b
            .wait("ink chunk", |u| {
                is_event(
                    u,
                    |e| matches!(e, ArtifactEvent::Ink(i) if i.chunk == chunk),
                )
            })
            .await;
        lat.push(sent_at[chunk as usize].elapsed());
        if let ArtifactUpdate::Event(e) = u
            && let ArtifactEvent::Ink(ink) = *e
        {
            assert_eq!(ink.actor, me);
            assert_eq!(drawing::unpack(&ink.points).unwrap().len(), 1);
        }
        tokio::time::sleep(Duration::from_millis(8)).await;
    }
    lat.sort();
    println!(
        "spike W5-2 ink fan-out A→daemon→B (loopback, debug): p50 {:.2} ms, p99 {:.2} ms, max {:.2} ms",
        lat[100].as_secs_f64() * 1e3,
        lat[198].as_secs_f64() * 1e3,
        lat[199].as_secs_f64() * 1e3
    );
    // The sender never gets its own ink back.
    assert!(
        !a.seen
            .iter()
            .any(|u| is_event(u, |e| matches!(e, ArtifactEvent::Ink(_))))
    );

    // Committed batches from both sides converge on both clients.
    a.c.client
        .artifact_apply(id, 1, vec![stroke(2, 5.0)])
        .await
        .unwrap();
    b.c.client
        .artifact_apply(
            id,
            2,
            vec![stroke(3, 9.0), DrawOp::Delete { id: ElementId(1) }],
        )
        .await
        .unwrap();
    let v =
        a.c.client
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
    assert_eq!(v, 4);
    for d in [&mut a, &mut b] {
        d.wait("v4", |u| {
            is_event(
                u,
                |e| matches!(e, ArtifactEvent::Changed { batch, .. } if batch.version == 4),
            )
        })
        .await;
    }
    let (_, sa) = a.c.client.artifact_scene(id).unwrap();
    let (_, sb) = b.c.client.artifact_scene(id).unwrap();
    assert!(scene_eq(&sa, &sb));
    assert_eq!(sa.version, 4);
    assert_eq!(sa.elements().len(), 2);

    // B goes away; A keeps drawing; B comes back and catches up by itself.
    b.c.client.suspend();
    for i in 0..3 {
        a.c.client
            .artifact_apply(id, 4 + i, vec![stroke(10 + i, 12.0)])
            .await
            .unwrap();
    }
    b.seen.clear();
    b.c.client.reconnect();
    b.wait(
        "b resynced v7",
        |u| matches!(u, ArtifactUpdate::Synced { artifact_id, version: 7 } if *artifact_id == id),
    )
    .await;
    let (_, sa) = a.c.client.artifact_scene(id).unwrap();
    let (_, sb) = b.c.client.artifact_scene(id).unwrap();
    assert!(scene_eq(&sa, &sb), "{sa:?}\n{sb:?}");
    // A full fetch agrees with the incremental cache.
    let full = b.c.client.artifact_get(id, 0).await.unwrap();
    assert_eq!(full.elements.as_deref(), Some(sa.elements()));

    // The anchor detaches when the screen and scrollback are cleared.
    a.c.type_line(pane, "printf '\\033[H\\033[2J\\033[3J'");
    b.wait("anchor detached", |u| {
        is_event(u, |e| {
            matches!(e, ArtifactEvent::Info(i) if i.artifact_id == id
                && i.anchor.is_some_and(|a| a.state == AnchorState::Detached(DetachReason::RowGone)))
        })
    })
    .await;
    drop((a, b));
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
    let pane = owner.c.attach_and_follow().await;
    let session = owner.session();
    let info = owner
        .c
        .client
        .artifact_create(drawing_req(
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
        .c
        .client
        .create_invite(spec, "owner".into())
        .await
        .unwrap();
    let mut vic = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    vic.client.attach(None);
    vic.until("viewer layout", |c| c.layout.is_some()).await;
    let mut vic = Drawer::new(vic);

    // Seeing is fine.
    let list = vic.c.client.artifacts(session).await.unwrap();
    assert_eq!(list.len(), 1);
    let scene = vic.c.client.artifact_get(id, 0).await.unwrap();
    assert_eq!(scene.elements.unwrap().len(), 1);
    let (_, svg) = vic
        .c
        .client
        .artifact_export(id, None, ExportFormat::Svg)
        .await
        .unwrap();
    assert!(String::from_utf8(svg).unwrap().starts_with("<svg"));

    // Editing, creating, deleting, sending and uploading are not.
    fn forbidden<T>(r: &Result<T, ArtifactError>) -> bool {
        matches!(r, Err(ArtifactError::Forbidden(m)) if m.contains("prompter or driver"))
    }
    let r = vic
        .c
        .client
        .artifact_apply(id, 1, vec![stroke(2, 1.0)])
        .await;
    assert!(forbidden(&r), "{r:?}");
    let r = vic
        .c
        .client
        .artifact_create(drawing_req(session, CoordSpace::Canvas, vec![]))
        .await;
    assert!(forbidden(&r), "{r:?}");
    let r = vic.c.client.artifact_delete(id).await;
    assert!(forbidden(&r), "{r:?}");
    let r = vic.c.client.send_to_agent(pane, Some(id), None, None).await;
    assert!(forbidden(&r), "{r:?}");
    let png = drawing::encode_png(&drawing::Rgba {
        width: 1,
        height: 1,
        data: vec![0; 4],
    });
    let r = vic.c.client.blob_upload(session, png).await;
    assert!(matches!(r, Err(ArtifactError::Forbidden(_))), "{r:?}");

    // Live ink from a viewer is refused and never reaches the owner.
    vic.c.client.ink_live(InkLive {
        artifact_id: id,
        stroke_id: ElementId(5),
        actor: vic.c.client.me().unwrap().actor,
        chunk: 0,
        tool: Tool::Pen,
        style: Style {
            color: 0xff,
            width: 1.0,
        },
        points: drawing::pack(&[InkPoint::at(1.0, 1.0, 0)]),
        done: true,
    });
    vic.c
        .until("ink refused", |c| {
            c.mp.iter()
                .any(|e| matches!(e, MultiplayerEvent::Forbidden { what, .. } if what == "InkLive"))
        })
        .await;
    // The owner's own edit still reaches the viewer, live.
    owner
        .c
        .client
        .artifact_apply(id, 1, vec![stroke(3, 4.0)])
        .await
        .unwrap();
    vic.wait("viewer sees v2", |u| {
        is_event(
            u,
            |e| matches!(e, ArtifactEvent::Changed { batch, .. } if batch.version == 2),
        )
    })
    .await;
    assert!(
        !owner
            .seen
            .iter()
            .any(|u| is_event(u, |e| matches!(e, ArtifactEvent::Ink(_))))
    );
    assert_eq!(
        owner
            .c
            .client
            .artifact_get(id, 0)
            .await
            .unwrap()
            .info
            .version,
        2
    );
    drop((owner, vic));
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
    let shell = owner.c.attach_and_follow().await;
    let session = owner.session();

    // The fake agent: turns on bracketed paste and shows every byte it reads (`cat -v`).
    let OpOutcome::PaneCreated { pane_id: agent } = owner
        .c
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
    owner.c.follow(agent).await;
    owner.c.wait_text(agent, "AGENT-READY").await;
    make_agent(&daemon, &dir, agent).await;

    let info = owner
        .c
        .client
        .artifact_create(drawing_req(
            session,
            CoordSpace::Canvas,
            vec![stroke(1, 0.0), stroke(2, 8.0)],
        ))
        .await
        .unwrap();
    let id = info.artifact_id;
    let png = drawing::encode_png(&drawing::rasterize(
        &owner.c.client.artifact_scene(id).unwrap().1,
        CoordSpace::Canvas,
        drawing::RasterOptions::default(),
    ));

    // Not into a shell.
    let r = owner
        .c
        .client
        .send_to_agent(shell, Some(id), None, Some(png.clone()))
        .await;
    assert_eq!(r, Err(ArtifactError::NotAgentPane));

    let sent = owner
        .c
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
    owner.c.wait_flat(agent, &expect).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let flat = owner.c.flat_text(agent);
    let after = &flat[flat.find(&expect).unwrap() + expect.len()..];
    assert!(!after.contains("^M") && !after.contains("^J"), "{after:?}");

    // A bare image (a photo) becomes an image artifact; the daemon's own render works too.
    let photo = drawing::encode_png(&drawing::Rgba {
        width: 2,
        height: 2,
        data: vec![9; 16],
    });
    let bare = owner
        .c
        .client
        .send_to_agent(agent, None, None, Some(photo.clone()))
        .await
        .unwrap();
    let image = owner
        .c
        .client
        .artifacts(session)
        .await
        .unwrap()
        .into_iter()
        .find(|i| i.artifact_id == bare.artifact_id)
        .unwrap();
    assert_eq!(image.kind, ArtifactKind::Image);
    assert_eq!(std::fs::read(&bare.path).unwrap(), photo);
    let rendered = owner
        .c
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
    let pane = owner.c.attach_and_follow().await;
    let session = owner.session();

    // A canvas pane splits off the terminal showing a (Pencil) drawing; `None` would make
    // an Excalidraw scene (tests/it/inline.rs).
    let pencil = owner
        .c
        .client
        .artifact_create(drawing_req(session, CoordSpace::Canvas, vec![]))
        .await
        .unwrap();
    let OpOutcome::PaneCreated { pane_id: canvas } = owner
        .c
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
        .wait("canvases", |u| {
            is_event(u, |e| matches!(e, ArtifactEvent::Canvases { canvases, .. } if canvases.iter().any(|c| c.pane_id == canvas)))
        })
        .await;
    let ArtifactUpdate::Event(e) = created else {
        unreachable!()
    };
    let ArtifactEvent::Canvases { canvases, .. } = *e else {
        unreachable!()
    };
    let drawing_id: ArtifactId = canvases[0].artifact_id;
    owner
        .c
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
        .c
        .client
        .blob_upload(session, photo.clone())
        .await
        .unwrap();
    assert_eq!((img.width, img.height), (3, 2));
    let image = owner
        .c
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
        .c
        .client
        .artifact_set_preview(drawing_id, 1, preview.clone())
        .await
        .unwrap();

    // Exports: PNG passthrough of the image and of the preview; SVG from the vectors.
    let (_, png) = owner
        .c
        .client
        .artifact_export(image.artifact_id, None, ExportFormat::Png)
        .await
        .unwrap();
    assert_eq!(png, photo);
    let (v, png) = owner
        .c
        .client
        .artifact_export(drawing_id, None, ExportFormat::Png)
        .await
        .unwrap();
    assert_eq!((v, png), (1, preview.clone()));
    let (_, svg) = owner
        .c
        .client
        .artifact_export(drawing_id, None, ExportFormat::Svg)
        .await
        .unwrap();
    let (info, scene) = owner.c.client.artifact_scene(drawing_id).unwrap();
    assert_eq!(
        String::from_utf8(svg).unwrap(),
        drawing::to_svg(&scene, info.space, "arch", &|_| None)
    );
    let (_, data) = owner.c.client.blob_download(img.hash).await.unwrap();
    assert_eq!(data, photo);
    let before = owner.c.client.artifacts(session).await.unwrap();
    drop(owner);
    daemon.shutdown().await;

    // Restart: same artifacts, versions, scenes, canvas pane and blobs.
    let daemon = start(dir.path()).await;
    let mut owner = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    owner.c.client.attach(None);
    owner.c.until("layout", |c| c.layout.is_some()).await;
    assert!(crate::support::leaves(&owner.c.tab().root).contains(&canvas));
    owner
        .wait("canvases after restart", |u| {
            is_event(u, |e| matches!(e, ArtifactEvent::Canvases { canvases, .. } if canvases.iter().any(|c| c.pane_id == canvas && c.artifact_id == drawing_id)))
        })
        .await;
    let after = owner.c.client.artifacts(session).await.unwrap();
    assert_eq!(after.len(), before.len());
    for (a, b) in before.iter().zip(&after) {
        assert_eq!(
            (
                a.artifact_id,
                a.version,
                a.elements,
                &a.title,
                a.image,
                a.preview
            ),
            (
                b.artifact_id,
                b.version,
                b.elements,
                &b.title,
                b.image,
                b.preview
            )
        );
    }
    let scene2 = owner.c.client.artifact_get(drawing_id, 0).await.unwrap();
    assert_eq!(scene2.elements.as_deref(), Some(scene.elements()));
    let (_, data) = owner.c.client.blob_download(img.hash).await.unwrap();
    assert_eq!(data, photo);

    // Closing the canvas pane keeps the drawing; deleting the image frees it.
    assert_eq!(
        owner.c.op(LayoutOp::ClosePane { pane_id: canvas }).await,
        OpOutcome::Done
    );
    owner
        .wait("canvas gone", |u| {
            is_event(
                u,
                |e| matches!(e, ArtifactEvent::Canvases { canvases, .. } if canvases.is_empty()),
            )
        })
        .await;
    assert!(owner.c.client.artifact_get(drawing_id, 0).await.is_ok());
    owner
        .c
        .client
        .artifact_delete(image.artifact_id)
        .await
        .unwrap();
    assert!(matches!(
        owner.c.client.artifact_get(image.artifact_id, 0).await,
        Err(ArtifactError::NotFound(_))
    ));
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn caps_refuse_oversized_blobs_and_batches() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = crate::support::start_with(dir.path(), |c| {
        c.artifacts.blob_max = 1000;
        c.artifacts.batch_max = 2000;
    })
    .await;
    let mut owner = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    owner.c.attach_and_follow().await;
    let session = owner.session();
    let big = drawing::encode_png(&drawing::Rgba {
        width: 64,
        height: 64,
        data: {
            let mut x = 0x9e37_79b9_u32;
            (0..64 * 64 * 4)
                .map(|_| {
                    x ^= x << 13;
                    x ^= x >> 17;
                    x ^= x << 5;
                    x as u8
                })
                .collect()
        },
    });
    assert!(big.len() > 1000);
    let r = owner.c.client.blob_upload(session, big).await;
    assert!(matches!(r, Err(ArtifactError::TooLarge(_))), "{r:?}");
    let info = owner
        .c
        .client
        .artifact_create(drawing_req(session, CoordSpace::Canvas, vec![]))
        .await
        .unwrap();
    let ops: Vec<DrawOp> = (0..50).map(|i| stroke(i, i as f32)).collect();
    let r = owner
        .c
        .client
        .artifact_apply(info.artifact_id, 0, ops)
        .await;
    assert!(matches!(r, Err(ArtifactError::TooLarge(_))), "{r:?}");
    let r = owner
        .c
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
    assert!(matches!(r, Err(ArtifactError::Invalid(_))), "{r:?}");
    drop(owner);
    daemon.shutdown().await;
}

// ---------------------------------------------------------------------------------------------
// Excalidraw scenes, inline placements, import
// ---------------------------------------------------------------------------------------------

fn exel(id: &str, version: u64, nonce: u32, x: f32, label: &str) -> client_core::proto::ExElement {
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

fn ex_state(c: &TestClient, id: ArtifactId) -> Vec<client_core::proto::ExElement> {
    c.client
        .excalidraw_scene(id)
        .map(|s| s.changed_since(0))
        .unwrap_or_default()
}

fn placed(u: &ArtifactUpdate, f: impl Fn(&client_core::proto::Placement) -> bool) -> bool {
    is_event(u, |e| matches!(e, ArtifactEvent::Placed(p) if f(p)))
}

#[tokio::test(flavor = "multi_thread")]
async fn excalidraw_scenes_reconcile_between_clients_and_export() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let shell = a.c.attach_and_follow().await;
    let mut b = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    b.c.client.attach(None);
    b.c.until("b layout", |c| c.layout.is_some()).await;

    // A canvas pane with no artifact gets a new Excalidraw scene.
    let OpOutcome::PaneCreated { pane_id: canvas } =
        a.c.op(LayoutOp::Split {
            pane_id: shell,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Canvas { artifact_id: None },
        })
        .await
    else {
        panic!("canvas split failed")
    };
    let u = b
        .wait("canvas on b", |u| {
            is_event(u, |e| matches!(e, ArtifactEvent::Canvases { canvases, .. } if canvases.iter().any(|c| c.pane_id == canvas)))
        })
        .await;
    let ArtifactUpdate::Event(e) = u else {
        unreachable!()
    };
    let ArtifactEvent::Canvases { canvases, .. } = *e else {
        unreachable!()
    };
    let id = canvases
        .iter()
        .find(|c| c.pane_id == canvas)
        .unwrap()
        .artifact_id;
    let info = a.c.client.artifact_get(id, u64::MAX).await.unwrap().info;
    assert_eq!(info.kind, ArtifactKind::Excalidraw);

    // Both edit: disjoint elements merge; the same element at the same version goes to the
    // lower versionNonce on every replica; an older version loses and comes back as the
    // winner.
    let (_, rejected) =
        a.c.client
            .excalidraw_put(
                id,
                vec![
                    exel("box-a", 1, 50, 0.0, "a1"),
                    exel("same", 5, 10, 200.0, "from-a"),
                ],
                None,
                vec![],
            )
            .await
            .unwrap();
    assert!(rejected.is_empty());
    let (_, rejected) =
        b.c.client
            .excalidraw_put(
                id,
                vec![
                    exel("box-b", 1, 1, 400.0, "b1"),
                    exel("same", 5, 3, 200.0, "from-b"),
                    exel("box-a", 0, 0, 0.0, "stale"),
                ],
                Some(r#"{"gridSize":20}"#.into()),
                vec![],
            )
            .await
            .unwrap();
    assert_eq!(rejected, vec![exel("box-a", 1, 50, 0.0, "a1")]);
    a.wait("b's elements on a", |u| {
        is_event(u, |e| matches!(e, ArtifactEvent::Excalidraw { elements, .. } if elements.iter().any(|e| e.id == "box-b")))
    })
    .await;
    b.wait("a's elements on b", |u| {
        is_event(u, |e| matches!(e, ArtifactEvent::Excalidraw { elements, .. } if elements.iter().any(|e| e.id == "box-a")))
    })
    .await;
    let sa = ex_state(&a.c, id);
    assert_eq!(sa, ex_state(&b.c, id));
    assert_eq!(sa.len(), 3);
    assert!(
        sa.iter()
            .any(|e| e.id == "same" && e.json.contains("from-b"))
    );
    let full = a.c.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(full.elements, sa);
    assert_eq!(full.app_state.as_deref(), Some(r#"{"gridSize":20}"#));

    // B away, A edits and deletes, B back: caught up.
    b.c.client.suspend();
    let mut gone = exel("box-b", 2, 9, 400.0, "b1");
    gone.deleted = true;
    gone.json = gone
        .json
        .replace(r#""isDeleted":false"#, r#""isDeleted":true"#);
    a.c.client
        .excalidraw_put(
            id,
            vec![exel("box-a", 2, 7, 10.0, "a2"), gone],
            None,
            vec![],
        )
        .await
        .unwrap();
    let rev = a.c.client.excalidraw_scene(id).unwrap().revision;
    b.seen.clear();
    b.c.client.reconnect();
    b.wait("b resynced", |u| {
        matches!(u, ArtifactUpdate::Synced { artifact_id, version } if *artifact_id == id && *version == rev)
    })
    .await;
    assert_eq!(ex_state(&a.c, id), ex_state(&b.c, id));
    assert_eq!(b.c.client.excalidraw_scene(id).unwrap().live(), 2);

    // Exports: ASCII box glyphs, SVG, PNG (the daemon's render).
    let (_, ascii) =
        b.c.client
            .artifact_export(id, None, ExportFormat::Ascii)
            .await
            .unwrap();
    let ascii = String::from_utf8(ascii).unwrap();
    assert!(ascii.contains('┌') && ascii.contains('┘'), "{ascii}");
    let (_, svg) =
        b.c.client
            .artifact_export(id, None, ExportFormat::Svg)
            .await
            .unwrap();
    assert_eq!(String::from_utf8(svg).unwrap().matches("<rect").count(), 2);
    let (_, png) =
        b.c.client
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
    let invite =
        a.c.client
            .create_invite(spec, "owner".into())
            .await
            .unwrap();
    let mut vic = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    vic.client.attach(None);
    vic.until("viewer layout", |c| c.layout.is_some()).await;
    assert_eq!(
        vic.client
            .excalidraw_get(id, 0)
            .await
            .unwrap()
            .elements
            .len(),
        3
    );
    let r = vic
        .client
        .excalidraw_put(id, vec![exel("v", 1, 1, 0.0, "v")], None, vec![])
        .await;
    assert!(matches!(r, Err(ArtifactError::Forbidden(_))), "{r:?}");
    let r = vic
        .client
        .import_to_pane(shell, "x.excalidraw".into(), b"{}".to_vec())
        .await;
    assert!(matches!(r, Err(ArtifactError::Forbidden(_))), "{r:?}");
    drop((a, b, vic));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn inline_placements_follow_output_and_survive_reattach() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let pane = a.c.attach_and_follow().await;
    let session = a.session();
    a.c.type_line(pane, "echo before-the-sketch");
    a.c.wait_text(pane, "before-the-sketch\n").await;

    // "Done" on the overlay: the drawing goes inline at the cursor row.
    let sketch =
        a.c.client
            .artifact_create(drawing_req(
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
    let p = a.c.client.place(place(None)).await.unwrap();
    assert_eq!(p.anchor.state, AnchorState::Live);
    assert_eq!(p.col, 2);
    assert!(p.cols >= 1 && p.rows >= 1);
    let start_fb = p.anchor.from_bottom;

    // More output scrolls it up; the placement stays on its row.
    a.c.type_line(
        pane,
        "i=0; while [ $i -lt 40 ]; do echo line-$i; i=$((i+1)); done",
    );
    a.c.wait_text(pane, "line-39").await;
    let list = a.c.client.list_placements(pane).await.unwrap();
    let now = list
        .iter()
        .find(|x| x.placement_id == p.placement_id)
        .unwrap();
    assert_eq!(now.anchor.state, AnchorState::Live);
    assert!(
        // 40 lines and two prompts below it (the screen had room for some at first).
        now.anchor.from_bottom > start_fb && now.anchor.from_bottom >= 40,
        "{start_fb} → {}",
        now.anchor.from_bottom
    );

    // A client attaching later (a new device, a resume after a snapshot) gets it too.
    let mut late = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    late.c.client.attach(None);
    late.wait("placement on attach", |u| {
        placed(u, |x| x.placement_id == p.placement_id)
    })
    .await;
    assert_eq!(late.c.client.placements(pane).len(), 1);

    // Re-opened and edited in place: the new version replaces the old placement.
    a.c.client
        .artifact_apply(sketch.artifact_id, 1, vec![stroke(2, 3.0)])
        .await
        .unwrap();
    let p2 = a.c.client.place(place(Some(p.placement_id))).await.unwrap();
    assert_eq!(p2.version, 2);
    late.wait("unplaced old", |u| {
        is_event(u, |e| matches!(e, ArtifactEvent::Unplaced { placement_id, .. } if *placement_id == p.placement_id))
    })
    .await;
    late.wait("placed new", |u| {
        placed(u, |x| x.placement_id == p2.placement_id)
    })
    .await;

    let png = drawing::encode_png(&drawing::Rgba {
        width: 36,
        height: 36,
        data: vec![120; 36 * 36 * 4],
    });
    // A dropped .excalidraw file becomes an inline diagram; so does a dropped photo.
    let flow = include_bytes!("../../../drawing/tests/fixtures/flow.excalidraw");
    let d =
        a.c.client
            .import_to_pane(pane, "flow.excalidraw".into(), flow.to_vec())
            .await
            .unwrap();
    let (_, ascii) =
        a.c.client
            .artifact_export(d.artifact_id, None, ExportFormat::Ascii)
            .await
            .unwrap();
    let ascii = String::from_utf8(ascii).unwrap();
    assert!(ascii.contains("daemon") && ascii.contains('▶'), "{ascii}");
    let photo =
        a.c.client
            .import_to_pane(pane, "photo.png".into(), png.clone())
            .await
            .unwrap();
    assert_eq!(photo.image.width, 36);
    let kinds: Vec<ArtifactKind> =
        a.c.client
            .artifacts(session)
            .await
            .unwrap()
            .iter()
            .map(|i| i.kind)
            .collect();
    assert!(kinds.contains(&ArtifactKind::Image));

    // Clearing the screen and scrollback detaches what was placed on the cleared rows.
    a.c.type_line(pane, "printf '\\033[H\\033[2J\\033[3J'");
    late.wait("placement detached", |u| {
        placed(u, |x| {
            x.placement_id == p2.placement_id
                && x.anchor.state == AnchorState::Detached(DetachReason::RowGone)
        })
    })
    .await;

    // Removing a placement tells everyone.
    a.c.client.unplace(photo.placement_id).await.unwrap();
    late.wait("unplaced photo", |u| {
        is_event(u, |e| matches!(e, ArtifactEvent::Unplaced { placement_id, .. } if *placement_id == photo.placement_id))
    })
    .await;
    let before = a.c.client.list_placements(pane).await.unwrap().len();
    drop((a, late));
    daemon.shutdown().await;

    // After a restart the placements are kept, detached (the terminal state is gone), and
    // the Excalidraw scene is intact.
    let daemon = start(dir.path()).await;
    let mut a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    a.c.client.attach(None);
    a.c.until("layout", |c| c.layout.is_some()).await;
    let after = a.c.client.list_placements(pane).await.unwrap();
    assert_eq!(after.len(), before);
    assert!(after.iter().all(|x| x.anchor.state != AnchorState::Live));
    let scene = a.c.client.excalidraw_get(d.artifact_id, 0).await.unwrap();
    assert_eq!(scene.elements.len(), 9);
    drop(a);
    daemon.shutdown().await;
}

// ---------------------------------------------------------------------------------------------
// A canvas pane shared by peers: owner, a second device, a driver guest and a viewer
// ---------------------------------------------------------------------------------------------

/// An Excalidraw element as the editor emits it: the common fields plus `extra`.
fn ex_el(
    id: &str,
    kind: &str,
    version: u64,
    nonce: u32,
    extra: serde_json::Value,
) -> client_core::proto::ExElement {
    let mut v = serde_json::json!({
        "id": id, "type": kind, "x": 120.5, "y": 80.0, "width": 240.0, "height": 120.0,
        "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
        "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1,
        "opacity": 100, "groupIds": [], "frameId": null, "roundness": {"type": 3},
        "seed": 1_968_410_350u32, "version": version, "versionNonce": nonce,
        "isDeleted": false, "boundElements": null, "updated": 1_729_000_000_000u64,
        "link": null, "locked": false,
    });
    let fields = v.as_object_mut().unwrap();
    fields.extend(extra.as_object().unwrap().clone());
    drawing::parse_element(&v.to_string()).unwrap()
}

fn ex_rect(id: &str, version: u64, nonce: u32, label: &str) -> client_core::proto::ExElement {
    ex_el(
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
    ex_el(
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
    ex_el(
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

/// `el` as a tombstone (Excalidraw keeps deleted elements with `isDeleted`).
fn ex_deleted(mut el: client_core::proto::ExElement) -> client_core::proto::ExElement {
    el.json = el
        .json
        .replace(r#""isDeleted":false"#, r#""isDeleted":true"#);
    el.deleted = true;
    el
}

/// The element `id` of a cached scene.
fn ex_find(s: &drawing::ExScene, id: &str) -> Option<client_core::proto::ExElement> {
    s.with_revisions()
        .find(|(e, _)| e.id == id)
        .map(|(e, _)| e.clone())
}

/// The canvas panes of the last `Canvases` push a drawer has seen.
fn last_canvases(d: &Drawer) -> Option<Vec<client_core::proto::CanvasPane>> {
    d.seen.iter().rev().find_map(|u| match u {
        ArtifactUpdate::Event(e) => match &**e {
            ArtifactEvent::Canvases { canvases, .. } => Some(canvases.clone()),
            _ => None,
        },
        ArtifactUpdate::Synced { .. } => None,
    })
}

/// Waits for a `Canvases` push that shows `pane` with `artifact`, or (`None`) without it.
async fn wait_canvas(d: &mut Drawer, what: &str, pane: PaneId, artifact: Option<ArtifactId>) {
    d.wait(what, |u| {
        is_event(u, |e| {
            matches!(e, ArtifactEvent::Canvases { canvases, .. }
                if canvases.iter().find(|c| c.pane_id == pane).map(|c| c.artifact_id) == artifact)
        })
    })
    .await;
}

fn all_leaves(c: &TestClient) -> Vec<PaneId> {
    c.layout
        .as_ref()
        .map(|l| {
            l.tabs
                .iter()
                .flat_map(|t| crate::support::leaves(&t.root))
                .collect()
        })
        .unwrap_or_default()
}

fn percentiles(mut lat: Vec<Duration>) -> String {
    lat.sort();
    let at = |q: f64| lat[((lat.len() - 1) as f64 * q).round() as usize].as_secs_f64() * 1e3;
    format!(
        "p50 {:.2} ms, p99 {:.2} ms, max {:.2} ms (n={})",
        at(0.5),
        at(0.99),
        at(1.0),
        lat.len()
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn canvas_pane_with_peers_syncs_inks_resyncs_and_closes() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    // A: the owner's Mac; B: the owner's iPad (a second paired device).
    let mut a = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    let shell = a.c.attach_and_follow().await;
    let session = a.session();
    let mut b = Drawer::new(TestClient::connect(
        &ticket(&daemon),
        ClientConfig::generate_key(),
    ));
    b.c.client.attach(None);
    b.c.until("b layout", |c| c.layout.is_some()).await;

    // A splits a canvas pane off the shell: the daemon makes an Excalidraw scene and both
    // devices learn which leaf it is.
    let OpOutcome::PaneCreated { pane_id: canvas } =
        a.c.op(LayoutOp::Split {
            pane_id: shell,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Canvas { artifact_id: None },
        })
        .await
    else {
        panic!("canvas split failed")
    };
    for p in [&mut a, &mut b] {
        p.wait("canvas created", |u| {
            is_event(
                u,
                |e| matches!(e, ArtifactEvent::Canvases { canvases, .. } if canvases.iter().any(|c| c.pane_id == canvas)),
            )
        })
        .await;
    }
    let id =
        a.c.client
            .canvas_panes(session)
            .iter()
            .find(|c| c.pane_id == canvas)
            .expect("canvas on a")
            .artifact_id;
    assert_eq!(
        a.c.client.canvas_panes(session),
        b.c.client.canvas_panes(session)
    );
    b.c.until("canvas leaf on b", |c| all_leaves(c).contains(&canvas))
        .await;
    let info = b.c.client.artifact_get(id, u64::MAX).await.unwrap().info;
    assert_eq!(info.kind, ArtifactKind::Excalidraw);
    assert_eq!(info.canvas_panes, vec![canvas]);

    // A driver guest joins and attaches later: the canvas list comes with the attach.
    let mut spec = GrantSpec::new(Roles::DRIVER, Scope::Daemon);
    spec.label = "dee".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite =
        a.c.client
            .create_invite(spec, "owner".into())
            .await
            .unwrap();
    let mut d = Drawer::new(TestClient::join(
        &invite.to_string(),
        ClientConfig::generate_key(),
    ));
    d.c.client.attach(None);
    d.c.until("driver layout", |c| c.layout.is_some()).await;
    wait_canvas(&mut d, "canvases on attach", canvas, Some(id)).await;

    // A draws a box, a pressure stroke and a label; B gets each put live.
    let mut lat = Vec::new();
    let first = [
        ex_rect("box", 1, 1_000, "a1"),
        ex_freedraw("ink", 1, 2_000, 40),
        ex_text("label", 1, 3_000, "auth service"),
    ];
    for el in &first {
        let sent = Instant::now();
        let (_, rejected) =
            a.c.client
                .excalidraw_put(id, vec![el.clone()], None, vec![])
                .await
                .unwrap();
        assert!(rejected.is_empty());
        b.until_ex(id, "a's element on b", |s| {
            ex_find(s, &el.id).as_ref() == Some(el)
        })
        .await;
        lat.push(sent.elapsed());
    }
    // The stroke grows as the editor reports it (a put per ~50 ms onChange in the app).
    for v in 2..=40u64 {
        let el = ex_freedraw("ink", v, 2_000 + v as u32, 40 + v as usize * 4);
        let sent = Instant::now();
        a.c.client
            .excalidraw_put(id, vec![el], None, vec![])
            .await
            .unwrap();
        b.until_ex(id, "stroke growth on b", |s| {
            ex_find(s, "ink").is_some_and(|e| e.version == v)
        })
        .await;
        lat.push(sent.elapsed());
    }
    println!(
        "canvas put A→daemon→B push (loopback, debug): {}",
        percentiles(lat)
    );
    let full = a.c.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(full.elements, ex_state(&a.c, id));
    assert_eq!(full.elements, ex_state(&b.c, id));
    assert_eq!(full.info.elements, 3);

    // B moves A's box (a higher version) and adds its own; the driver adds a note.
    b.c.client
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
    let (_, rejected) =
        d.c.client
            .excalidraw_put(id, vec![ex_text("note", 1, 9, "LGTM")], None, vec![])
            .await
            .unwrap();
    assert!(rejected.is_empty());
    for p in [&mut a, &mut b, &mut d] {
        p.until_ex(id, "everyone's edits", |s| {
            ex_find(s, "box").is_some_and(|e| e.json.contains("b-moved"))
                && ex_find(s, "b-box").is_some()
                && ex_find(s, "note").is_some()
        })
        .await;
    }

    // A conflict: A and B change the box at the same version at once. Excalidraw's rule
    // (a tie goes to the lower versionNonce) picks B's on every replica, in either order.
    let (ra, rb) = tokio::join!(
        a.c.client
            .excalidraw_put(id, vec![ex_rect("box", 3, 900, "a-loses")], None, vec![]),
        b.c.client
            .excalidraw_put(id, vec![ex_rect("box", 3, 400, "b-wins")], None, vec![]),
    );
    ra.unwrap();
    rb.unwrap();
    for p in [&mut a, &mut b, &mut d] {
        p.until_ex(id, "the conflict settled", |s| {
            ex_find(s, "box").is_some_and(|e| e.version_nonce == 400)
        })
        .await;
    }
    let daemon_box =
        a.c.client
            .excalidraw_get(id, 0)
            .await
            .unwrap()
            .elements
            .into_iter()
            .find(|e| e.id == "box");
    assert_eq!(daemon_box, Some(ex_rect("box", 3, 400, "b-wins")));
    assert_eq!(ex_state(&a.c, id), ex_state(&b.c, id));
    assert_eq!(ex_state(&a.c, id), ex_state(&d.c, id));

    // Live ink on the canvas from A reaches B and the driver, stamped with A (whatever A
    // claims), never echoed to A.
    let me = a.c.client.me().unwrap().actor;
    let forged = d.c.client.me().unwrap().actor;
    let mut lat = Vec::new();
    for chunk in 0..60u32 {
        let sent = Instant::now();
        a.c.client.ink_live(InkLive {
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
        for p in [&mut b, &mut d] {
            let u = p
                .wait("ink chunk", |u| {
                    is_event(u, |e| {
                        matches!(e, ArtifactEvent::Ink(i) if i.artifact_id == id && i.chunk == chunk)
                    })
                })
                .await;
            let ArtifactUpdate::Event(e) = u else {
                unreachable!()
            };
            let ArtifactEvent::Ink(ink) = *e else {
                unreachable!()
            };
            assert_eq!(ink.actor, me);
        }
        lat.push(sent.elapsed());
    }
    println!(
        "canvas ink A→daemon→B and driver (loopback, debug): {}",
        percentiles(lat)
    );

    // B deletes A's label: a tombstone at a higher version.
    b.c.client
        .excalidraw_put(
            id,
            vec![ex_deleted(ex_text("label", 2, 3_001, "auth service"))],
            None,
            vec![],
        )
        .await
        .unwrap();
    for p in [&mut a, &mut d] {
        p.until_ex(id, "label deleted", |s| {
            ex_find(s, "label").is_some_and(|e| e.deleted)
        })
        .await;
    }
    assert_eq!(a.c.client.excalidraw_scene(id).unwrap().live(), 4);
    assert!(
        !a.seen
            .iter()
            .any(|u| is_event(u, |e| matches!(e, ArtifactEvent::Ink(_))))
    );

    // B is suspended while A redraws the stroke, deletes B's box and changes the
    // background; B comes back caught up, with the canvas list again.
    b.c.client.suspend();
    a.c.client
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
    let rev = a.c.client.excalidraw_scene(id).unwrap().revision;
    b.seen.clear();
    b.c.client.reconnect();
    b.wait("b resynced", |u| {
        matches!(u, ArtifactUpdate::Synced { artifact_id, version } if *artifact_id == id && *version == rev)
    })
    .await;
    wait_canvas(&mut b, "canvases after reconnect", canvas, Some(id)).await;
    assert_eq!(ex_state(&a.c, id), ex_state(&b.c, id));
    let sb = b.c.client.excalidraw_scene(id).unwrap();
    assert_eq!(sb.live(), 3);
    assert!(sb.app_state.unwrap().contains("viewBackgroundColor"));

    // A viewer sees the canvas and the scene and follows live edits, but cannot put.
    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite =
        a.c.client
            .create_invite(spec, "owner".into())
            .await
            .unwrap();
    let mut v = Drawer::new(TestClient::join(
        &invite.to_string(),
        ClientConfig::generate_key(),
    ));
    v.c.client.attach(None);
    v.c.until("viewer layout", |c| c.layout.is_some()).await;
    wait_canvas(&mut v, "canvases on the viewer", canvas, Some(id)).await;
    let seen = v.c.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(seen.elements, ex_state(&a.c, id));
    let r =
        v.c.client
            .excalidraw_put(id, vec![ex_rect("box", 99, 0, "vandal")], None, vec![])
            .await;
    assert!(matches!(r, Err(ArtifactError::Forbidden(_))), "{r:?}");
    a.c.client
        .excalidraw_put(id, vec![ex_rect("box", 4, 1, "after-viewer")], None, vec![])
        .await
        .unwrap();
    for p in [&mut v, &mut b] {
        p.until_ex(id, "a's edit after the refused put", |s| {
            ex_find(s, "box").is_some_and(|e| e.json.contains("after-viewer"))
        })
        .await;
    }
    assert_eq!(ex_state(&v.c, id), ex_state(&a.c, id));

    // A second canvas pane on the same scene, in its own tab. Closing it keeps the scene.
    let OpOutcome::TabCreated {
        pane_id: tab_canvas,
        ..
    } =
        a.c.op(LayoutOp::NewTab {
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
    for p in [&mut a, &mut b, &mut d, &mut v] {
        wait_canvas(p, "tab canvas", tab_canvas, Some(id)).await;
    }
    for p in [&mut a, &mut b, &mut d, &mut v] {
        p.seen.clear();
    }
    assert_eq!(
        a.c.op(LayoutOp::ClosePane {
            pane_id: tab_canvas
        })
        .await,
        OpOutcome::Done
    );
    for p in [&mut a, &mut b, &mut d, &mut v] {
        wait_canvas(p, "tab canvas closed", tab_canvas, None).await;
        let left = last_canvases(p).unwrap();
        assert!(left.iter().any(|c| c.pane_id == canvas));
    }
    let kept = b.c.client.excalidraw_get(id, 0).await.unwrap();
    assert_eq!(kept.info.canvas_panes, vec![canvas]);
    assert_eq!(kept.elements, ex_state(&a.c, id));

    // Deleting the scene closes its canvas pane on every client.
    for p in [&mut a, &mut b, &mut d, &mut v] {
        p.seen.clear();
    }
    b.c.client.artifact_delete(id).await.unwrap();
    for p in [&mut a, &mut b, &mut d, &mut v] {
        p.wait("deleted", |u| {
            is_event(
                u,
                |e| matches!(e, ArtifactEvent::Deleted { artifact_id, .. } if *artifact_id == id),
            )
        })
        .await;
        wait_canvas(p, "canvas closed with its scene", canvas, None).await;
        p.c.until("canvas leaf gone", |c| !all_leaves(c).contains(&canvas))
            .await;
        assert!(p.c.client.canvas_panes(session).is_empty());
        assert!(p.c.client.excalidraw_scene(id).is_none());
    }
    assert!(matches!(
        a.c.client.excalidraw_get(id, 0).await,
        Err(ArtifactError::NotFound(_))
    ));
    drop((a, b, d, v));
    daemon.shutdown().await;
}
