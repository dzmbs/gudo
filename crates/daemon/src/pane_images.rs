//! Pictures pasted or dropped on an agent pane (`WorkspaceRequest::PasteImage`).
//!
//! The picture is written without its metadata to `<state>/pane-images/<pane>/<sha256>.<ext>`
//! (directories 0700, files 0600), bounded by [`PaneImageLimits`] with the oldest evicted, and
//! deleted when the pane closes. Its path is then pasted into the agent's input, never followed
//! by Enter: escaped as a shell word for Claude Code and Codex, which attach it as an image, and
//! as it is for pi, whose model reads the file.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use proto::{AgentKind, InputPayload, PaneId, PaneLaunch, PastedImage, PngSource, WsError};

use crate::config::PaneImageLimits;
use crate::core::{Core, PaneEntry, lock};

const STORE: &str = "pane-images";

pub(crate) async fn paste(
    core: &Arc<Core>,
    actor: proto::Actor,
    pane_id: PaneId,
    image: PngSource,
) -> Result<PastedImage, WsError> {
    let entry = core
        .pane(pane_id)
        .ok_or_else(|| WsError::NotFound(format!("pane {pane_id}")))?;
    let agent =
        agent_of(&entry).ok_or_else(|| WsError::Unavailable("This pane runs no agent.".into()))?;
    // A path typed into an open question could pick one of its answers.
    if lock(&entry.agent)
        .as_ref()
        .is_some_and(|runtime| runtime.is_blocked())
    {
        return Err(WsError::Unavailable(
            "The agent is waiting for an answer. Answer it, then paste again.".into(),
        ));
    }
    let path = {
        let core = Arc::clone(core);
        tokio::task::spawn_blocking(move || store(&core, pane_id, image))
            .await
            .map_err(|error| WsError::Failed(error.to_string()))??
    };
    let text = pasted_text(agent, &path)
        .ok_or_else(|| WsError::Failed("the image path has control characters".into()))?;
    let bytes = entry.pane.encode_input(InputPayload::Paste(text));
    entry
        .pane
        .write(bytes)
        .await
        .map_err(|_| WsError::NotFound(format!("pane {pane_id} exited")))?;
    core.mp.audit.append(
        proto::AuditKind::Prompt,
        crate::mp::AuditEntry {
            actor: Some(actor),
            pane_id: Some(pane_id),
            detail: format!("pasted an image into the agent as {path}"),
            ..crate::mp::AuditEntry::default()
        },
    );
    tokio::time::sleep(crate::art::send::ATTACH_SETTLE).await;
    Ok(PastedImage { path, agent })
}

/// The agent running in the pane: attached, launched, or pi known from its session.
fn agent_of(entry: &PaneEntry) -> Option<AgentKind> {
    if let Some(kind) = lock(&entry.agent).as_ref().map(|runtime| runtime.kind()) {
        return Some(kind);
    }
    if let Some(kind) = crate::agent_driver::chat_agent(entry) {
        return Some(kind);
    }
    match &lock(&entry.record).launch {
        PaneLaunch::Agent { agent, .. } | PaneLaunch::AccountAgent { agent, .. } => Some(*agent),
        _ => None,
    }
}

fn pasted_text(agent: AgentKind, path: &str) -> Option<String> {
    match agent {
        AgentKind::Claude | AgentKind::Codex => crate::art::send::paste_text(path),
        AgentKind::Pi => (!path.chars().any(char::is_control)).then(|| path.to_owned()),
    }
}

/// Writes the picture into the pane's store and evicts past the limits. Returns its absolute
/// path.
fn store(core: &Core, pane_id: PaneId, image: PngSource) -> Result<String, WsError> {
    let limits = core.cfg.pane_images;
    let bytes = match image {
        PngSource::Inline(bytes) if bytes.len() <= crate::art::INLINE_MAX => bytes,
        PngSource::Inline(_) => {
            return Err(WsError::Invalid(
                "inline images are at most 1 MiB; upload a blob".into(),
            ));
        }
        PngSource::Blob(hash) => {
            core.art
                .read_blob(&hash)
                .map_err(|error| WsError::NotFound(error.to_string()))?
                .1
        }
        PngSource::Artifact => {
            return Err(WsError::Invalid("paste an image, not a drawing".into()));
        }
    };
    if bytes.len() as u64 > limits.image_max {
        return Err(WsError::Invalid(format!(
            "the image is {} bytes; the limit is {}",
            bytes.len(),
            limits.image_max
        )));
    }
    let not_an_image = || WsError::Invalid("not a PNG or JPEG image".into());
    let (media, _, _) = drawing::sniff(&bytes).ok_or_else(not_an_image)?;
    let bytes = drawing::strip_metadata(&bytes).ok_or_else(not_an_image)?;

    let root = core.cfg.state_dir.join(STORE);
    let folder = root.join(pane_id.0.to_string());
    crate::fsutil::create_private_dir(&root).map_err(failed)?;
    crate::fsutil::create_private_dir(&folder).map_err(failed)?;
    let digest = grants::sha256(&[&bytes]);
    let path = folder.join(format!(
        "{}.{}",
        crate::fsutil::hex(&digest[..16]),
        media.extension()
    ));
    // The agent may read the file as soon as its path is pasted; write it whole first.
    crate::fsutil::write_atomic(&path, &bytes).map_err(failed)?;
    evict(&root, &limits, &path, |pane| core.pane(pane).is_some()).map_err(failed)?;
    let absolute = std::fs::canonicalize(&path).unwrap_or(path);
    Ok(absolute.to_string_lossy().into_owned())
}

/// Deletes the pane's pictures.
pub(crate) fn forget_pane(state_dir: &Path, pane_id: PaneId) {
    let folder = state_dir.join(STORE).join(pane_id.0.to_string());
    if let Err(error) = std::fs::remove_dir_all(&folder)
        && error.kind() != io::ErrorKind::NotFound
    {
        tracing::debug!("removing {}: {error}", folder.display());
    }
}

struct Stored {
    modified: SystemTime,
    size: u64,
    path: PathBuf,
}

/// Drops the folders of panes that are gone, then the oldest pictures past each pane's
/// limits and past the store's total. `keep` (the picture just written) always stays.
fn evict(
    root: &Path,
    limits: &PaneImageLimits,
    keep: &Path,
    is_live: impl Fn(PaneId) -> bool,
) -> io::Result<()> {
    let mut kept = Vec::new();
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        let pane = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<u64>().ok())
            .map(PaneId);
        let is_folder = entry.file_type()?.is_dir();
        if !is_folder || !pane.is_some_and(&is_live) {
            remove(&entry.path(), is_folder);
            continue;
        }
        let mut images = stored_in(&entry.path())?;
        let mut count = images.len();
        let mut bytes: u64 = images.iter().map(|image| image.size).sum();
        images.retain(|image| {
            let over = count > limits.per_pane || bytes > limits.pane_total_max;
            if !over || image.path == keep {
                return true;
            }
            remove(&image.path, false);
            count -= 1;
            bytes -= image.size;
            false
        });
        kept.extend(images);
    }
    kept.sort_by(|left, right| (left.modified, &left.path).cmp(&(right.modified, &right.path)));
    let mut total: u64 = kept.iter().map(|image| image.size).sum();
    for image in kept {
        if total <= limits.total_max {
            break;
        }
        if image.path != keep {
            remove(&image.path, false);
            total -= image.size;
        }
    }
    Ok(())
}

/// The pictures in a pane's folder, oldest first. Files being written (`.name.tmp…`) are
/// left alone.
fn stored_in(folder: &Path) -> io::Result<Vec<Stored>> {
    let mut images = Vec::new();
    for entry in std::fs::read_dir(folder)? {
        let entry = entry?;
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let metadata = entry.metadata()?;
        if !metadata.is_file() {
            continue;
        }
        images.push(Stored {
            modified: metadata.modified()?,
            size: metadata.len(),
            path: entry.path(),
        });
    }
    images.sort_by(|left, right| (left.modified, &left.path).cmp(&(right.modified, &right.path)));
    Ok(images)
}

fn remove(path: &Path, is_folder: bool) {
    let removed = if is_folder {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    };
    if let Err(error) = removed
        && error.kind() != io::ErrorKind::NotFound
    {
        tracing::debug!("evicting {}: {error}", path.display());
    }
}

fn failed(error: io::Error) -> WsError {
    WsError::Failed(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pi_gets_the_path_as_it_is_and_the_others_escaped() {
        let path = "/s/Application Support/pane-images/3/ab.png";
        assert_eq!(pasted_text(AgentKind::Pi, path).unwrap(), path);
        for agent in [AgentKind::Claude, AgentKind::Codex] {
            assert_eq!(
                pasted_text(agent, path).unwrap(),
                r"/s/Application\ Support/pane-images/3/ab.png"
            );
        }
        assert_eq!(pasted_text(AgentKind::Pi, "/s/a\nb.png"), None);
    }
}
