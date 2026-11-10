import DesignSystem
import HostKit
import PaneLayout

/// Moving panes between tabs and merging tabs. Panes move only within their host: the process
/// stays where it runs.
extension Workspace {
    /// Whether panes can move between this host's tabs: always in a layout the app keeps itself
    /// (this device, plain SSH); on a daemon that offers it.
    var canMovePanes: Bool {
        guard let daemon = host as? DaemonConnection else { return true }
        return daemon.daemonInfo?.paneMoves == true
    }

    func canMoveToNewTab(_ pane: PaneId) -> Bool {
        canMovePanes && (session.tab(containing: pane)?.root.panes.count ?? 0) > 1
    }
}

extension WindowModel {
    /// The tabs on `workspace`'s host a pane or tab can move into, besides `tab` (tabs carrying
    /// a mixed tab are left out: their panes show there).
    func moveTargets(in workspace: Workspace, besides tab: TabId?) -> [Tab] {
        guard workspace.canMovePanes else { return [] }
        return (groups.group(workspace.groupId)?.tabs ?? []).filter { $0.id != tab }
    }

    var canMovePaneToNewTab: Bool {
        guard destination == .terminal else { return false }
        if let mixed = activeMixed {
            guard mixed.leaves.count > 1 else { return false }
            if mixed.focusedEditor != nil { return true }
            return mixed.focusedMember.flatMap { workspace(ofGroup: $0.hostId) }?.canMovePanes == true
        }
        guard let workspace, let pane = workspace.focusedPane else { return false }
        return workspace.canMoveToNewTab(pane)
    }

    /// ⌥⇧⌘T: the focused pane (or `pane`) leaves for a new tab right after its own, focused. In a
    /// mixed tab a host pane goes to a tab on its host, an editor to a VS Code tab.
    func movePaneToNewTab(_ pane: PaneId? = nil, in workspace: Workspace? = nil) {
        if pane == nil, let mixed = activeMixed {
            return moveLeafToNewTab(mixed)
        }
        guard let workspace = workspace ?? self.workspace, let pane = pane ?? workspace.focusedPane else { return }
        guard workspace.canMovePanes else { return moveUnsupported(workspace) }
        guard workspace.canMoveToNewTab(pane) else { return }
        destination = .terminal
        workspace.apply(.movePaneToNewTab(pane))
    }

    func movePane(_ pane: PaneId, in workspace: Workspace, toTab target: Tab) {
        guard workspace.canMovePanes else { return moveUnsupported(workspace) }
        destination = .terminal
        if workspace.groupId != currentGroupId || activeMixedTab != nil { focus(TabRef(hostId: workspace.groupId, tab: target.id)) }
        workspace.apply(.movePane(pane, beside: target.root.trailingPane(along: .horizontal), side: .right))
    }

    /// Merges `tab` into `target` as a split beside `pane` on `side` (a dropped tab), or beside
    /// the target's trailing pane on the right (Merge Into Tab ▸).
    func mergeTab(_ tab: TabId, in workspace: Workspace, into target: Tab, beside pane: PaneId? = nil, side: Direction = .right) {
        guard workspace.canMovePanes else { return moveUnsupported(workspace) }
        guard tab != target.id else { return }
        destination = .terminal
        if workspace.groupId != currentGroupId || activeMixedTab != nil { focus(TabRef(hostId: workspace.groupId, tab: target.id)) }
        workspace.apply(.mergeTab(tab, beside: pane ?? target.root.trailingPane(along: .horizontal), side: side))
    }

    /// The tabs a window-owned tab (pages, editors, tools; no host panes) can merge into.
    func windowTabMergeTargets(besides id: TabId) -> [TabRef] {
        guard composites.tab(id)?.members.isEmpty == true else { return [] }
        return groups.tabs.filter { $0 != Self.mixedRef(id) }
    }

    /// Merges window tab `id` into `target` as a split beside `pane` (a host tab's pane, a window
    /// tab's leaf; else its last) on `side`. A host tab becomes a mixed tab in its place, in its
    /// project.
    func mergeWindowTab(_ id: TabId, into target: TabRef, beside pane: PaneId? = nil, side: Direction = .right) {
        destination = .terminal
        if target.hostId == HostGroups.mixedId {
            guard composites.merge(id, into: target.tab, beside: pane, side: side) else { return }
            focus(target)
            return
        }
        // Planned from before the merge: a host tab carrying a mixed tab leaves its project's
        // listing, and a project left with no tab listed with it.
        let planner = groups.planner()
        let project = planner.project(of: target)
        guard let hostTab = workspace(ofGroup: target.hostId)?.session.tabs.first(where: { $0.id == target.tab }),
              let merged = composites.merge(id, intoHost: target.hostId, tab: hostTab, beside: pane, side: side)
        else { return }
        if pairedTab == target { pairedTab = nil }
        let mergedRef = Self.mixedRef(merged)
        if let project, let index = project.tabs.firstIndex(of: target) {
            groups.apply(planner.move(mergedRef, into: project.id, at: index))
        }
        focus(mergedRef)
    }

    private func moveLeafToNewTab(_ mixed: CompositeTab) {
        guard canMovePaneToNewTab else {
            if let host = mixed.focusedMember?.hostId, let open = workspace(ofGroup: host) { moveUnsupported(open) }
            return
        }
        let member = mixed.focusedMember
        if let editorTab = composites.moveToNewTab(leaf: mixed.focusedLeaf, in: mixed.id) {
            focusMixedTab(editorTab)
        } else if let member {
            activeMixedTab = nil
            focus(pane: member.pane, onGroup: member.hostId)
        }
    }

    private func moveUnsupported(_ workspace: Workspace) {
        toasts.show(Toast(
            "Update the helper on \(groupName(workspace.groupId)) to move panes between tabs",
            systemImage: "arrow.up.circle", style: .neutral))
    }
}
