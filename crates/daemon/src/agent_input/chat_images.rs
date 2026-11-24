//! Images sent from Chat, kept as files the agent reads from the host.

use std::path::PathBuf;

use proto::{PaneId, PngSource, WsError};

use crate::core::Core;

const IMAGES_LIMIT: usize = 4;
const INLINE_LIMIT: usize = 1024 * 1024;

/// Writes each image into `<state>/chat-images` under its content hash, and returns the paths.
pub(crate) fn store(
    core: &Core,
    pane: PaneId,
    images: &[PngSource],
) -> Result<Vec<PathBuf>, WsError> {
    if images.is_empty() || images.len() > IMAGES_LIMIT {
        return Err(WsError::Invalid(format!(
            "Chat sends one to {IMAGES_LIMIT} images at a time"
        )));
    }
    core.pane(pane)
        .ok_or_else(|| WsError::NotFound("agent pane".into()))?;
    let folder = core.cfg.state_dir.join("chat-images");
    crate::fsutil::create_private_dir(&folder).map_err(failed)?;
    images
        .iter()
        .map(|image| {
            let bytes = match image {
                PngSource::Inline(bytes) if bytes.len() <= INLINE_LIMIT => bytes.clone(),
                PngSource::Inline(_) => {
                    return Err(WsError::Invalid(
                        "inline images are at most 1 MiB; upload a blob".into(),
                    ));
                }
                PngSource::Blob(hash) => {
                    core.art
                        .read_blob(hash)
                        .map_err(|error| WsError::NotFound(error.to_string()))?
                        .1
                }
                PngSource::Artifact => {
                    return Err(WsError::Invalid(
                        "Chat sends an image, not a drawing".into(),
                    ));
                }
            };
            let (media, _, _) = drawing::sniff(&bytes)
                .ok_or_else(|| WsError::Invalid("not a PNG or JPEG image".into()))?;
            let digest = grants::sha256(&[&bytes]);
            let path = folder.join(format!(
                "{}.{}",
                crate::fsutil::hex(&digest[..16]),
                media.extension()
            ));
            if !path.is_file() {
                crate::fsutil::write_atomic(&path, &bytes).map_err(failed)?;
            }
            Ok(path)
        })
        .collect()
}

fn failed(error: std::io::Error) -> WsError {
    WsError::Failed(error.to_string())
}
