//! Debounced, atomic persistence of the layout and per-pane restore records.

use std::collections::{BTreeMap, HashMap, HashSet};
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Saved {
    version: u32,
    layout: Layout,
    panes: BTreeMap<u64, PaneRecord>,
    /// Oldest first.
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

    pub fn with_creators(mut self, creators: impl IntoIterator<Item = (PaneId, PaneId)>) -> Self {
        self.creators = creators
            .into_iter()
            .map(|(pane, creator)| (pane.0, creator.0))
            .collect();
        self.creators.sort_unstable();
        self
    }

    pub fn take_creators(&mut self) -> Vec<(PaneId, PaneId)> {
        std::mem::take(&mut self.creators)
            .into_iter()
            .map(|(pane, creator)| (PaneId(pane), PaneId(creator)))
            .collect()
    }

    pub fn into_parts(self) -> (Layout, HashMap<PaneId, PaneRecord>, Vec<ClosedPane>) {
        let panes = self
            .panes
            .into_iter()
            .map(|(id, record)| (PaneId(id), record))
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
        Err(error) => {
            tracing::warn!("layout.json is unreadable ({error}); starting fresh");
            backup(&file)?;
            Ok(None)
        }
    }
}

fn backup(file: &Path) -> io::Result<()> {
    let aside = file.with_extension(format!("json.bad-{}", crate::identity::now_millis()));
    std::fs::rename(file, aside)
}

pub(crate) async fn save(core: &Arc<Core>) -> io::Result<()> {
    write(core, saved_state(core)).await
}

/// Saves on shutdown, keeping what programs that ended a moment before lost
/// (`core::ENDED_BY_SHUTDOWN`).
pub(crate) async fn save_on_shutdown(core: &Arc<Core>) -> io::Result<()> {
    write(core, core.state_to_save_on_shutdown()).await
}

async fn write(core: &Arc<Core>, saved: Saved) -> io::Result<()> {
    let bytes = serde_json::to_vec_pretty(&saved).map_err(io::Error::other)?;
    let file = path(&core.cfg.state_dir);
    let panes: HashSet<PaneId> = saved.panes.keys().map(|&id| PaneId(id)).collect();
    let core = Arc::clone(core);
    tokio::task::spawn_blocking(move || {
        write_atomic(&file, &bytes)?;
        core.screens.keep_only(&panes);
        Ok(())
    })
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
        if let Err(error) = save(&core).await {
            tracing::warn!("saving layout: {error}");
        }
    }
}
