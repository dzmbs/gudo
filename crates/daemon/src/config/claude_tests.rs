#[test]
fn dedicated_claude_launches_default_to_version_gated_display_streaming() {
    assert!(super::Config::new(std::path::PathBuf::from("/fixture/state")).claude_chat_streaming);
}
