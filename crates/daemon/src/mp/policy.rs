//! What each request needs: a role level and a scope target (docs/DAEMON.md §6.3 is the
//! human-readable version of this file; keep them in sync).

use proto::{
    AssistRequest, LayoutOp, MpError, PaneId, Roles, Scope, SessionId, TabId, WorkspaceRequest,
};

use super::Authz;
use crate::core::Core;

/// The role level an action needs. Roles combine; [`Roles::OWNER`] passes every check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Need {
    /// Any role: see output, scrollback, agent state, presence.
    View,
    /// Send prompts to agent panes through the composer path.
    Prompt,
    Draw,
    /// Raw input, layout changes, host files and forwards.
    Drive,
    /// Answer agent approval requests.
    Approve,
    /// Grants, revocation, audit, closing panes, host services.
    Own,
}

impl Need {
    /// Roles any one of which satisfies the need.
    fn roles(self) -> Roles {
        match self {
            Self::View => Roles::ALL,
            Self::Prompt => Roles::PROMPTER | Roles::DRIVER | Roles::APPROVER,
            Self::Draw => Roles::PROMPTER | Roles::DRIVER,
            Self::Drive => Roles::DRIVER,
            Self::Approve => Roles::APPROVER,
            Self::Own => Roles::OWNER,
        }
    }

    fn describe(self) -> &'static str {
        match self {
            Self::View => "any role",
            Self::Prompt => "the prompter, driver or approver role",
            Self::Draw => "the prompter or driver role",
            Self::Drive => "the driver role",
            Self::Approve => "the approver role",
            Self::Own => "the owner role",
        }
    }
}

/// What an action touches, for the scope check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Target {
    /// Nothing scoped (presence, pings, the caller's own state).
    Any,
    /// A pane, which must be inside the grant's scope.
    Pane(PaneId),
    /// A tab inside the scope.
    Tab(TabId),
    /// A session inside the scope.
    Session(SessionId),
    /// The whole session a pane belongs to (structural changes like a split).
    SessionOf(PaneId),
    /// The host beyond the terminal (files, git, forwards): a daemon- or session-wide grant.
    Host,
    /// The daemon itself (grants, audit, host services): a daemon-wide grant.
    Daemon,
}

/// Checks `authz` against `need` on `target`.
///
/// # Errors
///
/// [`MpError::Forbidden`] naming the missing role, or the scope the target lies outside of.
pub(crate) fn check(core: &Core, authz: &Authz, need: Need, target: Target) -> Result<(), MpError> {
    if !authz.roles.allows_any(need.roles()) {
        return Err(MpError::Forbidden(format!(
            "needs {}; this connection has {}",
            need.describe(),
            authz.roles.names()
        )));
    }
    let scope = authz.scope;
    let inside = match target {
        Target::Any => true,
        Target::Pane(p) => core.scope_within(Scope::Pane(p), scope),
        Target::Tab(t) => core.scope_within(Scope::Tab(t), scope),
        Target::Session(s) => core.scope_within(Scope::Session(s), scope),
        Target::SessionOf(p) => core
            .session_of_pane(p)
            .is_some_and(|s| core.scope_within(Scope::Session(s), scope)),
        Target::Host => matches!(scope, Scope::Daemon | Scope::Session(_)),
        Target::Daemon => scope == Scope::Daemon,
    };
    if inside {
        Ok(())
    } else {
        Err(MpError::Forbidden(format!(
            "outside this grant's scope ({scope})"
        )))
    }
}

/// What a layout op needs.
pub(crate) fn op(op: &LayoutOp) -> (Need, Target) {
    use LayoutOp as O;
    match op {
        O::Split { pane_id, .. } => (Need::Drive, Target::SessionOf(*pane_id)),
        O::NewTab { session_id, .. } | O::RenameSession { session_id, .. } => {
            (Need::Drive, Target::Session(*session_id))
        }
        O::Focus { pane_id } | O::Resize { pane_id, .. } | O::ToggleZoom { pane_id } => {
            (Need::Drive, Target::Pane(*pane_id))
        }
        O::FocusDirection { tab_id, .. }
        | O::MoveTab { tab_id, .. }
        | O::SelectTab { tab_id }
        | O::RenameTab { tab_id, .. } => (Need::Drive, Target::Tab(*tab_id)),
        O::ClosePane { pane_id } => (Need::Own, Target::Pane(*pane_id)),
        O::CloseTab { tab_id } => (Need::Own, Target::Tab(*tab_id)),
        O::CloseSession { session_id } => (Need::Own, Target::Session(*session_id)),
        O::CreateSession { .. } => (Need::Own, Target::Daemon),
    }
}

/// edits and sends to agents. The artifact itself must also be visible to the scope
/// (checked by the caller, which knows where it is anchored).
pub(crate) fn artifact(req: &proto::ArtifactRequest) -> (Need, Target) {
    use proto::ArtifactRequest as R;
    match req {
        R::List { .. } | R::Get { .. } | R::Export { .. } => (Need::View, Target::Any),
        R::Create(c) => match c.anchor {
            Some(a) => (Need::Draw, Target::Pane(a.pane_id)),
            None => (Need::Draw, Target::Session(c.session_id)),
        },
        R::Apply { .. } | R::Delete { .. } | R::SetPreview { .. } => (Need::Draw, Target::Any),
        R::SetAnchor { anchor, .. } => match anchor {
            Some(a) => (Need::Draw, Target::Pane(a.pane_id)),
            None => (Need::Draw, Target::Any),
        },
        R::Send(s) => (Need::Draw, Target::Pane(s.pane_id)),
        R::ExcalidrawGet { .. } => (Need::View, Target::Any),
        R::ExcalidrawPut(_) | R::Unplace { .. } => (Need::Draw, Target::Any),
        R::Place(p) => (Need::Draw, Target::Pane(p.pane_id)),
        R::Import(i) => (Need::Draw, Target::Pane(i.pane_id)),
        R::Placements { pane_id } => (Need::View, Target::Pane(*pane_id)),
        R::History { .. } => (Need::View, Target::Any),
        R::Restore { .. } => (Need::Draw, Target::Any),
    }
}

/// What a workspace request needs. List answers (ports, attention) are also filtered to the
/// scope by the caller.
pub(crate) fn workspace(req: &WorkspaceRequest) -> (Need, Target) {
    use WorkspaceRequest as R;
    match req {
        R::ListPorts | R::AttentionList | R::AttentionSeen(_) => (Need::View, Target::Any),
        R::ListTurns { pane_id } | R::TurnDiff { pane_id, .. } => {
            (Need::Prompt, Target::Pane(*pane_id))
        }
        R::SendReview(review) => (Need::Prompt, Target::Pane(review.pane_id)),
        R::WorktreeLaunch { split_from, .. } => (Need::Drive, Target::SessionOf(*split_from)),
        R::GitStatus { .. }
        | R::GitDiff(_)
        | R::FsList { .. }
        | R::FsStat { .. }
        | R::FsRead { .. }
        | R::FsWatch { .. }
        | R::FsUnwatch { .. }
        | R::FsWrite { .. }
        | R::FsMkdir { .. }
        | R::FsRename { .. }
        | R::FsDelete { .. }
        | R::WorktreeCreate(_)
        | R::WorktreeList { .. }
        | R::WorktreeRemove { .. }
        | R::EditorStatus
        | R::EditorOpen { .. }
        | R::VsCodeTunnelStatus
        | R::VsCodeTunnelOpen(_)
        // The git-native workspace touches the host's repositories (and GitHub as the
        // host's `gh` user), like the git and worktree requests above.
        | R::RepoRefresh { .. }
        | R::PrMerge(_)
        | R::PrRerunFailed { .. }
        | R::PrCreate(_)
        | R::PrCheckout(_)
        | R::WorktreeArchive { .. }
        | R::WorktreeArchived { .. }
        | R::WorktreeRestore { .. }
        | R::WorktreeSettings(None)
        | R::TaskCreate(_)
        | R::ScriptRun(_) => (Need::Drive, Target::Host),
        // Housekeeping that deletes worktrees is the owner's call.
        R::WorktreeSettings(Some(_)) => (Need::Own, Target::Daemon),
        R::EditorLaunch(_)
        | R::EditorStop { .. }
        | R::VsCodeCliInstall(_)
        | R::VsCodeTunnelStart(_)
        | R::VsCodeTunnelStop => (Need::Own, Target::Daemon),
        // Pushes carry agent prompts from every pane, and guests have no push scope yet
        R::PushRegister(_) | R::PushUnregister | R::PushStatus | R::PushAction(_) => {
            (Need::Own, Target::Daemon)
        }
        // The owner's plan and its limits; a guest has no business there.
        R::UsageWatch(_) | R::UsageUnwatch => (Need::Own, Target::Daemon),
        // Workflows are typed into a pane (driving it); listing reads files of the pane's
        // repository and the host's global directory, saving writes one there.
        R::WorkflowList { pane_id: Some(p) } => (Need::Drive, Target::Pane(*p)),
        R::WorkflowList { pane_id: None } | R::WorkflowSave(_) => (Need::Drive, Target::Host),
    }
}

/// foreground program is viewing it; submitting a line is driving it; history, completion and
/// file search read the host beyond the pane (other panes' commands, the file system);
/// answering a dialog on screen is approving.
pub(crate) fn assist(req: &AssistRequest) -> (Need, Target) {
    use AssistRequest as R;
    match req {
        R::Watch { pane_id, .. } | R::State { pane_id } | R::BlockedOptions { pane_id } => {
            (Need::View, Target::Pane(*pane_id))
        }
        R::SubmitLine(s) => (Need::Drive, Target::Pane(s.pane_id)),
        R::History(_) | R::Complete(_) | R::FileSearch(_) => (Need::Drive, Target::Host),
        R::AnswerBlocked(a) => (Need::Approve, Target::Pane(a.pane_id)),
    }
}

/// The pane an input-assistance request addresses, if any.
pub(crate) fn assist_pane(req: &AssistRequest) -> Option<PaneId> {
    use AssistRequest as R;
    match req {
        R::Watch { pane_id, .. } | R::State { pane_id } | R::BlockedOptions { pane_id } => {
            Some(*pane_id)
        }
        R::SubmitLine(s) => Some(s.pane_id),
        R::Complete(c) => Some(c.pane_id),
        R::AnswerBlocked(a) => Some(a.pane_id),
        R::History(_) | R::FileSearch(_) => None,
    }
}
