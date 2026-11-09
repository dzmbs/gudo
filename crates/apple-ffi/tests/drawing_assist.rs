//! The drawing and input-assistance FFI surface against a real daemon
//! (relays off, loopback), driven the way Swift drives it: plain threads, listener objects,
//! `async` methods awaited from a foreign executor.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use gudo_core::{
    ArtifactCreate, ArtifactError, ArtifactEvent, ArtifactKind, ArtifactListener, AssistError,
    AssistEvent, AssistListener, ClientConfig, ClientEvent, ClientEventListener, CompletionKind,
    CoordSpace, DaemonClient, DrawElement, DrawElementKind, DrawOp, DrawStyle, ExportFormat,
    HistoryQuery, InkChunk, InkPoint, InkTool, PaneSize, PlaceRequest, ProgramProfile, PromptPhase,
    PromptState, Pt, RelayMode, ShapeKind, ShellKind, TransferProgress, excalidraw_element,
    generate_device_key, pack_ink_points, render_ascii, render_png, simplify_ink_points,
    sniff_image, unpack_ink_points,
};

/// Records everything a listener is told; tests poll it.
struct Recorder<T>(Mutex<Vec<T>>);

impl<T: Clone + std::fmt::Debug> Recorder<T> {
    fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(Vec::new())))
    }

    fn push(&self, item: T) {
        self.0.lock().unwrap().push(item);
    }

    fn all(&self) -> Vec<T> {
        self.0.lock().unwrap().clone()
    }

    fn wait<U>(&self, what: &str, mut f: impl FnMut(&[T]) -> Option<U>) -> U {
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if let Some(found) = f(&self.0.lock().unwrap()) {
                return found;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let all = self.0.lock().unwrap();
        panic!(
            "timed out waiting for {what}; last: {:?}",
            &all[all.len().saturating_sub(5)..]
        );
    }
}

impl ClientEventListener for Recorder<ClientEvent> {
    fn on_event(&self, event: ClientEvent) {
        self.push(event);
    }
}

impl ArtifactListener for Recorder<ArtifactEvent> {
    fn on_artifact_event(&self, event: ArtifactEvent) {
        self.push(event);
    }
}

impl AssistListener for Recorder<AssistEvent> {
    fn on_assist_event(&self, event: AssistEvent) {
        self.push(event);
    }
}

impl TransferProgress for Recorder<(u64, u64)> {
    fn on_progress(&self, done: u64, total: u64) {
        self.push((done, total));
    }
}

/// Polls `f` for up to 20 s.
fn until<U>(what: &str, mut f: impl FnMut() -> Option<U>) -> U {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Some(found) = f() {
            return found;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("timed out waiting for {what}");
}

/// A daemon running `shell` with `$HOME` (and `ZDOTDIR`) in a temporary directory that the
/// path policy allows, plus the runtime the test awaits on.
struct Host {
    runtime: tokio::runtime::Runtime,
    daemon: Option<daemon::Daemon>,
    home: PathBuf,
    _dirs: (tempfile::TempDir, tempfile::TempDir),
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

impl Host {
    fn start(shell: &str) -> Self {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let state_dir = tempfile::tempdir().unwrap();
        let home_dir = tempfile::tempdir().unwrap();
        let state = state_dir.path().canonicalize().unwrap();
        let home = home_dir.path().canonicalize().unwrap();
        let daemon = runtime.block_on(async {
            let mut config = daemon::Config::new(&state);
            config.relay = daemon::RelayMode::Disabled;
            config.bind = Some("127.0.0.1:0".parse().unwrap());
            config.shell = Some(shell.into());
            config.pane_env = vec![
                ("PS1".into(), "$ ".into()),
                ("ENV".into(), String::new()),
                ("HOME".into(), path_text(&home)),
                ("ZDOTDIR".into(), path_text(&home)),
            ];
            config.fs_allow.push(home.clone());
            daemon::Daemon::start(config).await.unwrap()
        });
        Self {
            runtime,
            daemon: Some(daemon),
            home,
            _dirs: (state_dir, home_dir),
        }
    }

    /// A paired client, connected.
    fn client(&self) -> (Arc<DaemonClient>, Arc<Recorder<ClientEvent>>) {
        let ticket = self
            .daemon
            .as_ref()
            .unwrap()
            .pairing_ticket(daemon::PAIRING_TTL)
            .unwrap()
            .to_string();
        let events = Recorder::new();
        let config = ClientConfig {
            secret_key: generate_device_key(),
            relay: RelayMode::Disabled,
            mirror_vt: true,
            repo_status: false,
            low_data_mode: false,
        };
        let client = DaemonClient::connect(ticket, config, events.clone()).unwrap();
        events.wait("connected", |all| {
            all.iter()
                .any(|e| matches!(e, ClientEvent::Connected { .. }))
                .then_some(())
        });
        (client, events)
    }

    fn block_on<F: Future>(&self, f: F) -> F::Output {
        self.runtime.block_on(f)
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        if let Some(daemon) = self.daemon.take() {
            self.runtime.block_on(daemon.shutdown());
        }
    }
}

/// Attaches to the first session and follows its focused pane: `(session, pane)`.
fn attach(client: &DaemonClient, events: &Recorder<ClientEvent>) -> (u64, u64) {
    client.attach(None);
    let session = events.wait("attached", |all| {
        all.iter().find_map(|event| match event {
            ClientEvent::Attached { session_id, .. } => Some(*session_id),
            _ => None,
        })
    });
    let layout = events.wait("layout", |all| {
        all.iter().find_map(|event| match event {
            ClientEvent::Layout { layout } => Some(layout.clone()),
            _ => None,
        })
    });
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    client.resize(
        pane,
        PaneSize {
            cols: 80,
            rows: 24,
            width_px: 0,
            height_px: 0,
        },
    );
    client.set_view(Some(pane), vec![pane]);
    (session, pane)
}

fn at_prompt(state: &PromptState) -> Option<(String, u32)> {
    match &state.phase {
        PromptPhase::AtPrompt { input } => Some((input.text.clone(), input.cursor)),
        _ => None,
    }
}

fn zsh() -> Option<&'static str> {
    ["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh"]
        .into_iter()
        .find(|p| Path::new(p).exists())
}

#[test]
fn assist_prompt_submit_history_completion_files() {
    let Some(zsh) = zsh() else {
        eprintln!("skipped: no zsh");
        return;
    };
    let host = Host::start(zsh);
    std::fs::write(host.home.join(".zshrc"), "").unwrap();
    let work = host.home.join("work");
    std::fs::create_dir_all(work.join("src")).unwrap();
    std::fs::write(work.join("src/needle-target.txt"), "x").unwrap();

    let (client, events) = host.client();
    let assist = Recorder::<AssistEvent>::new();
    client.set_assist_listener(assist.clone());
    let (_, pane) = attach(&client, &events);

    let first = host.block_on(client.watch_prompt(pane, true)).unwrap();
    assert_eq!(first.prompt.pane_id, pane);

    // The shell's integration loads, then a prompt with an empty line.
    let start = until("an empty prompt", || {
        client
            .prompt_state(pane)
            .filter(|s| at_prompt(s).is_some_and(|(t, _)| t.is_empty()))
    });

    // Foreground program and profile: the shell.
    let shell_program = until("foreground", || {
        host.block_on(client.pane_assist(pane))
            .unwrap()
            .foreground
            .filter(|f| f.profile == ProgramProfile::Shell)
    });
    assert!(shell_program.name.contains("zsh"), "{shell_program:?}");
    assert_eq!(
        client.foreground(pane).map(|f| f.pid),
        Some(shell_program.pid)
    );

    // Typed partially, then completed by hand: the prompt state follows, pushed.
    client.send_input(pane, b"echo h");
    assist.wait("partial line pushed", |all| {
        all.iter().find_map(|event| match event {
            AssistEvent::Prompt { state } => {
                at_prompt(state).filter(|(t, _)| t == "echo h").map(|_| ())
            }
            _ => None,
        })
    });
    client.send_input(pane, b"i");
    let typed = until("typed line", || {
        client
            .prompt_state(pane)
            .filter(|s| at_prompt(s).is_some_and(|(t, _)| t == "echo hi"))
    });
    assert_eq!(typed.prompt_id, start.prompt_id);
    let PromptPhase::AtPrompt { input } = &typed.phase else {
        unreachable!()
    };
    assert_eq!(input.cursor, 7);
    assert_eq!(input.shell, ShellKind::Zsh);
    assert!(input.confident, "{typed:?}");
    let now = host.block_on(client.pane_assist(pane)).unwrap();
    assert_eq!(
        at_prompt(&now.prompt).map(|(t, _)| t),
        Some("echo hi".into())
    );

    // Atomic submit runs it once.
    host.block_on(client.submit_line(pane, typed.prompt_id, "echo hi".into(), true))
        .unwrap();
    let next = until("the next prompt", || {
        client.prompt_state(pane).filter(|s| {
            s.prompt_id != typed.prompt_id && at_prompt(s).is_some_and(|(t, _)| t.is_empty())
        })
    });
    let text = client.pane_text(pane).unwrap();
    assert_eq!(
        text.lines().filter(|l| l.trim_end() == "hi").count(),
        1,
        "{text}"
    );

    // A stale prompt id is refused with the state now, and nothing is written.
    let err = host
        .block_on(client.submit_line(pane, typed.prompt_id, "echo again".into(), true))
        .unwrap_err();
    match err {
        AssistError::NotAtPrompt { state } => assert_eq!(state.prompt_id, next.prompt_id),
        other => panic!("expected NotAtPrompt, got {other:?}"),
    }

    // History shows it, once.
    let entry = until("history entry", || {
        host.block_on(client.history(HistoryQuery {
            cwd: None,
            prefix: Some("echo".into()),
            contains: None,
            since_ms: None,
            limit: 10,
        }))
        .unwrap()
        .into_iter()
        .find(|e| e.command == "echo hi")
    });
    assert_eq!(entry.count, 1);
    assert_eq!(entry.exit, Some(0));

    // Completion: "ec" offers echo.
    let completions = host
        .block_on(client.complete(pane, "ec".into(), 2, 50))
        .unwrap();
    let echo = completions
        .items
        .iter()
        .find(|c| c.text.starts_with("echo"))
        .unwrap_or_else(|| panic!("no echo in {completions:?}"));
    assert!(
        matches!(echo.kind, CompletionKind::Command | CompletionKind::History),
        "{echo:?}"
    );
    assert_eq!((echo.start, echo.end), (0, 2));

    // File search finds the temporary file; outside the allowed roots is denied.
    let found = host
        .block_on(client.file_search("needtarg".into(), path_text(&work), 20))
        .unwrap();
    assert_eq!(
        found.matches.first().map(|m| m.path.as_str()),
        Some("src/needle-target.txt"),
        "{found:?}"
    );
    assert!(!found.matches[0].positions.is_empty());
    let denied = host
        .block_on(client.file_search("x".into(), "/etc".into(), 5))
        .unwrap_err();
    assert!(matches!(denied, AssistError::Denied { .. }), "{denied:?}");

    // A shell is not blocked on anything.
    assert_eq!(host.block_on(client.blocked_options(pane)).unwrap(), None);

    host.block_on(client.watch_prompt(pane, false)).unwrap();
}

fn stroke(id: u64, points: &[(f32, f32)]) -> DrawElement {
    let pts: Vec<InkPoint> = points
        .iter()
        .enumerate()
        .map(|(i, &(x, y))| InkPoint {
            x,
            y,
            pressure: 0.5,
            altitude: 1.2,
            azimuth: 0.0,
            t_ms: i as u32 * 4,
        })
        .collect();
    DrawElement {
        id,
        z: 0,
        style: DrawStyle {
            color: 0x2266_ccff,
            width: 3.0,
        },
        kind: DrawElementKind::Stroke {
            tool: InkTool::Pen,
            points: pack_ink_points(pts),
        },
    }
}

fn rect(id: u64) -> DrawElement {
    DrawElement {
        id,
        z: 1,
        style: DrawStyle {
            color: 0x0000_00ff,
            width: 2.0,
        },
        kind: DrawElementKind::Shape {
            shape: ShapeKind::Rect,
            from: Pt { x: 0.0, y: 0.0 },
            to: Pt { x: 120.0, y: 60.0 },
            filled: false,
        },
    }
}

#[test]
fn drawing_two_clients_ink_export_place_send() {
    let host = Host::start("/bin/sh");
    let (alice, alice_events) = host.client();
    let (bob, bob_events) = host.client();
    let b_art = Recorder::<ArtifactEvent>::new();
    bob.set_artifact_listener(b_art.clone());
    let a_art = Recorder::<ArtifactEvent>::new();
    alice.set_artifact_listener(a_art.clone());
    let (session, pane) = attach(&alice, &alice_events);
    let (b_session, b_pane) = attach(&bob, &bob_events);
    assert_eq!((b_session, b_pane), (session, pane));

    // Create: the other client hears it.
    let info = host
        .block_on(alice.artifact_create(ArtifactCreate {
            session_id: session,
            kind: ArtifactKind::Drawing,
            title: "sketch".into(),
            space: CoordSpace::Canvas,
            anchor: None,
            image: None,
            ops: vec![],
        }))
        .unwrap();
    assert_eq!(info.version, 0);
    let id = info.artifact_id;
    b_art.wait("created", |all| {
        all.iter()
            .any(|e| matches!(e, ArtifactEvent::Created { info } if info.artifact_id == id))
            .then_some(())
    });

    // Live ink reaches the other client (and not the sender).
    let line: Vec<(f32, f32)> = (0..40).map(|i| (i as f32 * 3.0, 10.0)).collect();
    let pts: Vec<InkPoint> = line
        .iter()
        .map(|&(x, y)| InkPoint {
            x,
            y,
            pressure: 1.0,
            altitude: 1.5707964,
            azimuth: 0.0,
            t_ms: 0,
        })
        .collect();
    assert_eq!(simplify_ink_points(pts.clone(), 0.5).len(), 2);
    let packed = pack_ink_points(pts.clone());
    assert_eq!(unpack_ink_points(packed.clone()).unwrap(), pts);
    alice.ink_live(InkChunk {
        artifact_id: id,
        stroke_id: 7,
        chunk: 0,
        tool: InkTool::Pen,
        style: DrawStyle {
            color: 0xff00_00ff,
            width: 2.0,
        },
        points: packed.clone(),
        done: true,
    });
    let ink = b_art.wait("live ink", |all| {
        all.iter().find_map(|event| match event {
            ArtifactEvent::Ink { ink } if ink.stroke_id == 7 => Some(ink.clone()),
            _ => None,
        })
    });
    assert_eq!(ink.artifact_id, id);
    assert_eq!(unpack_ink_points(ink.points).unwrap().len(), 40);
    assert_eq!(ink.actor, alice.me().unwrap().actor);

    // A stroke and a rectangle as one batch: the other client gets the change and its
    // cached scene follows.
    let version = host
        .block_on(alice.artifact_apply(
            id,
            0,
            vec![
                DrawOp::Add {
                    element: stroke(7, &line),
                },
                DrawOp::Add { element: rect(8) },
            ],
        ))
        .unwrap();
    assert_eq!(version, 1);
    let batch = b_art.wait("changed", |all| {
        all.iter().find_map(|event| match event {
            ArtifactEvent::Changed { info, batch } if info.artifact_id == id => Some(batch.clone()),
            _ => None,
        })
    });
    assert_eq!(batch.version, 1);
    assert_eq!(batch.ops.len(), 2);
    let cached = until("b's cache", || {
        bob.artifact_scene(id).filter(|c| c.version == 1)
    });
    assert_eq!(
        cached.elements.iter().map(|e| e.id).collect::<Vec<_>>(),
        [7, 8]
    );
    let scene = host.block_on(bob.artifact_get(id, 0)).unwrap();
    assert_eq!(scene.info.version, 1);
    assert!(
        a_art
            .all()
            .iter()
            .all(|e| !matches!(e, ArtifactEvent::Ink { .. }))
    );

    // Export: SVG and ASCII from the daemon; ASCII on the device matches.
    let svg = host
        .block_on(bob.artifact_export(id, None, ExportFormat::Svg))
        .unwrap();
    assert_eq!(svg.version, 1);
    let svg = String::from_utf8(svg.data.0).unwrap();
    assert!(svg.contains("<svg") && svg.contains("<path"), "{svg}");
    let ascii = host
        .block_on(bob.artifact_export(id, Some(1), ExportFormat::Ascii))
        .unwrap();
    let ascii = String::from_utf8(ascii.data.0).unwrap();
    assert!(ascii.contains('┌') && ascii.contains('┘'), "{ascii}");
    let local = render_ascii(cached.elements.clone(), CoordSpace::Canvas, 80).unwrap();
    assert!(local.contains('┌'), "{local}");

    // Blobs with progress: a PNG rendered on the device, up and down.
    let png = render_png(
        cached.elements.clone(),
        CoordSpace::Canvas,
        2.0,
        0xffff_ffff,
    )
    .unwrap();
    let sniffed = sniff_image(png.clone()).unwrap();
    assert!(sniffed.width > 100, "{sniffed:?}");
    let up = Recorder::<(u64, u64)>::new();
    let image = host
        .block_on(alice.blob_upload(session, png.clone(), Some(up.clone())))
        .unwrap();
    assert_eq!(image.size, png.len() as u64);
    assert_eq!(up.all().last(), Some(&(png.len() as u64, png.len() as u64)));
    let down = Recorder::<(u64, u64)>::new();
    let blob = host
        .block_on(bob.blob_download(image.hash.clone(), Some(down.clone())))
        .unwrap();
    assert_eq!(blob.data, png);
    assert_eq!(
        down.all().last(),
        Some(&(png.len() as u64, png.len() as u64))
    );

    // Place the device's render inline in the pane: the other client sees it placed.
    let placed = host
        .block_on(alice.place_png(
            PlaceRequest {
                pane_id: pane,
                artifact_id: id,
                version: None,
                anchor: None,
                col: 2,
                cols: 20,
                rows: 0,
                replace: None,
            },
            png.clone(),
        ))
        .unwrap();
    assert_eq!(placed.image.hash, image.hash);
    assert_eq!((placed.col, placed.cols), (2, 20));
    let seen = b_art.wait("placed", |all| {
        all.iter().find_map(|event| match event {
            ArtifactEvent::Placed { placement } => Some(placement.clone()),
            _ => None,
        })
    });
    assert_eq!(seen.placement_id, placed.placement_id);
    assert_eq!(bob.placements(pane), vec![seen.clone()]);
    assert_eq!(
        host.block_on(bob.list_placements(pane)).unwrap(),
        vec![seen.clone()]
    );
    host.block_on(alice.unplace(placed.placement_id)).unwrap();
    b_art.wait("unplaced", |all| {
        all.iter()
            .any(|event| {
                matches!(event, ArtifactEvent::Unplaced { placement_id, .. }
                    if *placement_id == placed.placement_id)
            })
            .then_some(())
    });
    until("placements emptied", || {
        bob.placements(pane).is_empty().then_some(())
    });

    // Send to agent into a shell pane: typed refusal.
    let err = host
        .block_on(alice.send_to_agent(pane, Some(id), None, None))
        .unwrap_err();
    assert_eq!(err, ArtifactError::NotAgentPane);

    // An Excalidraw scene: a put reaches the other client and its cache.
    let scene = host
        .block_on(alice.artifact_create(ArtifactCreate {
            session_id: session,
            kind: ArtifactKind::Excalidraw,
            title: String::new(),
            space: CoordSpace::Canvas,
            anchor: None,
            image: None,
            ops: vec![],
        }))
        .unwrap();
    let json = r#"{"id":"r1","type":"rectangle","x":0,"y":0,"width":100,"height":40,"version":2,"versionNonce":5,"isDeleted":false}"#;
    let element = excalidraw_element(json.into()).unwrap();
    assert_eq!((element.id.as_str(), element.version), ("r1", 2));
    let applied = host
        .block_on(alice.excalidraw_put(scene.artifact_id, vec![element.clone()], None, vec![]))
        .unwrap();
    assert!(applied.rejected.is_empty());
    b_art.wait("excalidraw push", |all| {
        all.iter()
            .any(|event| {
                matches!(event, ArtifactEvent::Excalidraw { artifact_id, elements, .. }
                    if *artifact_id == scene.artifact_id && elements.iter().any(|x| x.id == "r1"))
            })
            .then_some(())
    });
    let cached = until("b's excalidraw cache", || {
        bob.excalidraw_scene(scene.artifact_id)
            .filter(|s| s.elements.iter().any(|e| e.id == "r1"))
    });
    assert_eq!(cached.revision, applied.version);
    let fetched = host
        .block_on(bob.excalidraw_get(scene.artifact_id, 0))
        .unwrap();
    assert_eq!(fetched.elements, vec![element]);

    // List and delete.
    let list = host.block_on(bob.list_artifacts(session)).unwrap();
    assert!(
        list.iter()
            .any(|i| i.artifact_id == id && i.title == "sketch")
    );
    host.block_on(alice.artifact_delete(id)).unwrap();
    b_art.wait("deleted", |all| {
        all.iter()
            .any(|e| matches!(e, ArtifactEvent::Deleted { artifact_id, .. } if *artifact_id == id))
            .then_some(())
    });
    let gone = host.block_on(bob.artifact_get(id, 0)).unwrap_err();
    assert!(matches!(gone, ArtifactError::NotFound { .. }), "{gone:?}");
}
