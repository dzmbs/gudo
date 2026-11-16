fn main() {
    println!("cargo:rerun-if-env-changed=GUDO_FLAVOR");
    println!("cargo:rustc-check-cfg=cfg(gudo_dev)");
    match std::env::var("GUDO_FLAVOR").as_deref() {
        Ok("dev") => println!("cargo:rustc-cfg=gudo_dev"),
        Ok("release" | "") | Err(_) => {}
        Ok(flavor) => panic!("unsupported GUDO_FLAVOR: {flavor}"),
    }
    println!("cargo:rustc-env=GUDO_VERSION={}", product_version());
}

/// The version the apps ship as (`MARKETING_VERSION` in `apple/project.yml`, which releases
/// set), so the daemon and the CLI report the same one.
fn product_version() -> String {
    println!("cargo:rerun-if-env-changed=GUDO_VERSION");
    if let Ok(version) = std::env::var("GUDO_VERSION")
        && !version.is_empty()
    {
        return version;
    }
    let project = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../apple/project.yml");
    println!("cargo:rerun-if-changed={}", project.display());
    std::fs::read_to_string(&project)
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let value = line.trim().strip_prefix("MARKETING_VERSION:")?;
                Some(value.trim().trim_matches('"').to_owned())
            })
        })
        .filter(|version| !version.is_empty())
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_owned())
}
