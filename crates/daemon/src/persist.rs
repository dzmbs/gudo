//! Debounced, atomic persistence of the layout and per-pane restore records.

use std::collections::{BTreeMap, HashMap};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use proto::PaneId;
use serde::{Deserialize, Serialize};

use crate::core::{ClosedPane, Core, PaneRecord, saved_state};
use crate::fsutil::{read_optional, write_atomic};
use crate::layout::Layout;

const FILE: &str = "layout.json";
const VERSION: u32 = 1;

/// The on-disk state.
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct Saved {
    version: u32,
    layout: Layout,
    panes: BTreeMap<u64, PaneRecord>,
    /// Recently closed panes, oldest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    closed: Vec<ClosedPane>,
    /// Which pane created which (`[pane, creator]`), so agents keep driving the panes they
    /// opened after a restart.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    creators: Vec<(u64, u64)>,
}

impl Saved {
    pub fn new(layout: Layout, panes: BTreeMap<u64, PaneRecord>, closed: Vec<ClosedPane>) -> Self {
        Self {
            version: VERSION,
            layout,
            panes,
            closed,
            creators: Vec::new(),
        }
    }

    /// With the ownership map of the terminal tools.
    pub fn with_creators(mut self, creators: impl IntoIterator<Item = (PaneId, PaneId)>) -> Self {
        self.creators = creators.into_iter().map(|(p, c)| (p.0, c.0)).collect();
        self.creators.sort_unstable();
        self
    }

    /// Takes the ownership map out.
    pub fn take_creators(&mut self) -> Vec<(PaneId, PaneId)> {
        std::mem::take(&mut self.creators)
            .into_iter()
            .map(|(p, c)| (PaneId(p), PaneId(c)))
            .collect()
    }

    pub fn into_parts(self) -> (Layout, HashMap<PaneId, PaneRecord>, Vec<ClosedPane>) {
        let panes = self
            .panes
            .into_iter()
            .map(|(k, v)| (PaneId(k), v))
            .collect();
        (self.layout, panes, self.closed)
    }
}

pub(crate) fn path(state_dir: &Path) -> PathBuf {
    state_dir.join(FILE)
}

/// Loads the saved state. A missing file is a fresh start; an unreadable one is moved aside
/// (never silently overwritten) and treated as a fresh start.
pub(crate) fn load(state_dir: &Path) -> io::Result<Option<Saved>> {
    let file = path(state_dir);
    let Some(bytes) = read_optional(&file)? else {
        return Ok(None);
    };
    match serde_json::from_slice::<Saved>(&bytes) {
        Ok(saved) if saved.version == VERSION => Ok(Some(saved)),
        Ok(saved) => {
            tracing::warn!(
                version = saved.version,
                "unknown layout.json version; starting fresh"
            );
            backup(&file)?;
            Ok(None)
        }
        Err(e) => {
            tracing::warn!("layout.json is unreadable ({e}); starting fresh");
            backup(&file)?;
            Ok(None)
        }
    }
}

fn backup(file: &Path) -> io::Result<()> {
    let to = file.with_extension(format!("json.bad-{}", crate::identity::now_millis()));
    std::fs::rename(file, to)
}

/// Writes the current state now.
pub(crate) async fn save(core: &Core) -> io::Result<()> {
    let saved = saved_state(core);
    let bytes = serde_json::to_vec_pretty(&saved).map_err(io::Error::other)?;
    let file = path(&core.cfg.state_dir);
    tokio::task::spawn_blocking(move || write_atomic(&file, &bytes))
        .await
        .map_err(io::Error::other)?
}

/// Saves after every burst of changes, once the debounce window has been quiet.
pub(crate) async fn run(core: Arc<Core>) {
    loop {
        core.persist_dirty.notified().await;
        loop {
            let quiet =
                tokio::time::timeout(core.cfg.persist_debounce, core.persist_dirty.notified());
            if quiet.await.is_err() {
                break;
            }
        }
        if let Err(e) = save(&core).await {
            tracing::warn!("saving layout: {e}");
        }
    }
}
