//! Build automation (`cargo xtask <command>`, alias in `.cargo/config.toml`).
//!
//! - `build-xcframework [--macos-only]`: the Rust core for the app. Builds `apple-ffi` for
//!   iOS, the iOS simulator and macOS (arm64, release), generates the Swift bindings,
//!   hides every symbol but the UniFFI API (so the core's private copy of libghostty-vt and
//!   Rust's std cannot clash with the app's), strips, and assembles
//!   `apple/Packages/UnnamedCore/UnnamedCore.xcframework` plus the generated Swift source.
//! - `build-hostd-linux`: stripped, gzipped static musl daemons (aarch64 + x86_64) for the
//!   app bundle's SSH bootstrap and self upgrade, in `apple/build/hostd/`, stamped with the
//!   build id and time (`UN_BUILD_ID`, `UN_BUILD_UNIX`; see `daemon::info`) and described in
//!   `hostd-manifest.json` so the app knows what it bundles without running it.
//!
//! See docs/APPLE-FFI.md.

use std::ffi::OsStr;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use anyhow::{Context, Result, bail, ensure};
use camino::Utf8PathBuf;

/// The Swift package, module and xcframework name (brand-bearing: rename together with
/// `crates/apple-ffi/uniffi.toml`).
const CORE_NAME: &str = "UnnamedCore";
/// The clang module the generated Swift imports (`ffi_module_name` in uniffi.toml).
const FFI_MODULE: &str = "UnnamedCoreFFI";
/// `[lib] name` of crates/apple-ffi.
const LIB_NAME: &str = "unnamed_core";
/// Minimum OS versions (ARCHITECTURE D1).
const IOS_MIN: &str = "26.0";
const MACOS_MIN: &str = "26.0";

/// An Apple slice of the xcframework.
struct Slice {
    target: &'static str,
    sdk: &'static str,
    /// `ld -platform_version` name.
    platform: &'static str,
    min_os: &'static str,
}

const IOS: Slice = Slice {
    target: "aarch64-apple-ios",
    sdk: "iphoneos",
    platform: "ios",
    min_os: IOS_MIN,
};
const IOS_SIM: Slice = Slice {
    target: "aarch64-apple-ios-sim",
    sdk: "iphonesimulator",
    platform: "ios-simulator",
    min_os: IOS_MIN,
};
const MACOS: Slice = Slice {
    target: "aarch64-apple-darwin",
    sdk: "macosx",
    platform: "macos",
    min_os: MACOS_MIN,
};

const USAGE: &str = "usage: cargo xtask <command>

commands:
  build-xcframework [--macos-only]   build apple/Packages/UnnamedCore (UnnamedCore.xcframework
                                     + generated Swift); --macos-only skips the iOS slices
  build-hostd-linux                  stripped, gzipped static musl daemons (aarch64, x86_64)
                                     into apple/build/hostd/";

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("build-xcframework") => {
            let macos_only = match &args[1..] {
                [] => false,
                [flag] if flag == "--macos-only" => true,
                _ => bail!("{USAGE}"),
            };
            build_xcframework(macos_only)
        }
        Some("build-hostd-linux") if args.len() == 1 => build_hostd_linux(),
        _ => bail!("{USAGE}"),
    }
}

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask lives in the workspace root")
        .to_path_buf()
}

fn target_dir() -> PathBuf {
    std::env::var_os("CARGO_TARGET_DIR").map_or_else(|| root().join("target"), PathBuf::from)
}

fn cargo() -> Command {
    let mut cmd = Command::new(std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into()));
    cmd.current_dir(root());
    cmd
}

fn run(cmd: &mut Command) -> Result<()> {
    let status = cmd.status().with_context(|| format!("running {cmd:?}"))?;
    ensure!(status.success(), "{cmd:?} failed: {status}");
    Ok(())
}

fn output(cmd: &mut Command) -> Result<String> {
    let out = cmd.output().with_context(|| format!("running {cmd:?}"))?;
    ensure!(
        out.status.success(),
        "{cmd:?} failed: {}\n{}",
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn xcrun(sdk: &str, tool: &str) -> Command {
    let mut cmd = Command::new("xcrun");
    cmd.args(["--sdk", sdk, tool]);
    cmd
}

fn size_mb(path: &Path) -> f64 {
    fs::metadata(path).map_or(0.0, |m| m.len() as f64 / 1_048_576.0)
}

fn dir_size(path: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(path) else {
        return fs::metadata(path).map_or(0, |m| m.len());
    };
    entries
        .flatten()
        .map(|e| {
            let p = e.path();
            if p.is_dir() {
                dir_size(&p)
            } else {
                e.metadata().map_or(0, |m| m.len())
            }
        })
        .sum()
}

fn build_xcframework(macos_only: bool) -> Result<()> {
    let start = Instant::now();
    let slices: Vec<&Slice> = if macos_only {
        vec![&MACOS]
    } else {
        vec![&IOS, &IOS_SIM, &MACOS]
    };
    let root = root();
    let target = target_dir();
    let work = target.join("apple-ffi");
    let package = root.join("apple/Packages").join(CORE_NAME);

    // 1. Release static libraries. Debug info off (it would only be stripped again); the
    //    profile's thin LTO stays.
    for slice in &slices {
        eprintln!("==> cargo build {}", slice.target);
        run(cargo()
            .args(["build", "--release", "--lib", "-p", "apple-ffi", "--target"])
            .arg(slice.target)
            .env("CARGO_PROFILE_RELEASE_DEBUG", "false")
            .env("IPHONEOS_DEPLOYMENT_TARGET", IOS_MIN)
            .env("MACOSX_DEPLOYMENT_TARGET", MACOS_MIN))?;
    }
    let raw = |slice: &Slice| {
        target
            .join(slice.target)
            .join("release")
            .join(format!("lib{LIB_NAME}.a"))
    };

    // 2. Swift bindings from the macOS archive's UniFFI metadata (the same on every slice).
    eprintln!("==> uniffi-bindgen swift");
    let bindings = work.join("bindings");
    let _ = fs::remove_dir_all(&bindings);
    uniffi_bindgen::bindings::generate_swift_bindings(
        uniffi_bindgen::bindings::SwiftBindingsOptions {
            generate_swift_sources: true,
            generate_headers: true,
            generate_modulemap: false,
            source: utf8(raw(&MACOS))?,
            out_dir: utf8(bindings.clone())?,
            metadata_no_deps: true,
            ..Default::default()
        },
    )?;
    let header = format!("{FFI_MODULE}.h");
    let headers = work.join("headers");
    let _ = fs::remove_dir_all(&headers);
    // In a subdirectory named after the module: clang finds `<dir>/<Module>/module.modulemap`,
    // and SwiftPM copies every binary target's headers into one include directory, where a
    // top-level module.modulemap would collide with TerminalKit's libghostty-vt xcframework.
    let module_headers = headers.join(FFI_MODULE);
    fs::create_dir_all(&module_headers)?;
    fs::copy(bindings.join(&header), module_headers.join(&header))?;
    fs::write(
        module_headers.join("module.modulemap"),
        format!("module {FFI_MODULE} {{\n    header \"{header}\"\n    export *\n}}\n"),
    )?;

    // 3. Per slice, one archive exporting only the UniFFI API (see `hide_internals`).
    let exports = work.join("exported_symbols.txt");
    fs::write(
        &exports,
        format!("_uniffi_{LIB_NAME}_*\n_ffi_{LIB_NAME}_*\n"),
    )?;
    let api = api_symbols(&bindings.join(&header))?;
    let mut libraries = Vec::new();
    for slice in &slices {
        eprintln!("==> hide internals {}", slice.target);
        let library = hide_internals(slice, &raw(slice), &api, &exports, &work.join(slice.target))?;
        eprintln!(
            "    {}: {:.1} MB raw archive -> {:.1} MB",
            slice.target,
            size_mb(&raw(slice)),
            size_mb(&library)
        );
        libraries.push(library);
    }

    // 4. The xcframework, inside the Swift package (gitignored).
    let xcframework = package.join(format!("{CORE_NAME}.xcframework"));
    let _ = fs::remove_dir_all(&xcframework);
    let mut create = Command::new("xcodebuild");
    create.arg("-create-xcframework");
    for library in &libraries {
        create
            .arg("-library")
            .arg(library)
            .arg("-headers")
            .arg(&headers);
    }
    create.arg("-output").arg(&xcframework);
    output(&mut create)?;

    // 5. The generated Swift next to the hand-written sources.
    let sources = package.join("Sources").join(CORE_NAME);
    fs::create_dir_all(&sources)?;
    let swift = format!("{CORE_NAME}.swift");
    fs::copy(bindings.join(&swift), sources.join(&swift))?;

    eprintln!(
        "built {} ({:.1} MB) and Sources/{CORE_NAME}/{swift} in {:.0} s",
        xcframework.display(),
        dir_size(&xcframework) as f64 / 1_048_576.0,
        start.elapsed().as_secs_f64()
    );
    Ok(())
}

fn utf8(path: PathBuf) -> Result<Utf8PathBuf> {
    Utf8PathBuf::from_path_buf(path).map_err(|p| anyhow::anyhow!("non-UTF-8 path {}", p.display()))
}

/// `MH_SUBSECTIONS_VIA_SYMBOLS`: the object may be split at symbols, which is what lets the
/// app's final link dead-strip unused functions.
const MH_SUBSECTIONS_VIA_SYMBOLS: u32 = 0x2000;

/// The Mach-O header flags of a 64-bit object, if it is one.
fn macho_flags(object: &Path) -> Result<Option<u32>> {
    let data = fs::read(object)?;
    let word = |at: usize| {
        data.get(at..at + 4)
            .map(|b| u32::from_le_bytes(b.try_into().expect("4 bytes")))
    };
    Ok(match word(0) {
        Some(0xfeed_facf) => word(24),
        _ => None,
    })
}

/// Turns the raw Rust staticlib into an archive whose only global symbols are the UniFFI
/// API (plus a few assembly routines, below), so that the core's private libghostty-vt,
/// Rust std and crates cannot clash with anything else linked into the app (the app's own
/// libghostty-vt, another Rust library).
///
/// The archive's members are prelinked (`ld -r`) into one object whose other symbols are
/// made local (`-exported_symbols_list`). Members are pulled in from the API (`-u`), as the
/// app's link would, not all at once: libghostty-vt's archive carries Zig's compiler_rt,
/// which overlaps Rust's compiler_builtins, and only one copy of each may be loaded.
///
/// Hand-written assembly objects (ring's crypto, compiler_builtins' LSE atomics) are not
/// marked `MH_SUBSECTIONS_VIA_SYMBOLS`; one of them in the prelink would unmark the whole
/// output and the app's link could no longer dead-strip it (measured: +6.6 MB of text). They
/// stay separate members instead. Their symbols are versioned (`ring_core_0_17_*`) or the
/// standard outline-atomics helpers, so leaving them global is harmless.
fn hide_internals(
    slice: &Slice,
    raw: &Path,
    api: &[String],
    exports: &Path,
    dir: &Path,
) -> Result<PathBuf> {
    let _ = fs::remove_dir_all(dir);
    let members = dir.join("members");
    fs::create_dir_all(&members)?;
    let listing = output(Command::new("ar").arg("t").arg(raw))?;
    let mut names: Vec<&str> = listing.lines().filter(|n| n.ends_with(".o")).collect();
    let total = names.len();
    names.sort_unstable();
    names.dedup();
    ensure!(
        names.len() == total,
        "{}: duplicate member names",
        raw.display()
    );
    run(Command::new("ar").arg("x").arg(raw).current_dir(&members))?;

    let (mut splittable, mut assembly) = (Vec::new(), Vec::new());
    for name in names {
        let path = members.join(name);
        fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o644))?;
        match macho_flags(&path)? {
            Some(flags) if flags & MH_SUBSECTIONS_VIA_SYMBOLS != 0 => splittable.push(path),
            Some(_) => assembly.push(path),
            None => bail!("{}: {name} is not a 64-bit Mach-O object", raw.display()),
        }
    }

    let filelist = |paths: &[PathBuf], name: &str| -> Result<PathBuf> {
        let list = dir.join(name);
        let text: String = paths.iter().map(|p| format!("{}\n", p.display())).collect();
        fs::write(&list, text)?;
        Ok(list)
    };
    let inputs = dir.join("splittable.a");
    run(xcrun(slice.sdk, "libtool")
        .args(["-static", "-no_warning_for_no_symbols", "-o"])
        .arg(&inputs)
        .arg("-filelist")
        .arg(filelist(&splittable, "splittable.txt")?))?;

    let object = dir.join(format!("{LIB_NAME}.o"));
    let sdk_version =
        output(Command::new("xcrun").args(["--sdk", slice.sdk, "--show-sdk-version"]))?;
    run(xcrun(slice.sdk, "ld")
        .args([
            "-r",
            "-arch",
            "arm64",
            "-platform_version",
            slice.platform,
            slice.min_os,
        ])
        .arg(sdk_version.trim())
        .args(api.iter().flat_map(|s| ["-u", s]))
        .arg("-exported_symbols_list")
        .arg(exports)
        .arg(&inputs)
        .arg("-o")
        .arg(&object))?;
    // Debug info only: local symbols mark the function boundaries dead-stripping needs.
    run(xcrun(slice.sdk, "strip").arg("-S").arg(&object))?;
    ensure!(
        macho_flags(&object)?.is_some_and(|f| f & MH_SUBSECTIONS_VIA_SYMBOLS != 0),
        "{}: the prelinked object lost MH_SUBSECTIONS_VIA_SYMBOLS",
        slice.target
    );

    let library = dir.join(format!("lib{FFI_MODULE}.a"));
    let mut members_out = vec![object];
    members_out.extend(assembly.iter().cloned());
    run(xcrun(slice.sdk, "libtool")
        .args(["-static", "-no_warning_for_no_symbols", "-o"])
        .arg(&library)
        .arg("-filelist")
        .arg(filelist(&members_out, "final.txt")?))?;

    let mut allowed = Vec::new();
    for object in &assembly {
        allowed.extend(defined_globals(slice, object)?);
    }
    check_exports(slice, &library, &allowed)?;
    Ok(library)
}

/// Global symbols defined in `library` (`nm -g -U -j`, archive member headers skipped).
fn defined_globals(slice: &Slice, library: &Path) -> Result<Vec<String>> {
    let symbols = output(xcrun(slice.sdk, "nm").args(["-g", "-U", "-j"]).arg(library))?;
    Ok(symbols
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty() && !s.ends_with(':'))
        .map(str::to_owned)
        .collect())
}

/// `_uniffi_<lib>_…` or `_ffi_<lib>_…`.
fn is_api(symbol: &str) -> bool {
    symbol
        .strip_prefix('_')
        .and_then(|s| s.strip_prefix("uniffi_").or_else(|| s.strip_prefix("ffi_")))
        .and_then(|s| s.strip_prefix(LIB_NAME))
        .is_some_and(|s| s.starts_with('_'))
}

/// The UniFFI entry points, as linker symbols, from the generated C header. (Reading them
/// from the archive with Apple's `nm` fails on the bitcode Rust embeds in compiler_builtins,
/// which is newer than Xcode's LLVM.)
fn api_symbols(header: &Path) -> Result<Vec<String>> {
    let text = fs::read_to_string(header)?;
    let mut api: Vec<String> = text
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .map(|word| format!("_{word}"))
        .filter(|symbol| is_api(symbol))
        .collect();
    api.sort();
    api.dedup();
    ensure!(
        !api.is_empty(),
        "no UniFFI functions in {}",
        header.display()
    );
    Ok(api)
}

/// Fails if anything but the UniFFI API and `allowed` (or no API at all) is exported.
fn check_exports(slice: &Slice, library: &Path, allowed: &[String]) -> Result<()> {
    let symbols = defined_globals(slice, library)?;
    if let Some(stray) = symbols.iter().find(|s| !is_api(s) && !allowed.contains(s)) {
        bail!("{}: unexpected exported symbol {stray}", slice.target);
    }
    ensure!(
        !symbols.is_empty(),
        "{}: no UniFFI symbols exported",
        slice.target
    );
    Ok(())
}

/// The build id and time for release builds: the commit (with `-dirty` and the current time
/// when the tree has uncommitted changes), else the commit time.
fn build_stamp() -> Result<(String, u64)> {
    let vcs = |args: &[&str]| -> Result<String> {
        let out = Command::new("git")
            .args(args)
            .current_dir(root())
            .output()
            .with_context(|| format!("git {args:?}"))?;
        ensure!(out.status.success(), "git {args:?} failed");
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    };
    let commit = vcs(&["rev-parse", "--short=12", "HEAD"])?;
    let dirty = !vcs(&["status", "--porcelain", "--untracked-files=no"])?.is_empty();
    if dirty {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs();
        Ok((format!("{commit}-dirty"), now))
    } else {
        Ok((commit, vcs(&["log", "-1", "--format=%ct"])?.parse()?))
    }
}

fn build_hostd_linux() -> Result<()> {
    let out_dir = root().join("apple/build/hostd");
    fs::create_dir_all(&out_dir)?;
    let (build_id, built_unix) = build_stamp()?;
    eprintln!("==> build {build_id} ({built_unix})");
    let mut manifest = Vec::new();
    for arch in ["aarch64", "x86_64"] {
        let triple = format!("{arch}-unknown-linux-musl");
        eprintln!("==> cargo zigbuild {triple}");
        // Stripped by rustc's linker step: macOS `strip` cannot process ELF.
        run(cargo()
            .args(["zigbuild", "--release", "-p", "hostd", "--target"])
            .arg(&triple)
            .env("CARGO_PROFILE_RELEASE_STRIP", "symbols")
            .env("CARGO_PROFILE_RELEASE_DEBUG", "false")
            .env("UN_BUILD_ID", &build_id)
            .env("UN_BUILD_UNIX", built_unix.to_string()))?;
        let binary = target_dir()
            .join(&triple)
            .join("release")
            .join(brand::DAEMON_BIN);
        let data = fs::read(&binary).with_context(|| format!("reading {}", binary.display()))?;
        ensure!(
            data.starts_with(b"\x7fELF"),
            "{} is not ELF",
            binary.display()
        );
        let file = format!("{}-{arch}-linux.gz", brand::DAEMON_BIN);
        let dest = out_dir.join(&file);
        manifest.push(format!(
            "    {{\"file\": \"{file}\", \"os\": \"linux\", \"arch\": \"{arch}\", \"build\": \"{build_id}\", \"built_unix\": {built_unix}, \"protocol\": {protocol}, \"size\": {size}}}",
            protocol = proto::PROTOCOL_LEVEL,
            size = data.len(),
        ));
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
        gz.write_all(&data)?;
        fs::write(&dest, gz.finish()?)?;
        eprintln!(
            "    {} ({:.1} MB) -> {} ({:.1} MB)",
            binary.display(),
            data.len() as f64 / 1_048_576.0,
            dest.file_name().and_then(OsStr::to_str).unwrap_or_default(),
            size_mb(&dest)
        );
    }
    // What the app bundles, so it can tell an older daemon without running the build.
    let manifest = format!("{{\n  \"builds\": [\n{}\n  ]\n}}\n", manifest.join(",\n"));
    fs::write(out_dir.join("hostd-manifest.json"), manifest)?;
    eprintln!("bundle {} as app resources", out_dir.display());
    Ok(())
}
