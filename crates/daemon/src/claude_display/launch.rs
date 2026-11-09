use std::num::NonZeroU16;

use agents::{LaunchContext, LaunchMode, LaunchSpec};

pub(crate) fn prepare(
    context: &LaunchContext,
    mode: &LaunchMode,
    port: NonZeroU16,
    token: &str,
) -> Option<LaunchSpec> {
    let mut launch = agents::ClaudeCode::new().display_launch(context, mode, port, token);
    let file = launch.files.pop()?;
    let result = (|| {
        if let Some(parent) = file.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        crate::fsutil::write_atomic(&file.path, file.contents.as_bytes())
    })();
    match result {
        Ok(()) => Some(launch),
        Err(error) => {
            tracing::warn!(%error, "Claude display settings unavailable; using Terminal");
            None
        }
    }
}
