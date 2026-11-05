fn main() {
    println!("cargo:rerun-if-env-changed=GUDO_FLAVOR");
    println!("cargo:rustc-check-cfg=cfg(gudo_dev)");
    match std::env::var("GUDO_FLAVOR").as_deref() {
        Ok("dev") => println!("cargo:rustc-cfg=gudo_dev"),
        Ok("release" | "") | Err(_) => {}
        Ok(flavor) => panic!("unsupported GUDO_FLAVOR: {flavor}"),
    }
}
