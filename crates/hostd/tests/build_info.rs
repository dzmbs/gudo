//! `build-info --json` names the SHA-256 of the file that ran, so the Mac app can check that a
//! copy of its helper runs and is the build it copied.

use std::process::Command;

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

#[test]
fn build_info_reports_the_hash_of_the_file_that_ran() {
    let output = Command::new(HOSTD)
        .args(["build-info", "--json"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let info: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    let bytes = std::fs::read(HOSTD).unwrap();
    let expected: String = ring::digest::digest(&ring::digest::SHA256, &bytes)
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    assert_eq!(info["exe_sha256"], expected.as_str());
}
