//! Turns the SSH integration tests on when `UN_SSH_TEST_HOST` is set (docs/SSH.md §5);
//! without it they are compiled but `#[ignore]`d.

fn main() {
    println!("cargo::rustc-check-cfg=cfg(ssh_test_host)");
    println!("cargo::rerun-if-env-changed=UN_SSH_TEST_HOST");
    if std::env::var_os("UN_SSH_TEST_HOST").is_some_and(|v| !v.is_empty()) {
        println!("cargo::rustc-cfg=ssh_test_host");
    }
}
