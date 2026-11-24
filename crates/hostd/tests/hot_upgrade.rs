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
    run_with_env(exe, state, log, &[])
}

fn run_with_env(exe: &Path, state: &Path, log: &Path, env: &[(&str, String)]) -> Hostd {
    let home_directory = state.join("test-home");
    std::fs::create_dir_all(&home_directory).unwrap();
    let child = Command::new(exe)
        .env("HOME", &home_directory)
        .env("CLAUDE_CONFIG_DIR", home_directory.join(".claude"))
        .env("CODEX_HOME", home_directory.join(".codex"))
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
        .envs(env.iter().map(|(key, value)| (key, value)))
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

const CODEX_ID: &str = "0199a213-81c0-7800-8aa1-bbab2a035a53";

/// Writes a rollout the way Codex does, keeps it open and counts while running as `codex`.
const FAKE_CODEX: &str = r#"#!/bin/bash
case " $* " in *" resume "*) echo "resumed-session=${@: -1}"; exec -a codex /bin/sleep 600 ;; esac
dir="$CODEX_HOME/sessions/2026/10/18"
mkdir -p "$dir"
f="$dir/rollout-2026-10-18T12-00-00-__ID__.jsonl"
printf '{"type":"session_meta","payload":{"id":"x","cwd":"%s"}}\n' "$PWD" > "$f"
exec 3>>"$f"
exec -a codex /bin/sh -c 'echo codex-pid=$$; i=0; while :; do i=$((i+1)); echo n=$i; sleep 0.05; done'
"#;

/// An app update replaces the whole bundle the helper runs from, the app runs `restart`, and
/// a Codex started by hand keeps running: the same process, its output going on. Its session
/// stays recorded, so a cold restart later still resumes it. `GUDO_TEST_UPGRADE_FROM` and
/// `GUDO_TEST_UPGRADE_TO` name two builds to update between (default: this one twice).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_app_update_keeps_codex_running_and_resumable() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let macos = dir.path().join("Gudo.app/Contents/MacOS");
    std::fs::create_dir_all(&macos).unwrap();
    let exe = macos.join("gudo-hostd");
    let build =
        |var: &str| std::env::var_os(var).map_or_else(|| PathBuf::from(HOSTD), PathBuf::from);
    let (from, to) = (
        build("GUDO_TEST_UPGRADE_FROM"),
        build("GUDO_TEST_UPGRADE_TO"),
    );
    std::fs::copy(&from, &exe).unwrap();
    let tools = dir.path().join("bin");
    std::fs::create_dir_all(&tools).unwrap();
    let codex = tools.join("codex");
    std::fs::write(&codex, FAKE_CODEX.replace("__ID__", CODEX_ID)).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let env = [
        (
            "PATH",
            format!(
                "{}:{}",
                tools.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        ),
        (
            "CODEX_HOME",
            dir.path().join("codex-home").display().to_string(),
        ),
    ];
    let state = dir.path().join("state");
    let log = dir.path().join("hostd.log");
    let mut hostd = run_with_env(&exe, &state, &log, &env);
    let daemon_pid = hostd.child.id();
    let key = ClientConfig::generate_key();
    let mut client = TestClient::connect(&ticket(&exe, &state), key.clone());
    client.attach_and_follow().await;
    let session_id = client.layout.as_ref().unwrap().session_id;
    let OpOutcome::TabCreated { pane_id: pane, .. } = client
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch: PaneLaunch::Shell {
                cwd: Some(work.display().to_string()),
            },
        })
        .await
    else {
        panic!("new tab");
    };
    client.follow(pane).await;
    client.type_line(pane, "codex");
    client.wait_text(pane, "n=5").await;
    let codex_pid: u32 = printed(&client.text(pane), "codex-pid")
        .unwrap()
        .parse()
        .unwrap();
    let layout = state.join("layout.json");
    let saved = || std::fs::read_to_string(&layout).is_ok_and(|text| text.contains(CODEX_ID));
    // Releases before 0.1.5 do not learn a hand-started Codex's session; this build does.
    if from == to {
        let deadline = Instant::now() + support::TIMEOUT;
        while !saved() {
            assert!(Instant::now() < deadline, "session id never saved");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    // The update moves the old bundle away and puts the new one in its place.
    let staged = dir.path().join("staged/Gudo.app/Contents/MacOS");
    std::fs::create_dir_all(&staged).unwrap();
    std::fs::copy(&to, staged.join("gudo-hostd")).unwrap();
    std::fs::create_dir_all(dir.path().join("trash")).unwrap();
    std::fs::rename(
        dir.path().join("Gudo.app"),
        dir.path().join("trash/Gudo.app"),
    )
    .unwrap();
    std::fs::rename(
        dir.path().join("staged/Gudo.app"),
        dir.path().join("Gudo.app"),
    )
    .unwrap();
    let connections = client.connected;
    let build_before = client.client.daemon_info().unwrap().build;
    let output = restart_command(&exe, &state);
    assert!(output.status.success(), "{output:?}\n{}", hostd.log());
    assert_eq!(hostd.child.id(), daemon_pid);
    reconnected(&mut client, connections).await;
    if from != to {
        client
            .until("the new build answers", |client| {
                client.client.daemon_info().unwrap().build != build_before
            })
            .await;
    }
    let before = client.streams[&pane].bytes.len();
    client
        .until("codex goes on", |client| {
            client.streams[&pane].bytes.len() > before + 100
        })
        .await;
    assert!(alive(codex_pid));
    assert!(client.streams[&pane].gaps.is_empty());
    let deadline = Instant::now() + support::TIMEOUT;
    while !saved() {
        assert!(
            Instant::now() < deadline,
            "session id never saved after the update"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    // A cold restart later (a reboot, a crash) resumes the session.
    drop(client);
    // SAFETY: sends SIGTERM to the daemon this test started.
    unsafe { libc::kill(daemon_pid as libc::pid_t, libc::SIGTERM) };
    let _ = hostd.child.wait();
    let _hostd = run_with_env(&exe, &state, &dir.path().join("second.log"), &env);
    let mut client = TestClient::connect(&ticket(&exe, &state), key);
    client.client.attach(None);
    client
        .until("layout", |client| client.layout.is_some())
        .await;
    client.follow(pane).await;
    client
        .wait_text(pane, &format!("resumed-session={CODEX_ID}"))
        .await;
    client.wait_text(pane, "Restored after restart").await;
}

/// Every client sees an upgrade at once and is back within moments, not only the one that
/// sent it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn other_clients_are_back_moments_after_an_upgrade() {
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let state = dir.path().join("state");
    let hostd = run(&exe, &state, &dir.path().join("hostd.log"));
    let mut owner = TestClient::connect(&ticket(&exe, &state), ClientConfig::generate_key());
    let shell = owner.attach_and_follow().await;
    let mut other = TestClient::connect(&ticket(&exe, &state), ClientConfig::generate_key());
    other.client.attach(None);
    other
        .until("layout", |client| client.layout.is_some())
        .await;
    other.follow(shell).await;
    let connections = other.connected;

    let build = DaemonBuild::from_file(HOSTD, "hot upgrade".into()).unwrap();
    owner
        .client
        .upgrade_daemon(build, None)
        .await
        .unwrap_or_else(|error| panic!("upgrade: {error}\n{}", hostd.log()));
    let installed = Instant::now();
    reconnected(&mut other, connections).await;
    let back_after = installed.elapsed();
    assert!(
        back_after < Duration::from_secs(3),
        "the other client was back only after {back_after:?}\n{}",
        hostd.log()
    );
    other.type_line(shell, "echo still-typing");
    other.wait_text(shell, "still-typing").await;
}

const CLAUDE_ID: &str = "0b3bb01e-c7ff-4c07-b983-2dc15e6e1755";
const CLAUDE_TRANSCRIPT: &str =
    include_str!("../../daemon/tests/fixtures/timeline/claude-2.1.318.jsonl");

/// Writes its transcript where Claude Code does, reports it through the hooks a hand-started
/// Claude Code runs, and waits as `claude`.
const FAKE_CLAUDE: &str = r#"#!/bin/bash
cd "${CLAUDE_START_DIR:-.}"
dir="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$dir"
transcript="$dir/__ID__.jsonl"
cp "__TRANSCRIPT__" "$transcript"
for event in SessionStart UserPromptSubmit; do
  printf '{"hook_event_name":"%s","session_id":"__ID__","transcript_path":"%s","cwd":"%s","source":"startup","prompt":"hi"}' \
    "$event" "$transcript" "$PWD" | "$GUDO_HOOK" claude "$event"
done
echo claude-ready
exec -a claude /bin/sleep 600
"#;

/// A Claude Code typed into a shell keeps its Chat across an app update: the build that takes
/// the pane over finds the same conversation.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_app_update_keeps_chat_for_a_claude_started_by_hand() {
    update_keeps_chat_for_a_claude_started_by_hand("").await;
}

/// The same for a Claude Code whose transcript is not where the pane's directory says: the
/// path its hooks reported is kept across the update.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_app_update_keeps_chat_for_a_claude_started_in_another_directory() {
    update_keeps_chat_for_a_claude_started_by_hand("CLAUDE_START_DIR=elsewhere ").await;
}

async fn update_keeps_chat_for_a_claude_started_by_hand(command_prefix: &str) {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let build =
        |var: &str| std::env::var_os(var).map_or_else(|| PathBuf::from(HOSTD), PathBuf::from);
    let (from, to) = (
        build("GUDO_TEST_UPGRADE_FROM"),
        build("GUDO_TEST_UPGRADE_TO"),
    );
    let exe = install(dir.path());
    replace(&exe, &std::fs::read(&from).unwrap());
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    let transcript = dir.path().join("fixture.jsonl");
    std::fs::write(&transcript, CLAUDE_TRANSCRIPT).unwrap();
    let claude = tools.join("claude");
    std::fs::write(
        &claude,
        FAKE_CLAUDE
            .replace("__ID__", CLAUDE_ID)
            .replace("__TRANSCRIPT__", &transcript.display().to_string()),
    )
    .unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(work.join("elsewhere")).unwrap();
    let state = dir.path().join("state");
    let hostd = run(&exe, &state, &dir.path().join("hostd.log"));
    let mut client = TestClient::connect(&ticket(&exe, &state), ClientConfig::generate_key());
    client.attach_and_follow().await;
    let session_id = client.layout.as_ref().unwrap().session_id;
    let OpOutcome::TabCreated { pane_id: pane, .. } = client
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch: PaneLaunch::Shell {
                cwd: Some(work.display().to_string()),
            },
        })
        .await
    else {
        panic!("new tab");
    };
    client.follow(pane).await;
    client.type_line(pane, &format!("{command_prefix}{}", claude.display()));
    client.wait_text(pane, "claude-ready").await;
    client
        .until("the pane is an agent", |client| {
            client
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.agent.is_some())
        })
        .await;
    let before = chat_if_served(&client, pane).await;
    if let Some(before) = &before {
        assert_eq!(before.session.native_session, CLAUDE_ID, "{}", hostd.log());
        assert!(!before.items.is_empty());
    }

    let connections = client.connected;
    replace(&exe, &std::fs::read(&to).unwrap());
    let output = restart_command(&exe, &state);
    assert!(output.status.success(), "{output:?}\n{}", hostd.log());
    reconnected(&mut client, connections).await;
    client
        .until("the pane is an agent again", |client| {
            client
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.agent.is_some())
        })
        .await;
    let log = || hostd.log();
    assert_eq!(chat_session(&mut client, pane, &log).await, CLAUDE_ID);
    let after = client
        .client
        .timeline_watch(pane)
        .await
        .unwrap_or_else(|error| panic!("Chat after the update: {error}\n{}", hostd.log()));
    match before {
        Some(before) => assert_eq!(after.items.len(), before.items.len()),
        None => assert!(!after.items.is_empty()),
    }
}

/// A pane's Chat, or `None` from a release that serves no Chat yet.
async fn chat_if_served(
    client: &TestClient,
    pane: PaneId,
) -> Option<client_core::proto::TimelineSnapshot> {
    match client.client.timeline_watch(pane).await {
        Ok(snapshot) => Some(snapshot),
        Err(error) if error.to_string().contains("update the helper") => None,
        Err(error) => panic!("Chat: {error}\n{}", client.text(pane)),
    }
}

/// Answers the version check a launch makes, then runs as `FAKE_CLAUDE` does.
const LAUNCHED_CLAUDE: &str = r#"#!/bin/bash
case " $* " in *" --version "*) echo "2.1.318 (Claude Code)"; exit 0 ;; esac
echo claude-pid=$$
"#;

/// A Claude Code the helper launched, with Chat that sends to it, keeps running and keeps its
/// Chat, Send included, when the app updates the helper.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_app_update_keeps_a_launched_claude_and_its_chat() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    let transcript = dir.path().join("fixture.jsonl");
    std::fs::write(&transcript, CLAUDE_TRANSCRIPT).unwrap();
    let claude = tools.join("claude");
    let body = FAKE_CLAUDE
        .trim_start_matches("#!/bin/bash\n")
        .replace("__ID__", CLAUDE_ID)
        .replace("__TRANSCRIPT__", &transcript.display().to_string());
    std::fs::write(&claude, format!("{LAUNCHED_CLAUDE}{body}")).unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let env = [(
        "PATH",
        format!(
            "{}:{}",
            tools.display(),
            std::env::var("PATH").unwrap_or_default()
        ),
    )];
    let state = dir.path().join("state");
    let hostd = run_with_env(&exe, &state, &dir.path().join("hostd.log"), &env);
    let mut client = TestClient::connect(&ticket(&exe, &state), ClientConfig::generate_key());
    client.attach_and_follow().await;
    let session_id = client.layout.as_ref().unwrap().session_id;
    let OpOutcome::TabCreated { pane_id: pane, .. } = client
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch: PaneLaunch::Agent {
                agent: client_core::proto::AgentKind::Claude,
                resume: None,
                cwd: Some(work.display().to_string()),
            },
        })
        .await
    else {
        panic!("new tab");
    };
    client.follow(pane).await;
    client.wait_text(pane, "claude-ready").await;
    let claude_pid: u32 = printed(&client.text(pane), "claude-pid")
        .unwrap()
        .parse()
        .unwrap();
    let before = client
        .client
        .timeline_watch_capabilities(pane)
        .await
        .unwrap_or_else(|error| panic!("Chat: {error}\n{}", hostd.log()));
    assert_eq!(before.snapshot.session.native_session, CLAUDE_ID);
    assert!(
        before
            .capabilities
            .contains(client_core::proto::AgentCapabilities::SEND),
        "{:?}",
        before.capabilities
    );

    let connections = client.connected;
    replace(&exe, &std::fs::read(HOSTD).unwrap());
    let output = restart_command(&exe, &state);
    assert!(output.status.success(), "{output:?}\n{}", hostd.log());
    reconnected(&mut client, connections).await;
    assert!(alive(claude_pid));
    let after = client
        .client
        .timeline_watch_capabilities(pane)
        .await
        .unwrap_or_else(|error| panic!("Chat after the update: {error}\n{}", hostd.log()));
    assert_eq!(after.snapshot.session.native_session, CLAUDE_ID);
    assert_eq!(after.snapshot.items.len(), before.snapshot.items.len());
    assert_eq!(after.capabilities, before.capabilities);
}

// The update matrix: `scripts/upgrade-matrix.sh` runs the `a_release_*` tests once for every
// release that hands its panes on, with `GUDO_TEST_UPGRADE_FROM` naming that release's
// helper, `GUDO_TEST_UPGRADE_TO` this build stamped as newer, and `GUDO_TEST_RELEASE_CLIENT`
// a client built from the release. Without them each test updates this build to itself.

const MATRIX_CLAUDE_ID: &str = "4a6f2e1d-8c3b-4f5a-9e7d-1b2c3d4e5f60";
const MATRIX_LAUNCHED_ID: &str = "5b7a3f2e-9d4c-4a6b-8f8e-2c3d4e5f6a71";
const MATRIX_CODEX_ID: &str = "019a1b2c-3d4e-7f50-8a6b-7c8d9e0f1a2b";
const MATRIX_PI_ID: &str = "019a1b2c-4e5f-7061-8b7c-8d9e0f1a2b3c";

/// Claude Code typed by hand or launched by the helper (in a directory named `launched`): it
/// answers the launch's version check, writes its transcript and reports it through its hooks.
const MATRIX_CLAUDE: &str = r#"#!/bin/bash
case " $* " in *" --version "*) echo "2.1.318 (Claude Code)"; exit 0 ;; *" --help "*) exit 0 ;; esac
case "$(basename "$PWD")" in launched) id=__LAUNCHED_ID__ ;; *) id=__ID__ ;; esac
arguments="$*"
while [ $# -gt 0 ]; do
  case "$1" in --session-id | --resume) id="$2"; shift ;; esac
  shift
done
dir="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$dir"
transcript="$dir/$id.jsonl"
sed "s/__FIXTURE_ID__/$id/g" "__TRANSCRIPT__" > "$transcript"
for event in SessionStart UserPromptSubmit; do
  printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s","cwd":"%s","source":"startup","prompt":"hi"}' \
    "$event" "$id" "$transcript" "$PWD" | "$GUDO_HOOK" claude "$event"
done
echo "claude-ready $arguments"
exec -a claude /bin/sleep 600
"#;

const MATRIX_CODEX: &str = r#"#!/bin/bash
case " $* " in *" resume "*) echo "codex-resumed $*"; exec -a codex /bin/sleep 600 ;; esac
dir="$CODEX_HOME/sessions/2026/11/17"
mkdir -p "$dir"
f="$dir/rollout-2026-11-17T10-00-00-__ID__.jsonl"
printf '{"type":"session_meta","payload":{"id":"__ID__","cwd":"%s"}}\n' "$PWD" > "$f"
exec 3>>"$f"
echo codex-ready
exec -a codex /bin/sleep 600
"#;

const MATRIX_PI: &str = r#"#!/bin/bash
case " $* " in *" --session "*) echo "pi-resumed $*"; exec -a pi /bin/sleep 600 ;; esac
mkdir -p "$PI_CODING_AGENT_SESSION_DIR"
printf '{"type":"session","id":"__ID__"}\n' > "$PI_CODING_AGENT_SESSION_DIR/2026-11-17T10-00-00-000Z___ID__.jsonl"
echo pi-ready
exec -a pi /bin/sleep 600
"#;

/// How the app moves a helper to its new build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Update {
    /// The app replaced the helper's file and runs the new build's `restart`.
    RestartCommand,
    /// The app streams the new build to the helper over its connection.
    UpgradeStream,
}

/// What runs in the helper while it is updated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Workload {
    /// Shells, a split, and Claude Code, Codex and pi typed by hand.
    ByHand,
    /// Those and a Claude Code the helper launched, with Chat that sends to it.
    WithLaunchedAgent,
}

fn matrix_build(variable: &str) -> PathBuf {
    std::env::var_os(variable).map_or_else(|| PathBuf::from(HOSTD), PathBuf::from)
}

fn build_id(exe: &Path) -> String {
    let output = Command::new(exe)
        .args(["build-info", "--json"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&output.stdout);
    let line = text.lines().rfind(|line| line.starts_with('{')).unwrap();
    let info: serde_json::Value = serde_json::from_str(line).unwrap();
    info["build"].as_str().unwrap().to_owned()
}

fn endpoint(state: &Path) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(state.join("endpoint.json")).unwrap()).unwrap()
}

fn paired_devices(exe: &Path, state: &Path) -> usize {
    let output = Command::new(exe)
        .arg("--state-dir")
        .arg(state)
        .args(["devices", "--json"])
        .output()
        .unwrap();
    let devices: serde_json::Value =
        serde_json::from_slice(&output.stdout).unwrap_or_else(|_| panic!("devices: {output:?}"));
    devices.as_array().unwrap().len()
}

/// Stops whichever daemon serves `state` when the test ends: after an update that had to
/// restart the helper, it is no longer the test's child.
struct StopsDaemon(PathBuf);

impl Drop for StopsDaemon {
    fn drop(&mut self) {
        let pid = std::fs::read(self.0.join("endpoint.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .and_then(|info| info["pid"].as_u64());
        if let Some(pid) = pid {
            // SAFETY: signals the daemon this test started, by the pid it recorded.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
        }
    }
}

async fn new_pane(client: &mut TestClient, launch: PaneLaunch) -> PaneId {
    let session_id = client.layout.as_ref().unwrap().session_id;
    let OpOutcome::TabCreated { pane_id, .. } = client
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch,
        })
        .await
    else {
        panic!("new tab");
    };
    client.follow(pane_id).await;
    pane_id
}

fn shell_in(directory: &Path) -> PaneLaunch {
    PaneLaunch::Shell {
        cwd: Some(directory.display().to_string()),
    }
}

fn layout_leaves(client: &TestClient) -> Vec<Vec<PaneId>> {
    client
        .layout
        .as_ref()
        .unwrap()
        .tabs
        .iter()
        .map(|tab| support::leaves(&tab.root))
        .collect()
}

fn wait_saved(state: &Path, needles: &[&str], log: &dyn Fn() -> String) {
    let layout = state.join("layout.json");
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let text = std::fs::read_to_string(&layout).unwrap_or_default();
        if needles.iter().all(|needle| text.contains(needle)) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "never saved {needles:?}:\n{text}\n{}",
            log()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Whether `needles` are all saved with the layout within `wait`.
fn saved_within(state: &Path, needles: &[&str], wait: Duration) -> bool {
    let deadline = Instant::now() + wait;
    loop {
        let text = std::fs::read_to_string(state.join("layout.json")).unwrap_or_default();
        if needles.iter().all(|needle| text.contains(needle)) {
            return true;
        }
        if Instant::now() > deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

async fn chat_session(client: &mut TestClient, pane: PaneId, log: &dyn Fn() -> String) -> String {
    let mut last_error = String::new();
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        match client.client.timeline_watch(pane).await {
            Ok(snapshot) if !snapshot.session.native_session.is_empty() => {
                return snapshot.session.native_session;
            }
            Ok(_) => last_error = "no session yet".into(),
            Err(error) => last_error = error.to_string(),
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    panic!("no Chat on pane {pane}: {last_error}\n{}", log())
}

async fn is_agent(client: &mut TestClient, pane: PaneId) {
    client
        .until(&format!("pane {pane} is an agent"), |client| {
            client
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.agent.is_some())
        })
        .await;
}

/// A Claude Code the previous build launched takes a model chosen in Chat: it starts again on
/// its conversation, in its pane, with the model.
async fn changes_from_chat_after_the_update(
    client: &mut TestClient,
    pane: PaneId,
    log: &dyn Fn() -> String,
) {
    let session = chat_session(client, pane, log).await;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let controls = client.client.agent_controls_watch(pane).await;
        if let Ok(controls) = &controls
            && controls.config.support == client_core::proto::AgentConfigSupport::Supported
        {
            break;
        }
        assert!(Instant::now() < deadline, "{controls:?}\n{}", log());
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let change = client_core::proto::AgentConfigValues {
        model: Some("sonnet".into()),
        mode: None,
        effort: None,
    };
    client
        .client
        .set_agent_config(pane, change)
        .await
        .unwrap_or_else(|error| panic!("change from Chat: {error}\n{}", log()));
    let started = format!("claude-ready --resume {session} --model sonnet");
    let deadline = Instant::now() + Duration::from_secs(30);
    while !client.flat_text(pane).contains(&started) {
        assert!(
            Instant::now() < deadline,
            "never started again with the model:\n{}\n{}",
            client.text(pane),
            log()
        );
        client.until("pane output", |_| true).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    is_agent(client, pane).await;
}

async fn release_updates(update: Update, workload: Workload) {
    use std::os::unix::fs::PermissionsExt;
    let (from, to) = (
        matrix_build("GUDO_TEST_UPGRADE_FROM"),
        matrix_build("GUDO_TEST_UPGRADE_TO"),
    );
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    replace(&exe, &std::fs::read(&from).unwrap());
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    let fixture = dir.path().join("fixture.jsonl");
    std::fs::write(
        &fixture,
        CLAUDE_TRANSCRIPT.replace(CLAUDE_ID, "__FIXTURE_ID__"),
    )
    .unwrap();
    for (name, script) in [
        (
            "claude",
            MATRIX_CLAUDE
                .replace("__LAUNCHED_ID__", MATRIX_LAUNCHED_ID)
                .replace("__ID__", MATRIX_CLAUDE_ID)
                .replace("__TRANSCRIPT__", &fixture.display().to_string()),
        ),
        ("codex", MATRIX_CODEX.replace("__ID__", MATRIX_CODEX_ID)),
        ("pi", MATRIX_PI.replace("__ID__", MATRIX_PI_ID)),
    ] {
        let path = tools.join(name);
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let work = dir.path().join("work");
    let launched = dir.path().join("launched");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::create_dir_all(&launched).unwrap();
    let env = [
        (
            "PATH",
            format!(
                "{}:{}",
                tools.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        ),
        (
            "PI_CODING_AGENT_SESSION_DIR",
            dir.path().join("pi-sessions").display().to_string(),
        ),
    ];
    let state = dir.path().join("state");
    let log = dir.path().join("hostd.log");
    let _hostd = run_with_env(&exe, &state, &log, &env);
    let _stops = StopsDaemon(state.clone());
    let log = || std::fs::read_to_string(&log).unwrap_or_default();
    let mut client = TestClient::connect(&ticket(&exe, &state), ClientConfig::generate_key());

    let shell = client.attach_and_follow().await;
    client.type_line(
        shell,
        "export KEEP=kept; echo scroll-$((6*7))-start; seq 1 3000; echo visible-$((6*7))",
    );
    client.wait_text(shell, "visible-42").await;
    let OpOutcome::PaneCreated { pane_id: split } = client
        .op(LayoutOp::Split {
            pane_id: shell,
            axis: client_core::proto::Axis::Horizontal,
            launch: shell_in(&work),
        })
        .await
    else {
        panic!("split");
    };
    client.follow(split).await;
    let claude = new_pane(&mut client, shell_in(&work)).await;
    client.type_line(claude, "claude");
    client.wait_text(claude, "claude-ready").await;
    let codex = new_pane(&mut client, shell_in(&work)).await;
    client.type_line(codex, "codex");
    client.wait_text(codex, "codex-ready").await;
    let pi = new_pane(&mut client, shell_in(&work)).await;
    client.type_line(pi, "pi");
    client.wait_text(pi, "pi-ready").await;
    let launched_claude = if workload == Workload::WithLaunchedAgent {
        let pane = new_pane(
            &mut client,
            PaneLaunch::Agent {
                agent: client_core::proto::AgentKind::Claude,
                resume: None,
                cwd: Some(launched.display().to_string()),
            },
        )
        .await;
        client.wait_text(pane, "claude-ready").await;
        Some(pane)
    } else {
        None
    };
    is_agent(&mut client, claude).await;
    if chat_if_served(&client, claude).await.is_some() {
        assert_eq!(
            chat_session(&mut client, claude, &log).await,
            MATRIX_CLAUDE_ID
        );
    }
    let hands_off = Command::new(&from)
        .args(["build-info", "--json"])
        .output()
        .is_ok_and(|output| String::from_utf8_lossy(&output.stdout).contains("\"handoff\""));
    // Some releases never save the sessions of agents typed by hand; what they saved is
    // what a cold restart resumes.
    let sessions = [MATRIX_CLAUDE_ID];
    saved_within(
        &state,
        &sessions,
        Duration::from_secs(if hands_off { 10 } else { 2 }),
    );
    let scrolled = search_total(&mut client, shell, "scroll-42-start").await;
    assert_eq!(scrolled, 1);
    let daemon_id = endpoint(&state)["daemon_id"].as_str().unwrap().to_owned();
    let daemon_pid = endpoint(&state)["pid"].as_u64().unwrap();
    let devices = paired_devices(&exe, &state);
    let leaves_before = layout_leaves(&client);
    // Chat sends only to a launch the helper fences (0.1.5 and later): kept when it was there.
    let mut sends_before = false;
    if let Some(pane) = launched_claude
        && let Ok(chat) = client.client.timeline_watch_capabilities(pane).await
    {
        sends_before = chat
            .capabilities
            .contains(client_core::proto::AgentCapabilities::SEND);
    }
    let connections = client.connected;
    let saved_before = std::fs::read_to_string(state.join("layout.json")).unwrap_or_default();
    let claude_saved = saved_before.contains(MATRIX_CLAUDE_ID);
    let codex_saved = saved_before.contains(MATRIX_CODEX_ID);
    let pi_saved = saved_before.contains(MATRIX_PI_ID);

    let new_build = build_id(&to);
    match update {
        Update::RestartCommand => {
            replace(&exe, &std::fs::read(&to).unwrap());
            let output = restart_command(&exe, &state);
            assert!(output.status.success(), "{output:?}\n{}", log());
        }
        Update::UpgradeStream => {
            let build =
                DaemonBuild::from_file(&to.display().to_string(), new_build.clone()).unwrap();
            client
                .client
                .upgrade_daemon(build, None)
                .await
                .unwrap_or_else(|error| panic!("upgrade: {error}\n{}", log()));
        }
    }
    reconnected(&mut client, connections).await;
    client
        .until("the new build serves", |client| {
            client
                .client
                .daemon_info()
                .is_some_and(|info| info.build == new_build)
        })
        .await;
    assert_eq!(endpoint(&state)["daemon_id"].as_str().unwrap(), daemon_id);
    assert_eq!(paired_devices(&exe, &state), devices);
    client
        .until("the same layout", |client| {
            layout_leaves(client) == leaves_before
        })
        .await;
    let carried = hands_off && endpoint(&state)["pid"].as_u64() == Some(daemon_pid);
    if carried {
        assert_eq!(search_total(&mut client, shell, "scroll-42-start").await, 1);
        client.type_line(shell, "echo again-$KEEP");
        client.wait_text(shell, "again-kept").await;
    } else {
        // The release cannot or will not hand off and was restarted: agents resume.
        assert!(
            !hands_off || workload == Workload::WithLaunchedAgent,
            "{}",
            log()
        );
        if hands_off {
            client.wait_text(shell, "visible-42").await;
        }
        if claude_saved {
            client
                .wait_flat(claude, &format!("--resume {MATRIX_CLAUDE_ID}"))
                .await;
        }
        if codex_saved {
            client
                .wait_flat(codex, &format!("resume {MATRIX_CODEX_ID}"))
                .await;
        }
    }
    if carried || claude_saved {
        is_agent(&mut client, claude).await;
        assert_eq!(
            chat_session(&mut client, claude, &log).await,
            MATRIX_CLAUDE_ID
        );
    }
    if carried || codex_saved {
        is_agent(&mut client, codex).await;
    }
    if let Some(pane) = launched_claude {
        is_agent(&mut client, pane).await;
        // The helper names the session it launches; it is the same before and after.
        assert!(!chat_session(&mut client, pane, &log).await.is_empty());
        let chat = client
            .client
            .timeline_watch_capabilities(pane)
            .await
            .unwrap();
        assert!(
            !sends_before
                || chat
                    .capabilities
                    .contains(client_core::proto::AgentCapabilities::SEND),
            "{:?}",
            chat.capabilities
        );
        changes_from_chat_after_the_update(&mut client, pane, &log).await;
    }
    let mut sessions = Vec::new();
    if carried || claude_saved {
        sessions.push(MATRIX_CLAUDE_ID);
    }
    if carried || codex_saved {
        sessions.push(MATRIX_CODEX_ID);
    }
    if carried || pi_saved {
        sessions.push(MATRIX_PI_ID);
    }
    wait_saved(&state, &sessions, &log);

    if let Some(release_client) = std::env::var_os("GUDO_TEST_RELEASE_CLIENT") {
        client.type_line(shell, "echo client-$((6*7))-check");
        client.wait_text(shell, "client-42-check").await;
        let output = Command::new(release_client)
            .arg(ticket(&exe, &state))
            .arg(shell.0.to_string())
            .arg("client-42-check")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "a client of the release: {output:?}\n{}",
            log()
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_release_updates_with_the_restart_command() {
    release_updates(Update::RestartCommand, Workload::ByHand).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_release_updates_over_the_upgrade_stream() {
    release_updates(Update::UpgradeStream, Workload::ByHand).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_release_running_a_launched_agent_updates_with_the_restart_command() {
    release_updates(Update::RestartCommand, Workload::WithLaunchedAgent).await;
}

fn restart_into_command(exe: &Path, state: &Path, into: &Path) -> std::process::Output {
    Command::new(exe)
        .arg("--state-dir")
        .arg(state)
        .arg("restart")
        .arg("--into")
        .arg(into)
        .output()
        .unwrap()
}

fn running_executable(pid: u32) -> PathBuf {
    daemon::process_executable(pid)
        .unwrap()
        .canonicalize()
        .unwrap()
}

/// A helper running from one place (a build folder, an old app) hands its panes to the build
/// at another path, and runs from there from then on: a later update of that path restarts
/// into it, with the old place gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restart_into_hands_the_panes_to_a_build_at_another_path() {
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let state = dir.path().join("state");
    let hostd = run(&exe, &state, &dir.path().join("hostd.log"));
    let mut client = TestClient::connect(&ticket(&exe, &state), ClientConfig::generate_key());
    let shell = client.attach_and_follow().await;
    client.type_line(shell, "export KEEP=still-here; echo set-$KEEP");
    client.wait_text(shell, "set-still-here").await;
    let info = serde_json::from_slice::<serde_json::Value>(
        &Command::new(HOSTD)
            .args(["build-info", "--json"])
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap();
    assert_eq!(info["restart_into"], true);

    let current = dir.path().join("Helper/Versions/Current");
    std::fs::create_dir_all(&current).unwrap();
    let next = current.join("gudo-hostd");
    std::fs::copy(HOSTD, &next).unwrap();
    let next = next.canonicalize().unwrap();
    let connections = client.connected;
    let output = restart_into_command(&next, &state, &next);
    assert!(output.status.success(), "{output:?}\n{}", hostd.log());
    assert_eq!(endpoint_pid(&state), hostd.child.id());
    assert_eq!(running_executable(hostd.child.id()), next);
    reconnected(&mut client, connections).await;
    client.type_line(shell, "echo again-$KEEP");
    client.wait_text(shell, "again-still-here").await;

    std::fs::remove_dir_all(dir.path().join("bin")).unwrap();
    replace(&next, &std::fs::read(HOSTD).unwrap());
    let connections = client.connected;
    let started = started_at(&state);
    let output = restart_command(&next, &state);
    assert!(output.status.success(), "{output:?}\n{}", hostd.log());
    assert!(started_at(&state) > started);
    reconnected(&mut client, connections).await;
    client.type_line(shell, "echo third-$KEEP");
    client.wait_text(shell, "third-still-here").await;
}

fn endpoint_pid(state: &Path) -> u32 {
    let info: serde_json::Value =
        serde_json::from_slice(&std::fs::read(state.join("endpoint.json")).unwrap()).unwrap();
    info["pid"].as_u64().unwrap() as u32
}

/// A build another user could have changed is never run: neither one writable by its group or
/// by everyone, nor one in a directory they can write to.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restart_refuses_a_build_other_users_can_change() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let state = dir.path().join("state");
    let _hostd = run(&exe, &state, &dir.path().join("hostd.log"));
    let _ = ticket(&exe, &state);
    let first_start = started_at(&state);
    let shared = dir.path().join("shared");
    std::fs::create_dir(&shared).unwrap();
    let next = shared.join("gudo-hostd");
    std::fs::copy(HOSTD, &next).unwrap();
    let next = next.canonicalize().unwrap();
    for (file_mode, directory_mode) in [(0o775, 0o755), (0o757, 0o755), (0o755, 0o775)] {
        std::fs::set_permissions(&next, std::fs::Permissions::from_mode(file_mode)).unwrap();
        std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(directory_mode)).unwrap();
        let output = restart_into_command(Path::new(HOSTD), &state, &next);
        assert!(!output.status.success(), "{output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("writable by other users"),
            "{file_mode:o} in {directory_mode:o}: {output:?}"
        );
        assert_eq!(started_at(&state), first_start);
    }
}

/// An app that puts an older helper where the running one updates from cannot move it back:
/// the restart is refused and the daemon runs on untouched.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restart_refuses_an_older_build() {
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let state = dir.path().join("state");
    let _hostd = run(&exe, &state, &dir.path().join("hostd.log"));
    let _ = ticket(&exe, &state);
    let first_start = started_at(&state);
    let info = serde_json::json!({
        "version": "0.1.0", "build": "older", "built_unix": 1_700_000_000u64,
        "protocol": 0, "min_client_protocol": 0, "features": 0, "hostname": "test",
        "os": std::env::consts::OS, "arch": std::env::consts::ARCH, "os_name": "",
        "handoff": [1],
    });
    let older =
        format!("#!/bin/sh\nif [ \"$1\" = build-info ]; then echo '{info}'; exit 0; fi\nexit 3\n");
    replace(&exe, older.as_bytes());
    let output = restart_command(Path::new(HOSTD), &state);
    assert!(!output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("older than the running"),
        "{output:?}"
    );
    assert_eq!(started_at(&state), first_start);
}

/// Stands in for pi: loads the `--extension` it is given, as pi does, and starts its session.
const PI_HOST: &str = r#"
const args = process.argv.slice(2);
const extension = args[args.indexOf("--extension") + 1];
const model = { provider: "anthropic", id: "claude-opus-4-5", name: "Opus", reasoning: true };
const handlers = {};
const pi = {
  on: (event, handler) => (handlers[event] = handler),
  sendUserMessage: () => {},
  getCommands: () => [],
  getThinkingLevel: () => "off",
  setThinkingLevel: () => {},
  setModel: async () => true,
};
require(extension)(pi);
handlers.session_start({ reason: "startup" }, {
  cwd: process.cwd(),
  model,
  scopedModels: [],
  modelRegistry: { getAvailable: () => [model], find: () => model },
  sessionManager: { getSessionId: () => "__ID__", getSessionFile: () => undefined, getCwd: () => process.cwd() },
  isIdle: () => true,
  abort: () => {},
  getContextUsage: () => undefined,
});
console.log("pi-pid=" + process.pid);
setInterval(() => {}, 1000);
"#;

const BRIDGED_PI: &str = r#"#!/bin/bash
mkdir -p "$HOME/.pi/agent/sessions"
exec -a pi node "__HOST__" "$@"
"#;

async fn bridged(client: &mut TestClient, pane: PaneId, log: &dyn Fn() -> String) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let watched = client.client.timeline_watch_capabilities(pane).await;
        if watched.as_ref().is_ok_and(|watched| {
            watched
                .capabilities
                .contains(client_core::proto::AgentCapabilities::STOP)
        }) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "pi's bridge never connected: {watched:?}\n{}",
            log()
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// A pi the helper launched keeps running when the app updates the helper, and its bridge
/// extension connects to the new build, so Chat keeps streaming and stopping it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_app_update_keeps_a_launched_pi_and_its_bridge() {
    use std::os::unix::fs::PermissionsExt;
    if !Command::new("node")
        .arg("--version")
        .output()
        .is_ok_and(|output| output.status.success())
    {
        eprintln!("skipped: node is not installed");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let exe = install(dir.path());
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    let host = tools.join("pi-host.js");
    std::fs::write(&host, PI_HOST.replace("__ID__", MATRIX_PI_ID)).unwrap();
    let pi = tools.join("pi");
    std::fs::write(
        &pi,
        BRIDGED_PI.replace("__HOST__", &host.display().to_string()),
    )
    .unwrap();
    std::fs::set_permissions(&pi, std::fs::Permissions::from_mode(0o755)).unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let env = [(
        "PATH",
        format!(
            "{}:{}",
            tools.display(),
            std::env::var("PATH").unwrap_or_default()
        ),
    )];
    let state = dir.path().join("state");
    let hostd = run_with_env(&exe, &state, &dir.path().join("hostd.log"), &env);
    let mut client = TestClient::connect(&ticket(&exe, &state), ClientConfig::generate_key());
    client.attach_and_follow().await;
    let session_id = client.layout.as_ref().unwrap().session_id;
    let OpOutcome::TabCreated { pane_id: pane, .. } = client
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch: PaneLaunch::Agent {
                agent: client_core::proto::AgentKind::Pi,
                resume: None,
                cwd: Some(work.display().to_string()),
            },
        })
        .await
    else {
        panic!("new tab");
    };
    client.follow(pane).await;
    client.wait_text(pane, "pi-pid").await;
    let pi_pid: u32 = printed(&client.text(pane), "pi-pid")
        .unwrap()
        .parse()
        .unwrap();
    bridged(&mut client, pane, &|| hostd.log()).await;

    let connections = client.connected;
    replace(&exe, &std::fs::read(HOSTD).unwrap());
    let output = restart_command(&exe, &state);
    assert!(output.status.success(), "{output:?}\n{}", hostd.log());
    reconnected(&mut client, connections).await;
    assert!(alive(pi_pid));
    bridged(&mut client, pane, &|| hostd.log()).await;
}
