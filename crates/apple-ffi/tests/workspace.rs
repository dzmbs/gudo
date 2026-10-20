//! drives it: plain threads, listener objects, `async` methods awaited from a foreign
//! executor. One call (or flow) from each group: files, git, forwards, multiplayer,
//! attention, the editor, push.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use unnamed_core::{
    ApprovalMode, ApprovalPolicy, ConnectOptions, KnockListener, KnockResult, Risk, knock_invite,
};
use unnamed_core::{
    AttentionKind, AttentionSeen, AttentionUpdate, Axis, ClientConfig, ClientEvent,
    ClientEventListener, DaemonClient, DeleteMode, DiffBase, EditorKind, FileChange, FileKind,
    ForwardTarget, GitDiffRequest, InputRejectReason, InviteOptions, LayoutOp, MultiplayerEvent,
    MultiplayerListener, OpOutcome, PaneLaunch, PaneSize, PushError, PushPrefs, PushRegistration,
    RelayMode, RevokeTarget, Role, Scope, TransferProgress, WorkspaceError, WorkspaceEvent,
    WorkspaceListener, WriteTarget, generate_device_key, generate_push_seal_key, inspect_invite,
    open_push_notification, push_relay_register_body, push_seal_public_key,
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

impl WorkspaceListener for Recorder<WorkspaceEvent> {
    fn on_workspace_event(&self, event: WorkspaceEvent) {
        self.push(event);
    }
}

impl MultiplayerListener for Recorder<MultiplayerEvent> {
    fn on_multiplayer_event(&self, event: MultiplayerEvent) {
        self.push(event);
    }
}

impl TransferProgress for Recorder<(u64, u64)> {
    fn on_progress(&self, done: u64, total: u64) {
        self.push((done, total));
    }
}

/// A daemon whose `$HOME` (path policy, panes) is a temporary directory, with no `code`
/// CLI, plus the runtime the test awaits on.
struct Host {
    rt: tokio::runtime::Runtime,
    daemon: Option<daemon::Daemon>,
    state: PathBuf,
    home: PathBuf,
    _dirs: (tempfile::TempDir, tempfile::TempDir),
}

fn canonical_tempdir() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().canonicalize().unwrap();
    (dir, path)
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

impl Host {
    fn start() -> Self {
        Self::start_with(|_| {})
    }

    /// A host whose daemon config `f` adjusts last.
    fn start_with(f: impl FnOnce(&mut daemon::Config)) -> Self {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (state_dir, state) = canonical_tempdir();
        let (home_dir, home) = canonical_tempdir();
        let daemon = rt.block_on(async {
            let mut config = daemon::Config::new(&state);
            config.relay = daemon::RelayMode::Disabled;
            config.bind = Some("127.0.0.1:0".parse().unwrap());
            config.shell = Some("/bin/sh".into());
            config.pane_env = vec![
                ("PS1".into(), "$ ".into()),
                ("ENV".into(), String::new()),
                ("HOME".into(), s(&home)),
            ];
            config.fs_allow.push(home.clone());
            // No user `code` CLI, whatever this machine has installed.
            config.code_cli = Some(state.join("no-such-code"));
            f(&mut config);
            daemon::Daemon::start(config).await.unwrap()
        });
        Self {
            rt,
            daemon: Some(daemon),
            state,
            home,
            _dirs: (state_dir, home_dir),
        }
    }

    fn ticket(&self) -> String {
        self.daemon
            .as_ref()
            .unwrap()
            .pairing_ticket(daemon::PAIRING_TTL)
            .unwrap()
            .to_string()
    }

    /// A paired client, connected.
    fn client(&self) -> (Arc<DaemonClient>, Arc<Recorder<ClientEvent>>) {
        let events = Recorder::new();
        let client = DaemonClient::connect(self.ticket(), config(), events.clone()).unwrap();
        connected(&events);
        (client, events)
    }

    fn block_on<F: Future>(&self, f: F) -> F::Output {
        self.rt.block_on(f)
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        if let Some(d) = self.daemon.take() {
            self.rt.block_on(d.shutdown());
        }
    }
}

fn config() -> ClientConfig {
    ClientConfig {
        secret_key: generate_device_key(),
        relay: RelayMode::Disabled,
        mirror_vt: true,
        repo_status: false,
    }
}

fn connected(events: &Recorder<ClientEvent>) {
    events.wait("connected", |all| {
        all.iter()
            .any(|e| matches!(e, ClientEvent::Connected { .. }))
            .then_some(())
    });
}

/// Attaches and follows the first tab's focused pane.
fn attach(client: &DaemonClient, events: &Recorder<ClientEvent>) -> u64 {
    client.attach(None);
    let layout = events.wait("layout", |all| {
        all.iter().find_map(|e| match e {
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
    pane
}

fn target(path: &Path) -> WriteTarget {
    WriteTarget {
        path: s(path),
        if_match: None,
        create_new: false,
        mkdirs: true,
        mode: None,
    }
}

#[test]
fn files_round_trip_with_transfers() {
    let host = Host::start();
    let (client, _events) = host.client();
    let dir = host.home.join("proj");

    let made = host.block_on(client.fs_mkdir(s(&dir), true)).unwrap();
    assert_eq!(made.kind, FileKind::Dir);
    let written = host
        .block_on(client.fs_write(target(&dir.join("a.txt")), b"hello ffi".to_vec().into()))
        .unwrap();
    assert_eq!(written.size, 9);
    let chunk = host
        .block_on(client.fs_read(s(&dir.join("a.txt")), 6, 100))
        .unwrap();
    assert_eq!(&*chunk.data, b"ffi");
    assert!(chunk.eof);

    // A stale version is a typed conflict.
    let mut stale = target(&dir.join("a.txt"));
    stale.if_match = Some("0-0-0".into());
    let err = host
        .block_on(client.fs_write(stale, b"x".to_vec().into()))
        .unwrap_err();
    assert!(matches!(err, WorkspaceError::Conflict { .. }), "{err:?}");
    // Outside $HOME is denied.
    let err = host
        .block_on(client.fs_list("/etc".into(), false))
        .unwrap_err();
    assert!(matches!(err, WorkspaceError::Denied { .. }), "{err:?}");

    // Upload a file with progress, download it back.
    let big: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    let local = host.state.join("local.bin");
    std::fs::write(&local, &big).unwrap();
    let up = Recorder::new();
    let stat = host
        .block_on(client.upload_file(s(&local), target(&dir.join("big.bin")), Some(up.clone())))
        .unwrap();
    assert_eq!(stat.size, big.len() as u64);
    assert_eq!(up.0.lock().unwrap().last(), Some(&(300_000, 300_000)));
    let back = host.state.join("back.bin");
    let down = Recorder::new();
    host.block_on(client.download_file(
        s(&dir.join("big.bin")),
        s(&back),
        0,
        None,
        Some(down.clone()),
    ))
    .unwrap();
    assert_eq!(std::fs::read(&back).unwrap(), big);
    assert!(!down.0.lock().unwrap().is_empty());

    host.block_on(client.fs_rename(s(&dir.join("a.txt")), s(&dir.join("b.txt")), false))
        .unwrap();
    let listing = host.block_on(client.fs_list(s(&dir), false)).unwrap();
    let names: Vec<_> = listing.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["b.txt", "big.bin"]);
    host.block_on(client.fs_delete(s(&dir.join("b.txt")), DeleteMode::Permanent, false))
        .unwrap();
    let err = host
        .block_on(client.fs_stat(s(&dir.join("b.txt"))))
        .unwrap_err();
    assert!(matches!(err, WorkspaceError::NotFound { .. }), "{err:?}");
}

#[test]
fn git_status_and_diff_in_a_temp_repo() {
    let host = Host::start();
    let repo = host.home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let git = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .args(args)
            .current_dir(&repo)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {out:?}");
    };
    git(&["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("tracked.txt"), "one\n").unwrap();
    git(&["add", "."]);
    git(&[
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-qm",
        "first",
    ]);
    std::fs::write(repo.join("tracked.txt"), "one\ntwo\n").unwrap();
    std::fs::write(repo.join("new.txt"), "new\n").unwrap();

    let (client, _events) = host.client();
    let status = host.block_on(client.git_status(s(&repo))).unwrap();
    assert_eq!(status.branch.as_deref(), Some("main"));
    assert!(status.head.is_some());
    let change = |p: &str| {
        status
            .files
            .iter()
            .find(|f| f.path == p)
            .map(|f| (f.staged, f.unstaged))
    };
    assert_eq!(
        change("tracked.txt"),
        Some((FileChange::Unmodified, FileChange::Modified))
    );
    assert_eq!(
        change("new.txt"),
        Some((FileChange::Untracked, FileChange::Untracked))
    );

    let diff = host
        .block_on(client.git_diff(GitDiffRequest {
            path: s(&repo),
            base: DiffBase::Head,
            files: vec![],
            context: 3,
            hunks: true,
        }))
        .unwrap();
    let tracked = diff.files.iter().find(|f| f.path == "tracked.txt").unwrap();
    assert_eq!((tracked.additions, tracked.deletions), (1, 0));
    assert!(tracked.hunks[0].lines.iter().any(|l| l.text == "two"));

    let err = host.block_on(client.git_status(s(&host.home))).unwrap_err();
    assert!(matches!(err, WorkspaceError::NotFound { .. }), "{err:?}");
}

#[test]
fn forward_reaches_a_local_echo_server_and_stops() {
    let host = Host::start();
    let echo = TcpListener::bind("127.0.0.1:0").unwrap();
    let echo_port = echo.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for conn in echo.incoming() {
            let Ok(mut conn) = conn else { break };
            std::thread::spawn(move || {
                let mut buf = [0; 1024];
                while let Ok(n) = conn.read(&mut buf) {
                    if n == 0 || conn.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            });
        }
    });

    let (client, _events) = host.client();
    let local = client
        .forward(0, ForwardTarget::Tcp { port: echo_port })
        .unwrap();
    assert_ne!(local, 0);
    assert_eq!(client.forwards().len(), 1);
    assert_eq!(
        client.forwards()[0].target,
        ForwardTarget::Tcp { port: echo_port }
    );
    for round in 0..3 {
        let mut conn = TcpStream::connect(("127.0.0.1", local)).unwrap();
        conn.set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let msg = format!("ping {round}");
        conn.write_all(msg.as_bytes()).unwrap();
        let mut got = vec![0; msg.len()];
        conn.read_exact(&mut got).unwrap();
        assert_eq!(got, msg.as_bytes());
    }
    assert!(client.stop_forward(local));
    assert!(!client.stop_forward(local));
    assert!(client.forwards().is_empty());
}

#[test]
fn invite_join_and_a_viewer_cannot_type() {
    let host = Host::start();
    let (owner, owner_events) = host.client();
    let pane = attach(&owner, &owner_events);

    let invite = host
        .block_on(owner.create_invite(InviteOptions {
            roles: vec![Role::Viewer],
            scope: Scope::Daemon,
            ttl_secs: Some(3600),
            max_uses: Some(1),
            delegate: false,
            label: "carol".into(),
            inviter: "alice".into(),
            knock: false,
            since_join: false,
        }))
        .unwrap();
    assert!(
        invite.link.starts_with("unnamed://join/"),
        "{}",
        invite.link
    );
    assert_eq!(invite.qr_payload, invite.link.to_ascii_uppercase());
    let info = inspect_invite(invite.qr_payload.clone()).unwrap();
    assert_eq!(info.roles, [Role::Viewer]);
    assert_eq!(
        (info.inviter.as_str(), info.label.as_str()),
        ("alice", "carol")
    );
    assert!(info.expires_ms.is_some());

    let guest_events = Recorder::new();
    let guest_mp: Arc<Recorder<MultiplayerEvent>> = Recorder::new();
    let guest = DaemonClient::join(invite.link.clone(), config(), guest_events.clone()).unwrap();
    guest.set_multiplayer_listener(guest_mp.clone());
    connected(&guest_events);
    let me = guest_mp.wait("joined", |all| {
        all.iter().find_map(|e| match e {
            MultiplayerEvent::Joined { info } => Some(info.clone()),
            _ => None,
        })
    });
    assert_eq!(me.roles, [Role::Viewer]);
    assert_eq!(me.grant_id.as_deref(), Some(invite.grant_id.as_str()));
    assert_eq!(guest.me().unwrap().name, "carol");

    // The viewer sees the pane but its keystrokes are refused.
    let guest_pane = attach(&guest, &guest_events);
    assert_eq!(guest_pane, pane);
    guest_events.wait("snapshot", |all| {
        all.iter()
            .any(|e| matches!(e, ClientEvent::PaneSnapshot { .. }))
            .then_some(())
    });
    guest.send_input(pane, b"echo viewer-typed\r");
    guest_mp.wait("input refused", |all| {
        all.iter()
            .any(|e| {
                matches!(e, MultiplayerEvent::InputRejected { pane_id, reason }
                    if *pane_id == pane && *reason == InputRejectReason::Role)
            })
            .then_some(())
    });
    guest.set_typing(pane, true);
    let err = host.block_on(guest.take_control(pane, false)).unwrap_err();
    assert!(
        matches!(err, unnamed_core::MultiplayerError::Forbidden { .. }),
        "{err:?}"
    );

    // The owner sees both, lists and revokes the grant; the guest is told.
    let participants = host.block_on(owner.participants()).unwrap();
    assert_eq!(participants.len(), 2, "{participants:?}");
    let grants = host.block_on(owner.list_grants()).unwrap();
    assert!(grants.iter().any(|g| g.grant.grant_id == invite.grant_id));
    let revoked = host
        .block_on(owner.revoke(RevokeTarget::Grant {
            grant_id: invite.grant_id.clone(),
        }))
        .unwrap();
    assert_eq!(revoked.grants, std::slice::from_ref(&invite.grant_id));
    guest_mp.wait("revoked", |all| {
        all.iter()
            .any(|e| matches!(e, MultiplayerEvent::Revoked))
            .then_some(())
    });
    let audit = host.block_on(owner.audit(None, 100)).unwrap();
    assert!(audit.chain_ok);
    assert!(!audit.records.is_empty());
}

#[test]
fn attention_items_are_marked_seen() {
    let host = Host::start();
    let (client, events) = host.client();
    let ws = Recorder::new();
    client.set_workspace_listener(ws.clone());
    let shown = attach(&client, &events);
    let outcome = host
        .block_on(client.perform(LayoutOp::Split {
            pane_id: shown,
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        }))
        .unwrap();
    let OpOutcome::PaneCreated { pane_id: hidden } = outcome else {
        panic!("{outcome:?}")
    };
    client.set_view(Some(shown), vec![shown]);
    std::thread::sleep(Duration::from_millis(100));

    // An agent in the hidden pane finishes a turn (as its hooks report it).
    let hook = |event: &str, extra: serde_json::Value| {
        let mut payload = serde_json::json!({
            "session_id": "s", "cwd": s(&host.home), "hook_event_name": event,
        });
        payload
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        let request = daemon::HookRequest {
            v: 1,
            token: std::fs::read_to_string(host.state.join("hook.token")).unwrap(),
            pane: hidden.to_string(),
            agent: "claude".into(),
            event: event.into(),
            seq: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64,
            payload,
        };
        let socket = host.daemon.as_ref().unwrap().hook_socket();
        let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
        let mut line = serde_json::to_vec(&request).unwrap();
        line.push(b'\n');
        stream.write_all(&line).unwrap();
        let mut answer = String::new();
        std::io::BufRead::read_line(&mut std::io::BufReader::new(stream), &mut answer).unwrap();
    };
    hook("UserPromptSubmit", serde_json::json!({"prompt": "go"}));
    hook(
        "Stop",
        serde_json::json!({"last_assistant_message": "All tests pass."}),
    );
    let item = ws.wait("done item", |all| {
        all.iter().find_map(|e| match e {
            WorkspaceEvent::Attention {
                update: AttentionUpdate::Added { item, .. },
            } if matches!(item.kind, AttentionKind::AgentDone { .. }) => Some(item.clone()),
            _ => None,
        })
    });
    assert_eq!(item.pane_id, hidden);
    assert_eq!(item.body, "All tests pass.");
    assert!(!item.seen);
    let list = host.block_on(client.attention_list()).unwrap();
    assert!(list.unseen >= 1, "{list:?}");

    let list = host
        .block_on(client.attention_seen(AttentionSeen {
            ids: vec![item.id],
            up_to: None,
            pane_id: None,
        }))
        .unwrap();
    assert!(list.items.iter().any(|i| i.id == item.id && i.seen));
    ws.wait("seen pushed", |all| {
        all.iter()
            .any(|e| {
                matches!(e, WorkspaceEvent::Attention { update: AttentionUpdate::Seen { ids, .. } }
                    if ids.contains(&item.id))
            })
            .then_some(())
    });
}

#[test]
fn editor_without_code_cli_is_a_clear_error() {
    let host = Host::start();
    let (client, _events) = host.client();
    let status = host.block_on(client.editor_status()).unwrap();
    let vscode = status
        .available
        .iter()
        .find(|a| a.kind == EditorKind::VsCode)
        .unwrap();
    assert!(!vscode.installed);
    assert!(status.running.is_empty());

    // The default flow asks for nothing it cannot do: no CLI and no licence accepted → a
    // typed error saying what to do; never a sign-in.
    let err = host
        .block_on(client.open_editor(s(&host.home), false))
        .unwrap_err();
    let WorkspaceError::Unavailable { message } = &err else {
        panic!("{err:?}")
    };
    assert!(
        message.contains("not installed") && message.contains("licence"),
        "{message}"
    );
    assert!(client.forwards().is_empty());
    let tunnel = host.block_on(client.vscode_tunnel_status()).unwrap();
    assert!(tunnel.cli.is_none());
}

/// A stand-in `codium-server`: records its arguments, serves `200` with the token, `403`
/// without.
const FAKE_CODIUM: &str = r#"#!/usr/bin/env python3
import http.server, sys, os
args = sys.argv[1:]
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "args.txt"), "w") as f:
    f.write(" ".join(args))
port = int(args[args.index("--port") + 1])
token = args[args.index("--connection-token") + 1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if ("tkn=" + token) in self.path else 403)
        self.end_headers()
        self.wfile.write(b"fake codium")
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"#;

fn install_fake_codium(dir: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let bin = dir.join("bin/codium-server");
    std::fs::create_dir_all(bin.parent().unwrap()).unwrap();
    std::fs::write(&bin, FAKE_CODIUM).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn open_editor_with_vscodium_needs_no_licence() {
    if std::process::Command::new("python3")
        .arg("--version")
        .output()
        .is_err()
    {
        eprintln!("skipping: python3 not installed");
        return;
    }
    let codium = tempfile::tempdir().unwrap();
    install_fake_codium(codium.path());
    let dir = codium.path().to_owned();
    let host = Host::start_with(move |c| c.vscodium_dir = Some(dir));
    let (client, _events) = host.client();

    // No `code` CLI and no licence accepted: VSCodium still opens, and nothing is installed.
    let session = host
        .block_on(client.open_editor_with(s(&host.home), false, Some(EditorKind::Vscodium)))
        .unwrap();
    assert_eq!(session.instance.kind, EditorKind::Vscodium);
    assert!(!session.installed_cli);
    assert!(
        session
            .url
            .contains(&format!("tkn={}", session.instance.token)),
        "{}",
        session.url
    );
    let args = std::fs::read_to_string(codium.path().join("bin/args.txt")).unwrap();
    assert!(args.contains("--host 127.0.0.1"), "{args}");
    assert!(!args.contains("license"), "{args}");
    let tunnel = host.block_on(client.vscode_tunnel_status()).unwrap();
    assert!(tunnel.cli.is_none(), "the code CLI was installed");

    // The page is served through the forward, with the token only.
    let path = session
        .url
        .trim_start_matches(&format!("http://localhost:{}", session.local_port));
    let get = |path: &str| {
        let mut tcp = TcpStream::connect(("127.0.0.1", session.local_port)).unwrap();
        write!(tcp, "GET {path} HTTP/1.0\r\nHost: localhost\r\n\r\n").unwrap();
        let mut out = String::new();
        tcp.read_to_string(&mut out).unwrap();
        out
    };
    assert!(get(path).starts_with("HTTP/1.0 200"));
    assert!(get("/").starts_with("HTTP/1.0 403"));

    // Asking for VS Code explicitly still needs the licence.
    host.block_on(client.close_editor(session, true)).unwrap();
    let err = host
        .block_on(client.open_editor_with(s(&host.home), false, Some(EditorKind::VsCode)))
        .unwrap_err();
    assert!(matches!(err, WorkspaceError::Unavailable { .. }), "{err:?}");
}

#[test]
fn open_editor_follows_the_configured_default() {
    if std::process::Command::new("python3")
        .arg("--version")
        .output()
        .is_err()
    {
        eprintln!("skipping: python3 not installed");
        return;
    }
    let codium = tempfile::tempdir().unwrap();
    install_fake_codium(codium.path());
    let dir = codium.path().to_owned();
    let host = Host::start_with(move |c| {
        c.vscodium_dir = Some(dir);
        c.editor_default = client_core::proto::EditorKind::Vscodium;
    });
    let (client, _events) = host.client();
    let session = host
        .block_on(client.open_editor(s(&host.home), false))
        .unwrap();
    assert_eq!(session.instance.kind, EditorKind::Vscodium);
    let status = host.block_on(client.editor_status()).unwrap();
    let codium = status
        .available
        .iter()
        .find(|a| a.kind == EditorKind::Vscodium)
        .unwrap();
    assert!(codium.installed);
    assert_eq!(status.running.len(), 1);
}

/// `openEditor(folder:)` falls back to VSCodium, without a prompt, when Microsoft's CLI
/// cannot be obtained (the download fails) or cannot run on the host.
#[test]
fn open_editor_falls_back_to_vscodium_when_vscode_cannot_be_had() {
    use std::os::unix::fs::PermissionsExt;
    if std::process::Command::new("python3")
        .arg("--version")
        .output()
        .is_err()
    {
        eprintln!("skipping: python3 not installed");
        return;
    }
    let codium = tempfile::tempdir().unwrap();
    install_fake_codium(codium.path());

    // 1. No CLI, and Microsoft's update service unreachable.
    let dir = codium.path().to_owned();
    let blocked = codium.path().join("no-such-update-service");
    let host = Host::start_with(move |c| {
        c.vscodium_dir = Some(dir);
        c.vscode_update_url = format!("file://{}", blocked.display());
    });
    let (client, _events) = host.client();
    // Without the licence accepted nothing changes: the typed licence error, no fallback.
    assert!(matches!(
        host.block_on(client.open_editor(s(&host.home), false)),
        Err(WorkspaceError::Unavailable { .. })
    ));
    let session = host
        .block_on(client.open_editor(s(&host.home), true))
        .unwrap();
    assert_eq!(session.instance.kind, EditorKind::Vscodium);
    assert!(!session.installed_cli);
    assert!(session.fallback_reason.is_some(), "{session:?}");
    drop(client);
    drop(host);

    // 2. A `code` CLI that cannot run here (wrong libc, say).
    let broken = tempfile::tempdir().unwrap();
    let code = broken.path().join("code");
    std::fs::write(
        &code,
        "#!/bin/sh\necho 'code: not found (musl loader)' >&2\nexit 127\n",
    )
    .unwrap();
    std::fs::set_permissions(&code, std::fs::Permissions::from_mode(0o755)).unwrap();
    let dir = codium.path().to_owned();
    let host = Host::start_with(move |c| {
        c.vscodium_dir = Some(dir);
        c.code_cli = Some(code);
    });
    let (client, _events) = host.client();
    let session = host
        .block_on(client.open_editor(s(&host.home), true))
        .unwrap();
    assert_eq!(session.instance.kind, EditorKind::Vscodium);
    let reason = session.fallback_reason.unwrap();
    assert!(reason.contains("musl loader"), "{reason}");
}

#[test]
fn push_register_status_unregister() {
    let host = Host::start();
    let (client, _events) = host.client();
    let key = generate_push_seal_key();
    assert_eq!(key.secret.len(), 32);
    assert_eq!(
        push_seal_public_key(key.secret.clone()).unwrap(),
        key.public_key
    );
    let body: serde_json::Value = serde_json::from_str(&push_relay_register_body(
        vec![0xab; 32].into(),
        unnamed_core::ApnsEnvironment::Sandbox,
        "AB".repeat(32),
        unnamed_core::PushCapKind::Alert,
    ))
    .unwrap();
    assert_eq!(body["token"], "ab".repeat(32));
    assert_eq!(body["env"], "sandbox");
    assert_eq!(body["daemon"], "ab".repeat(32));
    assert_eq!(body["kind"], "alert");

    let prefs = PushPrefs {
        approvals: true,
        blocked: false,
        done: true,
        failed: true,
        commands: false,
    };
    let status = host
        .block_on(client.push_register(PushRegistration {
            cap: "v1.test-capability".into(),
            seal_key: key.public_key.clone(),
            relay_url: None,
            prefs,
            activity_cap: None,
        }))
        .unwrap();
    assert!(status.enabled);
    assert_eq!(status.registered, Some(prefs));
    assert_eq!(status.devices, 1);
    let status = host.block_on(client.push_status()).unwrap();
    assert_eq!(status.registered, Some(prefs));
    let status = host.block_on(client.push_unregister()).unwrap();
    assert_eq!(status.registered, None);

    let err = host
        .block_on(client.push_register(PushRegistration {
            cap: "v1.x".into(),
            seal_key: vec![1, 2, 3].into(),
            relay_url: None,
            prefs,
            activity_cap: None,
        }))
        .unwrap_err();
    assert!(matches!(err, WorkspaceError::Invalid { .. }), "{err:?}");
    assert_eq!(
        open_push_notification(key.secret, "not sealed".into()).unwrap_err(),
        PushError::Malformed
    );
}

impl KnockListener for Recorder<u64> {
    fn on_waiting(&self, knock_id: u64) {
        self.push(knock_id);
    }
}

#[test]
fn knock_admit_and_session_rules() {
    let host = Host::start();
    let (owner, owner_events) = host.client();
    let owner_mp: Arc<Recorder<MultiplayerEvent>> = Recorder::new();
    owner.set_multiplayer_listener(owner_mp.clone());
    attach(&owner, &owner_events);
    let session = owner_events.wait("attached", |all| {
        all.iter().find_map(|e| match e {
            ClientEvent::Layout { layout } => Some(layout.session_id),
            _ => None,
        })
    });

    // A knock invite says so on the join card.
    let invite = host
        .block_on(owner.create_invite(InviteOptions {
            roles: vec![Role::Viewer],
            scope: Scope::Daemon,
            ttl_secs: Some(3600),
            max_uses: None,
            delegate: false,
            label: String::new(),
            inviter: "alice".into(),
            knock: true,
            since_join: true,
        }))
        .unwrap();
    let info = inspect_invite(invite.link.clone()).unwrap();
    assert!(info.knock && info.since_join, "{info:?}");

    // Dee knocks from another thread (as a Swift task would) and waits.
    let key = generate_device_key();
    let knocker = ClientConfig {
        secret_key: key.clone(),
        ..config()
    };
    let waiting: Arc<Recorder<u64>> = Recorder::new();
    let listener = waiting.clone();
    let link = invite.link.clone();
    let knock = std::thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(knock_invite(
                link,
                knocker,
                ConnectOptions::default(),
                Some("Dee".into()),
                listener,
            ))
    });
    let knock_id = waiting.wait("asked the owner", |all| all.first().copied());
    let seen = owner_mp.wait("knock pushed", |all| {
        all.iter().rev().find_map(|e| match e {
            MultiplayerEvent::KnockAdded { knock } if knock.name == "Dee" => Some(knock.clone()),
            _ => None,
        })
    });
    assert_eq!(seen.knock_id, knock_id);
    assert!(
        owner
            .pending_knocks()
            .iter()
            .any(|k| k.knock_id == knock_id)
    );
    let grant = host
        .block_on(owner.admit_knock(knock_id, vec![Role::Viewer, Role::Approver], false, None))
        .unwrap();
    let KnockResult::Admitted { invite: admitted } = knock.join().unwrap().unwrap() else {
        panic!("not admitted");
    };
    assert_eq!(grant.bound.len(), 1);
    let dee_events = Recorder::new();
    let dee_mp: Arc<Recorder<MultiplayerEvent>> = Recorder::new();
    let dee = DaemonClient::join(
        admitted,
        ClientConfig {
            secret_key: key,
            ..config()
        },
        dee_events.clone(),
    )
    .unwrap();
    dee.set_multiplayer_listener(dee_mp.clone());
    connected(&dee_events);
    let me = dee_mp.wait("joined", |all| {
        all.iter().find_map(|e| match e {
            MultiplayerEvent::Joined { info } => Some(info.clone()),
            _ => None,
        })
    });
    assert_eq!(me.roles, [Role::Viewer, Role::Approver]);
    assert_eq!(me.name, "Dee");
    owner_mp.wait("knock gone", |all| {
        all.iter()
            .any(|e| matches!(e, MultiplayerEvent::KnockGone { knock_id: k, .. } if *k == knock_id))
            .then_some(())
    });

    // Session rules: the owner sets them, the guest hears them and may not change them.
    attach(&dee, &dee_events);
    let rules = ApprovalPolicy {
        mode: ApprovalMode::TwoPerson,
        max_risk: Risk::Edits,
    };
    assert_eq!(
        host.block_on(owner.set_approval_policy(session, rules))
            .unwrap(),
        rules
    );
    dee_mp.wait("rules pushed", |all| {
        all.iter()
            .any(|e| matches!(e, MultiplayerEvent::ApprovalPolicy { policy, .. } if *policy == rules))
            .then_some(())
    });
    assert_eq!(dee.approval_policy_cached(), Some(rules));
    assert!(matches!(
        host.block_on(dee.set_approval_policy(
            session,
            ApprovalPolicy {
                mode: ApprovalMode::AnyApprover,
                max_risk: Risk::Any,
            }
        )),
        Err(unnamed_core::MultiplayerError::Forbidden { .. })
    ));
    assert_eq!(host.block_on(dee.approval_policy(session)).unwrap(), rules);
}
