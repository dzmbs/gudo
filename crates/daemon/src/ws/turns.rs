//! "What did this agent turn change": the worktree is snapshotted as a git tree when an agent
//! turn starts and again when it ends (see [`git::worktree_tree`]), and the turn's diff is the
//! diff between the two trees. Snapshots run one at a time on a worker so a turn's end can
//! never be recorded before its start.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use proto::{GitDiff, PaneId, TurnInfo, UnixMillis, WsError};
use tokio::sync::mpsc;

use super::git;
use crate::core::{Core, lock};

const MAX_TURNS: usize = 50;

#[derive(Debug)]
pub(crate) enum Boundary {
    Start { pane: PaneId, cwd: PathBuf },
    End { pane: PaneId },
}

pub(crate) struct Turns {
    by_pane: Mutex<HashMap<PaneId, Vec<TurnInfo>>>,
    tx: mpsc::UnboundedSender<Boundary>,
    rx: Mutex<Option<mpsc::UnboundedReceiver<Boundary>>>,
}

impl Turns {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        Self {
            by_pane: Mutex::new(HashMap::new()),
            tx,
            rx: Mutex::new(Some(rx)),
        }
    }

    pub fn record(&self, boundary: Boundary) {
        let _ = self.tx.send(boundary);
    }

    pub fn list(&self, pane: PaneId) -> Vec<TurnInfo> {
        lock(&self.by_pane).get(&pane).cloned().unwrap_or_default()
    }

    pub fn forget_pane(&self, pane: PaneId) {
        lock(&self.by_pane).remove(&pane);
    }

    /// The diff of a turn (the latest when `turn` is `None`); a running turn is compared with
    /// the worktree as it is now.
    pub fn diff(
        &self,
        pane: PaneId,
        turn: Option<u64>,
        context: u32,
        hunks: bool,
    ) -> Result<GitDiff, WsError> {
        let info = {
            let by_pane = lock(&self.by_pane);
            let turns = by_pane
                .get(&pane)
                .ok_or_else(|| WsError::NotFound(format!("no recorded turns in pane {pane}")))?;
            match turn {
                Some(number) => turns
                    .iter()
                    .find(|recorded| recorded.turn == number)
                    .cloned(),
                None => turns.last().cloned(),
            }
            .ok_or_else(|| WsError::NotFound(format!("turn {turn:?} in pane {pane}")))?
        };
        let root = PathBuf::from(&info.root);
        let end_tree = match &info.end_tree {
            Some(tree) => tree.clone(),
            None => git::worktree_tree(&root)?,
        };
        git::diff_trees(&root, &info.start_tree, &end_tree, &[], context, hunks)
    }
}

pub(crate) async fn run(core: Arc<Core>) {
    let Some(mut rx) = lock(&core.ws.turns.rx).take() else {
        return;
    };
    while let Some(boundary) = rx.recv().await {
        let core = Arc::clone(&core);
        let _ = tokio::task::spawn_blocking(move || apply(&core, boundary)).await;
    }
}

fn apply(core: &Core, boundary: Boundary) {
    let turns = &core.ws.turns;
    let now = UnixMillis(crate::identity::now_millis());
    match boundary {
        Boundary::Start { pane, cwd } => {
            // An unfinished previous turn ends where this one starts.
            let open = lock(&turns.by_pane)
                .get(&pane)
                .and_then(|pane_turns| pane_turns.last())
                .filter(|turn| turn.end_tree.is_none())
                .map(|turn| PathBuf::from(&turn.root));
            if let Some(root) = open {
                finish(turns, pane, &root, now);
            }
            let snapshot = git::toplevel(&cwd).and_then(|root| {
                let tree = git::worktree_tree(&root)?;
                Ok((root, tree))
            });
            let (root, tree) = match snapshot {
                Ok(snapshot) => snapshot,
                Err(error) => {
                    tracing::debug!(%pane, "no turn snapshot in {}: {error}", cwd.display());
                    return;
                }
            };
            let mut by_pane = lock(&turns.by_pane);
            let pane_turns = by_pane.entry(pane).or_default();
            let turn = pane_turns.last().map_or(1, |last| last.turn + 1);
            pane_turns.push(TurnInfo {
                turn,
                root: root.to_string_lossy().into_owned(),
                started_at: now,
                ended_at: None,
                start_tree: tree,
                end_tree: None,
            });
            if pane_turns.len() > MAX_TURNS {
                pane_turns.remove(0);
            }
            tracing::debug!(%pane, turn, "turn snapshot taken");
        }
        Boundary::End { pane } => {
            let open = lock(&turns.by_pane)
                .get(&pane)
                .and_then(|pane_turns| pane_turns.last())
                .filter(|turn| turn.end_tree.is_none())
                .map(|turn| PathBuf::from(&turn.root));
            if let Some(root) = open {
                finish(turns, pane, &root, now);
            }
        }
    }
}

fn finish(turns: &Turns, pane: PaneId, root: &std::path::Path, now: UnixMillis) {
    let tree = match git::worktree_tree(root) {
        Ok(tree) => tree,
        Err(error) => {
            tracing::debug!(%pane, "turn end snapshot: {error}");
            return;
        }
    };
    if let Some(last) = lock(&turns.by_pane)
        .get_mut(&pane)
        .and_then(|pane_turns| pane_turns.last_mut())
        && last.end_tree.is_none()
    {
        last.end_tree = Some(tree);
        last.ended_at = Some(now);
    }
}
