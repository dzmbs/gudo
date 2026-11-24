//! `ChatFileSearch`: files under an agent pane's working directory, for `@` mentions typed in
//! Chat.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use proto::{CHAT_FILE_MATCHES_MAX, CHAT_FILE_QUERY_MAX_BYTES, FileMatches, PaneId, WsError};

use super::paths::{Policy, holds_home};
use super::{ConnCtx, blocking};
use crate::core::{Core, lock};

pub(crate) async fn search(
    core: &Arc<Core>,
    conn: &ConnCtx,
    pane_id: PaneId,
    query: String,
    limit: u16,
) -> Result<FileMatches, WsError> {
    // Security: the listing names files beyond what the pane shows, so like Chat sending it is
    // the owner's alone, whatever role a guest's grant names.
    if !conn.owner {
        return Err(WsError::Denied(
            "Only the owner can search files from Chat.".into(),
        ));
    }
    if query.len() > CHAT_FILE_QUERY_MAX_BYTES || query.contains('\0') {
        return Err(WsError::Invalid("overlong or NUL query".into()));
    }
    let entry = core
        .pane(pane_id)
        .filter(|_| core.scope_within(proto::Scope::Pane(pane_id), conn.scope))
        .ok_or_else(|| WsError::NotFound(format!("pane {}", pane_id.0)))?;
    let cwd = lock(&entry.meta)
        .cwd
        .clone()
        .ok_or_else(|| WsError::Unavailable("The agent's folder is not known yet.".into()))?;
    let policy = core.ws.policy.clone();
    let root = policy.resolve_followed(&cwd)?;
    if holds_home(&root, policy.home()) {
        return Err(WsError::Unavailable(
            "Files are searched in a project folder, not the home folder.".into(),
        ));
    }
    if !root.is_dir() {
        return Err(WsError::NotFound(root.display().to_string()));
    }
    let limit = usize::from(limit.clamp(1, CHAT_FILE_MATCHES_MAX));
    let core = Arc::clone(core);
    blocking(move || {
        let mut found =
            core.assist
                .search_files(&root, &query, 2 * usize::from(CHAT_FILE_MATCHES_MAX));
        found
            .matches
            .retain(|file| is_served(&policy, &root, &file.path));
        found.matches.truncate(limit);
        Ok(found)
    })
    .await
}

// Security: a project folder can hold the daemon's own state; the walk does not know the
// policy, so every match is checked as the Files browser would check it.
fn is_served(policy: &Policy, root: &Path, relative: &str) -> bool {
    let path: PathBuf = root.join(relative);
    policy.resolve(&path.to_string_lossy()).is_ok()
}
