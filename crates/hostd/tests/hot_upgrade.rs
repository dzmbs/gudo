//! A real `gudo-hostd` upgraded while programs run in its panes keeps them running: the same
//! processes on the same terminals, their output stream continuing without a gap for the
//! client that reconnects, screens and scrollback intact, shell state kept, input working,
//! and no descriptor of the daemon's leaking into any program. A build that cannot continue
//! the panes ends them cleanly and starts afresh.

#[allow(dead_code)]
#[path = "../../daemon/tests/it/support.rs"]
mod support;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use client_core::proto::{
    CaseMode, LayoutOp, OpOutcome, PaneId, PaneLaunch, SearchMode, SearchQuery,
};
use client_core::{ClientConfig, ClientEvent, DaemonBuild};

use support::TestClient;

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

/// The daemon process, killed with its process group when the test ends however it ends.
struct Hostd {
    child: Child,
    log: PathBuf,
}

impl Drop for Hostd {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Hostd {
    fn log(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}

/// An installed copy of the daemon in `dir/bin` (a directory it may replace itself in).
fn install(dir: &Path) -> PathBuf {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let exe = bin.join("gudo-hostd");
    std::fs::copy(HOSTD, &exe).unwrap();
    exe
}

fn run(exe: &Path, state: &Path, log: &Path) -> Hostd {
    let child = Command::new(exe)
        .arg("--state-dir")
        .arg(state)
        .args([
            "run",
            "--no-relay",
            "--bind",
            "127.0.0.1:0",
            "--shell",
            "/bin/sh",
        ])
        .env("GUDO_LOG", "info")
        .stdout(Stdio::null())
        .stderr(std::fs::File::create(log).unwrap())
        .spawn()
        .unwrap();
    Hostd {
        child,
        log: log.to_owned(),
    }
}

fn ticket(exe: &Path, state: &Path) -> String {
    let output = Command::new(exe)
        .arg("--state-dir")
        .arg(state)
        .args(["pair", "--json", "--local", "--wait", "20"])
        .output()
        .unwrap();
    let paired: serde_json::Value = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|_| panic!("pair: {}", String::from_utf8_lossy(&output.stderr)));
    paired["ticket"].as_str().unwrap().to_owned()
}

fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

/// The value printed after `key=` last in `text`.
fn printed(text: &str, key: &str) -> Option<String> {
    let at = text.rfind(&format!("{key}="))?;
    let rest = &text[at + key.len() + 1..];
    Some(rest.split_whitespace().next()?.to_owned())
}

async fn new_tab(client: &mut TestClient, argv: &[&str]) -> PaneId {
    let session_id = client.layout.as_ref().unwrap().session_id;
    let launch = PaneLaunch::Command {
        argv: argv.iter().map(|arg| (*arg).to_owned()).collect(),
        cwd: None,
    };
    match client
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch,
        })
        .await
    {
        OpOutcome::TabCreated { pane_id, .. } => pane_id,
        other => panic!("new tab: {other:?}"),
    }
}

async fn follow_all(client: &mut TestClient, panes: &[PaneId]) {
    for &pane in panes {
        client.follow(pane).await;
    }
    client.client.set_view(Some(panes[0]), panes.to_vec());
}

/// What each of a process's descriptors refers to.
fn open_files(pid: u32) -> Vec<String> {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_dir(format!("/proc/{pid}/fd"))
            .unwrap()
            .filter_map(|entry| {
                let entry = entry.ok()?;
                let target = std::fs::read_link(entry.path()).ok()?;
                Some(format!(
                    "{} {}",
                    entry.file_name().to_string_lossy(),
                    target.display()
                ))
            })
            .collect()
    }
    #[cfg(target_os = "macos")]
    {
        let output = Command::new("lsof")
            .args([
                "-n",
                "-P",
                "-a",
                "-d",
                "0-1023",
                "-p",
                &pid.to_string(),
                "-F",
                "fn",
            ])
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&output.stdout);
        let mut files = Vec::new();
        let mut fd = String::new();
        for line in text.lines() {
            if let Some(number) = line.strip_prefix('f') {
                fd = number.to_owned();
            } else if let Some(name) = line.strip_prefix('n') {
                files.push(format!("{fd} {name}"));
            }
        }
        files
    }
}

/// A pane's program holds its terminal on 0, 1 and 2 and nothing of the daemon's: no PTY
/// master (its own or another pane's), no hand-off file, no socket.
fn assert_no_leaks(pid: u32, what: &str) {
    let files = open_files(pid);
    assert!(!files.is_empty(), "{what}: no descriptors listed for {pid}");
    for file in &files {
        let (fd, name) = file.split_once(' ').unwrap();
        let fd: u32 = fd.parse().unwrap();
        assert!(
            !name.contains("ptmx")
                && !name.contains("memfd")
                && !name.contains("handoff")
                && !name.contains("socket")
                && !name.contains("hostd"),
            "{what}: {pid} holds {file}; all: {files:?}"
        );
        assert!(
            fd <= 2 || fd == 255 || name.contains("/dev/null"),
            "{what}: {pid} holds an unexpected descriptor {file}; all: {files:?}"
        );
    }
}

async fn reconnected(client: &mut TestClient, before: u32) {
    client
        .until("the client reconnects", |client| client.connected > before)
        .await;
}

async fn search_total(client: &mut TestClient, pane: PaneId, text: &str) -> u32 {
    let query = SearchQuery {
        pattern: text.to_owned(),
        mode: SearchMode::Plain,
        case: CaseMode::Sensitive,
    };
    let id = client.client.search(pane, query, 0, 10);
    match client.answer(id).await {
        ClientEvent::SearchResult { result, .. } => result.unwrap().total,
        other => panic!("search: {other:?}"),
    }
}

/// The counter values in a stream, in order.
fn counts(bytes: &[u8]) -> Vec<u64> {
    String::from_utf8_lossy(bytes)
        .split(['\r', '\n'])
        .filter_map(|line| line.trim().strip_prefix("n=")?.parse().ok())
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn running_programs_survive_an_upgrade() {
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let state = dir.path().join("state");
    let hostd = run(&exe, &state, &dir.path().join("hostd.log"));
    let daemon_pid = hostd.child.id();
    let ticket = ticket(&exe, &state);
    let key = ClientConfig::generate_key();
    let mut client = TestClient::connect(&ticket, key.clone());

    // An interactive shell with state.
    let shell = client.attach_and_follow().await;
    client.type_line(
        shell,
        "export KEEP=kept-42; cd /tmp; echo early-marker; i=0; while [ $i -lt 200 ]; do i=$((i+1)); echo line-$i; done; echo shell-pid=$$",
    );
    client
        .until("the shell's pid", |client| {
            printed(&client.text(shell), "shell-pid").is_some_and(|pid| pid.parse::<u32>().is_ok())
        })
        .await;
    // A counter, and a program that only sleeps.
    let counter = new_tab(
        &mut client,
        &[
            "/bin/sh",
            "-c",
            "echo counter-pid=$$; i=0; while :; do i=$((i+1)); echo n=$i; sleep 0.02; done",
        ],
    )
    .await;
    let sleeper = new_tab(
        &mut client,
        &["/bin/sh", "-c", "echo sleeper-pid=$$; exec sleep 600"],
    )
    .await;
    follow_all(&mut client, &[shell, counter, sleeper]).await;
    client.wait_text(counter, "n=20").await;
    client.wait_text(sleeper, "sleeper-pid=").await;
    let shell_pid: u32 = printed(&client.text(shell), "shell-pid")
        .unwrap()
        .parse()
        .unwrap();
    let counter_pid: u32 = printed(&client.text(counter), "counter-pid")
        .unwrap()
        .parse()
        .unwrap();
    let sleeper_pid: u32 = printed(&client.text(sleeper), "sleeper-pid")
        .unwrap()
        .parse()
        .unwrap();
    assert!(alive(shell_pid) && alive(counter_pid) && alive(sleeper_pid));
    let counter_snapshots = client.streams[&counter].snapshots;
    let shell_snapshots = client.streams[&shell].snapshots;
    let connections = client.connected;

    // The owner installs a build (this one again, as a new file).
    let build = DaemonBuild::from_file(HOSTD, "hot upgrade".into()).unwrap();
    client
        .client
        .upgrade_daemon(build, None)
        .await
        .unwrap_or_else(|error| panic!("upgrade: {error}\n{}", hostd.log()));
    reconnected(&mut client, connections).await;
    let before = client.streams[&counter].bytes.len();
    client
        .until("the counter goes on", |client| {
            client.streams[&counter].bytes.len() > before + 200
        })
        .await;
    let log = hostd.log();
    assert!(
        log.contains("handing the panes to the new build"),
        "hand-off missing:\n{log}"
    );
    assert!(
        log.contains("continued the pane from the previous build"),
        "adoption missing:\n{log}"
    );

    // The same daemon process and the same programs.
    assert_eq!(hostd.child.id(), daemon_pid);
    assert!(alive(shell_pid) && alive(counter_pid) && alive(sleeper_pid));
    // The stream went on where it stood: no gap, no snapshot, every number once in order.
    let stream = &client.streams[&counter];
    assert!(stream.gaps.is_empty(), "stream jumped: {:?}", stream.gaps);
    assert_eq!(
        stream.snapshots, counter_snapshots,
        "the counter was not resumed"
    );
    assert_eq!(client.streams[&shell].snapshots, shell_snapshots);
    let numbers = counts(&stream.bytes);
    let first = numbers[0];
    assert_eq!(
        numbers,
        (first..first + numbers.len() as u64).collect::<Vec<_>>(),
        "the counter skipped or repeated"
    );

    // Shell state and input.
    client.type_line(shell, "echo \"after-$KEEP-$(pwd)\" shell-pid=$$");
    client.wait_text(shell, "after-kept-42-/tmp").await;
    assert_eq!(
        printed(&client.text(shell), "shell-pid"),
        Some(shell_pid.to_string())
    );

    // Scrollback from before, for a client that comes new.
    let mut late = TestClient::connect(&ticket, key);
    late.attach_and_follow().await;
    assert!(search_total(&mut late, shell, "early-marker").await >= 1);
    assert!(search_total(&mut late, shell, "line-1").await >= 100);

    // A pane opened after the upgrade, and the carried ones, hold nothing of the daemon's.
    let fresh = new_tab(
        &mut client,
        &["/bin/sh", "-c", "echo fresh-pid=$$; exec sleep 600"],
    )
    .await;
    client.follow(fresh).await;
    client.wait_text(fresh, "fresh-pid=").await;
    let fresh_pid: u32 = printed(&client.text(fresh), "fresh-pid")
        .unwrap()
        .parse()
        .unwrap();
    for (pid, what) in [
        (sleeper_pid, "carried sleep"),
        (fresh_pid, "pane started after the upgrade"),
    ] {
        assert_no_leaks(pid, what);
    }

    // A second upgrade carries them again.
    let connections = client.connected;
    let build = DaemonBuild::from_file(HOSTD, "hot upgrade 2".into()).unwrap();
    client
        .client
        .upgrade_daemon(build, None)
        .await
        .unwrap_or_else(|error| panic!("second upgrade: {error}\n{}", hostd.log()));
    reconnected(&mut client, connections).await;
    client.type_line(shell, "echo again-$KEEP");
    client.wait_text(shell, "again-kept-42").await;
    assert!(alive(counter_pid) && alive(sleeper_pid) && alive(fresh_pid));
    assert!(client.streams[&counter].gaps.is_empty());
}

/// Writes a hand-off in a format no build reads, naming `pid` (a child of the process that
/// will read it) and a descriptor that is no terminal.
fn foreign_hand_off(path: &Path, fd: i32, pid: u32) {
    let mut file = std::fs::File::create(path).unwrap();
    file.write_all(b"HOSTDHO\0").unwrap();
    file.write_all(&999u32.to_le_bytes()).unwrap();
    file.write_all(&1u32.to_le_bytes()).unwrap();
    file.write_all(&fd.to_le_bytes()).unwrap();
    file.write_all(&pid.to_le_bytes()).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hand_off_it_cannot_read_ends_the_panes_and_starts_afresh() {
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let state = dir.path().join("state");
    std::fs::create_dir_all(&state).unwrap();
    let pid_file = dir.path().join("pid");
    let go = dir.path().join("go");
    let hand_off = dir.path().join("handoff");
    let log = dir.path().join("hostd.log");
    // A shell starts a child that ignores hangups, waits for the hand-off to be written, then
    // becomes the daemon with it (as a build that handed off would), so the child is the
    // daemon's.
    let script = format!(
        "trap '' HUP; sleep 600 & echo $! > {pid}; while [ ! -e {go} ]; do sleep 0.05; done; \
         exec 7<{hand_off} 8</dev/null; GUDO_HANDOFF_FD=7 exec {exe} --state-dir {state} run \
         --no-relay --bind 127.0.0.1:0 --shell /bin/sh",
        pid = pid_file.display(),
        go = go.display(),
        hand_off = hand_off.display(),
        exe = exe.display(),
        state = state.display(),
    );
    let hostd = Hostd {
        child: Command::new("/bin/sh")
            .args(["-c", &script])
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(&log).unwrap())
            .spawn()
            .unwrap(),
        log: log.clone(),
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    let child_pid: u32 = loop {
        if let Some(pid) = std::fs::read_to_string(&pid_file)
            .ok()
            .and_then(|text| text.trim().parse().ok())
        {
            break pid;
        }
        assert!(
            Instant::now() < deadline,
            "the stand-in child never started"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    foreign_hand_off(&hand_off, 8, child_pid);
    std::fs::write(&go, b"").unwrap();

    // The daemon serves as after a plain restart...
    let ticket = ticket(&exe, &state);
    let mut client = TestClient::connect(&ticket, ClientConfig::generate_key());
    let shell = client.attach_and_follow().await;
    client.type_line(shell, "echo fresh-$((6*7))");
    client.wait_text(shell, "fresh-42").await;
    // ...and ended the carried child, although it ignores hangups, and reaped it.
    let deadline = Instant::now() + Duration::from_secs(10);
    while alive(child_pid) {
        assert!(
            Instant::now() < deadline,
            "the carried child still runs:\n{}",
            hostd.log()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        hostd.log().contains("does not read"),
        "no word of the foreign hand-off:\n{}",
        hostd.log()
    );
    // The variable never reaches a pane.
    client.type_line(shell, "echo \"var=[${GUDO_HANDOFF_FD:-unset}]\"");
    client.wait_text(shell, "var=[unset]").await;
}

fn restart_command(exe: &Path, state: &Path) -> std::process::Output {
    Command::new(exe)
        .arg("--state-dir")
        .arg(state)
        .arg("restart")
        .output()
        .unwrap()
}

/// Puts `contents` at `exe` as a new file, as a package manager or an app update does.
fn replace(exe: &Path, contents: &[u8]) {
    use std::os::unix::fs::PermissionsExt;
    let staged = exe.with_extension("staged");
    std::fs::write(&staged, contents).unwrap();
    std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::rename(&staged, exe).unwrap();
}

fn started_at(state: &Path) -> u64 {
    let info: serde_json::Value =
        serde_json::from_slice(&std::fs::read(state.join("endpoint.json")).unwrap()).unwrap();
    info["started_at"].as_u64().unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_restart_command_continues_the_panes_in_the_installed_build() {
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let state = dir.path().join("state");
    let hostd = run(&exe, &state, &dir.path().join("hostd.log"));
    let ticket = ticket(&exe, &state);
    let mut client = TestClient::connect(&ticket, ClientConfig::generate_key());
    let shell = client.attach_and_follow().await;
    client.type_line(shell, "export KEEP=still-here; echo set-$KEEP");
    client.wait_text(shell, "set-still-here").await;
    let first_start = started_at(&state);

    // The file it runs from is unchanged: nothing to do.
    let output = restart_command(&exe, &state);
    assert!(output.status.success(), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stdout).contains("already running"));
    assert_eq!(started_at(&state), first_start);

    // A build that cannot take the sessions over is refused; the daemon runs on untouched.
    let info = serde_json::json!({
        "version": "9.9.9", "build": "no-handoff", "built_unix": 1_800_000_000u64,
        "protocol": 999, "min_client_protocol": 0, "features": 0, "hostname": "test",
        "os": std::env::consts::OS, "arch": std::env::consts::ARCH, "os_name": "",
    });
    let old_build =
        format!("#!/bin/sh\nif [ \"$1\" = build-info ]; then echo '{info}'; exit 0; fi\nexit 3\n");
    replace(&exe, old_build.as_bytes());
    let output = restart_command(Path::new(HOSTD), &state);
    assert!(!output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("cannot take over"),
        "{output:?}"
    );
    assert_eq!(started_at(&state), first_start);

    // The real build, installed anew: the same process restarts into it, the shell lives on.
    replace(&exe, &std::fs::read(HOSTD).unwrap());
    let connections = client.connected;
    let output = restart_command(&exe, &state);
    assert!(output.status.success(), "{output:?}\n{}", hostd.log());
    assert!(started_at(&state) > first_start);
    reconnected(&mut client, connections).await;
    client.type_line(shell, "echo again-$KEEP");
    client.wait_text(shell, "again-still-here").await;
    assert!(client.streams[&shell].gaps.is_empty());
}
