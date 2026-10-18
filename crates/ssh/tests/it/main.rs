//! Integration tests against a real OpenSSH server (docs/SSH.md §5).
//!
//! Prepare a VM with `scripts/ssh-test-vm.sh`, `source target/ssh-test/env`, then
//! `cargo test -p ssh --test it`. Without `UN_SSH_TEST_HOST` these tests are ignored.

mod auth;
mod bootstrap;
mod channels;
mod common;
mod reliability;
