//! Inline placements: artifacts shown in a terminal pane, glued to an output row, so a
//! finished drawing becomes part of the pane's output.
//!
//! Placements travel as `ArtifactEvent::Placed` and are sent again on `Attach`; their rows
//! are tracked pins like ink anchors. Two ways in: a person places an artifact (the overlay's
//! "done", or "place" from a list), or a file is pasted or dropped onto the pane (`Import`).
//! Images programs print with the kitty graphics protocol are not placements: the VTs keep
//! them and snapshots carry them (docs/DAEMON.md §7.10).

use std::sync::Arc;

use proto::{
    Actor, AnchorState, ArtifactError, ArtifactId, ArtifactKind, DetachReason, ExportFormat,
    ImageRef, ImportRequest, PaneId, PaneSize, PlaceRequest, Placement, PlacementSource,
    UnixMillis,
};

use super::{Art, Result, row_anchor};
use crate::anchor::AnchorPos;
use crate::core::{Core, lock};
use crate::identity::now_millis;

/// Anchor keys of placements (artifact anchors use the artifact id).
pub(crate) const PLACEMENT_KEY: u64 = 1 << 63;
/// Default cell size in image pixels for sizing a placement (2× renders of 9×18 pt cells).
const CELL_PX: (f32, f32) = (18.0, 36.0);

impl Art {
    fn alloc_placement(&self) -> u64 {
        let mut state = lock(&self.state);
        state.next_placement = state.next_placement.max(1);
        let id = state.next_placement;
        state.next_placement += 1;
        id
    }

    fn insert_placement(&self, placement: Placement, key: u64) {
        let mut state = lock(&self.state);
        state.anchor_keys.insert(placement.placement_id, key);
        state.placements.insert(placement.placement_id, placement);
        self.save_index(&state);
    }

    /// Removes a placement; returns it with its anchor key.
    pub fn remove_placement(&self, id: u64) -> Option<(Placement, u64)> {
        let mut state = lock(&self.state);
        let placement = state.placements.remove(&id)?;
        let key = state.anchor_keys.remove(&id).unwrap_or(PLACEMENT_KEY | id);
        self.save_index(&state);
        Some((placement, key))
    }

    pub fn placement_panes(&self, artifact: ArtifactId) -> Vec<PaneId> {
        lock(&self.state)
            .placements
            .values()
            .filter(|placement| placement.artifact_id == artifact)
            .map(|placement| placement.pane_id)
            .collect()
    }

    pub fn placement(&self, id: u64) -> Option<Placement> {
        lock(&self.state).placements.get(&id).cloned()
    }

    /// A pane's placements, oldest first.
    pub fn placements(&self, pane: PaneId) -> Vec<Placement> {
        lock(&self.state)
            .placements
            .values()
            .filter(|placement| placement.pane_id == pane)
            .cloned()
            .collect()
    }

    /// Refreshes live placements' rows; returns those that detached (to broadcast).
    pub fn check_placements(&self, core: &Core) -> Vec<Placement> {
        let live: Vec<(u64, u64, PaneId)> = {
            let state = lock(&self.state);
            state
                .placements
                .values()
                .filter(|placement| placement.anchor.state == AnchorState::Live)
                .map(|placement| {
                    let key = state
                        .anchor_keys
                        .get(&placement.placement_id)
                        .copied()
                        .unwrap_or(PLACEMENT_KEY | placement.placement_id);
                    (placement.placement_id, key, placement.pane_id)
                })
                .collect()
        };
        let mut changed = Vec::new();
        for (id, key, pane) in live {
            let position = match core.pane(pane) {
                None => AnchorPos::Detached(DetachReason::PaneClosed),
                Some(entry) => entry
                    .pane
                    .anchor_position(key)
                    .unwrap_or(AnchorPos::Detached(DetachReason::RowGone)),
            };
            let mut state = lock(&self.state);
            let Some(placement) = state.placements.get_mut(&id) else {
                continue;
            };
            let detached = matches!(position, AnchorPos::Detached(_));
            placement.anchor = row_anchor(pane, position, placement.anchor.command_id);
            if detached {
                changed.push(placement.clone());
                self.save_index(&state);
            }
        }
        changed
    }
}

/// Size in cells for an image placed at column `col` of a pane: as asked, else the image's
/// size at the pane's cell size (2× renders of 9×18 pt cells when the client sent no pixel
/// size), at most the pane's width.
fn size_for(image: &ImageRef, pane: PaneSize, col: u16, cols: u16, rows: u16) -> (u16, u16) {
    let (cell_width, cell_height) = if pane.width_px > 0 && pane.height_px > 0 {
        (
            f32::from(pane.width_px) / f32::from(pane.cols.max(1)),
            f32::from(pane.height_px) / f32::from(pane.rows.max(1)),
        )
    } else {
        CELL_PX
    };
    let room = pane.cols.saturating_sub(col).max(1);
    let cols = if cols > 0 {
        cols.min(room)
    } else {
        ((image.width as f32 / cell_width).round() as u16).clamp(1, room)
    };
    let rows = if rows > 0 {
        rows
    } else {
        let aspect = image.height as f32 / image.width.max(1) as f32;
        ((f32::from(cols) * cell_width * aspect / cell_height).round() as u16).max(1)
    };
    (cols, rows.min(500))
}

/// The PNG shown for `artifact` at `version`: a given blob, else the image, preview, or the
/// daemon's render.
fn image_for(
    art: &Art,
    artifact: ArtifactId,
    version: Option<u64>,
    png: Option<proto::BlobHash>,
) -> Result<(u64, ImageRef)> {
    let info = art
        .info(artifact)
        .ok_or_else(|| ArtifactError::NotFound(format!("artifact {artifact}")))?;
    if let Some(hash) = png {
        let (image, _) = art.read_blob(&hash)?;
        return Ok((version.unwrap_or(info.version), image));
    }
    let exported = super::export(art, artifact, version, ExportFormat::Png)?;
    let image = match exported.blob {
        Some(hash) => art.read_blob(&hash)?.0,
        None => art.put_blob(&exported.data)?,
    };
    Ok((exported.version, image))
}

/// Places an artifact inline (the caller checked roles and visibility). Returns the
/// placement and the one it replaced.
pub(crate) fn place(
    core: &Arc<Core>,
    request: PlaceRequest,
    source: PlacementSource,
) -> Result<(Placement, Option<Placement>)> {
    let entry = core
        .pane(request.pane_id)
        .ok_or_else(|| ArtifactError::NotFound(format!("terminal pane {}", request.pane_id)))?;
    let info = core
        .art
        .info(request.artifact_id)
        .ok_or_else(|| ArtifactError::NotFound(format!("artifact {}", request.artifact_id)))?;
    if core.session_of_pane(request.pane_id) != Some(info.session_id) {
        return Err(ArtifactError::Invalid(
            "the artifact belongs to another session".into(),
        ));
    }
    let (version, image) = image_for(&core.art, request.artifact_id, request.version, request.png)?;
    let id = core.art.alloc_placement();
    let key = PLACEMENT_KEY | id;
    let (position, command_id) = match request.anchor {
        Some(anchor) if anchor.pane_id == request.pane_id => entry
            .pane
            .anchor_create(key, anchor.at_seq, anchor.from_bottom)
            .map_err(ArtifactError::Invalid)?,
        Some(_) => {
            return Err(ArtifactError::Invalid(
                "the anchor must be on the placement's pane".into(),
            ));
        }
        None => (
            entry
                .pane
                .anchor_cursor(key)
                .map_err(ArtifactError::Invalid)?,
            None,
        ),
    };
    let (cols, rows) = size_for(
        &image,
        entry.pane.size(),
        request.col,
        request.cols,
        request.rows,
    );
    let replaced = match request.replace {
        Some(old) => unplace(core, old),
        None => None,
    };
    let placement = Placement {
        placement_id: id,
        pane_id: request.pane_id,
        artifact_id: request.artifact_id,
        version,
        image,
        anchor: row_anchor(request.pane_id, position, command_id),
        col: request.col,
        cols,
        rows,
        source,
        at: UnixMillis(now_millis()),
    };
    core.art.insert_placement(placement.clone(), key);
    Ok((placement, replaced))
}

/// Shows `image` (a render of `version`) in every placement of `artifact`, keeping each one's
/// row, column and width (the height follows the image); returns the changed placements.
pub(crate) fn reshow(
    core: &Core,
    artifact: ArtifactId,
    version: u64,
    image: ImageRef,
) -> Vec<Placement> {
    let ids: Vec<u64> = lock(&core.art.state)
        .placements
        .values()
        .filter(|placement| placement.artifact_id == artifact)
        .map(|placement| placement.placement_id)
        .collect();
    let mut changed = Vec::new();
    for id in ids {
        let size = {
            let state = lock(&core.art.state);
            state
                .placements
                .get(&id)
                .map(|placement| (placement.pane_id, placement.col, placement.cols))
        };
        let Some((pane, col, cols)) = size else {
            continue;
        };
        let pane_size = core.pane(pane).map(|entry| entry.pane.size());
        let mut state = lock(&core.art.state);
        let Some(placement) = state.placements.get_mut(&id) else {
            continue;
        };
        if let Some(pane_size) = pane_size {
            (placement.cols, placement.rows) = size_for(&image, pane_size, col, cols, 0);
        }
        placement.image = image;
        placement.version = version;
        changed.push(placement.clone());
        core.art.save_index(&state);
    }
    changed
}

pub(crate) fn unplace(core: &Core, id: u64) -> Option<Placement> {
    let (placement, key) = core.art.remove_placement(id)?;
    if let Some(entry) = core.pane(placement.pane_id) {
        entry.pane.anchor_remove(key);
    }
    Some(placement)
}

/// A file pasted or dropped onto a pane: an image or an `.excalidraw` scene becomes an
/// artifact placed at the cursor row. Returns the placement and the new artifact's info.
pub(crate) fn import(
    core: &Arc<Core>,
    actor: Actor,
    request: ImportRequest,
) -> Result<(Placement, proto::ArtifactInfo)> {
    let session = core
        .session_of_pane(request.pane_id)
        .ok_or_else(|| ArtifactError::NotFound(format!("pane {}", request.pane_id)))?;
    let bytes = match request.blob {
        Some(hash) => core.art.read_blob(&hash)?.1,
        None if request.data.len() > super::INLINE_MAX => {
            return Err(ArtifactError::TooLarge(
                "inline imports are at most 1 MiB; upload a blob".into(),
            ));
        }
        None => request.data,
    };
    let lower = request.name.to_ascii_lowercase();
    let info = if lower.ends_with(".excalidraw")
        || (lower.ends_with(".json") && bytes.starts_with(b"{"))
    {
        let file = drawing::parse_file(&bytes).map_err(ArtifactError::Invalid)?;
        core.art.ex_import(actor, session, &request.name, file)?
    } else {
        let image = core.art.put_blob(&bytes)?;
        core.art
            .create(
                actor,
                &proto::ArtifactCreate {
                    session_id: session,
                    kind: ArtifactKind::Image,
                    title: request.name.clone(),
                    space: proto::CoordSpace::Canvas,
                    anchor: None,
                    image: Some(image.hash),
                    ops: Vec::new(),
                },
                None,
            )?
            .0
    };
    let placed = place(
        core,
        PlaceRequest {
            pane_id: request.pane_id,
            artifact_id: info.artifact_id,
            version: None,
            anchor: None,
            col: 0,
            cols: 0,
            rows: 0,
            png: None,
            replace: None,
        },
        PlacementSource::User,
    );
    match placed {
        Ok((placement, _)) => Ok((placement, core.art.info(info.artifact_id).unwrap_or(info))),
        Err(error) => {
            let _ = core.art.delete(info.artifact_id);
            Err(error)
        }
    }
}
