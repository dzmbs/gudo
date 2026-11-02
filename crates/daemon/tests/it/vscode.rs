//! The VS Code tunnel end to end with a fake `code` CLI: licence gating, device-code sign-in
//! pushed to the client, the vscode.dev link, restart after a crash, restart at daemon start,
//! adopting the user's own tunnel, open-at-line URLs, and the CLI download from a stand-in
//! update service (SHA-256 checked).

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use client_core::proto::{
    ForwardTarget, TunnelProvider, TunnelState, VsCodeTunnelOpen, VsCodeTunnelStart,
    VsCodeTunnelStatus, WsError,
};
use client_core::{ClientConfig, WorkspaceEvent, WorkspaceEventQueue};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TestClient, start_with, ticket};

/// Stands in for Microsoft's `code` CLI. State lives next to the script: `logged_in`,
/// `approve` (the user finished the device-code sign-in), `crash` (next tunnel run fails),
/// `adopt` (another tunnel already runs), `calls.txt`, `tunnel.pid`.
const FAKE_CODE: &str = r#"#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/calls.txt"
if [ "$1" = "--version" ]; then echo "code 1.142.0 (commit fakecommit)"; exit 0; fi
[ "$1" = "tunnel" ] || exit 2
case "$2" in
  status)
    if [ -f "$D/adopt" ]; then echo '{"tunnel":{"name":"theirs","tunnel":"Connected"},"service_installed":true}'
    else echo '{"tunnel":null,"service_installed":false}'; fi
    exit 0;;
  user)
    case "$3" in
      show) if [ -f "$D/logged_in" ]; then echo "logged in"; exit 0; fi; echo "not logged in"; exit 1;;
      login)
        if [ "$5" = "microsoft" ]; then
          echo "To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code MSCODE123 to authenticate."
        else
          echo "To grant access to the server, please log into https://github.com/login/device and use code ABCD-1234"
        fi
        while [ ! -f "$D/approve" ]; do sleep 0.1; done
        touch "$D/logged_in"; exit 0;;
    esac;;
esac
echo "*"
echo "* Visual Studio Code Server"
echo "*"
if [ -f "$D/crash" ]; then rm -f "$D/crash"; echo "error: tunnel service unreachable" >&2; exit 1; fi
name=""
while [ $# -gt 0 ]; do [ "$1" = "--name" ] && name="$2"; shift; done
echo "$$" > "$D/tunnel.pid"
echo "Open this link in your browser https://vscode.dev/tunnel/$name/home/me"
exec sleep 1000
"#;

fn canonical_tempdir() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().canonicalize().unwrap();
    (dir, path)
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn install_fake(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, FAKE_CODE).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

async fn connected(daemon: &daemon::Daemon) -> TestClient {
    let mut c = TestClient::connect(&ticket(daemon), ClientConfig::generate_key());
    c.until("connected", |c| c.connected > 0).await;
    c
}

async fn tunnel_event(
    events: &mut UnboundedReceiver<WorkspaceEvent>,
    what: &str,
    mut pick: impl FnMut(&TunnelState) -> bool,
) -> VsCodeTunnelStatus {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if let WorkspaceEvent::VsCodeTunnel { status } =
                events.recv().await.expect("listener alive")
                && pick(&status.state)
            {
                return status;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn tunnel_pid(dir: &Path) -> i32 {
    std::fs::read_to_string(dir.join("tunnel.pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap()
}

async fn gone(pid: i32) -> bool {
    for _ in 0..50 {
        if !alive(pid) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    false
}

#[tokio::test(flavor = "multi_thread")]
async fn vscode_tunnel_signs_in_runs_restarts_and_opens() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let bin = home.join("bin");
    let code = bin.join("code");
    install_fake(&code);
    let edit = {
        let (code, home) = (code.clone(), home.clone());
        move |c: &mut daemon::Config| {
            c.pane_env.push(("HOME".into(), s(&home)));
            c.fs_allow.push(home);
            c.code_cli = Some(code);
            c.vscode_serve_web = true;
        }
    };
    let daemon = start_with(&state, edit.clone()).await;
    let c = connected(&daemon).await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);

    let status = c.client.vscode_tunnel_status().await.unwrap();
    let cli = status.cli.expect("the fake CLI is found");
    assert_eq!(cli.path, s(&code));
    assert_eq!(cli.version.as_deref(), Some("1.142.0"));
    assert_eq!(cli.commit.as_deref(), Some("fakecommit"));
    assert!(!cli.managed);
    assert_eq!(status.state, TunnelState::Stopped);

    // The server licence must be accepted in the app first.
    let start = |accept| VsCodeTunnelStart {
        accept_server_license: accept,
        provider: TunnelProvider::GitHub,
        name: Some("testbox".into()),
    };
    assert!(matches!(
        c.client.vscode_tunnel_start(start(false)).await,
        Err(WsError::Denied(_))
    ));
    assert!(
        !bin.join("calls.txt").exists() || {
            let calls = std::fs::read_to_string(bin.join("calls.txt")).unwrap();
            !calls.contains("tunnel")
        }
    );

    // Not signed in: the device code reaches the client.
    c.client.vscode_tunnel_start(start(true)).await.unwrap();
    let st = tunnel_event(&mut events, "device code", |s| {
        matches!(s, TunnelState::NeedsLogin(_))
    })
    .await;
    let TunnelState::NeedsLogin(login) = st.state else {
        unreachable!()
    };
    assert_eq!(login.provider, TunnelProvider::GitHub);
    assert_eq!(login.verification_url, "https://github.com/login/device");
    assert_eq!(login.user_code, "ABCD-1234");

    // The user signs in; the tunnel connects and reports its vscode.dev link.
    std::fs::write(bin.join("approve"), "").unwrap();
    let st = tunnel_event(&mut events, "running", |s| {
        matches!(s, TunnelState::Running { .. })
    })
    .await;
    assert_eq!(
        st.state,
        TunnelState::Running {
            name: "testbox".into(),
            web_url: "https://vscode.dev/tunnel/testbox/home/me".into(),
            adopted: false,
        }
    );
    let calls = std::fs::read_to_string(bin.join("calls.txt")).unwrap();
    assert!(
        calls.contains("tunnel user login --provider github"),
        "{calls}"
    );
    assert!(
        calls.contains("tunnel --accept-server-license-terms --name testbox"),
        "{calls}"
    );
    // Starting again reuses the running tunnel.
    let again = c.client.vscode_tunnel_start(start(true)).await.unwrap();
    assert!(matches!(again.state, TunnelState::Running { .. }));

    // Open a file at a line: the folder is the git work tree.
    let project = home.join("project");
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::create_dir_all(project.join("src dir")).unwrap();
    std::fs::write(project.join("src dir/main.rs"), "fn main() {}\n").unwrap();
    let opened = c
        .client
        .vscode_tunnel_open(VsCodeTunnelOpen {
            folder: None,
            path: s(&project.join("src dir/main.rs")),
            line: Some(3),
            column: Some(7),
        })
        .await
        .unwrap();
    assert_eq!(opened.name, "testbox");
    assert_eq!(opened.folder, s(&project));
    assert_eq!(
        opened.web_url,
        format!("https://vscode.dev/tunnel/testbox{}", s(&project))
    );
    assert_eq!(
        opened.desktop_uri,
        format!(
            "vscode://vscode-remote/tunnel+testbox{}/src%20dir/main.rs:3:7",
            s(&project)
        )
    );
    assert!(!opened.in_window, "no connected window in the fake");
    assert!(matches!(
        c.client
            .vscode_tunnel_open(VsCodeTunnelOpen {
                folder: None,
                path: "/etc/passwd".into(),
                line: None,
                column: None,
            })
            .await,
        Err(WsError::Denied(_))
    ));

    // The tunnel dies: the daemon reports it and starts it again.
    let pid = tunnel_pid(&bin);
    std::fs::write(bin.join("crash"), "").unwrap();
    // SAFETY: plain syscall on the fake's pid.
    unsafe { libc::kill(pid, libc::SIGKILL) };
    tunnel_event(&mut events, "failure", |s| {
        matches!(s, TunnelState::Failed { retrying: true, .. })
    })
    .await;
    let st = tunnel_event(&mut events, "running again", |s| {
        matches!(s, TunnelState::Running { .. })
    })
    .await;
    assert!(matches!(
        st.state,
        TunnelState::Running { adopted: false, .. }
    ));
    let pid = tunnel_pid(&bin);
    assert!(alive(pid));

    // Daemon restart: the tunnel stops with it and comes back on its own (signed in).
    drop(c);
    daemon.shutdown().await;
    assert!(gone(pid).await, "the tunnel stopped with the daemon");
    let record = std::fs::read_to_string(state.join("vscode/tunnel.json")).unwrap();
    assert!(record.contains("\"enabled\": true"), "{record}");
    let daemon = start_with(&state, edit.clone()).await;
    let c = connected(&daemon).await;
    let mut running = None;
    for _ in 0..100 {
        let st = c.client.vscode_tunnel_status().await.unwrap();
        if matches!(st.state, TunnelState::Running { .. }) {
            running = Some(st);
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(running.is_some(), "autostarted");
    let pid = tunnel_pid(&bin);

    // Stop: the process goes and it no longer starts with the daemon.
    let st = c.client.vscode_tunnel_stop().await.unwrap();
    assert_eq!(st.state, TunnelState::Stopped);
    assert!(gone(pid).await);
    let record = std::fs::read_to_string(state.join("vscode/tunnel.json")).unwrap();
    assert!(record.contains("\"enabled\": false"), "{record}");
    assert!(matches!(
        c.client
            .vscode_tunnel_open(VsCodeTunnelOpen {
                folder: None,
                path: s(&project),
                line: None,
                column: None,
            })
            .await,
        Err(WsError::Unavailable(_))
    ));

    // The user runs their own tunnel: adopted, not duplicated.
    std::fs::write(bin.join("adopt"), "").unwrap();
    let st = c.client.vscode_tunnel_start(start(true)).await.unwrap();
    let st = if matches!(st.state, TunnelState::Running { .. }) {
        st
    } else {
        let (listener, mut events) = WorkspaceEventQueue::channel();
        c.client.set_workspace_listener(listener);
        let now = c.client.vscode_tunnel_status().await.unwrap();
        if matches!(now.state, TunnelState::Running { .. }) {
            now
        } else {
            tunnel_event(&mut events, "adopted", |s| {
                matches!(s, TunnelState::Running { .. })
            })
            .await
        }
    };
    assert_eq!(
        st.state,
        TunnelState::Running {
            name: "theirs".into(),
            web_url: "https://vscode.dev/tunnel/theirs".into(),
            adopted: true,
        }
    );
    c.client.vscode_tunnel_stop().await.unwrap();
    drop(c);
    daemon.shutdown().await;
}

/// The device code for a Microsoft account is parsed too.
#[tokio::test(flavor = "multi_thread")]
async fn vscode_tunnel_microsoft_device_code() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let code = home.join("bin/code");
    install_fake(&code);
    let daemon = start_with(&state, {
        let code = code.clone();
        move |c| {
            c.code_cli = Some(code);
            c.vscode_serve_web = true;
        }
    })
    .await;
    let c = connected(&daemon).await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);
    c.client
        .vscode_tunnel_start(VsCodeTunnelStart {
            accept_server_license: true,
            provider: TunnelProvider::Microsoft,
            name: None,
        })
        .await
        .unwrap();
    let st = tunnel_event(&mut events, "device code", |s| {
        matches!(s, TunnelState::NeedsLogin(_))
    })
    .await;
    let TunnelState::NeedsLogin(login) = st.state else {
        unreachable!()
    };
    assert_eq!(login.provider, TunnelProvider::Microsoft);
    assert_eq!(login.verification_url, "https://login.microsoft.com/device");
    assert_eq!(login.user_code, "MSCODE123");
    // Stopping while it waits for the sign-in kills the login process.
    c.client.vscode_tunnel_stop().await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let calls = std::fs::read_to_string(home.join("bin/calls.txt")).unwrap();
    assert!(
        calls.contains("tunnel user login --provider microsoft"),
        "{calls}"
    );
    assert!(!calls.contains("--accept-server-license-terms"), "{calls}");
    drop(c);
    daemon.shutdown().await;
}

fn sha256(path: &Path) -> String {
    let out = Command::new("shasum")
        .args(["-a", "256"])
        .arg(path)
        .output()
        .or_else(|_| Command::new("sha256sum").arg(path).output())
        .unwrap();
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .next()
        .unwrap()
        .to_owned()
}

/// A stand-in update service as a `file://` tree with every CLI platform's answer.
fn update_service(root: &Path, archive: &Path, sha: &str) {
    for platform in [
        "cli-linux-x64",
        "cli-linux-arm64",
        "cli-linux-armhf",
        "cli-alpine-x64",
        "cli-alpine-arm64",
        "cli-darwin-arm64",
        "cli-darwin-x64",
    ] {
        let dir = root.join("api/update").join(platform).join("stable");
        std::fs::create_dir_all(&dir).unwrap();
        let json = format!(
            r#"{{"url":"file://{}","name":"9.9.9","version":"abcdef0123456789","productVersion":"9.9.9","hash":"x","timestamp":1,"sha256hash":"{sha}","supportsFastUpdate":true}}"#,
            archive.display()
        );
        std::fs::write(dir.join("latest"), json).unwrap();
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn vscode_cli_downloads_from_the_update_service_and_checks_its_hash() {
    let (_state, state) = canonical_tempdir();
    let (_srv, srv) = canonical_tempdir();
    // The archive holds a single `code`, like Microsoft's.
    install_fake(&srv.join("pkg/code"));
    let archive = srv.join("vscode_cli.tar.gz");
    assert!(
        Command::new("tar")
            .arg("-czf")
            .arg(&archive)
            .arg("-C")
            .arg(srv.join("pkg"))
            .arg("code")
            .status()
            .unwrap()
            .success()
    );
    let sha = sha256(&archive);
    let api = srv.join("svc");
    update_service(&api, &archive, &"0".repeat(64));
    let daemon = start_with(&state, {
        let api = api.clone();
        move |c| c.vscode_update_url = format!("file://{}", api.display())
    })
    .await;
    let c = connected(&daemon).await;

    assert!(matches!(
        c.client.vscode_cli_install(false).await,
        Err(WsError::Denied(_))
    ));
    // A hash that does not match what the service published is refused.
    match c.client.vscode_cli_install(true).await {
        Err(WsError::Failed(m)) => assert!(m.contains("checksum mismatch"), "{m}"),
        other => panic!("expected a checksum failure, got {other:?}"),
    }
    assert!(!state.join("vscode/cli/install.json").exists());

    update_service(&api, &archive, &sha);
    let st = c.client.vscode_cli_install(true).await.unwrap();
    let record = std::fs::read_to_string(state.join("vscode/cli/install.json")).unwrap();
    let record: serde_json::Value = serde_json::from_str(&record).unwrap();
    assert_eq!(record["version"], "9.9.9");
    assert_eq!(record["commit"], "abcdef0123456789");
    assert_eq!(record["sha256"], sha.as_str());
    let installed = PathBuf::from(record["path"].as_str().unwrap());
    assert!(installed.is_file());
    assert!(installed.starts_with(state.join("vscode/cli")));
    // Unless the machine has its own VS Code, the managed CLI is the one in use.
    let cli = st.cli.expect("a CLI");
    if cli.path == s(&installed) {
        assert!(cli.managed);
        assert_eq!(cli.sha256.as_deref(), Some(sha.as_str()));
        assert_eq!(cli.version.as_deref(), Some("9.9.9"));
    }
    drop(c);
    daemon.shutdown().await;
}

/// `forward_io` splices any reader/writer onto a host port (what `gudo ssh-proxy` does with
/// stdin/stdout for VS Code Remote - SSH).
#[tokio::test(flavor = "multi_thread")]
async fn forward_io_splices_a_stream_onto_a_host_port() {
    let (_state, state) = canonical_tempdir();
    let echo = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = echo.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (mut sock, _) = echo.accept().await.unwrap();
        sock.write_all(b"SSH-2.0-fake\r\n").await.unwrap();
        let mut buf = vec![0; 64];
        let n = sock.read(&mut buf).await.unwrap();
        sock.write_all(&buf[..n]).await.unwrap();
    });
    let daemon = start_with(&state, |_| {}).await;
    let c = connected(&daemon).await;
    let (ours, theirs) = tokio::io::duplex(1024);
    let (r, w) = tokio::io::split(theirs);
    let drive = async {
        let (mut rd, mut wr) = tokio::io::split(ours);
        let mut banner = vec![0; 14];
        rd.read_exact(&mut banner).await.unwrap();
        assert_eq!(&banner, b"SSH-2.0-fake\r\n");
        wr.write_all(b"hello").await.unwrap();
        let mut back = vec![0; 5];
        rd.read_exact(&mut back).await.unwrap();
        assert_eq!(&back, b"hello");
        wr.shutdown().await.unwrap();
    };
    let (spliced, ()) = tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(
            c.client.forward_io(ForwardTarget::Tcp { port }, r, w),
            drive
        )
    })
    .await
    .unwrap();
    spliced.unwrap();
    drop(c);
    daemon.shutdown().await;
}
