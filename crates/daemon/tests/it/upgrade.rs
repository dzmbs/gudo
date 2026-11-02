//! Daemon info and self upgrade (`proto::info`): every connection learns the daemon's build
//! and host name before `Welcome`; the owner streams a new build over the connection, the
//! daemon checks and swaps it in and asks to restart; after the restart (simulated by
//! starting a daemon on the same state directory and port) the same client comes back by
//! itself with the layout, the agent resumed and fresh shells. Guests, damaged and foreign
//! builds are refused without touching anything; an owner whose snapshot format differs is
//! let in to upgrade only.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use client_core::grants::GrantSpec;
use client_core::proto::{
    self, AgentKind, Axis, DaemonFeatures, LayoutOp, OpOutcome, PaneLaunch, Roles, Scope,
    UnixMillis, UpgradeFailure,
};
use client_core::{ClientConfig, DaemonBuild, UpgradeError, now_millis};
use daemon::Daemon;

use crate::support::{TIMEOUT, TestClient, leaves, shape, start_with, ticket};

const CODEX_ID: &str = "0199a213-81c0-7800-8aa1-bbab2a035a54";

const FAKE_CODEX: &str = r#"#!/bin/sh
echo "fake codex $*"
dir="$CODEX_HOME/sessions/2026/10/19"
mkdir -p "$dir"
f="$dir/rollout-2026-10-19T12-00-00-__ID__.jsonl"
if [ ! -e "$f" ]; then
  printf '{"type":"session_meta","payload":{"id":"__ID__","cwd":"%s"}}\n' "$PWD" > "$f"
fi
exec 3>>"$f"
exec sleep 600
"#;

/// A stand-in for a daemon build: answers `build-info --json` like `gudo-hostd` does.
/// Newer than the daemon under test (a `dev` build) unless `protocol` says otherwise.
fn fake_build(build: &str, os: &str, arch: &str, exit: i32) -> Vec<u8> {
    build_at(build, os, arch, exit, proto::PROTOCOL_LEVEL + 1)
}

fn build_at(build: &str, os: &str, arch: &str, exit: i32, protocol: u32) -> Vec<u8> {
    let info = proto::DaemonInfo {
        version: "9.9.9".into(),
        build: build.into(),
        built_unix: 1_800_000_000,
        protocol,
        min_client_protocol: 0,
        features: DaemonFeatures::EMPTY,
        hostname: "test".into(),
        os: os.into(),
        arch: arch.into(),
        os_name: String::new(),
    };
    let json = serde_json::to_string(&info).unwrap();
    format!("#!/bin/sh\nif [ \"$1\" = build-info ]; then echo '{json}'; exit {exit}; fi\nexit 3\n")
        .into_bytes()
}

fn good_build(build: &str) -> Vec<u8> {
    fake_build(build, std::env::consts::OS, std::env::consts::ARCH, 0)
}

fn gzip(data: &[u8]) -> Vec<u8> {
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    gz.write_all(data).unwrap();
    gz.finish().unwrap()
}

/// The "installed" executable: a file the daemon may replace.
fn installed_exe(dir: &Path) -> PathBuf {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let exe = bin.join(brand::DAEMON_BIN);
    std::fs::write(&exe, b"#!/bin/sh\necho old build\n").unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
    exe
}

fn free_udp_port() -> u16 {
    std::net::UdpSocket::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Files in the executable's directory other than the executable and its `.prev`: leftover
/// staged builds.
fn strays(exe: &Path) -> Vec<String> {
    let name = exe.file_name().unwrap().to_string_lossy().into_owned();
    std::fs::read_dir(exe.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| *n != name && *n != format!("{name}.prev"))
        .collect()
}

async fn upgrade(c: &TestClient, data: Vec<u8>) -> Result<proto::DaemonInfo, UpgradeError> {
    let build = DaemonBuild::new(data, "test-build".into()).unwrap();
    c.client.upgrade_daemon(build, None).await
}

fn assert_refused(result: Result<proto::DaemonInfo, UpgradeError>, want: UpgradeFailure) {
    match result {
        Err(UpgradeError::Daemon { code, .. }) => assert_eq!(code, want),
        other => panic!("expected {want:?}, got {other:?}"),
    }
}

/// Whether the daemon asked to restart within `wait`.
async fn restart_requested(daemon: &Daemon, wait: Duration) -> Option<PathBuf> {
    tokio::time::timeout(wait, daemon.restart_requested())
        .await
        .ok()
}

#[tokio::test(flavor = "multi_thread")]
async fn every_connection_learns_the_daemon_and_its_host_name() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |_| {}).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let info = c.infos[0].clone().expect("daemon info before Welcome");
    assert_eq!(info.protocol, proto::PROTOCOL_LEVEL);
    assert_eq!(info.hostname, daemon::info::hostname());
    assert!(!info.hostname.is_empty());
    assert_eq!(info.os, std::env::consts::OS);
    assert_eq!(info.arch, std::env::consts::ARCH);
    // A library daemon without an installed executable cannot replace itself.
    assert!(!info.features.contains(DaemonFeatures::SELF_UPGRADE));
    assert_eq!(c.client.daemon_info(), Some(info.clone()));
    assert_eq!(daemon.info().build, info.build);
    assert!(c.incompatible.is_empty());

    // A refused device learns the build but not the host name.
    let stale = ticket(&daemon);
    let mut a = TestClient::connect(&stale, ClientConfig::generate_key());
    a.until("first pairing", |c| c.connected > 0).await;
    let mut b = TestClient::connect(&stale, ClientConfig::generate_key());
    b.until("refusal", |c| !c.refused.is_empty()).await;
    let refused = b.infos.last().cloned().flatten().expect("info on refusal");
    assert!(refused.hostname.is_empty());
    assert_eq!(refused.protocol, proto::PROTOCOL_LEVEL);
    drop((a, b, c));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn owner_upgrades_the_daemon_and_the_session_comes_back() {
    let dir = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let exe = installed_exe(tools.path());
    let bin = tools.path().join("path");
    std::fs::create_dir_all(&bin).unwrap();
    let codex = bin.join("codex");
    std::fs::write(&codex, FAKE_CODEX.replace("__ID__", CODEX_ID)).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let env = vec![
        (
            "PATH".to_owned(),
            format!(
                "{}:{}",
                bin.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        ),
        (
            "CODEX_HOME".to_owned(),
            tools.path().join("codex-home").display().to_string(),
        ),
    ];
    let port = free_udp_port();
    let configure = |env: Vec<(String, String)>, exe: PathBuf| {
        move |c: &mut daemon::Config| {
            c.bind = Some(format!("127.0.0.1:{port}").parse().unwrap());
            c.pane_env.extend(env);
            c.self_exe = Some(exe);
        }
    };

    // The old daemon: a shell, an agent beside it, a second tab.
    let daemon = start_with(dir.path(), configure(env.clone(), exe.clone())).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = c.attach_and_follow().await;
    assert!(
        c.infos[0]
            .as_ref()
            .unwrap()
            .features
            .contains(DaemonFeatures::SELF_UPGRADE)
    );
    let OpOutcome::PaneCreated { pane_id: agent } = c
        .op(LayoutOp::Split {
            pane_id: shell,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Agent {
                agent: AgentKind::Codex,
                resume: None,
                cwd: None,
            },
        })
        .await
    else {
        panic!("split failed");
    };
    c.follow(agent).await;
    c.wait_text(agent, "fake codex").await;
    let session_id = c.layout.as_ref().unwrap().session_id;
    c.op(LayoutOp::NewTab {
        session_id,
        name: "second".into(),
        launch: PaneLaunch::Shell { cwd: None },
    })
    .await;
    let layout = dir.path().join("layout.json");
    let deadline = Instant::now() + TIMEOUT;
    while !std::fs::read_to_string(&layout).is_ok_and(|s| s.contains(CODEX_ID)) {
        assert!(
            Instant::now() < deadline,
            "agent session id never persisted"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let before = c.layout.clone().unwrap();
    c.type_line(shell, "echo before-upgrade");
    c.wait_text(shell, "before-upgrade").await;

    // The upgrade: gzip on the wire, verified, swapped in, old build kept.
    let new = good_build("new-build");
    let installed = upgrade(&c, gzip(&new)).await.expect("upgrade installed");
    assert_eq!(installed.build, "new-build");
    assert_eq!(installed.protocol, proto::PROTOCOL_LEVEL + 1);
    assert_eq!(std::fs::read(&exe).unwrap(), new);
    assert_eq!(
        std::fs::read(daemon::upgrade_prev_path(&exe)).unwrap(),
        b"#!/bin/sh\necho old build\n"
    );
    assert!(
        strays(&exe).is_empty(),
        "staged files left: {:?}",
        strays(&exe)
    );
    let restart = restart_requested(&daemon, TIMEOUT).await;
    assert_eq!(restart.as_deref(), Some(exe.as_path()));
    // One upgrade at a time: the daemon is restarting now.
    assert_refused(upgrade(&c, good_build("again")).await, UpgradeFailure::Busy);

    // What `gudo-hostd run` does next: save, stop, exec the new build. The "new build"
    // here is this same daemon library on the same state directory and port.
    daemon.shutdown().await;
    let connections = c.connected;
    let daemon = start_with(dir.path(), configure(env, exe.clone())).await;

    // The same client reconnects by itself and finds its session.
    c.until("reconnected", |c| c.connected > connections).await;
    c.until("layout after the upgrade", |c| {
        c.layout
            .as_ref()
            .is_some_and(|l| l.session_id == session_id && shape(l) == shape(&before))
    })
    .await;
    let panes: Vec<_> = c
        .layout
        .as_ref()
        .unwrap()
        .tabs
        .iter()
        .flat_map(|t| leaves(&t.root))
        .collect();
    assert!(
        panes.contains(&agent) && panes.contains(&shell),
        "{panes:?}"
    );
    // The agent resumed its session; the shell is a new process that takes input.
    c.follow(agent).await;
    c.wait_flat(agent, &format!("resume {CODEX_ID}")).await;
    c.follow(shell).await;
    c.type_line(shell, "echo after-upgrade$((1+1))");
    c.wait_text(shell, "after-upgrade2").await;
    drop(c);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_and_bad_builds_are_refused_and_change_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let exe = installed_exe(tools.path());
    let original = std::fs::read(&exe).unwrap();
    let exe2 = exe.clone();
    let daemon = start_with(dir.path(), move |c| c.self_exe = Some(exe2)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;

    // A guest, even one allowed to drive and approve, is not the owner.
    let mut spec = GrantSpec::new(Roles::DRIVER | Roles::APPROVER, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .expect("invite");
    let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    guest.client.attach(None);
    guest.until("guest layout", |c| c.layout.is_some()).await;
    guest.follow(pane).await;
    assert_refused(
        upgrade(&guest, good_build("guest")).await,
        UpgradeFailure::Forbidden,
    );

    // Damaged in transit: the hash does not match.
    let mut damaged = DaemonBuild::new(good_build("damaged"), String::new()).unwrap();
    damaged.sha256[0] ^= 0xff;
    assert_refused(
        owner.client.upgrade_daemon(damaged, None).await,
        UpgradeFailure::Corrupt,
    );
    // Built for another machine, or failing its self-check.
    assert_refused(
        upgrade(&owner, fake_build("foreign", "plan9", "mips", 0)).await,
        UpgradeFailure::Rejected,
    );
    assert_refused(
        upgrade(
            &owner,
            fake_build("broken", std::env::consts::OS, std::env::consts::ARCH, 1),
        )
        .await,
        UpgradeFailure::Rejected,
    );
    // Not an executable at all.
    assert_refused(
        upgrade(&owner, b"\x7fELF\x02\x01\x01 nonsense".to_vec()).await,
        UpgradeFailure::Rejected,
    );

    assert_eq!(std::fs::read(&exe).unwrap(), original);
    assert!(!daemon::upgrade_prev_path(&exe).exists());
    assert!(
        strays(&exe).is_empty(),
        "staged files left: {:?}",
        strays(&exe)
    );
    assert!(
        restart_requested(&daemon, Duration::from_millis(200))
            .await
            .is_none()
    );
    // The session was never disturbed.
    owner.type_line(pane, "echo still-here");
    owner.wait_text(pane, "still-here").await;

    // After the failures the owner can still upgrade (nothing stayed busy).
    upgrade(&owner, good_build("fine")).await.expect("upgrade");
    assert!(restart_requested(&daemon, TIMEOUT).await.is_some());
    drop((owner, guest));
    daemon.shutdown().await;
}

/// Rollback protection: an older build is refused unless the owner explicitly downgrades, and
/// a guest cannot downgrade either.
#[tokio::test(flavor = "multi_thread")]
async fn an_older_build_needs_the_owners_explicit_downgrade() {
    let dir = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let exe = installed_exe(tools.path());
    let original = std::fs::read(&exe).unwrap();
    let exe2 = exe.clone();
    let daemon = start_with(dir.path(), move |c| c.self_exe = Some(exe2)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let older = || {
        let data = build_at(
            "older",
            std::env::consts::OS,
            std::env::consts::ARCH,
            0,
            proto::PROTOCOL_LEVEL - 1,
        );
        DaemonBuild::new(data, "older".into()).unwrap()
    };

    assert_refused(
        owner.client.upgrade_daemon(older(), None).await,
        UpgradeFailure::Older,
    );
    assert_eq!(std::fs::read(&exe).unwrap(), original);
    assert!(strays(&exe).is_empty(), "{:?}", strays(&exe));

    let mut spec = GrantSpec::new(Roles::DRIVER | Roles::APPROVER, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .expect("invite");
    let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    guest.client.attach(None);
    guest.until("guest layout", |c| c.layout.is_some()).await;
    guest.follow(pane).await;
    let mut forced = older();
    forced.downgrade = true;
    assert_refused(
        guest.client.upgrade_daemon(forced, None).await,
        UpgradeFailure::Forbidden,
    );
    assert!(
        restart_requested(&daemon, Duration::from_millis(200))
            .await
            .is_none()
    );

    let mut forced = older();
    forced.downgrade = true;
    let info = owner
        .client
        .upgrade_daemon(forced, None)
        .await
        .expect("explicit downgrade");
    assert_eq!(info.build, "older");
    assert_ne!(std::fs::read(&exe).unwrap(), original);
    assert!(restart_requested(&daemon, TIMEOUT).await.is_some());
    drop((owner, guest));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_daemon_that_cannot_replace_itself_says_so() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |_| {}).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    assert_refused(
        upgrade(&c, good_build("x")).await,
        UpgradeFailure::Unsupported,
    );
    drop(c);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_incompatible_owner_is_let_in_only_to_upgrade() {
    let dir = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let exe = installed_exe(tools.path());
    let exe2 = exe.clone();
    let key = ClientConfig::generate_key();
    // Pair while compatible, then restart announcing a snapshot format the client lacks.
    let daemon = start_with(dir.path(), |_| {}).await;
    let mut c = TestClient::connect(&ticket(&daemon), key.clone());
    c.attach_and_follow().await;
    drop(c);
    daemon.shutdown().await;
    let daemon = start_with(dir.path(), move |c| {
        c.self_exe = Some(exe2);
        c.test_snapshot_format = Some(0xdead);
    })
    .await;
    let mut c = TestClient::connect(&ticket(&daemon), key);
    c.client.attach(None);
    c.until("incompatible", |c| !c.incompatible.is_empty())
        .await;
    assert!(c.client.is_incompatible());
    assert!(c.infos.last().cloned().flatten().is_some());
    // Nothing but the upgrade works: no layout ever arrives.
    let start = Instant::now();
    c.until("a quiet moment", |c| {
        c.layout.is_some() || start.elapsed() > Duration::from_millis(300)
    })
    .await;
    assert!(c.layout.is_none());
    assert_eq!(c.connected, 0);
    let installed = upgrade(&c, good_build("compatible-again"))
        .await
        .expect("upgrade over the maintenance connection");
    assert_eq!(installed.build, "compatible-again");
    assert!(restart_requested(&daemon, TIMEOUT).await.is_some());

    // A device that is not paired gets the plain refusal, not the upgrade door.
    let mut stranger = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    stranger.until("refusal", |c| !c.refused.is_empty()).await;
    assert!(
        stranger.refused[0].contains("SnapshotFormat"),
        "{:?}",
        stranger.refused
    );
    assert!(stranger.layout.is_none());
    drop((c, stranger));
    daemon.shutdown().await;
}
