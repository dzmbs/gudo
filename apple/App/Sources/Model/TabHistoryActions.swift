import DesignSystem
import Foundation
import HostKit
import PaneLayout
import SwiftUI
import GudoCore

// Tab history in a window: closing tabs into Recently Closed and bringing them back where they
// were, "A New Terminal" at launch, the idle-tab suggestion, and the sidebar's multi-selection.

extension WindowModel {
    // MARK: Closing

    /// Closes tabs (host tabs and the window's own), each host tab kept in Recently Closed; tabs
    /// closed together come back together (⇧⌘T, Undo).
    func closeTabs(_ refs: [TabRef], undoable: Bool) {
        expandedTabs.subtract(refs)
        let batch = refs.count > 1 ? UUID() : nil
        var closed: [ClosedTab] = []
        for ref in refs {
            if ref.hostId == HostGroups.mixedId {
                closeWindowTab(ref.tab, undoable: false)
                continue
            }
            // The host's own layout: a host this window lists but has not shown has no window
            // workspace yet, and its tabs close all the same.
            guard let store = groups.layoutStore(ref.hostId), store.session.tabs.contains(where: { $0.id == ref.tab }) else { continue }
            if let entry = closedEntry(ref, batch: batch) { closed.append(entry) }
            if let workspace = workspace(ofGroup: ref.hostId) {
                workspace.apply(.closeTab(ref.tab))
            } else {
                store.apply(.closeTab(ref.tab))
            }
        }
        recentlyClosed.record(closed)
        tabSelection.keep(Set(groups.tabs))
        guard undoable, !closed.isEmpty else { return }
        let message = closed.count == 1 ? "Closed “\(closed[0].title)”" : "Closed \(closed.count) tabs"
        let ids = closed.map(\.id)
        offerUndo(message) { [weak self] in
            guard let self else { return }
            reopen(ids.compactMap { self.recentlyClosed.take($0) })
        }
    }

    /// What Recently Closed keeps of a tab about to close; nil for tabs that are not this
    /// device's to keep (a guest's view of someone else's host).
    func closedEntry(_ ref: TabRef, batch: UUID? = nil) -> ClosedTab? {
        guard let tab = groups.sessionTabs(of: ref.hostId)?.first(where: { $0.id == ref.tab }) else { return nil }
        let workspace = workspace(ofGroup: ref.hostId)
        let daemon = app.hosts.connection(ref.hostId) as? DaemonConnection
        if daemon?.multiplayer.isGuest == true { return nil }
        // The pane the host brings back: the agent's, else the focused one.
        let agentPane = tab.root.panes.first { daemon?.meta[$0]?.agent != nil }
        let pane = agentPane ?? tab.focused
        let directory = daemon?.meta[pane]?.cwd ?? workspace?.absoluteDirectory(of: tab)
        return groups.closedTab(
            ref, title: workspace?.title(of: tab) ?? tab.title ?? "Shell", name: tab.title, hostName: groups.group(ref.hostId)?.name ?? ref.hostId,
            pane: daemon == nil ? nil : pane.rawValue, directory: directory, agent: agentPane.flatMap { daemon?.meta[$0]?.agent?.kind },
            batch: batch)
    }

    /// ⌘W: a tab's last pane closes the tab (kept in Recently Closed); with several tabs
    /// selected in the sidebar, those tabs close.
    func closeFocusedPaneOrTab() {
        if tabSelection.isMultiple {
            requestCloseSelectedTabs()
            return
        }
        guard let workspace, let tab = workspace.session.activeTab else { return }
        if tab.root.panes.count == 1, let ref = currentTab {
            closeTabs([ref], undoable: false)
        } else {
            workspace.closeFocusedPane()
        }
    }

    // MARK: Reopening

    /// ⇧⌘T: the last close back (every tab closed with it too).
    func reopenLastClosed() {
        reopen(recentlyClosed.takeLatest())
    }

    /// History ▸ Show All Recently Closed…: the palette listing them, searchable.
    func showRecentlyClosed() {
        paletteMode = .recentlyClosed
        isPaletteShown = true
    }

    func reopenClosed(_ id: UUID) {
        if let entry = recentlyClosed.take(id) { reopen([entry]) }
    }

    /// Reopens closed tabs in order, each on its host, in its project at its place, in its last
    /// directory, its agent resuming its session; the last one is shown.
    func reopen(_ entries: [ClosedTab]) {
        guard !entries.isEmpty else { return }
        Task { @MainActor [weak self] in
            var last: TabRef?
            for entry in entries {
                guard let self else { return }
                if let ref = await self.reopenOne(entry) { last = ref }
            }
            if let self, let last {
                withAnimation(DS.Motion.snappy) { self.focus(last) }
            }
        }
    }

    private func reopenOne(_ entry: ClosedTab) async -> TabRef? {
        do {
            let ref: TabRef
            if entry.hostId != HostGroups.localId, app.hosts.record(entry.hostId)?.kind == .daemon {
                _ = try groups.open(entry.hostId)
                syncWorkspaces()
                guard let daemon = await readyDaemon(entry.hostId) else { throw HostError.notConnected }
                ref = try await daemon.reopenTab(closedPane: entry.pane, directory: entry.directory, name: entry.name ?? "")
            } else {
                // This device's shell or plain SSH: a new tab there (nothing outlives its close).
                guard let made = await newTabWaiting(onGroup: entry.hostId) else { throw HostError.notConnected }
                ref = made
                if let name = entry.name { workspace(ofGroup: entry.hostId)?.layout.apply(.rename(ref.tab, name)) }
            }
            guard await appeared(ref) else { return nil }
            withAnimation(DS.Motion.reorder) { groups.place(ref, as: entry) }
            AppModel.log.info("reopened \(entry.title, privacy: .private) on \(entry.hostId, privacy: .public)")
            return ref
        } catch {
            recentlyClosed.record(entry)
            toasts.show(Toast("Couldn't reopen “\(entry.title)”: \(SshErrorText.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            return nil
        }
    }

    /// The host's connection once it has a session to open tabs in (up to 15 s).
    private func readyDaemon(_ host: String) async -> DaemonConnection? {
        for _ in 0..<150 {
            if let daemon = app.hosts.connection(host) as? DaemonConnection, daemon.isReady, daemon.layout.sessionId != nil, daemon.status.isLive {
                return daemon
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// A new tab on a host without a daemon, once its layout has it.
    private func newTabWaiting(onGroup host: String) async -> TabRef? {
        let known = Set(groups.sessionTabs(of: host)?.map(\.id) ?? [])
        newTab(onGroup: host)
        for _ in 0..<50 {
            if let fresh = groups.sessionTabs(of: host)?.first(where: { !known.contains($0.id) }) {
                return TabRef(hostId: host, tab: fresh.id)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Whether `ref` is in its host's layout (a daemon's arrives a moment after the op).
    private func appeared(_ ref: TabRef) async -> Bool {
        for _ in 0..<50 {
            if groups.sessionTabs(of: ref.hostId)?.contains(where: { $0.id == ref.tab }) == true { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: Launch ("A New Terminal")

    /// What runs in a tab now, from what the hosts report without asking (agents, programs'
    /// own reports, a program in front of a local shell).
    func tabActivity(_ ref: TabRef) -> TabActivity {
        guard let tab = groups.sessionTabs(of: ref.hostId)?.first(where: { $0.id == ref.tab }) else { return TabActivity() }
        let daemon = app.hosts.connection(ref.hostId) as? DaemonConnection
        let workspace = workspace(ofGroup: ref.hostId)
        var activity = TabActivity()
        for pane in tab.root.panes {
            if daemon?.meta[pane]?.exit != nil { continue }
            if daemon?.meta[pane]?.agent != nil { activity.agent = true }
            if let report = daemon?.programs[pane], report.state != .idle { activity.agent = true }
            if let local = workspace?.pane(pane), workspace?.reportedProgram(of: local) != nil { activity.command = true }
        }
        return activity
    }

    /// "A New Terminal" at launch: the tabs each host reports first stay out of sight unless
    /// something runs in them, and one new terminal opens on This Mac (else the host used
    /// last, where the device has no shell of its own).
    func startFresh(lastHost: String?) {
        launchHiding = Set(groups.openHosts)
        if let helper = app.thisDeviceHostId {
            launchHiding.insert(helper)
            launchTerminalHost = helper
        } else if LaunchOptions.hasLocalShell {
            launchTerminalHost = HostGroups.localId
        } else {
            launchTerminalHost = lastHost.flatMap { groups.openHosts.contains($0) ? $0 : nil } ?? groups.openHosts.first
        }
        if launchTerminalHost == HostGroups.localId, groups.sessionTabs(of: HostGroups.localId)?.isEmpty != false {
            newTab(onGroup: HostGroups.localId)
        }
        Task { @MainActor [weak self] in await self?.settleLaunch() }
    }

    private func settleLaunch() async {
        let deadline = ContinuousClock.now + .seconds(30)
        while !launchHiding.isEmpty, ContinuousClock.now < deadline, !isClosed {
            for host in launchHiding {
                guard let tabs = groups.sessionTabs(of: host), app.hosts.connection(host)?.status.isLive == true else { continue }
                let found = tabs.map { TabRef(hostId: host, tab: $0.id) }
                withAnimation(DS.Motion.reorder) {
                    groups.hiddenTabs.formUnion(RestoreDecision.hidden(found, setting: .newTerminal, activity: tabActivity))
                }
                launchHiding.remove(host)
                if host == launchTerminalHost {
                    launchTerminalHost = nil
                    newTab(onGroup: host)
                }
                let hidden = found.filter { groups.hiddenTabs.contains($0) }
                Task { @MainActor [weak self] in await self?.revealRunningCommands(hidden) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        launchHiding = []
    }

    /// Hidden tabs where a command turns out to run (asked of the host: the program in front
    /// of each pane's shell) come back: running work is never out of sight.
    private func revealRunningCommands(_ refs: [TabRef]) async {
        for ref in refs {
            guard let daemon = app.hosts.connection(ref.hostId) as? DaemonConnection,
                  let tab = groups.sessionTabs(of: ref.hostId)?.first(where: { $0.id == ref.tab })
            else { continue }
            for pane in tab.root.panes {
                guard let assist = await daemon.paneAssist(pane), assist.runsCommand else { continue }
                withAnimation(DS.Motion.reorder) { groups.unhide(ref) }
                break
            }
        }
    }

    /// Reopen Previous Tabs (History, the sidebar's Restore row).
    func restoreHiddenTabs() {
        withAnimation(DS.Motion.reorder) { groups.restoreHiddenTabs() }
    }

    // MARK: Idle tabs

    /// Looks for idle tabs now and then (a moment after the window opens, then every half hour).
    func followIdleTabs() {
        guard !LaunchOptions.mock else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while let self, !self.isClosed {
                await self.refreshIdleTabs()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    /// Daemon tabs idle at a prompt, untouched for `IdleTabRule.days`, nothing running (the
    /// host is asked about each candidate's panes). Never the tab on screen.
    func refreshIdleTabs(now: Date = .now) async {
        var idle: [TabRef] = []
        for ref in groups.tabs where ref.hostId != HostGroups.mixedId && ref != currentTab {
            guard let daemon = app.hosts.connection(ref.hostId) as? DaemonConnection, daemon.status.isLive,
                  !daemon.multiplayer.isGuest,
                  let tab = groups.sessionTabs(of: ref.hostId)?.first(where: { $0.id == ref.tab })
            else { continue }
            let touched = TabTouches.shared.touched(ref, now: now)
            let activity = tabActivity(ref)
            // The cheap check first: most tabs are recent or busy.
            guard IdleTabRule.isIdle(TabIdleFacts(activity: activity, atPrompt: true, touched: touched), now: now) else { continue }
            var atPrompt = true
            var since: Date?
            for pane in tab.root.panes {
                guard let assist = await daemon.paneAssist(pane), !assist.runsCommand else {
                    atPrompt = false
                    break
                }
                if let changed = assist.foregroundSince { since = max(since ?? changed, changed) }
            }
            if IdleTabRule.isIdle(TabIdleFacts(activity: activity, atPrompt: atPrompt, touched: touched, foregroundSince: since), now: now) {
                idle.append(ref)
            }
        }
        if idle != idleTabs { withAnimation(DS.Motion.snappy) { idleTabs = idle } }
    }

    /// The suggestion's tap: the idle tabs close together, one Undo brings them back.
    func closeIdleTabs() {
        let refs = idleTabs
        withAnimation(DS.Motion.reorder) {
            idleTabs = []
            closeTabs(refs, undoable: true)
        }
    }

    /// Not now: their clocks start over, so they are suggested again only after another
    /// stretch untouched.
    func dismissIdleTabs() {
        for ref in idleTabs { TabTouches.shared.touch(ref) }
        withAnimation(DS.Motion.snappy) { idleTabs = [] }
    }

    // MARK: Selection

    /// A click or tap on a tab's row: shows the tab; with ⌘ toggles it in the selection, with
    /// ⇧ extends the selection to it (Finder). In touch selection mode a tap toggles.
    func clickTab(_ ref: TabRef, modifiers: EventModifiers = []) {
        if isSelectingTabs {
            tabSelection.toggle(ref, current: nil)
        } else if modifiers.contains(.command) {
            tabSelection.toggle(ref, current: currentTab)
        } else if modifiers.contains(.shift) {
            tabSelection.extend(to: ref, current: currentTab, in: groups.tabs)
        } else {
            tabSelection.clear()
            withAnimation(DS.Motion.snappy) { focus(ref) }
        }
    }

    /// The selected tabs in sidebar order.
    var selectedTabs: [TabRef] { tabSelection.ordered(groups.tabs) }

    /// Whether a row is part of a selection of several (bulk actions apply to it).
    func isInMultipleSelection(_ ref: TabRef) -> Bool {
        (tabSelection.isMultiple || isSelectingTabs) && tabSelection.contains(ref)
    }

    func selectAllTabs() {
        tabSelection.selectAll(groups.tabs)
    }

    func endTabSelection() {
        tabSelection.clear()
        isSelectingTabs = false
    }

    /// Close Tabs on the selection: asks once when any of them runs an agent or a command.
    func requestCloseSelectedTabs() {
        let refs = selectedTabs
        guard !refs.isEmpty else { return }
        if refs.contains(where: { tabActivity($0).isBusy }) {
            pendingBulkClose = refs
        } else {
            closeSelectedTabs(refs)
        }
    }

    func closeSelectedTabs(_ refs: [TabRef]) {
        withAnimation(DS.Motion.reorder) {
            closeTabs(refs, undoable: true)
            endTabSelection()
        }
    }

    /// Move to Project ▸ on the selection, in sidebar order at the project's end.
    func moveSelectedTabs(toProject id: String) {
        withAnimation(DS.Motion.reorder) {
            for ref in selectedTabs where groups.project(of: ref)?.id != id {
                groups.apply(groups.planner().move(ref, into: id, at: .max))
            }
            endTabSelection()
        }
    }

    /// New Project from Selected Tabs: named for the folder they share, its name open for typing.
    func newProjectFromSelectedTabs() {
        let refs = selectedTabs
        guard !refs.isEmpty else { return }
        withAnimation(DS.Motion.reorder) {
            newProject(from: refs)
            endTabSelection()
        }
    }

    /// The selection carried along by a drag of one of its rows.
    func carriedTabs(dragging ref: TabRef) -> [TabRef] {
        guard tabSelection.isMultiple, tabSelection.contains(ref) else { return [] }
        return selectedTabs.filter { $0 != ref }
    }
}

extension PaneAssist {
    /// Something other than the shell at its prompt is in front: a command, an editor, a REPL.
    var runsCommand: Bool {
        if case .running = prompt.phase { return true }
        guard let foreground else { return false }
        return foreground.profile != .shell
    }

    /// When the program in front last changed.
    var foregroundSince: Date? {
        foreground.map { Date(timeIntervalSince1970: Double($0.sinceMs) / 1000) }
    }
}
