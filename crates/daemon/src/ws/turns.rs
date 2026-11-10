//! "What did this agent turn change": the worktree is snapshotted as a git tree when an agent
//! turn starts and again when it ends (see [`git::worktree_tree`]), and the turn's diff is the
//! diff between the two trees. A pane's snapshots run one at a time so a turn's end can
//! never be recorded before its start; panes run independently, so a repository whose git
//! hangs holds only its own panes' turns.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use proto::{GitDiff, PaneId, TurnInfo, UnixMillis, WsError};
use tokio::sync::mpsc;
use tokio::task::JoinSet;

use super::git;
use crate::core::{Core, lock};

const MAX_TURNS: usize = 50;

#[derive(Debug)]
pub(crate) enum Boundary {
    Start { pane: PaneId, cwd: PathBuf },
    End { pane: PaneId },
}

impl Boundary {
    fn pane(&self) -> PaneId {
        match self {
            Self::Start { pane, .. } | Self::End { pane } => *pane,
        }
    }
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
    let Some(boundaries) = lock(&core.ws.turns.rx).take() else {
        return;
    };
    apply_per_pane(boundaries, Arc::new(move |boundary| apply(&core, boundary))).await;
}

type Apply = Arc<dyn Fn(Boundary) + Send + Sync>;

/// Applies each pane's boundaries in order, one at a time, and different panes' at once.
async fn apply_per_pane(mut boundaries: mpsc::UnboundedReceiver<Boundary>, apply: Apply) {
    let mut waiting: HashMap<PaneId, VecDeque<Boundary>> = HashMap::new();
    let mut applying: JoinSet<PaneId> = JoinSet::new();
    let start = |applying: &mut JoinSet<PaneId>, boundary: Boundary| {
        let pane = boundary.pane();
        let apply = Arc::clone(&apply);
        applying.spawn(async move {
            let _ = tokio::task::spawn_blocking(move || apply(boundary)).await;
            pane
        });
    };
    loop {
        tokio::select! {
            received = boundaries.recv() => {
                let Some(boundary) = received else {
                    return;
                };
                match waiting.get_mut(&boundary.pane()) {
                    Some(queue) => queue.push_back(boundary),
                    None => {
                        waiting.insert(boundary.pane(), VecDeque::new());
                        start(&mut applying, boundary);
                    }
                }
            }
            Some(Ok(pane)) = applying.join_next() => {
                match waiting.get_mut(&pane).and_then(VecDeque::pop_front) {
                    Some(next) => start(&mut applying, next),
                    None => {
                        waiting.remove(&pane);
                    }
                }
            }
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// One pane's snapshot hangs (its repository is on a stalled mount): the other pane's
    /// turns are still recorded, and the stuck pane's own boundaries keep their order.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_stuck_pane_holds_only_its_own_turns() {
        let stuck = PaneId(1);
        let other = PaneId(2);
        let (release, released) = std::sync::mpsc::channel::<()>();
        let released = Mutex::new(released);
        let (applied_tx, mut applied) = mpsc::unbounded_channel();
        let apply: Apply = Arc::new(move |boundary: Boundary| {
            if matches!(boundary, Boundary::Start { pane, .. } if pane == stuck) {
                let _ = lock(&released).recv();
            }
            let _ = applied_tx.send(format!("{boundary:?}"));
        });
        let (boundaries, receiver) = mpsc::unbounded_channel();
        let worker = tokio::spawn(apply_per_pane(receiver, apply));
        let cwd = PathBuf::from("/repo");
        for boundary in [
            Boundary::Start {
                pane: stuck,
                cwd: cwd.clone(),
            },
            Boundary::End { pane: stuck },
            Boundary::Start {
                pane: other,
                cwd: cwd.clone(),
            },
            Boundary::End { pane: other },
        ] {
            boundaries.send(boundary).unwrap();
        }
        let mut next = async || {
            tokio::time::timeout(Duration::from_secs(5), applied.recv())
                .await
                .expect("a boundary is applied")
                .unwrap()
        };
        assert!(next().await.starts_with("Start { pane: PaneId(2)"));
        assert!(next().await.starts_with("End { pane: PaneId(2)"));
        release.send(()).unwrap();
        assert!(next().await.starts_with("Start { pane: PaneId(1)"));
        assert!(next().await.starts_with("End { pane: PaneId(1)"));
        worker.abort();
    }
}
