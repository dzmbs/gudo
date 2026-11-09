#[test]
fn dedicated_codex_launches_default_to_the_version_gated_pane_driver() {
    assert!(super::Config::new(std::path::PathBuf::from("/fixture/state")).codex_chat);
}
