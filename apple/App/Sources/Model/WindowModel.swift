import DesignSystem
import Foundation
import HostKit
import Observation
import PaneLayout

/// What the detail column (or the iPhone tab) shows.
enum Destination: Hashable {
    case terminal
    case inbox
    case hosts
}

/// What the command palette lists: everything, every tab on every host (Go to Tab… ⌘P), or the
/// hosts a new tab can open on (⌥⌘T).
enum PaletteMode: Equatable {
    case commands
    case goToTab
    case newTabOnHost
}

/// Modal surfaces. One at a time, like the system's own sheets.
enum SheetRoute: String, Identifiable {
    case pairing, launchAgent, invite, links, diff, files, browser, editor, settings
    var id: String { rawValue }
}

/// One window's UI state and the data sources behind its screens. App-wide data (hosts,
/// connections, workspaces) lives in `AppModel`; this holds what the window shows and adapts
/// those models to the screens' protocols (`ScreenModels.swift`). With `-mock` the screens read
/// `MockData.swift` instead, for screenshots.
///
/// A window shows every open host at once (`groups`): each host keeps its connection and its
/// workspace while it is open, and the window's `target` only picks which one the detail column
/// shows. Selecting a tab on another host is a switch of `target`, never a reconnect.
@MainActor
@Observable
final class WindowModel {
    var destination = Destination.terminal
    var sheet: SheetRoute?
    var isPaletteShown = false {
        didSet { if !isPaletteShown { paletteMode = .commands } }
    }
    var paletteMode = PaletteMode.commands
    var isSearchShown = false
    var searchNeedle = ""
    /// The Add Host sheet's starting mode and destination (quick connect pre-fills SSH).
    var pairingMode = PairingSheet.Mode.ssh
    var pairingDestination = ""
    /// Every host this window shows at once (sidebar groups, the unified tab order).
    let groups: HostGroups
    /// What the detail column shows: this device or a host (`show`, `focus`).
    private(set) var target = WorkspaceTarget.local
    /// The workspace of each group (this device and every open host), kept for as long as the
    /// host is open so switching to it is instant: its panes keep streaming in the background.
    private(set) var workspaces: [String: Workspace] = [:]
    /// The workspace on screen (the target's).
    private(set) var workspace: Workspace? {
        didSet {
            if workspace !== oldValue { followConnection() }
            if workspace != nil { ActiveWindow.workspace = workspace }
            workspace?.onNewTabUnavailable = { [weak self] in self?.newTab() }
        }
    }
    /// The design fixtures' stand-in connection state (`-screen reconnect`).
    var connectionOverride: ConnectionState?
    /// The window's host link in the design system's words; `.connected` for the local workspace.
    private(set) var liveConnection = ConnectionState.connected

    let app: AppModel
    let hosts: any HostDirectory
    let agents: any AgentFeed
    let paneStatus: any PaneStatusSource
    let files: any FileSource
    let diffs: any DiffSource
    let toasts = ToastCenter()

    @ObservationIgnored private var downSince: Date?
    /// A restored tab to select once its host's layout arrives.
    @ObservationIgnored private var pendingFocus: TabRef?

    init(app: AppModel) {
        self.app = app
        let local = app.workspace(for: .local)
        groups = HostGroups(
            hosts: app.hosts,
            local: LaunchOptions.hasLocalShell ? local.map { HostGroups.Local(name: Self.deviceName, layout: $0.layout) } : nil)
        files = MockFileSource()
        diffs = MockDiffSource()
        if LaunchOptions.mock {
            hosts = MockHostDirectory()
            agents = MockAgentFeed()
            paneStatus = MockPaneStatus()
        } else {
            let live = LiveHostDirectory(app: app)
            hosts = live
            agents = LiveAgentFeed(hosts: app.hosts)
            let status = LivePaneStatus()
            paneStatus = status
            live.window = self
            status.window = self
        }
        ActiveWindow.register(self)
        if let local { workspaces[HostGroups.localId] = local }
        workspace = local
        followGroups()
    }

    var connection: ConnectionState { connectionOverride ?? liveConnection }

    var needsYouCount: Int { agents.items.filter(\.state.needsYou).count }

    /// The window's host as the chrome names it: the host's name, or this device.
    var hostName: String {
        if LaunchOptions.mock { return connectionOverride == nil ? Self.deviceName : "studio" }
        guard let id = workspace?.hostId else { return Self.deviceName }
        return app.hosts.record(id)?.name ?? id
    }

    /// Whether the window shows a remote host.
    var isRemote: Bool { workspace?.isRemote ?? false }

    static var deviceName: String {
        #if os(macOS)
        "This Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        #endif
    }

    // MARK: Actions

    /// Add Host, optionally straight into SSH with a destination typed elsewhere.
    func addHost(mode: PairingSheet.Mode = .ssh, destination: String = "") {
        pairingMode = mode
        pairingDestination = destination
        sheet = .pairing
    }

    /// Retry from the reconnect card and banners.
    func retryConnection() {
        if connectionOverride != nil { connectionOverride = nil; return }
        workspace?.host?.retry()
    }

    /// Leaves the window's host: it closes in this window (the host stays saved) and the
    /// nearest tab on another host takes over.
    func disconnect() {
        if connectionOverride != nil { connectionOverride = nil; return }
        guard let id = workspace?.hostId else { return }
        closeHost(id)
    }

    func report(_ error: any Error, _ prefix: String) {
        toasts.show(Toast("\(prefix): \(SshErrorText.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
    }

    // MARK: Hosts and tabs across hosts

    /// The group on screen: this device or the host's id.
    var currentGroupId: String { workspace?.hostId ?? HostGroups.localId }

    /// The tab on screen, as a reference that names its host.
    var currentTab: TabRef? {
        workspace?.session.activeTabId.map { TabRef(hostId: currentGroupId, tab: $0) }
    }

    func workspace(ofGroup id: String) -> Workspace? {
        workspaces[id]
    }

    /// Shows a target in this window: this device, or a host (opened and kept open, connecting
    /// it if needed). A host already open shows at once: nothing redials.
    func show(_ selected: WorkspaceTarget) {
        if case .host(let id) = selected {
            do {
                try groups.open(id)
            } catch {
                report(error, "Couldn't open \(app.hosts.record(id)?.name ?? id)")
            }
        }
        if selected != target { AppModel.log.info("show \(String(describing: selected), privacy: .public)") }
        target = selected
        syncWorkspaces()
    }

    /// Selects a tab on any host: the window switches to that host's workspace (already live)
    /// and the host selects the tab.
    func focus(_ ref: TabRef) {
        destination = .terminal
        if ref.hostId != currentGroupId { show(ref.hostId == HostGroups.localId ? .local : .host(ref.hostId)) }
        if workspace?.session.activeTabId != ref.tab { workspace?.selectTab(ref.tab) }
    }

    /// Focuses a pane on any host (the sidebar's agent rows).
    func focus(pane: PaneId, onGroup id: String) {
        guard let tab = workspaces[id]?.session.tabs.first(where: { $0.root.panes.contains(pane) }) else { return }
        focus(TabRef(hostId: id, tab: tab.id))
        workspace?.apply(.focus(pane))
    }

    /// ⌘T (the current host), ⌥⌘T's choice or a group's +: a new tab on that host. Where this
    /// device has no shell (iPhone, iPad) a new tab goes to an open host, else Add Host.
    func newTab(onGroup id: String? = nil) {
        guard let host = groups.newTabHost(preferred: id ?? currentGroupId) else {
            if let id, id != HostGroups.localId, groups.group(id) != nil {
                // A host still connecting: show it; the tab comes with its first layout.
                show(.host(id))
                return
            }
            addHost()
            return
        }
        destination = .terminal
        if host != currentGroupId { show(host == HostGroups.localId ? .local : .host(host)) }
        workspace?.apply(.newTab)
    }

    /// ⌥⌘T: the host picker (the palette listing "New Tab on …" per host).
    func showHostPicker() {
        paletteMode = .newTabOnHost
        isPaletteShown = true
    }

    /// ⌘P: Go to Tab… across every host.
    func showTabFinder() {
        paletteMode = .goToTab
        isPaletteShown = true
    }

    /// ⌘1…⌘8 across every host's tabs; ⌘9 the last.
    func selectTab(shortcut number: Int) {
        if let ref = groups.tab(forShortcut: number) { focus(ref) }
    }

    /// ⇧⌘] / ⇧⌘[: the next or previous tab, across host boundaries.
    func selectTab(offset: Int) {
        if let ref = groups.tab(after: currentTab, offset: offset) { focus(ref) }
    }

    /// Closes a host in this window (drops its connection; it stays saved). If it was on screen,
    /// the next tab in the unified list takes over, else this device.
    func closeHost(_ id: String) {
        let wasShown = currentGroupId == id
        let others = groups.tabs.filter { $0.hostId != id }
        groups.close(id)
        workspaces[id] = nil
        guard wasShown else { return }
        if let next = others.first { focus(next) } else { show(.local) }
    }

    /// A host was forgotten (Hosts ▸ Forget): it leaves the window too.
    func forgetHost(_ id: String) {
        let wasShown = currentGroupId == id
        groups.forget(id)
        workspaces[id] = nil
        if wasShown { show(.local) }
    }

    /// The host on screen has no tabs left (its last one closed): go to the nearest tab on
    /// another host, if any.
    func tabsEmptied() {
        guard workspace?.session.tabs.isEmpty == true else { return }
        if let next = groups.tabs.first(where: { $0.hostId != currentGroupId }) { focus(next) }
    }

    /// Launch restore: reopens the hosts this window had open and selects the last-focused tab
    /// once its host has a layout (a daemon's arrives after connecting).
    func restore(openHosts ids: [String], collapsed: Set<String>, focus ref: TabRef?) {
        groups.restore(ids)
        groups.collapsed = collapsed.intersection(Set(ids))
        syncWorkspaces()
        guard let ref, ref.hostId != HostGroups.localId else {
            // Local shells do not outlive the app: this device's tabs are new ones.
            return
        }
        guard groups.group(ref.hostId) != nil else { return }
        show(.host(ref.hostId))
        pendingFocus = ref
        Task { [weak self] in
            for _ in 0..<300 {
                guard let self, let pending = self.pendingFocus else { return }
                if let tabs = self.workspaces[pending.hostId]?.session.tabs, !tabs.isEmpty {
                    if tabs.contains(where: { $0.id == pending.tab }), self.currentGroupId == pending.hostId {
                        self.workspaces[pending.hostId]?.selectTab(pending.tab)
                    }
                    self.pendingFocus = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// An agent's state in a pane of any group: the daemon's report for hosts; this device's
    /// stand-ins (`-mock`) for local panes.
    func agentState(ofPane pane: PaneId, onGroup id: String) -> DesignSystem.AgentState? {
        if id == HostGroups.localId { return paneStatus.state(of: pane.description) }
        return (app.hosts.connection(id) as? DaemonConnection)?.meta[pane]?.agent.map { DesignSystem.AgentState($0.state) }
    }

    /// The program that reports an agent state in a pane of any group.
    func agentProgram(ofPane pane: PaneId, onGroup id: String) -> String? {
        if id == HostGroups.localId { return paneStatus.program(of: pane.description) }
        return (app.hosts.connection(id) as? DaemonConnection)?.meta[pane]?.agent?.kind
    }

    /// Keeps a workspace for every open host whose connection exists (a new one when a host's
    /// connection object is replaced, plain SSH → daemon), and the target's on screen.
    func syncWorkspaces() {
        var next: [String: Workspace] = [:]
        if let local = app.workspace(for: .local) { next[HostGroups.localId] = local }
        for group in groups.groups where !group.isLocal && app.hosts.connection(group.id) != nil {
            next[group.id] = app.workspace(for: .host(group.id))
        }
        if next.count != workspaces.count || next.contains(where: { workspaces[$0.key] !== $0.value }) {
            workspaces = next
        }
        let shown: Workspace? = switch target {
        case .local: next[HostGroups.localId]
        case .host(let id): next[id] ?? app.workspace(for: target)
        }
        if shown !== workspace { workspace = shown }
    }

    /// Re-syncs when hosts open, close, are forgotten or swap their connection.
    private func followGroups() {
        withObservationTracking {
            _ = groups.openHosts
            _ = app.hosts.records.count
            for connection in app.hosts.connections.values { _ = ObjectIdentifier(connection) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncWorkspaces()
                self?.followGroups()
            }
        }
    }

    // MARK: Connection state

    /// Mirrors the window's host status into `liveConnection`, remembering when it went down so
    /// the reconnect card can say how long ago output last arrived.
    private func followConnection() {
        let status = workspace?.host?.status
        if status?.isLive ?? true {
            downSince = nil
        } else if downSince == nil {
            downSince = .now
        }
        // No host: this device's own shell is "connected"; an iPhone or iPad without one is not.
        let next = status.map { ConnectionState($0, since: downSince ?? .now) } ?? (LaunchOptions.hasLocalShell ? .connected : .disconnected)
        if next != liveConnection { liveConnection = next }
        guard let host = workspace?.host else { return }
        let observed = workspace
        withObservationTracking {
            _ = host.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // Only the host on screen drives the window's state.
                guard let self, self.workspace === observed else { return }
                self.followConnection()
            }
        }
    }
}

extension ConnectionState {
    init(_ status: ConnectionStatus, since: Date) {
        switch status {
        case .connected:
            self = .connected
        case .idle, .connecting, .suspended:
            self = .connecting
        case .reconnecting(let attempt, _):
            self = .reconnecting(attempt: Int(max(attempt, 1)), since: since)
        case .offline(let reason):
            self = .unreachable(reason: reason, hint: "Sessions resume when the network is back.")
        case .needsAttention(let reason):
            self = .unreachable(reason: reason, hint: nil)
        }
    }
}

/// Launch arguments for design review and screenshots:
/// `-mock` fills the screens with sample hosts, agents and statuses; `-screen <name>` opens
/// straight to one screen.
enum LaunchOptions {
    static let mock = ProcessInfo.processInfo.arguments.contains("-mock")
    static let screen: String? = UserDefaults.standard.string(forKey: "screen")
    /// Whether this device offers a local shell: always on the Mac; on iPhone and iPad only the
    /// echo stand-in, so only for UI tests (`-localEcho YES`), `-mock` and design fixtures. A real
    /// iOS install starts on the welcome and Hosts screens, never in a fake shell.
    static var hasLocalShell: Bool {
        #if os(macOS)
        true
        #else
        mock || screen != nil || UserDefaults.standard.bool(forKey: "localEcho")
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
