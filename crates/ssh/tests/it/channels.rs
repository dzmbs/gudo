//! PTY shells, exec, upload and ProxyJump against the real sshd.

use std::time::{Duration, Instant};

use ssh::{Connection, HostSpec, PtyRequest, ShellEvent, ShellOutput, Target, UploadEncoding};

use crate::common::env;

/// Reads shell output until `needle` shows up; returns everything read.
async fn read_until(out: &mut ShellOutput, needle: &str) -> String {
    let mut seen = String::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !seen.contains(needle) {
        let left = deadline.saturating_duration_since(Instant::now());
        match tokio::time::timeout(left, out.next()).await {
            Ok(Some(ShellEvent::Data(d) | ShellEvent::Stderr(d))) => {
                seen.push_str(&String::from_utf8_lossy(&d));
            }
            Ok(Some(ShellEvent::Exit { .. }) | None) => break,
            Err(_) => panic!("timed out waiting for {needle:?}; got {seen:?}"),
        }
    }
    assert!(seen.contains(needle), "no {needle:?} in {seen:?}");
    seen
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn pty_echo_resize_env_and_exit() {
    let conn = env().connect().await;
    let mut request = PtyRequest::new(80, 24);
    request.term = "xterm-256color".into();
    request.env = vec![("LC_UN_TEST".into(), "hello-env".into())];
    let (shell, mut out) = conn.open_shell(&request).await.unwrap();

    // Echo: what we type comes back (the PTY echoes it), and the command runs.
    let started = Instant::now();
    shell.write(b"echo marker-$((6*7))\n").await.unwrap();
    read_until(&mut out, "marker-42").await;
    eprintln!("first command round trip: {:?}", started.elapsed());

    shell.write(b"stty size; echo $TERM\n").await.unwrap();
    let text = read_until(&mut out, "xterm-256color\r\n").await;
    assert!(text.contains("24 80"), "{text:?}");

    shell.resize(120, 40).await.unwrap();
    shell.write(b"stty size\n").await.unwrap();
    read_until(&mut out, "40 120").await;

    // Ubuntu's sshd accepts LC_*; the value reaches the shell.
    shell.write(b"echo \"env=$LC_UN_TEST\"\n").await.unwrap();
    read_until(&mut out, "env=hello-env").await;

    // A keystroke round trip on an idle shell.
    let t = Instant::now();
    shell.write(b"Q").await.unwrap();
    read_until(&mut out, "Q").await;
    eprintln!("keystroke echo: {:?}", t.elapsed());
    shell.write(b"\x15exit 3\n").await.unwrap();
    let mut status = None;
    while let Some(event) = out.next().await {
        if let ShellEvent::Exit { status: s, .. } = event {
            status = s;
        }
    }
    assert_eq!(status, Some(3));
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn exec_captures_streams_and_status() {
    let conn = env().connect().await;
    let out = conn.exec("echo out; echo err >&2; exit 7").await.unwrap();
    assert_eq!(out.stdout_text(), "out\n");
    assert_eq!(String::from_utf8_lossy(&out.stderr), "err\n");
    assert_eq!(out.exit_status, Some(7));
    match out.check() {
        Err(ssh::SshError::Remote { status, stderr }) => {
            assert_eq!(status, "exit 7");
            assert_eq!(stderr, "err");
        }
        other => panic!("{other:?}"),
    }
    let killed = conn.exec("kill -TERM $$").await.unwrap();
    assert_eq!(killed.exit_signal.as_deref(), Some("TERM"));
    // Large output is not truncated.
    let big = conn.exec("head -c 3000000 /dev/zero").await.unwrap();
    assert_eq!(big.stdout.len(), 3_000_000);
    // Several channels at once on one connection.
    let (a, b, c) = tokio::join!(
        conn.exec("echo a"),
        conn.exec("echo b"),
        conn.exec("echo c")
    );
    assert_eq!(
        [
            a.unwrap().stdout_text(),
            b.unwrap().stdout_text(),
            c.unwrap().stdout_text()
        ],
        ["a\n", "b\n", "c\n"]
    );
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn upload_raw_and_gzip_with_checksum() {
    let conn = env().connect().await;
    // Half compressible, half random.
    let mut data = vec![0u8; 4 << 20];
    getrandom::fill(&mut data[..2 << 20]).unwrap();
    for encoding in [UploadEncoding::Raw, UploadEncoding::Gzip] {
        let path = "~/un-test/dir with space/upload.bin";
        let t = Instant::now();
        let report = conn.upload(path, &data, 0o640, encoding).await.unwrap();
        eprintln!(
            "{encoding:?}: {} bytes ({} on the wire) in {:?}",
            report.size,
            report.sent,
            t.elapsed()
        );
        assert_eq!(report.sha256, ssh::sha256_hex(&data));
        if encoding == UploadEncoding::Gzip {
            assert!(report.sent < report.size * 3 / 4);
        }
        let check = conn
            .exec("sha256sum ~/'un-test/dir with space/upload.bin' && stat -c %a ~/'un-test/dir with space/upload.bin' && ls ~/'un-test/dir with space' | wc -l")
            .await
            .unwrap()
            .check()
            .unwrap()
            .stdout_text();
        assert!(check.starts_with(&report.sha256), "{check}");
        assert!(check.contains("\n640\n"), "{check}");
        assert!(check.ends_with("1\n"), "temp file left behind: {check}");
        assert_eq!(conn.download(path).await.unwrap(), data);
    }
    conn.exec("rm -rf ~/un-test").await.unwrap();
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn proxy_jump_chain() {
    let env = env();
    // VM → its own sshd on 127.0.0.1 → again 127.0.0.1: two jumps, three handshakes.
    let inner = HostSpec::new("127.0.0.1", &env.user);
    let target = Target {
        jumps: vec![env.spec(), inner.clone()],
        host: HostSpec {
            host_key_alias: Some("localhost-final".into()),
            ..inner
        },
    };
    let t = Instant::now();
    let conn = Connection::connect(&target, &env.options(env.key_creds()))
        .await
        .unwrap();
    eprintln!("3-hop connect: {:?}", t.elapsed());
    let out = conn
        .exec("echo $SSH_CONNECTION")
        .await
        .unwrap()
        .check()
        .unwrap();
    // The final hop sees a connection from loopback (the jump host), not from us.
    assert!(
        out.stdout_text().starts_with("127.0.0.1 "),
        "{}",
        out.stdout_text()
    );
    let (shell, mut out) = conn.open_shell(&PtyRequest::new(80, 24)).await.unwrap();
    shell.write(b"echo through-$((1+1))-jumps\n").await.unwrap();
    read_until(&mut out, "through-2-jumps").await;

    // A jump host that cannot reach the next hop reports which hop failed.
    let bad = Target {
        jumps: vec![env.spec()],
        host: HostSpec::new("127.0.0.1", &env.user).with_port(1),
    };
    let err = Connection::connect(&bad, &env.options(env.key_creds()))
        .await
        .unwrap_err();
    assert!(
        err.to_string().contains("could not reach 127.0.0.1:1"),
        "{err}"
    );

    // The same route from an ssh_config `ProxyJump`.
    let config = ssh::SshConfig::parse(&format!(
        "Host vm\n  HostName {}\n  User {}\nHost behind\n  HostName 127.0.0.1\n  ProxyJump vm\n  User {}\n",
        env.host, env.user, env.user
    ))
    .unwrap();
    let target = config.target("behind", "nobody").unwrap();
    assert_eq!(target.jumps.len(), 1);
    let conn = Connection::connect(&target, &env.options(env.key_creds()))
        .await
        .unwrap();
    assert!(conn.exec("true").await.unwrap().success());
}
