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

    // A canvas pane splits off the terminal with a new drawing.
    let OpOutcome::PaneCreated { pane_id: canvas } = owner
        .c
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Canvas { artifact_id: None },
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
