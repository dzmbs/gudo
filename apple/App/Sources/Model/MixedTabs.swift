import DesignSystem
import Foundation
import HostKit
import PaneLayout
#if canImport(UIKit)
import UIKit
#endif

/// Mixed tabs (panes from several hosts in one tab) and Two Columns, as a window runs them
/// (docs/APP-ARCHITECTURE.md §19). The composites themselves live in `groups.composites`
/// (PaneLayout's `CompositeTabs`); this connects them to the window's workspaces: what each
/// host's layout is, where ops go, which host is on screen, and what each daemon hears.
extension WindowModel {
    var composites: CompositeTabs { groups.composites }

    /// The mixed tab on screen.
    var activeMixed: CompositeTab? { activeMixedTab.flatMap(composites.tab) }

    static func mixedRef(_ id: TabId) -> TabRef { TabRef(hostId: HostGroups.mixedId, tab: id) }

    // MARK: Wiring

    /// Called once from `start()`.
    func startMixedTabs() {
        composites.hostSession = { [weak self] id in self?.mixedHostSession(id) }
        composites.send = { [weak self] id, op in self?.sendToHost(id, op) ?? false }
        composites.onDissolve = { [weak self] id, rest in self?.mixedTabDissolved(id, into: rest) }
        composites.onAdopt = { [weak self] id, leaf in
            guard let self, self.activeMixedTab == id else { return }
            self.focusLeaf(leaf, inMixedTab: id)
        }
        followMixedHosts()
        followColumns()
    }

    /// A host's layout as mixed tabs may trust it: known (open here, ready) and live. A host
    /// that is down or still connecting is unknown, so its leaves stay (shown stale).
    private func mixedHostSession(_ id: String) -> Session? {
        guard let workspace = workspace(ofGroup: id) else { return nil }
        if let host = workspace.host, !(host.isReady && host.status.isLive) { return nil }
        return workspace.sharedLayout.session
    }

    /// An op from a mixed tab to a host's layout, through the window's workspace there (so the
    /// window adopts what it creates, as for its own ops).
    private func sendToHost(_ id: String, _ op: LayoutOp) -> Bool {
        guard let workspace = workspace(ofGroup: id) else { return false }
        switch op {
        case .newTab where !workspace.canOpenTabs:
            return false
        case .newTab, .split:
            guard workspace.isLayoutLive else {
                hostUnavailable(id)
                return false
            }
        default:
            break
        }
        workspace.apply(op)
        return true
    }

    private func hostUnavailable(_ id: String) {
        toasts.show(Toast("Not available until \(groupName(id)) is connected", systemImage: "network.slash", style: .neutral))
    }

    func groupName(_ id: String) -> String {
        groups.group(id)?.name ?? app.hosts.record(id)?.name ?? id
    }

    /// Keeps the composites in step with every host's layout and link, and each workspace's
    /// pane focus reaching the window.
    private func followMixedHosts() {
        guard !isClosed else { return }
        wireWorkspaces()
        withObservationTracking {
            _ = composites.tabs
            for open in workspaces.values {
                _ = open.sharedLayout.session
                _ = open.host?.status
                _ = open.host?.isReady
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.noteHostLinks()
                self.composites.reconcile()
                self.syncMixedFocus()
                self.followMixedHosts()
            }
        }
    }

    private func wireWorkspaces() {
        for (id, open) in workspaces where open.onPaneFocus == nil {
            open.onPaneFocus = { [weak self] pane in self?.paneFocused(pane, onGroup: id) }
        }
    }

    /// When each host's link went down, for the per-pane reconnect card in a mixed tab.
    private func noteHostLinks() {
        for (id, open) in workspaces {
            guard let host = open.host else { continue }
            if host.status.isLive || host.status == .suspended {
                hostDownSince[id] = nil
            } else if hostDownSince[id] == nil {
                hostDownSince[id] = .now
            }
        }
    }

    /// A host's link in the design system's words (this device is always connected).
    func connectionState(ofGroup id: String) -> ConnectionState {
        guard id != HostGroups.localId else { return .connected }
        guard let status = workspace(ofGroup: id)?.host?.status ?? app.hosts.connection(id)?.status else { return .disconnected }
        if case .idle = status { return .disconnected }
        return ConnectionState(status, since: hostDownSince[id] ?? .now)
    }

    // MARK: Focus

    /// Shows a mixed tab, its focused pane taking the keyboard.
    func focusMixedTab(_ id: TabId) {
        guard composites.tab(id) != nil else { return }
        destination = .terminal
        activeMixedTab = id
        syncMixedFocus()
    }

    /// Focuses one leaf of a mixed tab: the window's target becomes the leaf's host, so every
    /// action (find, links, prompts, drawing) acts on that pane.
    func focusLeaf(_ leaf: PaneId, inMixedTab id: TabId) {
        composites.apply(.focus(leaf), to: id)
        activeMixedTab = id
        syncMixedFocus()
    }

    /// Brings the target and the host's own focus in line with the mixed tab's focused pane. An
    /// editor's host becomes the target (⌘T, Files and the toolbar act there).
    func syncMixedFocus() {
        if let browser = activeMixed?.focusedBrowser {
            if let host = browser.hostId, currentGroupId != host, groups.group(host) != nil {
                show(.host(host), keepingMixedTab: true)
            }
            return
        }
        if let editor = activeMixed?.focusedEditor {
            if currentGroupId != editor.hostId, groups.group(editor.hostId) != nil {
                show(.host(editor.hostId), keepingMixedTab: true)
            }
            return
        }
        guard let mixed = activeMixed, let member = mixed.focusedMember, let open = workspace(ofGroup: member.hostId) else { return }
        if currentGroupId != member.hostId {
            show(member.hostId == HostGroups.localId ? .local : .host(member.hostId), keepingMixedTab: true)
        }
        if open.session.tab(containing: member.pane) != nil, open.focusedPane != member.pane {
            open.apply(.focus(member.pane))
        }
    }

    /// A pane's terminal took the keyboard (click, tap): the window follows it into a mixed tab
    /// or the other column.
    func paneFocused(_ pane: PaneId, onGroup id: String) {
        let member = HostPane(hostId: id, pane: pane)
        if let mixed = activeMixed, let leaf = mixed.leaf(for: member) {
            if mixed.focusedLeaf != leaf { focusLeaf(leaf, inMixedTab: mixed.id) }
            return
        }
        if let other = composites.tab(containing: member), let leaf = other.leaf(for: member) {
            focusLeaf(leaf, inMixedTab: other.id)
            return
        }
        if activeMixedTab != nil || id != currentGroupId { focus(pane: pane, onGroup: id) }
    }

    /// A composite came apart: down to one host it is that host's tab again (shown in its
    /// place); empty, the next tab takes over.
    private func mixedTabDissolved(_ id: TabId, into rest: CompositeTabs.TabRefParts?) {
        let ref = rest.map { TabRef(hostId: $0.hostId, tab: $0.tab) }
        AppModel.log.info("mixed tab \(id.rawValue) dissolved into \(ref?.description ?? "nothing", privacy: .public)")
        if pairedTab == Self.mixedRef(id) { pairedTab = ref }
        guard activeMixedTab == id else { return }
        activeMixedTab = nil
        if let ref {
            focus(ref)
        } else if let next = tabAfterClosing {
            focus(next)
        } else {
            show(.local)
        }
    }

    // MARK: Actions

    /// The mixed tab's own handling of a pane action (split on the pane's host, close on it,
    /// zoom, focus and resize within the tab). False: not a mixed tab, or not a pane action.
    func performInMixedTab(_ action: WorkspaceAction) -> Bool {
        guard destination == .terminal, let mixed = activeMixed else { return false }
        switch action {
        case .splitRight: splitInMixedTab(mixed, axis: .horizontal)
        case .splitDown: splitInMixedTab(mixed, axis: .vertical)
        case .closePane:
            composites.close(leaf: mixed.focusedLeaf, in: mixed.id)
            syncMixedFocus()
        case .toggleZoom: composites.apply(.toggleZoom, to: mixed.id)
        case .focus(let direction):
            composites.apply(.focusDirection(direction), to: mixed.id)
            syncMixedFocus()
        case .resize(let direction):
            composites.apply(.resize(mixed.focusedLeaf, direction, amount: 0.05), to: mixed.id)
        default:
            return false
        }
        return true
    }

    private func splitInMixedTab(_ mixed: CompositeTab, axis: Axis) {
        guard let host = mixed.focusedMember?.hostId else { return }
        guard mixedHostSession(host) != nil else { return hostUnavailable(host) }
        composites.split(mixed.id, axis: axis)
    }

    /// Hosts a pane can be split onto from the focused pane: every open host that can take a
    /// pane now, except the focused pane's own.
    var splitWithHostCandidates: [HostGroup] {
        let focusedHost = activeMixed?.focusedMember?.hostId ?? currentGroupId
        return groups.groups.filter { ($0.isLocal || $0.isReady) && $0.id != focusedHost }
    }

    /// Whether Split with Host can run: a pane is on screen and another host is open.
    var canSplitWithHost: Bool {
        destination == .terminal && (activeMixed != nil || workspace?.focusedPane != nil)
    }

    /// ⇧⌥⌘D / Pane ▸ Split with Host…: the palette lists the hosts to open the pane on.
    func showSplitWithHostPicker() {
        guard canSplitWithHost else { return }
        paletteMode = .splitWithHost
        isPaletteShown = true
    }

    /// Opens a pane on `host` beside the focused pane. A host tab becomes a mixed tab in its
    /// place (same tree, same panes); a mixed tab gains the pane.
    func split(withHost host: String, axis: Axis = .horizontal) {
        destination = .terminal
        if let mixed = activeMixed {
            guard mixedHostSession(host) != nil else { return hostUnavailable(host) }
            composites.split(mixed.id, onHost: host, axis: axis)
            return
        }
        guard let open = workspace, let tab = open.session.activeTab else { return }
        let own = currentGroupId
        if host == own {
            open.split(axis)
            return
        }
        guard mixedHostSession(own) != nil else { return hostUnavailable(own) }
        guard mixedHostSession(host) != nil else { return hostUnavailable(host) }
        let id = composites.make(fromHost: own, tab: tab)
        if pairedTab == TabRef(hostId: own, tab: tab.id) { pairedTab = nil }
        activeMixedTab = id
        composites.split(id, onHost: host, axis: axis)
        syncMixedFocus()
    }

    /// Closes a mixed tab: each host closes the panes it holds for it.
    func closeMixedTab(_ id: TabId) {
        let wasActive = activeMixedTab == id
        composites.closeTab(id)
        guard wasActive else { return }
        activeMixedTab = nil
        if let next = tabAfterClosing { focus(next) } else { show(.local) }
    }

    /// The tab shown after the one on screen closed: the one worked in before it (an editor tab
    /// gives way to the terminal it was opened from), else the first.
    private var tabAfterClosing: TabRef? {
        let all = groups.tabs
        if let last = lastTerminalTab, all.contains(last) { return last }
        return all.first
    }

    /// The name a mixed tab goes by: its own (the host tab it grew from, or a rename), else the
    /// focused pane's title.
    func title(ofMixedTab tab: CompositeTab) -> String {
        if let title = tab.title, !title.isEmpty { return title }
        if let browser = tab.focusedBrowser ?? (tab.isBrowserOnly ? tab.leaves.compactMap({ tab.browsers[$0] }).first : nil) {
            return title(ofBrowser: browser)
        }
        if let editor = tab.focusedEditor ?? (tab.isEditorOnly ? tab.leaves.compactMap({ tab.editors[$0] }).first : nil) {
            return editor.folderName
        }
        // A tool beside a terminal keeps the terminal's name for the tab.
        if tab.members.isEmpty, let tool = tab.focusedTool ?? tab.leaves.lazy.compactMap({ tab.tools[$0] }).first {
            return tool.tool.title
        }
        let member = tab.focusedMember ?? (tab.focusedTool != nil ? tab.leaves.lazy.compactMap({ tab.members[$0] }).first : nil)
        if let member, let open = workspace(ofGroup: member.hostId),
           var carrier = open.session.tab(containing: member.pane)
        {
            carrier.focused = member.pane
            return open.title(of: carrier)
        }
        return "Mixed"
    }

    /// The mark a window-owned tab shows: VS Code while an editor has its focus, else the
    /// focused pane's program.
    func programIdentity(ofMixedTab tab: CompositeTab) -> ProgramIdentity {
        if tab.focusedBrowser != nil || tab.isBrowserOnly { return .browser }
        if tab.focusedEditor != nil || tab.isEditorOnly { return .vscode }
        // A tool has no mark of its own: the tab's terminal keeps showing.
        let member = tab.focusedMember ?? tab.leaves.lazy.compactMap { tab.members[$0] }.first
        return member.map { programIdentity(ofPane: $0.pane, onGroup: $0.hostId) } ?? .shell
    }

    // MARK: What the daemons hear

    /// Each host's share of what the window shows: visible panes of the tab on screen (a mixed
    /// tab's across its hosts) and of the other column, and the focused pane for its own host
    /// only. A host absent from the result shows nothing in this window.
    func screenViews() -> [String: (focused: PaneId?, visible: [PaneId])] {
        var views: [String: (focused: PaneId?, visible: [PaneId])] = [:]
        func add(_ host: String, focused: PaneId? = nil, visible: [PaneId]) {
            var view = views[host] ?? (nil, [])
            if let focused { view.focused = focused }
            for pane in visible where !view.visible.contains(pane) { view.visible.append(pane) }
            views[host] = view
        }
        func addMixed(_ mixed: CompositeTab, focused: Bool) {
            for leaf in mixed.visibleLeaves {
                if let member = mixed.members[leaf] { add(member.hostId, visible: [member.pane]) }
            }
            if focused, let member = mixed.focusedMember { add(member.hostId, focused: member.pane, visible: []) }
        }
        if let mixed = activeMixed {
            addMixed(mixed, focused: true)
        } else if let open = workspace {
            let view = open.layout.view
            add(open.groupId, focused: view.focused, visible: view.visible)
        }
        if isTwoColumns, let paired = validPairedTab {
            if paired.hostId == HostGroups.mixedId {
                if let mixed = composites.tab(paired.tab) { addMixed(mixed, focused: false) }
            } else if let tab = workspace(ofGroup: paired.hostId)?.session.tabs.first(where: { $0.id == paired.tab }) {
                add(paired.hostId, visible: tab.zoomed.map { [$0] } ?? tab.root.panes)
            }
        }
        return views
    }

    // MARK: Restore

    /// Launch restore: the window's mixed tabs as saved. This device's own panes do not outlive
    /// the app, and hosts no longer open here are gone from the window: their panes leave.
    func restoreMixedTabs(_ saved: [CompositeTab], openHosts ids: [String]) {
        guard !saved.isEmpty else { return }
        AppModel.log.info("restoring \(saved.count) mixed tab(s): \(saved.map { tab in tab.leaves.compactMap { tab.members[$0]?.description } }, privacy: .public)")
        composites.restore(saved)
        let kept = Set(ids)
        for host in Set(saved.flatMap(\.hosts)) where host == HostGroups.localId || !kept.contains(host) {
            composites.dropHost(host)
        }
    }

    // MARK: Two Columns

    /// How this window uses its fold (never on an external display's copy).
    var foldLayout: FoldLayout {
        isPresentation ? .standard : FoldLayout.plan(fold)
    }

    /// Two Columns is on: the user's choice for this window, else on by itself while an open
    /// foldable's pages hold a tab each (the sidebar hidden; shown, it is the left page). A book
    /// always keeps its pages apart: a column never runs under an active fold. Never in compact
    /// width, nor on the deck of a half-folded screen.
    var isTwoColumns: Bool {
        guard !isPresentation, widthBucket != .compact else { return false }
        switch foldLayout {
        case .pages:
            if isSidebarShown { return false }
            return fold.posture == .book ? true : twoColumnsChoice ?? true
        case .deck:
            return false
        case .standard:
            return twoColumnsChoice ?? false
        }
    }

    /// View ▸ Two Columns. Across a fold the sidebar is the left page: turning columns on there
    /// gives that page to a tab.
    func toggleTwoColumns() {
        let on = !isTwoColumns
        twoColumnsChoice = on
        if on, case .pages = foldLayout, isSidebarShown { isSidebarShown = false }
        syncColumns()
    }

    /// The tabs in the left and right column (nil: that column is empty, waiting for a tab).
    var columns: (left: TabRef?, right: TabRef?)? {
        guard isTwoColumns, destination == .terminal, let current = currentTab else { return nil }
        let other = validPairedTab
        return currentColumnIsLeft ? (current, other) : (other, current)
    }

    /// The other column's tab while it still exists (and is not the current one).
    var validPairedTab: TabRef? {
        guard let pairedTab, pairedTab != currentTab, groups.tabs.contains(pairedTab) else { return nil }
        return pairedTab
    }

    /// The empty column's New Tab: the tab lands in that column.
    func newTabInOtherColumn() {
        columnAwaitsTab = true
        newTab()
    }

    private func followColumns() {
        guard !isClosed else { return }
        withObservationTracking {
            _ = currentTab
            _ = isTwoColumns
            _ = groups.tabs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.syncColumns()
                self.followColumns()
            }
        }
    }

    /// Keeps the columns put while focus moves: a tab chosen in the sidebar replaces the current
    /// column's; focus moving to the other column's tab swaps which column is current; a closed
    /// tab's column takes the next tab not shown.
    func syncColumns() {
        let current = currentTab
        defer { lastCurrentTab = current }
        guard isTwoColumns else {
            columnAwaitsTab = false
            return
        }
        if let current, let previous = lastCurrentTab, current != previous {
            if current == pairedTab || columnAwaitsTab {
                pairedTab = groups.tabs.contains(previous) ? previous : nil
                currentColumnIsLeft.toggle()
                columnAwaitsTab = false
            }
        }
        if validPairedTab == nil {
            let all = groups.tabs
            let start = current.flatMap { all.firstIndex(of: $0) } ?? -1
            let after = all.indices.map { all[(start + 1 + $0) % all.count] }
            pairedTab = after.first { $0 != current }
        }
    }
}
