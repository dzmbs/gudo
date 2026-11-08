//! What each request needs: a role level and a scope target (docs/DAEMON.md §6.3 is the
//! human-readable version of this file; keep them in sync).

use proto::{
    AssistRequest, LayoutOp, MpError, PaneId, PaneLaunch, Roles, Scope, SessionId, TabId,
    WorkspaceRequest,
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
    /// Edit drawings and send them to agents.
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
    /// The tab a pane belongs to (arranging its floating windows).
    TabOf(PaneId),
    /// The host beyond the terminal (files, git, forwards): a daemon- or session-wide grant.
    Host,
    /// The daemon itself (grants, audit, host services): a daemon-wide grant.
    Daemon,
}

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
        Target::Pane(pane_id) => core.scope_within(Scope::Pane(pane_id), scope),
        Target::Tab(tab_id) => core.scope_within(Scope::Tab(tab_id), scope),
        Target::Session(session_id) => core.scope_within(Scope::Session(session_id), scope),
        Target::SessionOf(pane_id) => core
            .session_of_pane(pane_id)
            .is_some_and(|session_id| core.scope_within(Scope::Session(session_id), scope)),
        Target::TabOf(pane_id) => core
            .tab_of_pane(pane_id)
            .is_some_and(|tab_id| core.scope_within(Scope::Tab(tab_id), scope)),
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

/// Whether a layout op chooses one of the owner's agent accounts: an agent under a named
/// account other than the system one, or a sign-in. Only the owner's own devices may.
pub(crate) fn chooses_account(op: &LayoutOp) -> bool {
    let launch = match op {
        LayoutOp::Split { launch, .. } | LayoutOp::NewTab { launch, .. } => launch,
        _ => return false,
    };
    match launch {
        PaneLaunch::AccountAgent {
            account: Some(account),
            ..
        } => account != proto::SYSTEM_ACCOUNT,
        PaneLaunch::AccountSignIn { .. } => true,
        _ => false,
    }
}

pub(crate) fn op(op: &LayoutOp) -> (Need, Target) {
    use LayoutOp as O;
    match op {
        // A closed pane comes back only for the owner, who closed it: it can resume the
        // owner's agent session.
        O::Split {
            pane_id,
            launch: PaneLaunch::Reopen { .. },
            ..
        } => (Need::Own, Target::SessionOf(*pane_id)),
        O::NewTab {
            session_id,
            launch: PaneLaunch::Reopen { .. },
            ..
        } => (Need::Own, Target::Session(*session_id)),
        O::Split { pane_id, .. } if chooses_account(op) => (Need::Own, Target::SessionOf(*pane_id)),
        O::NewTab { session_id, .. } if chooses_account(op) => {
            (Need::Own, Target::Session(*session_id))
        }
        O::Split { pane_id, .. } | O::BreakPane { pane_id } | O::MovePane { pane_id, .. } => {
            (Need::Drive, Target::SessionOf(*pane_id))
        }
        O::MergeTab { target, .. } => (Need::Drive, Target::SessionOf(*target)),
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
        // Projects are the owner's own organisation; guests neither see nor change them.
        O::SetTabProject { tab_id, .. } => (Need::Own, Target::Tab(*tab_id)),
        O::PutProject { session_id, .. } | O::RemoveProject { session_id, .. } => {
            (Need::Own, Target::Session(*session_id))
        }
        // A new float, and docking (which can move a window into another tab), change the
        // session's tree like a split; moving, chipping and pinning arrange one tab.
        O::NewFloat { pane_id, .. }
        | O::DockPane { pane_id, .. }
        | O::MovePaneToEdge { pane_id, .. } => (Need::Drive, Target::SessionOf(*pane_id)),
        O::FloatPane { pane_id, .. } | O::SetFloat { pane_id, .. } => {
            (Need::Drive, Target::TabOf(*pane_id))
        }
    }
}

/// The artifact itself must also be visible to the scope; the caller checks that, since it
/// knows where the artifact is anchored.
pub(crate) fn artifact(req: &proto::ArtifactRequest) -> (Need, Target) {
    use proto::ArtifactRequest as R;
    match req {
        R::List { .. } | R::Get { .. } | R::Export { .. } => (Need::View, Target::Any),
        R::Create(create) => match create.anchor {
            Some(anchor) => (Need::Draw, Target::Pane(anchor.pane_id)),
            None => (Need::Draw, Target::Session(create.session_id)),
        },
        R::Apply { .. } | R::Delete { .. } | R::SetPreview { .. } => (Need::Draw, Target::Any),
        R::SetAnchor { anchor, .. } => match anchor {
            Some(anchor) => (Need::Draw, Target::Pane(anchor.pane_id)),
            None => (Need::Draw, Target::Any),
        },
        R::Send(send) => (Need::Draw, Target::Pane(send.pane_id)),
        R::ExcalidrawGet { .. } => (Need::View, Target::Any),
        R::ExcalidrawPut(_) | R::Unplace { .. } => (Need::Draw, Target::Any),
        R::Place(place) => (Need::Draw, Target::Pane(place.pane_id)),
        R::Import(import) => (Need::Draw, Target::Pane(import.pane_id)),
        R::Placements { pane_id } => (Need::View, Target::Pane(*pane_id)),
        R::History { .. } => (Need::View, Target::Any),
        R::Restore { .. } => (Need::Draw, Target::Any),
    }
}

/// List answers (ports, attention) are also filtered to the scope by the caller.
pub(crate) fn workspace(req: &WorkspaceRequest) -> (Need, Target) {
    use WorkspaceRequest as R;
    match req {
        R::ListPorts | R::AttentionList | R::AttentionSeen(_) => (Need::View, Target::Any),
        R::TimelineWatch { pane_id }
        | R::TimelineWatchVersioned { pane_id, .. }
        | R::TimelineUnwatch { pane_id }
        | R::TimelineItemsBefore { pane_id, .. }
        | R::TimelineToolOutput { pane_id, .. }
        | R::TimelineWatchCapabilities { pane_id, .. }
        | R::TimelineToolDiff { pane_id, .. } => (Need::View, Target::Pane(*pane_id)),
        R::ListTurns { pane_id } | R::TurnDiff { pane_id, .. } => {
            (Need::Prompt, Target::Pane(*pane_id))
        }
        R::ChatPrepare { pane_id } | R::ChatSend { pane_id, .. }
        | R::ChatInterruptPrepare { pane_id } | R::ChatInterrupt { pane_id, .. } => {
            (Need::Prompt, Target::Pane(*pane_id))
        }
        R::SendReview(review) => (Need::Prompt, Target::Pane(review.pane_id)),
        R::WorktreeLaunch { split_from, .. } => (Need::Drive, Target::SessionOf(*split_from)),
        R::GitStatus { .. }
        | R::RepoRoot { .. }
        | R::GitDiff(_)
        | R::FsList { .. }
        | R::FsStat { .. }
        | R::FsRead { .. }
        | R::ResolvePaths(_)
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
        | R::ScriptRun(_)
        | R::RepoHooks(_) => (Need::Drive, Target::Host),
        // Lets a repository's own commands run as the user from then on.
        R::PowerSettings(_) | R::RepoTrust { .. } => (Need::Own, Target::Daemon),
        // Housekeeping that deletes worktrees is the owner's call.
        R::WorktreeSettings(Some(_)) => (Need::Own, Target::Daemon),
        R::EditorLaunch(_)
        | R::EditorStop { .. }
        | R::VsCodeCliInstall(_)
        | R::VsCodeTunnelStart(_)
        | R::VsCodeTunnelStop => (Need::Own, Target::Daemon),
        // Pushes carry agent prompts from every pane, and guests have no push scope yet,
        // so only owner devices register and act.
        R::PushRegister(_)
        | R::PushUnregister
        | R::PushStatus
        | R::PushAction(_)
        | R::PushActivity(_)
        | R::PushAgents(_) => {
            (Need::Own, Target::Daemon)
        }
        // The owner's plan and its limits; a guest has no business there.
        R::UsageWatch(_) | R::UsageUnwatch => (Need::Own, Target::Daemon),
        // Workflows are typed into a pane (driving it); listing reads files of the pane's
        // repository and the host's global directory, saving writes one there.
        R::WorkflowList {
            pane_id: Some(pane_id),
        } => (Need::Drive, Target::Pane(*pane_id)),
        R::WorkflowList { pane_id: None } | R::WorkflowSave(_) => (Need::Drive, Target::Host),
        // Asked before launching an agent on the host.
        R::AgentInstalls => (Need::Drive, Target::Host),
        // Changes the owner's agent configuration.
        R::AgentMcpCommands { .. } => (Need::Own, Target::Daemon),
        // The owner's sign-ins: a guest neither sees nor switches them.
        R::Accounts
        | R::AccountAdd(_)
        | R::AccountEdit { .. }
        | R::AccountRemove { .. }
        | R::AccountCheck { .. }
        | R::AccountSetDefault { .. } => (Need::Own, Target::Daemon),
    }
}

/// Reading a pane's prompt and foreground program is viewing it; submitting a line is driving it; history, completion and
/// file search read the host beyond the pane (other panes' commands, the file system);
/// answering a dialog on screen is approving.
pub(crate) fn assist(req: &AssistRequest) -> (Need, Target) {
    use AssistRequest as R;
    match req {
        R::Watch { pane_id, .. } | R::State { pane_id } | R::BlockedOptions { pane_id } => {
            (Need::View, Target::Pane(*pane_id))
        }
        R::SubmitLine(submit) => (Need::Drive, Target::Pane(submit.pane_id)),
        R::History(_) | R::Complete(_) | R::FileSearch(_) => (Need::Drive, Target::Host),
        R::AnswerBlocked(answer) => (Need::Approve, Target::Pane(answer.pane_id)),
    }
}

pub(crate) fn assist_pane(req: &AssistRequest) -> Option<PaneId> {
    use AssistRequest as R;
    match req {
        R::Watch { pane_id, .. } | R::State { pane_id } | R::BlockedOptions { pane_id } => {
            Some(*pane_id)
        }
        R::SubmitLine(submit) => Some(submit.pane_id),
        R::Complete(complete) => Some(complete.pane_id),
        R::AnswerBlocked(answer) => Some(answer.pane_id),
        R::History(_) | R::FileSearch(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A guest who drives may start an agent under the host default, but never choose one of
    /// the owner's accounts or open a sign-in.
    #[test]
    fn choosing_an_account_needs_the_owner() {
        let session = SessionId(1);
        let tab = |launch| LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch,
        };
        let agent = |account: Option<&str>| PaneLaunch::AccountAgent {
            agent: proto::AgentKind::Claude,
            account: account.map(str::to_owned),
            resume: None,
            cwd: None,
        };
        assert_eq!(
            op(&tab(agent(None))),
            (Need::Drive, Target::Session(session))
        );
        assert_eq!(
            op(&tab(agent(Some(proto::SYSTEM_ACCOUNT)))),
            (Need::Drive, Target::Session(session))
        );
        assert_eq!(
            op(&tab(agent(Some("a1b2c3d4")))),
            (Need::Own, Target::Session(session))
        );
        let sign_in = PaneLaunch::AccountSignIn {
            agent: proto::AgentKind::Codex,
            account: "a1b2c3d4".into(),
            device_code: true,
        };
        let split = LayoutOp::Split {
            pane_id: PaneId(2),
            axis: proto::Axis::Horizontal,
            launch: sign_in,
        };
        assert_eq!(op(&split), (Need::Own, Target::SessionOf(PaneId(2))));
        assert!(chooses_account(&split));
        let accounts = WorkspaceRequest::AccountSetDefault {
            agent: proto::AgentKind::Claude,
            project: None,
            account: None,
        };
        assert_eq!(workspace(&accounts), (Need::Own, Target::Daemon));
    }

    /// A driver may open tabs, but bringing back a closed pane (which can resume the owner's
    /// agent session) is the owner's.
    #[test]
    fn reopening_a_closed_pane_needs_the_owner() {
        let session = SessionId(1);
        let reopen = || PaneLaunch::Reopen {
            pane_id: PaneId(4),
            cwd: None,
        };
        let shell = LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Shell { cwd: None },
        };
        assert_eq!(op(&shell), (Need::Drive, Target::Session(session)));
        let tab = LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: reopen(),
        };
        assert_eq!(op(&tab), (Need::Own, Target::Session(session)));
        let split = LayoutOp::Split {
            pane_id: PaneId(2),
            axis: proto::Axis::Horizontal,
            launch: reopen(),
        };
        assert_eq!(op(&split), (Need::Own, Target::SessionOf(PaneId(2))));
    }
}
