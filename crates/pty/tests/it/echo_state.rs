//! changes reach `echo_updates`? Run with `--nocapture` to see the measured latencies.

use std::path::Path;
use std::time::Instant;

use pty::{EchoState, Seq};

use crate::support::{read_to_end, read_until, spawn, wait_echo};

const COOKED: EchoState = EchoState {
    echo: true,
    canonical: true,
};
const HIDDEN: EchoState = EchoState {
    echo: false,
    canonical: true,
};
const RAW: EchoState = EchoState {
    echo: false,
    canonical: false,
};

#[tokio::test]
async fn fresh_pty_is_cooked_with_echo() {
    let pty = spawn(&["/bin/cat"]);
    assert_eq!(pty.echo_state(), COOKED);
    assert!(!pty.echo_state().is_hidden_input());
}

#[tokio::test]
async fn stty_echo_off_and_on() {
    let pty = spawn(&[
        "/bin/sh",
        "-c",
        "stty -echo; echo OFF; read x; stty echo; echo ON; read y; echo \"got:$x\"",
    ]);
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();

    read_until(&mut out, "OFF").await;
    let state = wait_echo(&pty, |s| !s.echo).await;
    assert_eq!(state, HIDDEN);
    assert!(state.is_hidden_input());

    pty.write("secret\n").await.unwrap();
    let seen = read_until(&mut out, "ON").await;
    assert!(
        !seen.contains("secret"),
        "typed while -echo was echoed: {seen:?}"
    );
    assert_eq!(wait_echo(&pty, |s| s.echo).await, COOKED);

    pty.write("z\n").await.unwrap();
    read_until(&mut out, "got:secret").await;
}

#[tokio::test]
async fn bash_read_s_password_prompt() {
    let pty = spawn(&[
        "/bin/bash",
        "--norc",
        "--noprofile",
        "-c",
        "read -s -p 'Password: ' pw; echo; echo \"len=${#pw}\"",
    ]);
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut out, "Password: ").await;
    let at_prompt = pty.echo_state();
    let start = Instant::now();
    assert_eq!(wait_echo(&pty, |s| s.is_hidden_input()).await, HIDDEN);
    eprintln!(
        "S6 read -s: state when prompt arrived {at_prompt:?}, hidden after {:?}",
        start.elapsed()
    );

    pty.write("hunter2\n").await.unwrap();
    let rest = read_to_end(&mut out).await;
    assert!(!rest.contains("hunter2"), "password echoed: {rest:?}");
    assert!(rest.contains("len=7"), "{rest:?}");
}

#[tokio::test]
async fn raw_mode_is_not_hidden_input() {
    let pty = spawn(&["/bin/sh", "-c", "stty raw -echo; echo RAW; read x"]);
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut out, "RAW").await;
    let state = wait_echo(&pty, |s| !s.canonical).await;
    assert_eq!(state, RAW);
    assert!(!state.is_hidden_input());
}

/// A change with no output around it is still picked up, by the periodic re-check.
#[tokio::test]
async fn silent_change_is_detected_by_polling() {
    for delay in ["0.2", "1.5"] {
        let script = format!("echo GO; sleep {delay}; stty -echo; sleep 5");
        let pty = spawn(&["/bin/sh", "-c", &script]);
        let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
        read_until(&mut out, "GO").await;
        let start = Instant::now();
        wait_echo(&pty, |s| !s.echo).await;
        let elapsed = start.elapsed();
        eprintln!("S6 silent stty -echo after {delay}s seen after {elapsed:?}");
        let delay: f64 = delay.parse().unwrap();
        // Within the 500 ms active window the re-check runs every 25 ms, after it every 1 s.
        // Allow 300 ms for `stty` startup and scheduling.
        let bound = delay + if delay < 0.5 { 0.025 } else { 1.0 } + 0.3;
        assert!(elapsed.as_secs_f64() < bound, "{elapsed:?} >= {bound}s");
    }
}

/// Line editors put the tty in raw, no-echo mode at the prompt and restore cooked mode for the
/// commands they run, so `read -s` inside an interactive shell is visible as hidden input.
#[tokio::test]
async fn interactive_shells_line_editor_and_read_s() {
    let shells: [&[&str]; 2] = [
        &["/bin/zsh", "-f", "-i"],
        &["/bin/bash", "--norc", "--noprofile", "-i"],
    ];
    // zsh is not installed everywhere (many Linux images); bash is.
    for argv in shells
        .into_iter()
        .filter(|argv| Path::new(argv[0]).exists())
    {
        let mut cmd = crate::support::command(argv);
        cmd.env("PS1", "PROMPT> ");
        let pty = pty::PtyActor::spawn(cmd, pty::SpawnOptions::default()).unwrap();
        let mut out = pty.subscribe_from(Seq::ZERO).unwrap();

        read_until(&mut out, "PROMPT> ").await;
        let at_prompt = wait_echo(&pty, |s| !s.canonical).await;
        eprintln!("S6 {} at prompt: {at_prompt:?}", argv[0]);
        assert!(!at_prompt.is_hidden_input());

        pty.write("read -s v; echo \"n=${#v}\"\n").await.unwrap();
        let hidden = wait_echo(&pty, |s| s.is_hidden_input()).await;
        assert_eq!(hidden, HIDDEN);
        pty.write("abc\n").await.unwrap();
        let seen = read_until(&mut out, "n=3").await;
        assert!(!seen.contains("abc"), "{seen:?}");

        read_until(&mut out, "PROMPT> ").await;
        assert!(!wait_echo(&pty, |s| !s.canonical).await.is_hidden_input());
        pty.write("exit\n").await.unwrap();
        crate::support::within("exit", pty.wait()).await.unwrap();
    }
}

/// Python's `getpass` (the same termios dance as `sudo` and `ssh`). Ignored by default because
/// `/usr/bin/python3` may be the Xcode stub.
#[tokio::test]
#[ignore = "needs a working python3"]
async fn python_getpass() {
    let pty = spawn(&[
        "/usr/bin/python3",
        "-c",
        "import getpass; p = getpass.getpass('Pw: '); print('len', len(p))",
    ]);
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut out, "Pw: ").await;
    assert_eq!(wait_echo(&pty, |s| !s.echo).await, HIDDEN);
    pty.write("swordfish\n").await.unwrap();
    let rest = read_to_end(&mut out).await;
    assert!(
        !rest.contains("swordfish") && rest.contains("len 9"),
        "{rest:?}"
    );
}

/// A mode change with no output and no input (past the active polling window) is seen as soon
/// as someone asks: quiet terminals do not poll their modes forever.
#[tokio::test]
async fn refresh_echo_reads_a_silent_mode_change() {
    let pty = spawn(&["/bin/sh", "-c", "sleep 1; stty -echo; sleep 100"]);
    tokio::time::sleep(std::time::Duration::from_millis(1300)).await;
    pty.refresh_echo();
    let deadline = Instant::now() + std::time::Duration::from_millis(150);
    while pty.echo_state().echo && Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert_eq!(pty.echo_state(), HIDDEN);
}
