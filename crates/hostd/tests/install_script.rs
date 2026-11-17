//! `site/install.sh` over an install whose helper is running: the new build arrives as a new
//! file renamed into place, the running one keeps the file it executes, and nothing is left
//! behind.

use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::process::Command;

const SCRIPT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../site/install.sh");
const RELEASE_FILE: &str = "gudo-hostd-x86_64-unknown-linux-musl";

fn tool(bin: &Path, name: &str, body: &str) {
    let path = bin.join(name);
    std::fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn sha256(bytes: &[u8]) -> String {
    let output = Command::new("shasum")
        .args(["-a", "256"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            use std::io::Write;
            child.stdin.take().unwrap().write_all(bytes)?;
            child.wait_with_output()
        })
        .unwrap();
    String::from_utf8(output.stdout).unwrap()[..64].to_owned()
}

#[test]
fn the_install_script_renames_the_new_helper_over_a_running_one() {
    let dir = tempfile::tempdir().unwrap();
    let release = dir.path().join("release");
    let bin = dir.path().join("bin");
    let install = dir.path().join("install");
    for directory in [&release, &bin, &install] {
        std::fs::create_dir_all(directory).unwrap();
    }
    let new_build = b"#!/bin/sh\necho new build\n";
    std::fs::write(release.join(RELEASE_FILE), new_build).unwrap();
    std::fs::write(release.join("VERSION"), "9.9.9\n").unwrap();
    std::fs::write(
        release.join("SHA256SUMS"),
        format!("{}  {RELEASE_FILE}\n", sha256(new_build)),
    )
    .unwrap();
    tool(
        &bin,
        "uname",
        r#"case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac"#,
    );
    tool(
        &bin,
        "curl",
        &format!(
            r#"while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; https://*) url="$1" ;; esac; shift; done
cp "{}/$(basename "$url")" "$out""#,
            release.display()
        ),
    );
    let helper = install.join("gudo-hostd");
    std::fs::write(&helper, b"#!/bin/sh\nexec sleep 30\n").unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut running = Command::new(&helper).spawn().unwrap();
    let running_inode = std::fs::metadata(&helper).unwrap().ino();

    let output = Command::new("/bin/sh")
        .arg(SCRIPT)
        .env(
            "PATH",
            format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", bin.display()),
        )
        .env("GUDO_INSTALL_DIR", &install)
        .output()
        .unwrap();
    let _ = running.kill();
    let _ = running.wait();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(std::fs::read(&helper).unwrap(), new_build);
    let installed = std::fs::metadata(&helper).unwrap();
    assert_ne!(installed.ino(), running_inode);
    assert_eq!(installed.mode() & 0o777, 0o755);
    let mut names: Vec<_> = std::fs::read_dir(&install)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, ["gudo", "gudo-hostd"]);
}
