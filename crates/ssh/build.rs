//! Turns the sshd integration tests on when `GUDO_SSH_TEST_HOST` is set (docs/SSH.md §5);
//! without it they are compiled but `#[ignore]`d.

fn main() {
    println!("cargo::rustc-check-cfg=cfg(ssh_test_host)");
    println!("cargo::rerun-if-env-changed=GUDO_SSH_TEST_HOST");
    if std::env::var_os("GUDO_SSH_TEST_HOST").is_some_and(|value| !value.is_empty()) {
        println!("cargo::rustc-cfg=ssh_test_host");
    }
}
