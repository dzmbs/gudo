//! PTY shells, exec, upload and ProxyJump against the real sshd.

use std::time::{Duration, Instant};

use ssh::{
    AuthMethod, Connection, Credentials, HostSpec, PtyRequest, SecretKey, ShellEvent, ShellOutput,
    SshError, Target, UploadEncoding,
};

use crate::common::env;

/// Reads shell output until `needle` shows up; returns everything read.
async fn read_until(output: &mut ShellOutput, needle: &str) -> String {
    let mut seen = String::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !seen.contains(needle) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match tokio::time::timeout(remaining, output.next()).await {
            Ok(Some(ShellEvent::Data(data) | ShellEvent::Stderr(data))) => {
                seen.push_str(&String::from_utf8_lossy(&data));
            }
            Ok(Some(ShellEvent::Exit { .. }) | None) => break,
            Err(_) => panic!("timed out waiting for {needle:?}; got {seen:?}"),
        }
    }
    assert!(seen.contains(needle), "no {needle:?} in {seen:?}");
    seen
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn pty_echo_resize_env_and_exit() {
    let connection = env().connect().await;
    let mut request = PtyRequest::new(80, 24);
    request.term = "xterm-256color".into();
    request.env = vec![("LC_UN_TEST".into(), "hello-env".into())];
    let (shell, mut output) = connection.open_shell(&request).await.unwrap();

    // Echo: what we type comes back (the PTY echoes it), and the command runs.
    let started = Instant::now();
    shell.write(b"echo marker-$((6*7))\n").await.unwrap();
    read_until(&mut output, "marker-42").await;
    eprintln!("first command round trip: {:?}", started.elapsed());

    shell.write(b"stty size; echo $TERM\n").await.unwrap();
    let text = read_until(&mut output, "xterm-256color\r\n").await;
    assert!(text.contains("24 80"), "{text:?}");

    shell.resize(120, 40).await.unwrap();
    shell.write(b"stty size\n").await.unwrap();
    read_until(&mut output, "40 120").await;

    // Ubuntu's sshd accepts LC_*; the value reaches the shell.
    shell.write(b"echo \"env=$LC_UN_TEST\"\n").await.unwrap();
    read_until(&mut output, "env=hello-env").await;

    // A keystroke round trip on an idle shell.
    let typed = Instant::now();
    shell.write(b"Q").await.unwrap();
    read_until(&mut output, "Q").await;
    eprintln!("keystroke echo: {:?}", typed.elapsed());
    shell.write(b"\x15exit 3\n").await.unwrap();
    let mut status = None;
    while let Some(event) = output.next().await {
        if let ShellEvent::Exit {
            status: exit_status,
            ..
        } = event
        {
            status = exit_status;
        }
    }
    assert_eq!(status, Some(3));
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn exec_captures_streams_and_status() {
    let connection = env().connect().await;
    let output = connection
        .exec("echo out; echo err >&2; exit 7")
        .await
        .unwrap();
    assert_eq!(output.stdout_text(), "out\n");
    assert_eq!(String::from_utf8_lossy(&output.stderr), "err\n");
    assert_eq!(output.exit_status, Some(7));
    match output.check() {
        Err(ssh::SshError::Remote { status, stderr }) => {
            assert_eq!(status, "exit 7");
            assert_eq!(stderr, "err");
        }
        other => panic!("{other:?}"),
    }
    let killed = connection.exec("kill -TERM $$").await.unwrap();
    assert_eq!(killed.exit_signal.as_deref(), Some("TERM"));
    // Large output is not truncated.
    let large = connection.exec("head -c 3000000 /dev/zero").await.unwrap();
    assert_eq!(large.stdout.len(), 3_000_000);
    // Several channels at once on one connection.
    let (a, b, c) = tokio::join!(
        connection.exec("echo a"),
        connection.exec("echo b"),
        connection.exec("echo c")
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
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn upload_raw_and_gzip_with_checksum() {
    let connection = env().connect().await;
    // Half compressible, half random.
    let mut data = vec![0u8; 4 << 20];
    getrandom::fill(&mut data[..2 << 20]).unwrap();
    for encoding in [UploadEncoding::Raw, UploadEncoding::Gzip] {
        let path = "~/gudo-test/dir with space/upload.bin";
        let started = Instant::now();
        let report = connection
            .upload(path, &data, 0o640, encoding)
            .await
            .unwrap();
        eprintln!(
            "{encoding:?}: {} bytes ({} on the wire) in {:?}",
            report.size,
            report.sent,
            started.elapsed()
        );
        assert_eq!(report.sha256, ssh::sha256_hex(&data));
        if encoding == UploadEncoding::Gzip {
            assert!(report.sent < report.size * 3 / 4);
        }
        let check = connection
            .exec("sha256sum ~/'gudo-test/dir with space/upload.bin' && stat -c %a ~/'gudo-test/dir with space/upload.bin' && ls ~/'gudo-test/dir with space' | wc -l")
            .await
            .unwrap()
            .check()
            .unwrap()
            .stdout_text();
        assert!(check.starts_with(&report.sha256), "{check}");
        assert!(check.contains("\n640\n"), "{check}");
        assert!(check.ends_with("1\n"), "temp file left behind: {check}");
        assert_eq!(connection.download(path).await.unwrap(), data);
    }
    connection.exec("rm -rf ~/gudo-test").await.unwrap();
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
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
    let started = Instant::now();
    let connection = Connection::connect(&target, &env.options(env.key_credentials()))
        .await
        .unwrap();
    eprintln!("3-hop connect: {:?}", started.elapsed());
    let output = connection
        .exec("echo $SSH_CONNECTION")
        .await
        .unwrap()
        .check()
        .unwrap();
    // The final hop sees a connection from loopback (the jump host), not from us.
    assert!(
        output.stdout_text().starts_with("127.0.0.1 "),
        "{}",
        output.stdout_text()
    );
    let (shell, mut output) = connection
        .open_shell(&PtyRequest::new(80, 24))
        .await
        .unwrap();
    shell.write(b"echo through-$((1+1))-jumps\n").await.unwrap();
    read_until(&mut output, "through-2-jumps").await;

    // A jump host that cannot reach the next hop reports which hop failed.
    let bad = Target {
        jumps: vec![env.spec()],
        host: HostSpec::new("127.0.0.1", &env.user).with_port(1),
    };
    let error = Connection::connect(&bad, &env.options(env.key_credentials()))
        .await
        .unwrap_err();
    assert!(
        error.to_string().contains("could not reach 127.0.0.1:1"),
        "{error}"
    );

    // The same route from an ssh_config `ProxyJump`.
    let config = ssh::SshConfig::parse(&format!(
        "Host vm\n  HostName {}\n  User {}\nHost behind\n  HostName 127.0.0.1\n  ProxyJump vm\n  User {}\n",
        env.host, env.user, env.user
    ))
    .unwrap();
    let target = config.target("behind", "nobody").unwrap();
    assert_eq!(target.jumps.len(), 1);
    let connection = Connection::connect(&target, &env.options(env.key_credentials()))
        .await
        .unwrap();
    assert!(connection.exec("true").await.unwrap().success());
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn jump_hosts_sign_in_with_their_own_credentials() {
    let env = env();
    let config = ssh::SshConfig::parse(&format!(
        "Host vm\n  HostName {}\n  User {}\n  IdentityFile {}\n",
        env.host,
        env.user,
        env.keys.join("id_ecdsa").display()
    ))
    .unwrap();
    let route = config
        .route(&format!("{}@127.0.0.1", env.user), Some("vm"), "nobody")
        .unwrap();
    assert_eq!(route.target.jumps.len(), 1);
    let jump_keys: Vec<AuthMethod> = route.jump_identity_files[0]
        .iter()
        .map(|path| AuthMethod::Key(SecretKey::load(path, None).unwrap()))
        .collect();

    // The destination only takes the password; the jump host only gets its own key.
    let mut options =
        env.options(Credentials::new().with(AuthMethod::Password(env.password.clone())));
    options.jump_credentials = vec![Credentials { methods: jump_keys }];
    let connection = Connection::connect(&route.target, &options).await.unwrap();
    assert!(connection.exec("true").await.unwrap().success());

    // A jump host given only a wrong password fails at the jump, not at the destination.
    options.jump_credentials = vec![Credentials::new().with(AuthMethod::Password("wrong".into()))];
    let error = Connection::connect(&route.target, &options)
        .await
        .unwrap_err();
    assert!(
        matches!(&error, SshError::AuthFailed { host, .. } if *host == env.host),
        "{error}"
    );
}
