//! Builds the pinned libghostty-vt with Zig and links it statically.
//!
//! Adapted from herdr's `crates/ghostty-vt/build.rs` (Apache-2.0). Every input is listed in
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
    let ghostty = manifest_dir.join("../../vendor/ghostty");

    println!("cargo:rerun-if-changed=build.rs");
    for input in ["build.zig", "build.zig.zon", "include", "pkg", "src"] {
        println!("cargo:rerun-if-changed={}", ghostty.join(input).display());
    }
    for var in [
        "ZIG",
        "LIBGHOSTTY_VT_OPTIMIZE",
        "LIBGHOSTTY_VT_ALLOW_PARTIAL",
        "SDKROOT",
    ] {
        println!("cargo:rerun-if-env-changed={var}");
    }

    let target = env::var("TARGET").expect("TARGET");
    let optimize = env::var("LIBGHOSTTY_VT_OPTIMIZE").unwrap_or_else(|_| "ReleaseFast".into());
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let prefix = out_dir.join("zig-out");
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".into());

    let status = Command::new(&zig)
        .current_dir(&ghostty)
        .arg("build")
        .arg("--prefix")
        .arg(&prefix)
        .arg("-Demit-lib-vt")
        .arg("-Demit-xcframework=false")
        .arg(format!("-Doptimize={optimize}"))
        .arg(format!("-Dtarget={}", zig_target(&target)))
        .status()
        .unwrap_or_else(|err| {
            panic!("failed to run {zig:?} (Zig 0.16.x required; set ZIG to override): {err}")
        });
    let static_lib = prefix.join("lib/libghostty-vt.a");
    // TEMPORARY escape hatch for Command-Line-Tools-only Macs, where Ghostty's unused dylib
    // link step fails against a newer SDK while the static archive installs fine.
    let allow_partial = env::var_os("LIBGHOSTTY_VT_ALLOW_PARTIAL").is_some();
    if !status.success() {
        assert!(
            allow_partial && static_lib.exists(),
            "zig build of libghostty-vt failed: {status}"
        );
        println!("cargo:warning=zig build failed ({status}); using the static archive anyway");
    }

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
    println!("cargo:include={}", ghostty.join("include").display());
}
