//! Inline placements: artifacts shown in a terminal pane, glued to an output row, so a
//!
//! The daemon owns image and placement state instead of leaving it to the VT's kitty
//! or attaches later would lose them. Placements travel as `ArtifactEvent::Placed` and are
//! sent again on `Attach`; their rows are tracked pins like ink anchors.
//!
//! Three ways in: a person places an artifact (the overlay's "done", or "place" from a
//! list), a file is pasted or dropped onto the pane (`Import`), or a program in the pane
//! prints a PNG with the kitty graphics protocol (`un draw show`, `kitten icat`), which the
//! output scanner hands over with the cursor row pinned.

use std::sync::Arc;

use proto::{
    Actor, AnchorState, ArtifactError, ArtifactEvent, ArtifactId, ArtifactKind, DetachReason,
    ExportFormat, ImageRef, ImportRequest, PaneId, PaneSize, PlaceRequest, Placement,
    PlacementSource, UnixMillis,
};

use super::{Art, Result, row_anchor};
use crate::anchor::AnchorPos;
use crate::core::{Core, lock};
use crate::identity::now_millis;

/// Anchor keys of placements (artifact anchors use the artifact id; kitty captures set bit 62).
pub(crate) const PLACEMENT_KEY: u64 = 1 << 63;
/// Default cell size in image pixels for sizing a placement (2× renders of 9×18 pt cells).
const CELL_PX: (f32, f32) = (18.0, 36.0);

impl Art {
    fn alloc_placement(&self) -> u64 {
        let mut st = lock(&self.state);
        st.next_placement = st.next_placement.max(1);
        let id = st.next_placement;
        st.next_placement += 1;
        id
    }

    fn insert_placement(&self, p: Placement, key: u64) {
        let mut st = lock(&self.state);
        st.anchor_keys.insert(p.placement_id, key);
        st.placements.insert(p.placement_id, p);
        self.save_index(&st);
    }

    /// Removes a placement; returns it with its anchor key.
    pub fn remove_placement(&self, id: u64) -> Option<(Placement, u64)> {
        let mut st = lock(&self.state);
        let p = st.placements.remove(&id)?;
        let key = st.anchor_keys.remove(&id).unwrap_or(PLACEMENT_KEY | id);
        self.save_index(&st);
        Some((p, key))
    }

    /// Panes an artifact is placed in.
    pub fn placement_panes(&self, artifact: ArtifactId) -> Vec<PaneId> {
        lock(&self.state)
            .placements
            .values()
            .filter(|p| p.artifact_id == artifact)
            .map(|p| p.pane_id)
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
            .filter(|p| p.pane_id == pane)
            .cloned()
            .collect()
    }

    /// Refreshes live placements' rows; returns those that detached (to broadcast).
    pub fn check_placements(&self, core: &Core) -> Vec<Placement> {
        let live: Vec<(u64, u64, PaneId)> = {
            let st = lock(&self.state);
            st.placements
                .values()
                .filter(|p| p.anchor.state == AnchorState::Live)
                .map(|p| {
                    let key = st
                        .anchor_keys
                        .get(&p.placement_id)
                        .copied()
                        .unwrap_or(PLACEMENT_KEY | p.placement_id);
                    (p.placement_id, key, p.pane_id)
                })
                .collect()
        };
        let mut changed = Vec::new();
        for (id, key, pane) in live {
            let pos = match core.pane(pane) {
                None => AnchorPos::Detached(DetachReason::PaneClosed),
                Some(e) => e
                    .pane
                    .anchor_position(key)
                    .unwrap_or(AnchorPos::Detached(DetachReason::RowGone)),
            };
            let mut st = lock(&self.state);
            let Some(p) = st.placements.get_mut(&id) else {
                continue;
            };
            let detached = matches!(pos, AnchorPos::Detached(_));
            p.anchor = row_anchor(pane, pos, p.anchor.command_id);
            if detached {
                changed.push(p.clone());
                self.save_index(&st);
            }
        }
        changed
    }
}

/// Size in cells for an image placed at column `col` of a pane: as asked, else the image's
/// size at the pane's cell size (2× renders of 9×18 pt cells when the client sent no pixel
/// size), at most the pane's width.
fn size_for(image: &ImageRef, pane: PaneSize, col: u16, cols: u16, rows: u16) -> (u16, u16) {
    let (cw, ch) = if pane.width_px > 0 && pane.height_px > 0 {
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
        ((image.width as f32 / cw).round() as u16).clamp(1, room)
    };
    let rows = if rows > 0 {
        rows
    } else {
        let aspect = image.height as f32 / image.width.max(1) as f32;
        ((f32::from(cols) * cw * aspect / ch).round() as u16).max(1)
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
    req: PlaceRequest,
    source: PlacementSource,
) -> Result<(Placement, Option<Placement>)> {
    let entry = core
        .pane(req.pane_id)
        .ok_or_else(|| ArtifactError::NotFound(format!("terminal pane {}", req.pane_id)))?;
    let info = core
        .art
        .info(req.artifact_id)
        .ok_or_else(|| ArtifactError::NotFound(format!("artifact {}", req.artifact_id)))?;
    if core.session_of_pane(req.pane_id) != Some(info.session_id) {
        return Err(ArtifactError::Invalid(
            "the artifact belongs to another session".into(),
        ));
    }
    let (version, image) = image_for(&core.art, req.artifact_id, req.version, req.png)?;
    let id = core.art.alloc_placement();
    let key = PLACEMENT_KEY | id;
    let (pos, command_id) = match req.anchor {
        Some(a) if a.pane_id == req.pane_id => entry
            .pane
            .anchor_create(key, a.at_seq, a.from_bottom)
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
    let (cols, rows) = size_for(&image, entry.pane.size(), req.col, req.cols, req.rows);
    let replaced = match req.replace {
        Some(old) => unplace(core, old),
        None => None,
    };
    let placement = Placement {
        placement_id: id,
        pane_id: req.pane_id,
        artifact_id: req.artifact_id,
        version,
        image,
        anchor: row_anchor(req.pane_id, pos, command_id),
        col: req.col,
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
        .filter(|p| p.artifact_id == artifact)
        .map(|p| p.placement_id)
        .collect();
    let mut changed = Vec::new();
    for id in ids {
        let size = {
            let st = lock(&core.art.state);
            st.placements.get(&id).map(|p| (p.pane_id, p.col, p.cols))
        };
        let Some((pane, col, cols)) = size else {
            continue;
        };
        let pane_size = core.pane(pane).map(|e| e.pane.size());
        let mut st = lock(&core.art.state);
        let Some(p) = st.placements.get_mut(&id) else {
            continue;
        };
        if let Some(pane_size) = pane_size {
            (p.cols, p.rows) = size_for(&image, pane_size, col, cols, 0);
        }
        p.image = image;
        p.version = version;
        changed.push(p.clone());
        core.art.save_index(&st);
    }
    changed
}

/// Removes a placement and its pin.
pub(crate) fn unplace(core: &Core, id: u64) -> Option<Placement> {
    let (p, key) = core.art.remove_placement(id)?;
    if let Some(e) = core.pane(p.pane_id) {
        e.pane.anchor_remove(key);
    }
    Some(p)
}

/// A file pasted or dropped onto a pane: an image or an `.excalidraw` scene becomes an
/// artifact placed at the cursor row. Returns the placement and the new artifact's info.
pub(crate) fn import(
    core: &Arc<Core>,
    actor: Actor,
    req: ImportRequest,
) -> Result<(Placement, proto::ArtifactInfo)> {
    let session = core
        .session_of_pane(req.pane_id)
        .ok_or_else(|| ArtifactError::NotFound(format!("pane {}", req.pane_id)))?;
    let bytes = match req.blob {
        Some(hash) => core.art.read_blob(&hash)?.1,
        None if req.data.len() > super::INLINE_MAX => {
            return Err(ArtifactError::TooLarge(
                "inline imports are at most 1 MiB; upload a blob".into(),
            ));
        }
        None => req.data,
    };
    let lower = req.name.to_ascii_lowercase();
    let info = if lower.ends_with(".excalidraw")
        || (lower.ends_with(".json") && bytes.starts_with(b"{"))
    {
        let file = drawing::parse_file(&bytes).map_err(ArtifactError::Invalid)?;
        core.art.ex_import(actor, session, &req.name, file)?
    } else {
        let image = core.art.put_blob(&bytes)?;
        core.art
            .create(
                actor,
                &proto::ArtifactCreate {
                    session_id: session,
                    kind: ArtifactKind::Image,
                    title: req.name.clone(),
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
            pane_id: req.pane_id,
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
        Ok((p, _)) => Ok((p, core.art.info(info.artifact_id).unwrap_or(info))),
        Err(e) => {
            let _ = core.art.delete(info.artifact_id);
            Err(e)
        }
    }
}

/// A PNG a program printed with the kitty graphics protocol, its top-left cell already
/// pinned under `key` by the output scanner: kept as an image artifact and placement.
pub(crate) fn kitty_image(
    core: &Arc<Core>,
    pane: PaneId,
    key: u64,
    png: &[u8],
    (col, cols, rows): (u16, u16, u16),
) {
    let Some(entry) = core.pane(pane) else { return };
    let Some(session) = core.session_of_pane(pane) else {
        entry.pane.anchor_remove(key);
        return;
    };
    let actor = Actor {
        principal: proto::PrincipalId([0; 16]),
        device: proto::DeviceId(core.identity.daemon_id().0),
    };
    let created = core.art.put_blob(png).and_then(|image| {
        core.art.create(
            actor,
            &proto::ArtifactCreate {
                session_id: session,
                kind: ArtifactKind::Image,
                title: "kitty image".into(),
                space: proto::CoordSpace::Canvas,
                anchor: None,
                image: Some(image.hash),
                ops: Vec::new(),
            },
            None,
        )
    });
    let info = match created {
        Ok((info, _)) => info,
        Err(e) => {
            tracing::debug!(%pane, "kitty image not kept: {e}");
            entry.pane.anchor_remove(key);
            return;
        }
    };
    let Some(image) = info.image else { return };
    let pos = entry
        .pane
        .anchor_position(key)
        .unwrap_or(AnchorPos::Detached(DetachReason::RowGone));
    let (cols, rows) = size_for(&image, entry.pane.size(), col, cols, rows);
    let placement = Placement {
        placement_id: core.art.alloc_placement(),
        pane_id: pane,
        artifact_id: info.artifact_id,
        version: 0,
        image,
        anchor: row_anchor(pane, pos, None),
        col,
        cols,
        rows,
        source: PlacementSource::Kitty,
        at: UnixMillis(now_millis()),
    };
    core.art.insert_placement(placement.clone(), key);
    core.emit_artifact(session, ArtifactEvent::Created(info), None);
    core.emit_artifact(session, ArtifactEvent::Placed(placement), None);
}
