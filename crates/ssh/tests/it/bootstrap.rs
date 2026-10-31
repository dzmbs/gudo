//! Daemon bootstrap over SSH: fresh install, reuse, upgrade (pairing over iroh is tested in
//! client-core, which owns the iroh client).

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use ssh::{
    BinarySource, BootstrapListener, BootstrapOptions, BootstrapStep, HostPlatform, HostdBinaries,
    InstallAction, ServiceMode, SshError, UploadEncoding,
};

use crate::common::env;

/// The stripped static build for the VM, made by `scripts/ssh-test-vm.sh`
/// (`UN_SSH_TEST_HOSTD` overrides).
pub fn hostd_binary(platform: HostPlatform) -> PathBuf {
    if let Some(p) = std::env::var_os("UN_SSH_TEST_HOSTD") {
        return PathBuf::from(p);
    }
    let arch = match platform {
        HostPlatform::LinuxAarch64 => "aarch64",
        HostPlatform::LinuxX86_64 => "x86_64",
        other => panic!("no test build for {other:?}"),
    };
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/ssh-test/bin")
        .join(format!("{}-{arch}-linux", brand::DAEMON_BIN));
    assert!(
        path.exists(),
        "{} missing: run scripts/ssh-test-vm.sh",
        path.display()
    );
    path
}

#[derive(Default)]
struct Steps(Mutex<Vec<BootstrapStep>>);

impl BootstrapListener for Steps {
    fn on_step(&self, step: BootstrapStep) {
        self.0.lock().unwrap().push(step);
    }
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn install_reuse_upgrade() {
    let _host = HOST.lock().await;
    let env = env();
    let conn = env.connect().await;
    let platform = ssh::detect_platform(&conn).await.unwrap();
    let path = hostd_binary(platform);
    let binary = std::fs::read(&path).unwrap();

    // Start from nothing.
    conn.exec(&format!(
        "systemctl --user disable --now {bin}.service; rm -f ~/.local/bin/{bin} \
         ~/.config/systemd/user/{bin}.service; systemctl --user daemon-reload",
        bin = brand::DAEMON_BIN
    ))
    .await
    .unwrap();

    let steps = Arc::new(Steps::default());
    let options = BootstrapOptions {
        listener: Some(steps.clone()),
        ..BootstrapOptions::default()
    };
    let binaries = HostdBinaries {
        linux_aarch64: Some(BinarySource::Path(path.clone())),
        linux_x86_64: Some(BinarySource::Path(path.clone())),
        ..HostdBinaries::default()
    };
    let t = Instant::now();
    let first = ssh::bootstrap(&conn, &binaries, &options).await.unwrap();
    eprintln!("fresh install: {:?} {first:?}", t.elapsed());
    assert_eq!(first.action, InstallAction::Installed);
    assert_eq!(first.service, ServiceMode::Service);
    assert_eq!(first.sha256, ssh::sha256_hex(&binary));
    assert!(
        first
            .ticket
            .starts_with(&format!("{}://pair/", brand::URL_SCHEME))
    );
    assert_eq!(first.daemon_id.len(), 64);
    assert!(
        first
            .install_path
            .ends_with(&format!("/.local/bin/{}", brand::DAEMON_BIN))
    );
    let uploaded =
        steps.0.lock().unwrap().iter().any(
            |s| matches!(s, BootstrapStep::Uploading { size, sent } if *sent > 0 && sent < size),
        );
    assert!(
        uploaded,
        "gzip upload expected: {:?}",
        steps.0.lock().unwrap()
    );
    let active = conn
        .exec(&format!("systemctl --user is-active {}", brand::DAEMON_BIN))
        .await
        .unwrap();
    assert_eq!(active.stdout_text().trim(), "active");

    // Again: same build, running → nothing uploaded or restarted, new ticket.
    let t = Instant::now();
    let again = ssh::bootstrap(&conn, &binaries, &BootstrapOptions::default())
        .await
        .unwrap();
    eprintln!("reuse: {:?}", t.elapsed());
    assert_eq!(again.action, InstallAction::Reused);
    assert_eq!(again.service, ServiceMode::AlreadyRunning);
    assert_eq!(again.daemon_id, first.daemon_id, "same daemon identity");
    assert_ne!(again.ticket, first.ticket, "a fresh one-time secret");

    // A different build (one trailing byte; still a valid ELF) → upgraded and restarted.
    let pid_before = main_pid(&conn).await;
    let mut other = binary.clone();
    other.push(0);
    let upgraded = ssh::bootstrap(
        &conn,
        &HostdBinaries {
            linux_aarch64: Some(BinarySource::Bytes(Arc::new(other.clone()))),
            linux_x86_64: Some(BinarySource::Bytes(Arc::new(other.clone()))),
            ..HostdBinaries::default()
        },
        &BootstrapOptions::default(),
    )
    .await
    .unwrap();
    assert_eq!(upgraded.action, InstallAction::Upgraded);
    assert_eq!(upgraded.service, ServiceMode::Service);
    assert_eq!(upgraded.sha256, ssh::sha256_hex(&other));
    assert_eq!(
        upgraded.daemon_id, first.daemon_id,
        "state survives the upgrade"
    );
    assert_ne!(
        main_pid(&conn).await,
        pid_before,
        "the daemon was restarted"
    );

    // Back to the original build for the other tests.
    let back = ssh::bootstrap(&conn, &binaries, &BootstrapOptions::default())
        .await
        .unwrap();
    assert_eq!(back.action, InstallAction::Upgraded);
}

async fn main_pid(conn: &ssh::Connection) -> String {
    conn.exec(&format!(
        "systemctl --user show -p MainPID --value {}",
        brand::DAEMON_BIN
    ))
    .await
    .unwrap()
    .stdout_text()
    .trim()
    .to_owned()
}

/// Bytes altered between the app and the disk (here by a hostile `gzip` on the remote) are
/// refused by the remote SHA-256 check: nothing is installed and no temp file is left.
#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn a_tampered_upload_is_refused_and_installs_nothing() {
    let conn = env().connect().await;
    // A `gzip` first on PATH that corrupts its output only for uploads into ~/un-tamper (its
    // parent `sh -c` script names the target), so parallel tests are unaffected.
    conn.exec(
        r#"set -e
mkdir -p ~/un-tamper-bin ~/un-tamper
rm -f ~/un-tamper/*
cat > ~/un-tamper-bin/gzip <<'SH'
#!/bin/sh
if grep -q un-tamper /proc/$PPID/cmdline 2>/dev/null; then
  /usr/bin/gzip "$@"; printf X
else
  exec /usr/bin/gzip "$@"
fi
SH
chmod +x ~/un-tamper-bin/gzip
grep -q un-tamper-bin ~/.bashrc || sed -i '1i export PATH="$HOME/un-tamper-bin:$PATH"' ~/.bashrc"#,
    )
    .await
    .unwrap()
    .check()
    .unwrap();
    let data = b"\x7fELF pretend helper".repeat(1000);
    let result = conn
        .upload("~/un-tamper/helper", &data, 0o755, UploadEncoding::Gzip)
        .await;
    let left = conn
        .exec("ls -A ~/un-tamper; sed -i '/un-tamper-bin/d' ~/.bashrc; rm -rf ~/un-tamper-bin")
        .await
        .unwrap();
    match result {
        Err(SshError::ChecksumMismatch {
            expected, actual, ..
        }) => {
            assert_eq!(expected, ssh::sha256_hex(&data));
            assert_ne!(actual, expected);
        }
        other => panic!("expected a checksum mismatch, got {other:?}"),
    }
    assert_eq!(left.stdout_text().trim(), "", "nothing may be left behind");
}

/// A stand-in helper: answers what the bootstrap asks (`build-info`, `status`, `service
/// install`, `pair`) as a build of `protocol`.
fn fake_helper(build: &str, protocol: u32) -> Vec<u8> {
    format!(
        r#"#!/bin/sh
case "$1" in
  build-info) echo '{{"version":"9.9.9","build":"{build}","built_unix":1800000000,"protocol":{protocol},"min_client_protocol":0,"features":0,"hostname":"t","os":"linux","os_name":"","arch":"x"}}' ;;
  status) echo "running (pid 1, state dir /x)" ;;
  service) exit 0 ;;
  pair) echo '{{"ticket":"t","daemon_id":"d"}}' ;;
  *) exit 3 ;;
esac
"#
    )
    .into_bytes()
}

fn fakes(build: &[u8]) -> HostdBinaries {
    let b = Arc::new(build.to_vec());
    HostdBinaries {
        linux_aarch64: Some(BinarySource::Bytes(b.clone())),
        linux_x86_64: Some(BinarySource::Bytes(b)),
        ..HostdBinaries::default()
    }
}

/// Rollback protection over SSH: an app carrying an older helper keeps the newer one the host
/// runs, unless the downgrade is explicit.
#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn an_older_helper_never_replaces_a_newer_install() {
    let _host = HOST.lock().await;
    let conn = env().connect().await;
    let installed = format!("~/.local/bin/{}", brand::DAEMON_BIN);
    conn.exec(&format!(
        "systemctl --user disable --now {}.service 2>/dev/null; true",
        brand::DAEMON_BIN
    ))
    .await
    .unwrap();
    let newer = fake_helper("newer", 99);
    conn.upload(&installed, &newer, 0o755, UploadEncoding::Raw)
        .await
        .unwrap();

    let older = fake_helper("older", 1);
    let kept = ssh::bootstrap(&conn, &fakes(&older), &BootstrapOptions::default())
        .await
        .unwrap();
    assert_eq!(kept.action, InstallAction::KeptNewer);
    assert_eq!(kept.sha256, ssh::sha256_hex(&newer));
    assert_eq!(conn.download(&installed).await.unwrap(), newer);
    let listing = conn.exec("ls -A ~/.local/bin").await.unwrap();
    assert!(
        !listing.stdout_text().contains(".new"),
        "{}",
        listing.stdout_text()
    );

    let forced = ssh::bootstrap(
        &conn,
        &fakes(&older),
        &BootstrapOptions {
            allow_downgrade: true,
            ..BootstrapOptions::default()
        },
    )
    .await
    .unwrap();
    assert_eq!(forced.action, InstallAction::Upgraded);
    assert_eq!(conn.download(&installed).await.unwrap(), older);

    // And forwards again: a newer build replaces the older one.
    let upgraded = ssh::bootstrap(&conn, &fakes(&newer), &BootstrapOptions::default())
        .await
        .unwrap();
    assert_eq!(upgraded.action, InstallAction::Upgraded);
    assert_eq!(conn.download(&installed).await.unwrap(), newer);
    conn.exec(&format!("rm -f {installed}")).await.unwrap();
}

/// The bootstrap tests share the host's one install path.
static HOST: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
