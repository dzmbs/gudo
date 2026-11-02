//! "Send to agent" and the blob streams.
//!
//! Send: the PNG is written to `<state>/artifacts/<session>/send/<artifact>@<version>.png`
//! and its absolute path is pasted into the agent pane — bracketed when the program enabled
//! bracketed paste (Claude Code and Codex do), never followed by Enter, so the agent turns it
//! into an `[Image #N]` attachment and the user keeps typing.

use std::sync::Arc;

use iroh::endpoint::{RecvStream, SendStream};
use proto::{
    Actor, ArtifactCreate, ArtifactError, ArtifactEvent, ArtifactId, ArtifactKind, ArtifactSend,
    BlobHeader, BlobReply, CoordSpace, InputPayload, MediaType, PngSource, Sent,
};

use super::{INLINE_MAX, Result, failed};
use crate::core::Core;

/// The text pasted for `path`: the path itself when it holds only `[A-Za-z0-9_./@:-]` (or
/// non-ASCII), else every other character backslash-escaped. Claude Code and Codex both attach
/// `…/Application\ Support/…` paths; Codex refuses the raw spaced form (it shlex-splits the
/// paste), Claude Code refuses `'\''` splices and `file://` URLs. `None` for paths with
/// control characters.
pub(crate) fn paste_text(path: &str) -> Option<String> {
    let mut escaped = String::with_capacity(path.len() + 8);
    for character in path.chars() {
        if character.is_control() {
            return None;
        }
        let plain = character.is_ascii_alphanumeric()
            || "_./@:-".contains(character)
            || !character.is_ascii();
        if !plain {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    Some(escaped)
}

/// Sends a PNG to an agent pane. Returns what was sent and the events to broadcast (a bare
/// image becomes an image artifact).
pub(crate) async fn send(
    core: &Arc<Core>,
    actor: Actor,
    request: ArtifactSend,
) -> Result<(Sent, Vec<ArtifactEvent>)> {
    let entry = core
        .pane(request.pane_id)
        .ok_or_else(|| ArtifactError::NotFound(format!("pane {}", request.pane_id)))?;
    if !core.is_agent_pane(request.pane_id) {
        return Err(ArtifactError::NotAgentPane);
    }
    let session = core
        .session_of_pane(request.pane_id)
        .ok_or_else(|| ArtifactError::NotFound(format!("pane {}", request.pane_id)))?;
    let art = &core.art;
    let mut events = Vec::new();

    let (png, artifact_id, version) = match (&request.png, request.artifact_id) {
        (PngSource::Inline(bytes), _) if bytes.len() > INLINE_MAX => {
            return Err(ArtifactError::TooLarge(
                "inline PNGs are at most 1 MiB; upload a blob".into(),
            ));
        }
        (PngSource::Inline(bytes), id) => (bytes.clone(), id, request.version),
        (PngSource::Blob(hash), id) => (art.read_blob(hash)?.1, id, request.version),
        (PngSource::Artifact, None) => {
            return Err(ArtifactError::Invalid("no artifact to render".into()));
        }
        (PngSource::Artifact, Some(id)) => {
            let exported = super::export(art, id, request.version, proto::ExportFormat::Png)?;
            let bytes = match exported.blob {
                Some(hash) => art.read_blob(&hash)?.1,
                None => exported.data,
            };
            (bytes, Some(id), Some(exported.version))
        }
    };
    let (media, _, _) = drawing::sniff(&png)
        .ok_or_else(|| ArtifactError::Invalid("not a PNG or JPEG image".into()))?;

    let (artifact_id, version) = match artifact_id {
        Some(id) => {
            let info = art
                .info(id)
                .ok_or_else(|| ArtifactError::NotFound(format!("artifact {id}")))?;
            if info.session_id != session {
                return Err(ArtifactError::Invalid(
                    "the artifact belongs to another session".into(),
                ));
            }
            let version = version.unwrap_or(info.version);
            if version > info.version {
                return Err(ArtifactError::NotFound(format!("version {version}")));
            }
            (id, version)
        }
        None => {
            // A dropped or pasted image: keep it as an image artifact of the session.
            let image = art.put_blob(&png)?;
            let (info, _) = art.create(
                actor,
                &ArtifactCreate {
                    session_id: session,
                    kind: ArtifactKind::Image,
                    title: "sent image".into(),
                    space: CoordSpace::Canvas,
                    anchor: None,
                    image: Some(image.hash),
                    ops: Vec::new(),
                },
                None,
            )?;
            events.push(ArtifactEvent::Created(info.clone()));
            (info.artifact_id, 0)
        }
    };

    let path = write_send_file(core, session, artifact_id, version, media, &png)?;
    let text = paste_text(&path)
        .ok_or_else(|| ArtifactError::Failed("the send path has control characters".into()))?;
    let bytes = entry.pane.encode_input(InputPayload::Paste(text.clone()));
    let bracketed = bytes.starts_with(b"\x1b[200~");
    entry
        .pane
        .write(bytes)
        .await
        .map_err(|_| ArtifactError::NotFound(format!("pane {} exited", request.pane_id)))?;
    // Claude Code attaches the image asynchronously: a keystroke right behind the paste can
    // land in front of the chip. Answer once it has had time to settle.
    tokio::time::sleep(std::time::Duration::from_millis(120)).await;
    Ok((
        Sent {
            artifact_id,
            version,
            path,
            pasted: text,
            bracketed,
        },
        events,
    ))
}

fn write_send_file(
    core: &Core,
    session: proto::SessionId,
    id: ArtifactId,
    version: u64,
    media: MediaType,
    bytes: &[u8],
) -> Result<String> {
    let dir = core
        .cfg
        .state_dir
        .join("artifacts")
        .join(session.0.to_string())
        .join("send");
    std::fs::create_dir_all(&dir).map_err(failed)?;
    let path = dir.join(format!("{id}@{version}.{}", media.extension()));
    // Agents may read the file at any time after the paste; write it whole first.
    crate::fsutil::write_atomic(&path, bytes).map_err(failed)?;
    let absolute = std::fs::canonicalize(&path).unwrap_or(path);
    Ok(absolute.to_string_lossy().into_owned())
}

/// Serves one blob stream (the caller checked the roles).
pub(crate) async fn serve_blob(
    core: Arc<Core>,
    header: BlobHeader,
    mut send: SendStream,
    mut recv: RecvStream,
) {
    let result = match header {
        BlobHeader::Put { size, media, .. } => put(&core, size, media, &mut send, &mut recv).await,
        BlobHeader::Get { hash } => match core.art.read_blob(&hash) {
            Ok((image, bytes)) => {
                if crate::net::send(&mut send, &BlobReply::Found(image))
                    .await
                    .is_ok()
                {
                    // QUIC flow control paces this write: a slow reader holds it back.
                    let _ = send.write_all(&bytes).await;
                }
                Ok(())
            }
            Err(error) => Err(error),
        },
    };
    if let Err(error) = result {
        let _ = crate::net::send(&mut send, &BlobReply::Failed(error)).await;
    }
    let _ = send.finish();
    let _ = send.stopped().await;
}

async fn put(
    core: &Core,
    size: u64,
    media: MediaType,
    send: &mut SendStream,
    recv: &mut RecvStream,
) -> Result<()> {
    if size > core.art.limits.blob_max {
        return Err(ArtifactError::TooLarge(format!(
            "image of {size} bytes; the limit is {}",
            core.art.limits.blob_max
        )));
    }
    crate::net::send(send, &BlobReply::Ready)
        .await
        .map_err(failed)?;
    let mut bytes = vec![0; size as usize];
    recv.read_exact(&mut bytes)
        .await
        .map_err(|error| failed(format!("upload ended early: {error}")))?;
    let image = core.art.put_blob(&bytes)?;
    if image.media != media {
        tracing::debug!("blob declared {media:?}, is {:?}", image.media);
    }
    crate::net::send(send, &BlobReply::Stored(image))
        .await
        .map_err(failed)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escaping_matches_the_agents_rules() {
        let escaped = |path: &str| paste_text(path).unwrap();
        assert_eq!(escaped("/tmp/a/1@2.png"), "/tmp/a/1@2.png");
        assert_eq!(
            escaped("/tmp/Library/Application Support/gudo/x.png"),
            r"/tmp/Library/Application\ Support/gudo/x.png"
        );
        assert_eq!(escaped("/t/it's (1).png"), r"/t/it\'s\ \(1\).png");
        assert_eq!(escaped("/t/ü+.png"), "/t/ü\\+.png");
        assert_eq!(paste_text("/t/a\nb.png"), None);
    }
}
