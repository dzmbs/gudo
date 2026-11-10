use super::*;

fn ended_pid() -> u32 {
    let mut child = std::process::Command::new("/usr/bin/true").spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    pid
}

#[test]
fn only_directories_of_ended_daemons_from_before_this_start_are_removed() {
    let parent = tempfile::tempdir().unwrap();
    let prefix = "brand-codex-";
    let ended = parent.path().join(format!("{prefix}{}-left", ended_pid()));
    let current = parent
        .path()
        .join(format!("{prefix}{}-live", std::process::id()));
    let legacy = parent.path().join(format!("{prefix}0123456789abcdef"));
    let unrelated = parent.path().join("other-1-directory");
    for directory in [&ended, &current, &legacy, &unrelated] {
        std::fs::create_dir(directory).unwrap();
    }
    sweep(parent.path(), prefix, SystemTime::UNIX_EPOCH);
    assert!(ended.exists(), "a directory newer than the start stays");
    sweep(
        parent.path(),
        prefix,
        SystemTime::now() + Duration::from_secs(60),
    );
    assert!(!ended.exists());
    assert!(current.exists());
    assert!(legacy.exists());
    assert!(unrelated.exists());
}

#[tokio::test]
async fn teardown_reaches_the_whole_process_group() {
    let marker = tempfile::tempdir().unwrap();
    let pid_file = marker.path().join("child");
    let mut command = tokio::process::Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(format!(
            "trap '' TERM; sleep 60 & echo $! > '{}'; wait",
            pid_file.display()
        ))
        .kill_on_drop(true);
    isolate(&mut command);
    let process = command.spawn().unwrap();
    let child = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Ok(text) = std::fs::read_to_string(&pid_file)
                && let Ok(pid) = text.trim().parse::<u32>()
            {
                return pid;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    terminate(process).await;
    tokio::time::timeout(Duration::from_secs(5), async {
        while is_running(child) && !is_zombie(child) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the app-server's child outlived teardown");
}

fn is_zombie(pid: u32) -> bool {
    std::process::Command::new("/bin/ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .is_ok_and(|output| {
            String::from_utf8_lossy(&output.stdout)
                .trim()
                .starts_with('Z')
        })
}
