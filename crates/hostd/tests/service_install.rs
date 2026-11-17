//! `service install --no-start` points the login item at this build and leaves the running
//! daemon alone: nothing is asked of launchd. `launchctl` is replaced by a recorder, so the
//! test never reaches the real launchd domain.
#![cfg(target_os = "macos")]

use std::os::unix::fs::PermissionsExt;
use std::process::Command;

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

#[test]
fn installing_without_starting_only_writes_the_launch_agent() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let bin = dir.path().join("bin");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&bin).unwrap();
    let calls = dir.path().join("launchctl-calls");
    let launchctl = bin.join("launchctl");
    std::fs::write(
        &launchctl,
        format!("#!/bin/sh\necho \"$@\" >> '{}'\n", calls.display()),
    )
    .unwrap();
    std::fs::set_permissions(&launchctl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let state = dir.path().join("state");

    let output = Command::new(HOSTD)
        .env("HOME", &home)
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .arg("--state-dir")
        .arg(&state)
        .args(["service", "install", "--no-start"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(
        !calls.exists(),
        "launchctl ran: {:?}",
        std::fs::read_to_string(&calls)
    );
    let agents: Vec<_> = std::fs::read_dir(home.join("Library/LaunchAgents"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(agents.len(), 1, "{agents:?}");
    let plist = std::fs::read_to_string(&agents[0]).unwrap();
    assert!(
        plist.contains(&format!("<string>{HOSTD}</string>")),
        "{plist}"
    );
    assert!(plist.contains(&format!("<string>{}</string>", state.display())));
}
