//! Builds the pinned libghostty-vt with Zig and links it statically.
//!
//! Adapted from herdr's `crates/ghostty-vt/build.rs` (Apache-2.0). The source compiled is
//! `vendor/ghostty` plus `patches/ghostty/*.patch`, prepared in `OUT_DIR` by
//! `scripts/ghostty-source.sh` (shared with the Apple build). Every input is listed in
//! `rerun-if-changed`, so Rust-only edits never re-run `zig build`.

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn zig_target(target: &str) -> &'static str {
    match target {
        "aarch64-apple-darwin" => "aarch64-macos",
        "x86_64-apple-darwin" => "x86_64-macos",
        "aarch64-apple-ios" => "aarch64-ios",
        "aarch64-apple-ios-sim" => "aarch64-ios-simulator",
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        other => panic!("unsupported target for libghostty-vt: {other}"),
    }
}

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let root = manifest_dir.join("../..");
    let vendor = root.join("vendor/ghostty");
    let script = root.join("scripts/ghostty-source.sh");

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}", script.display());
    println!(
        "cargo:rerun-if-changed={}",
        root.join("patches/ghostty").display()
    );
    for input in ["build.zig", "build.zig.zon", "include", "pkg", "src"] {
        println!("cargo:rerun-if-changed={}", vendor.join(input).display());
    }
    for var in ["ZIG", "LIBGHOSTTY_VT_OPTIMIZE", "SDKROOT"] {
        println!("cargo:rerun-if-env-changed={var}");
    }

    let target = env::var("TARGET").expect("TARGET");
    let optimize = env::var("LIBGHOSTTY_VT_OPTIMIZE").unwrap_or_else(|_| "fast".into());
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let source = out_dir.join("ghostty");
    let prefix = out_dir.join("zig-out");
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".into());

    let prepared = Command::new("bash")
        .arg(&script)
        .arg(&source)
        .output()
        .unwrap_or_else(|err| panic!("failed to run {}: {err}", script.display()));
    assert!(
        prepared.status.success(),
        "preparing the patched Ghostty source failed:\n{}",
        String::from_utf8_lossy(&prepared.stderr)
    );
    let version = String::from_utf8_lossy(&prepared.stdout).trim().to_owned();

    let status = Command::new(&zig)
        .current_dir(&source)
        .arg("build")
        .arg("--prefix")
        .arg(&prefix)
        // One local cache for every prepared tree (Zig's cache is content-addressed).
        .arg("--cache-dir")
        .arg(vendor.join(".zig-cache"))
        .arg("-Demit-lib-vt")
        .arg("-Demit-xcframework=false")
        .arg(format!("-Dversion-string={version}"))
        .arg(format!("-Doptimize={optimize}"))
        .arg(format!("-Dtarget={}", zig_target(&target)))
        .status()
        .unwrap_or_else(|err| {
            panic!("failed to run {zig:?} (Zig 0.17.x required; set ZIG to override): {err}")
        });
    assert!(
        status.success(),
        "zig build of libghostty-vt failed: {status}"
    );

    let mut lib_dir = prefix.join("lib");
    if target.contains("-apple-") {
        // Apple's linker prefers a sibling dylib for `-l`, so link from a directory that
        // holds only the static archive.
        let static_dir = out_dir.join("static");
        fs::create_dir_all(&static_dir).expect("create static lib dir");
        fs::copy(
            lib_dir.join("libghostty-vt.a"),
            static_dir.join("libghostty-vt.a"),
        )
        .expect("copy libghostty-vt.a");
        lib_dir = static_dir;
    }
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=ghostty-vt");
    println!("cargo:include={}", source.join("include").display());
}
