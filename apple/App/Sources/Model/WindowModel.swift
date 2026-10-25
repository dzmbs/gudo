import DesignSystem
import Foundation
import HostKit
import Observation
import PaneLayout
import TerminalCore
import TerminalRenderer
import UnnamedCore

/// What the detail column (or the iPhone tab) shows.
enum Destination: String, Hashable {
    case terminal
    /// Every agent across hosts: what needs you, what runs, what finished.
    case inbox
    case hosts

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .inbox: "Agents"
        case .hosts: "Hosts"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .inbox: "sparkles.rectangle.stack"
        case .hosts: "server.rack"
        }
    }
}

/// What the command palette lists: everything, every tab on every host (Go to Tab… ⌘P), or the
/// hosts a new tab can open on (⌥⌘T).
enum PaletteMode: Equatable {
    case commands
    case goToTab
    case newTabOnHost
    /// Split with Host… (⇧⌥⌘D): the host the new pane opens on.
    case splitWithHost
    /// The focused pane's workflows ("/" in the palette; `Model/Workflows.swift`).
    case workflows
}

/// Modal surfaces. One at a time, like the system's own sheets.
enum SheetRoute: String, Identifiable {
    case pairing, launchAgent, invite, sharing, join, links, diff, files, browser, editor, settings, shortcuts, replays
    var id: String { rawValue }
}

/// One window's UI state and the data sources behind its screens. App-wide data (hosts,
/// connections, layouts, pane streams) lives in `AppModel`; this holds what the window shows,
/// its own workspace per host, and adapts those models to the screens' protocols
/// (`ScreenModels.swift`). With `-mock` the screens read `MockData.swift` instead, for
/// screenshots.
///
/// A window shows every open host at once (`groups`): each host keeps its connection and this
/// window's workspace on it while it is open, and the window's `target` only picks which one the
/// detail column shows. Selecting a tab on another host is a switch of `target`, never a
/// reconnect. Windows are independent (iPad scenes, Stage Manager, Mac windows): each selects its
/// own host, tab and pane, and has its own terminals on the shared streams.
@MainActor
@Observable
final class WindowModel {
    var destination = Destination.terminal {
        didSet { if destination != oldValue { reportViews() } }
    }
    var sheet: SheetRoute? {
        didSet {
            // Browsing tools open beside the pane, or in a window of their own (`ToolLeaves.swift`).
            if let route = sheet, presentTool(route) { sheet = nil }
        }
    }
    /// Opens a tool window (macOS), set by the window's view.
    @ObservationIgnored var openTool: ((ToolWindowRequest) -> Void)?
    /// The toolbar's host switcher is open.
    var isHostSwitcherShown = false
    /// What the Replays sheet shows.
    var replayRequest = ReplayRequest.all
    /// What the next New Agent sheet starts with, once: a prompt (Ask Agent about a command with
    /// no agent open), the host and repository whose + opened it.
    @ObservationIgnored var newAgentSeed = NewAgentSeed()
    /// The tab being dragged from this window's sidebar or strip (panes take it as a split).
    @ObservationIgnored var draggedTab: TabRef?
    var isPaletteShown = false {
        didSet {
            if !isPaletteShown { paletteMode = .commands }
            if isPaletteShown {
                git.refreshArchived()
                loadWorkflows()
            }
        }
    }
    var paletteMode = PaletteMode.commands
    /// The focused pane's workflows as last read (`loadWorkflows`), and that pane.
    var workflowList: WorkflowList?
    @ObservationIgnored var workflowPane: PaneId?
    @ObservationIgnored var workflowLoad: Task<Void, Never>?
    /// The workflow argument form or New Workflow panel over the window.
    var workflowPanel: WorkflowPanel?
    /// The sidebar (Safari's model): shown, it holds the tabs; hidden, the tabs move to a strip on
    /// top (unless `TabPlacement.showsTabBarKey` is off). Per window; the last choice is the next
    /// window's start.
    var isSidebarShown = TabPlacement.sidebarShown {
        didSet {
            TabPlacement.sidebarShown = isSidebarShown
            quietLayoutResizes()
        }
    }

    /// The grids about to change follow an animated layout change, not a resize the user is
    /// making: no cols × rows overlay counting through every frame of it.
    func quietLayoutResizes() {
        for workspace in workspaces.values { workspace.layoutChangeUntil = .now + .milliseconds(700) }
        // The terminals resize through the animation: their grids change once, as it settles.
        TerminalSurface.holdGrids(for: .seconds(DS.Motion.panelDuration))
    }
    var isSearchShown = false
    var searchNeedle = "" {
        didSet { if searchNeedle != oldValue { updateSearchCount() } }
    }
    /// Find matches the needle's case exactly (the bar's "Aa").
    var searchCaseSensitive = false {
        didSet { if searchCaseSensitive != oldValue { updateSearchCount() } }
    }
    /// Matches of `searchNeedle` in the focused pane's whole scrollback (daemon panes).
    var searchTotal: Int?
    @ObservationIgnored var searchCountTask: Task<Void, Never>?
    /// The searched pane's own search: its terminal's matches and the selected one (`PaneSearch.swift`).
    var searchStatus = SearchStatus.idle
    @ObservationIgnored weak var searchPane: Pane?
    /// Fetching older scrollback from the host to reach a match only the host still has.
    @ObservationIgnored var searchHistoryTask: Task<Void, Never>?
    /// The Add Host sheet's starting mode and destination (quick connect pre-fills SSH).
    var pairingMode = PairingSheet.Mode.ssh
    var pairingDestination = ""
    /// The invite link the Join sheet starts with (a `<scheme>://join/…` deep link).
    var joinInvite = ""
    /// Every host this window shows at once (sidebar groups, the unified tab order).
    let groups: HostGroups
    /// What the detail column shows: this device or a host (`show`, `focus`).
    private(set) var target = WorkspaceTarget.local
    /// This window's workspace on each group (this device and every open host), kept for as
    /// long as the host is open so switching to it is instant: its panes keep streaming in the
    /// background.
    private(set) var workspaces: [String: Workspace] = [:]
    /// The connection each host's workspace was made on (a new connection, plain SSH upgraded
    /// to the daemon, gets a new workspace).
    @ObservationIgnored private var workspaceConnections: [String: ObjectIdentifier] = [:]
    /// The window closed: its terminals stopped (`close()`).
    @ObservationIgnored private(set) var isClosed = false
    /// Whether the window is on screen (its scene is not in the background): the daemon only
    /// hears about panes a window shows.
    var isOnScreen = true {
        didSet { if isOnScreen != oldValue { reportViews() } }
    }
    /// The workspace on screen (the target's).
    private(set) var workspace: Workspace? {
        didSet {
            if workspace !== oldValue {
                followConnection()
                followView()
            }
            if workspace != nil, !isPresentation { ActiveWindow.workspace = workspace }
            workspace?.onNewTabUnavailable = { [weak self] in self?.newTab() }
            workspace?.onLayoutUnavailable = { [weak self] in
                guard let self else { return }
                toasts.show(Toast(layoutUnavailableHelp, systemImage: "network.slash", style: .neutral))
            }
        }
    }
    /// The design fixtures' stand-in connection state (`-screen reconnect`).
    var connectionOverride: ConnectionState?
    #if DEBUG
    /// The detail column's frame in window coordinates, for the dogfood runner's layout checks.
    @ObservationIgnored var detailFrame: CGRect = .zero
    #endif
    /// The window's host link in the design system's words; `.connected` for the local workspace.
    private(set) var liveConnection = ConnectionState.connected

    // MARK: Mixed tabs and Two Columns (Model/MixedTabs.swift)

    /// The mixed tab on screen (`groups.composites`), if any. The detail column shows it, and
    /// `target` follows its focused pane's host, so the window's actions act on that pane.
    var activeMixedTab: TabId? {
        didSet { if activeMixedTab != oldValue { reportViews() } }
    }
    /// Two Columns: the user's choice for this window; nil follows the window's shape (on for a
    /// foldable's open inner screen, `WidthBucket.isTwoSegment`).
    var twoColumnsChoice: Bool?
    /// The window's size (`WindowRoot` measures it): automatic Two Columns.
    var windowSize = CGSize.zero
    /// Two Columns: the tab in the column without focus, and which column has the current tab.
    var pairedTab: TabRef?
    var currentColumnIsLeft = true
    /// The tab on screen before the last change (Two Columns keeps it in the other column).
    @ObservationIgnored var lastCurrentTab: TabRef?
    /// Two Columns: the empty column asked for a new tab; it lands there.
    @ObservationIgnored var columnAwaitsTab = false
    /// When each host's link went down (the reconnect card's "last contact").
    @ObservationIgnored var hostDownSince: [String: Date] = [:]

    let app: AppModel
    let hosts: any HostDirectory
    let agents: any AgentFeed
    let paneStatus: any PaneStatusSource
    let files: any FileSource
    let diffs: any DiffSource
    /// The window's VS Code editors (`Model/EditorPanes.swift`): one per editor leaf.
    let editors: EditorPanes
    /// The window's browser pages (`Model/BrowserLeaves.swift`): one per browser leaf.
    let browsers = BrowserPanes()
    /// The tab worked in before an editor tab came forward (⌃⌘` goes back to it).
    @ObservationIgnored var lastTerminalTab: TabRef?
    /// The editor shown full screen while it has the focus (⌃⌘F, `isEditorFullScreen`).
    var fullScreenEditor: UUID?
    let ports: any PortSource
    let links: any LinkSource
    /// Agent plan usage per host (sidebar host headers, Inbox).
    let usage: any UsageFeed
    /// The host whose usage detail popover is open (from its meter or its menu).
    var usageDetailHost: String?
    /// The page the in-app browser opens (a forwarded port, a link).
    var browserURL: URL? {
        didSet {
            browserHost = nil
            browserSignInPane = nil
        }
    }
    /// The pane whose sign-in `browserURL` is (its code is typed there; `pastedSignInCode`).
    @ObservationIgnored var browserSignInPane: (hostId: String, pane: UInt64)?
    /// Callback ports of the sign-ins this window shows (`HostSignIn`).
    var signInPorts: Set<UInt16> = []
    /// The host whose dev server `browserURL` is (its web data store routes to it); set after
    /// `browserURL`, nil for other pages.
    var browserHost: String?
    let toasts = ToastCenter()
    /// Full screen's hint, shown under VS Code's title bar rather than over its controls.
    let fullScreenHints = ToastCenter()
    /// Agents on other tabs and hosts that need you or finished (`AgentToasts`).
    let agentToasts = AgentToasts()
    /// The git-native workspace of this window (worktree, pull request, scripts).
    let git = GitUI()

    @ObservationIgnored private var downSince: Date?
    /// A restored tab to select once its host's layout arrives.
    @ObservationIgnored private var pendingFocus: TabRef?

    /// An external display's presentation of another window (`ExternalDisplayRoot`): never the
    /// window menu commands act on.
    let isPresentation: Bool
    /// The size of the area the active tab's panes fill (the external display scales to it).
    var terminalArea = CGSize.zero

    init(app: AppModel, isPresentation: Bool = false) {
        self.app = app
        self.isPresentation = isPresentation
        Self.made += 1
        serial = Self.made
        groups = HostGroups(
            hosts: app.hosts,
            local: LaunchOptions.hasLocalShell ? HostGroups.Local(name: Self.deviceName, layout: app.localLayout) : nil)
        groups.helperServesLocal = { [weak app] in app?.thisDeviceHostId != nil }
        if LaunchOptions.mock || LaunchOptions.fakeUsage {
            let groups = groups
            usage = FakeUsageFeed { groups.groups.map { UsageHost(id: $0.id, name: $0.name) } }
        } else {
            usage = LiveUsageFeed(app: app)
        }
        if LaunchOptions.mock {
            hosts = MockHostDirectory()
            agents = MockAgentFeed()
            paneStatus = MockPaneStatus()
            files = MockFileSource()
            diffs = MockDiffSource()
            editors = EditorPanes { _ in MockEditorSource() }
            ports = MockPortSource()
            links = MockLinkSource()
        } else {
            let live = LiveHostDirectory(app: app)
            hosts = live
            let feed = LiveAgentFeed(hosts: app.hosts)
            agents = feed
            let status = LivePaneStatus()
            paneStatus = status
            let files = LiveFileSource(app: app)
            let diffs = LiveDiffSource(app: app)
            editors = EditorPanes { [weak app] member in
                guard let app else { return MockEditorSource() }
                return LiveEditorSource(app: app, pinned: member)
            }
            let ports = LivePortSource(app: app)
            let links = LiveLinkSource(app: app)
            self.files = files
            self.diffs = diffs
            self.ports = ports
            self.links = links
            live.window = self
            status.window = self
            feed.window = self
            files.window = self
            diffs.window = self
            ports.window = self
            links.window = self
        }
        git.window = self
        browsers.onPopup = { [weak self] opener, url in self?.openPopup(url, from: opener) }
        browsers.onPopupPane = { [weak self] opener, pane in self?.openPopup(pane.initialURL, from: opener, id: pane.id) }
        browsers.onClose = { [weak self] in self?.closeBrowser($0) }
        #if os(iOS)
        // A first guess from the screen until the window is measured (`WindowRoot`), so an
        // iPhone never draws the regular layout for a frame.
        if !isPresentation { widthBucket = WidthBucket.of(width: Double(UIScreen.main.bounds.width), current: nil) }
        #endif
    }

    #if os(iOS)
    /// The window's scene (`SceneReader`), to bring it forward.
    @ObservationIgnored weak var scene: UIWindowScene?

    /// Brings the n-th open window (in opening order) to the front (UI tests).
    func bringWindowForward(_ index: Int) {
        let windows = app.openWindows.filter { !$0.isPresentation }
        guard windows.indices.contains(index), let session = windows[index].scene?.session else { return }
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil)
    }
    #endif

    #if DEBUG
    /// UI tests: the window's content narrower than the window (`-windowWidth <pt>`, the
    /// probe's buttons, `<scheme>://debug/width/<pt>`), to cross the width boundary as Split
    /// View and Stage Manager do.
    var debugWidth: Double? = UserDefaults.standard.double(forKey: "windowWidth").nonZeroWidth
    #endif

    /// The order this window was made in (windows list in opening order).
    let serial: Int

    /// Window models made in this process (the probe shows it: one per window).
    static var made = 0

    /// Whether `start()` ran: the window is on screen and owns terminals.
    private(set) var isStarted = false

    /// The window appeared: it registers and opens this device's workspace. Not in `init`:
    /// SwiftUI may build a view's `@State` initial value more than once and keep only one, and
    /// a discarded model must own no terminals and count as no window.
    func start() {
        guard !isStarted, !isClosed else { return }
        isStarted = true
        if !isPresentation { ActiveWindow.register(self) }
        app.register(self)
        groups.isOpenElsewhere = { [weak self, weak app] id in
            guard let self, let app else { return false }
            return app.isHostOpen(id, elsewhereThan: self)
        }
        let local = app.makeWorkspace(for: .local)
        if let local { workspaces[HostGroups.localId] = local }
        workspace = local
        if let id = app.thisDeviceHostId { openThisDevice(id) }
        followGroups()
        startMixedTabs()
        followEditors()
        followFullScreen()
        followAgentToasts()
    }

    /// The window closed: its terminals stop and the daemons stop counting its panes as shown.
    /// Hosts stay connected and every pane stays in its host's layout (other windows, a window
    /// opened later, other devices).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        editors.stop()
        for open in workspaces.values {
            (open.host as? DaemonConnection)?.setWindowView(self, focused: nil, visible: [])
            open.close()
        }
        app.windowsChanged += 1
        AppModel.log.info("window closed")
    }

    var connection: ConnectionState { connectionOverride ?? liveConnection }

    var needsYouCount: Int { agents.items.filter(\.state.needsYou).count }

    /// The window's host as the chrome names it: the host's name, or this device.
    var hostName: String {
        if LaunchOptions.mock { return connectionOverride == nil ? Self.deviceName : "studio" }
        guard let id = workspace?.hostId else { return Self.deviceName }
        return app.hosts.record(id)?.name ?? id
    }

    var layoutUnavailableHelp: String { "Not available until \(hostName) is connected" }

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
        if let activeMixedTab { return TabRef(hostId: HostGroups.mixedId, tab: activeMixedTab) }
        return workspace?.session.activeTabId.map { TabRef(hostId: currentGroupId, tab: $0) }
    }

    func workspace(ofGroup id: String) -> Workspace? {
        workspaces[id]
    }

    /// Shows a target in this window: this device, or a host (opened and kept open, connecting
    /// it if needed). A host already open shows at once: nothing redials.
    func show(_ selected: WorkspaceTarget, keepingMixedTab: Bool = false) {
        if !keepingMixedTab { activeMixedTab = nil }
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
        if ref != currentTab { noteLeavingTab() }
        destination = .terminal
        if ref.hostId == HostGroups.mixedId {
            focusMixedTab(ref.tab)
            return
        }
        activeMixedTab = nil
        if ref.hostId != currentGroupId { show(ref.hostId == HostGroups.localId ? .local : .host(ref.hostId)) }
        if workspace?.session.activeTabId != ref.tab { workspace?.selectTab(ref.tab) }
    }

    /// Focuses a pane on any host (the sidebar's agent rows).
    func focus(pane: PaneId, onGroup id: String) {
        if let mixed = groups.composites.tab(containing: HostPane(hostId: id, pane: pane)),
           let leaf = mixed.leaf(for: HostPane(hostId: id, pane: pane))
        {
            destination = .terminal
            focusLeaf(leaf, inMixedTab: mixed.id)
            return
        }
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
        activeMixedTab = nil
        if host != currentGroupId { show(host == HostGroups.localId ? .local : .host(host)) }
        workspace?.apply(.newTab)
    }

    /// ⇧⌘N or a +'s New Agent: the New Agent sheet, on `host` (and `repo`) when given.
    func newAgent(onGroup host: String? = nil, repo: String? = nil) {
        newAgentSeed.host = host
        newAgentSeed.repo = repo
        sheet = .launchAgent
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
        let ref = groups.tab(forShortcut: number)
        AppModel.log.debug("⌘\(number) → \(ref?.description ?? "none", privacy: .public) from \(self.currentTab?.description ?? "none", privacy: .public)")
        if let ref { focus(ref) }
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
        let elsewhere = app.isHostOpen(id, elsewhereThan: self)
        if let closing = workspaces[id] {
            (closing.host as? DaemonConnection)?.setWindowView(self, focused: nil, visible: [])
            closing.close(ending: !elsewhere)
            if !elsewhere, let connection = closing.host { app.endSharedPanes(of: connection) }
        }
        groups.close(id)
        workspaces[id] = nil
        workspaceConnections[id] = nil
        guard wasShown else { return }
        if let next = others.first { focus(next) } else { show(home(leaving: id)) }
    }

    /// Where a window goes when nothing else is left: This Mac's helper while it serves the
    /// Mac and no plain shell is open, else this device's own workspace.
    func home(leaving id: String? = nil) -> WorkspaceTarget {
        guard let helper = app.thisDeviceHostId, helper != id, app.localLayout.session.tabs.isEmpty else { return .local }
        return .host(helper)
    }

    /// Opens This Mac's helper in this window, and shows it if the window shows nothing else.
    func openThisDevice(_ id: String) {
        _ = try? groups.open(id)
        if currentGroupId == HostGroups.localId, app.localLayout.session.tabs.isEmpty { show(.host(id)) }
    }

    /// A host was forgotten (Hosts ▸ Forget): it leaves the window too.
    func forgetHost(_ id: String) {
        let wasShown = currentGroupId == id
        groups.forget(id)
        workspaces[id]?.close(ending: true)
        workspaces[id] = nil
        workspaceConnections[id] = nil
        if wasShown { show(home(leaving: id)) }
    }

    /// The host on screen has no tabs left (its last one closed): go to the nearest tab on
    /// another host, if any.
    func tabsEmptied() {
        guard workspace?.session.tabs.isEmpty == true else { return }
        if let next = groups.tabs.first(where: { $0.hostId != currentGroupId }) { focus(next) }
    }

    /// Launch restore: reopens the hosts this window had open and selects the last-focused tab
    /// once its host has a layout (a daemon's arrives after connecting).
    func restore(openHosts ids: [String], collapsed: Set<String>, focus ref: TabRef?, mixedTabs: [CompositeTab] = []) {
        groups.restore(ids)
        groups.collapsed = collapsed.intersection(Set(ids))
        restoreMixedTabs(mixedTabs, openHosts: ids)
        syncWorkspaces()
        if let ref, ref.hostId == HostGroups.mixedId {
            select(ref, pane: nil)
            return
        }
        guard let ref, ref.hostId != HostGroups.localId else {
            // Local shells do not outlive the app: this device's tabs are new ones.
            return
        }
        guard groups.group(ref.hostId) != nil else { return }
        select(ref, pane: nil)
    }

    /// Shows a tab (and a pane in it) as soon as its host's layout has it: at once for this
    /// device, after connecting for a host. A tab the host no longer has leaves the host shown.
    func select(_ ref: TabRef, pane: PaneId?) {
        destination = .terminal
        if ref.hostId == HostGroups.mixedId {
            if groups.composites.tab(ref.tab) != nil { focusMixedTab(ref.tab) }
            return
        }
        show(ref.hostId == HostGroups.localId ? .local : .host(ref.hostId))
        pendingFocus = ref
        Task { [weak self] in
            for _ in 0..<300 {
                guard let self, let pending = self.pendingFocus, pending == ref else { return }
                if let workspace = self.workspaces[pending.hostId], !workspace.session.tabs.isEmpty {
                    if workspace.session.tabs.contains(where: { $0.id == pending.tab }), self.currentGroupId == pending.hostId {
                        if let pane, workspace.session.tab(containing: pane)?.id == pending.tab {
                            workspace.apply(.focus(pane))
                        } else {
                            workspace.selectTab(pending.tab)
                        }
                    }
                    self.pendingFocus = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Windows

    /// Opens a new window (`WindowRoot` sets it from SwiftUI's `openWindow`).
    @ObservationIgnored var openWindow: ((WindowRequest) -> Void)?

    /// The window's width bucket (`WindowRoot` measures it): compact or regular layout.
    var widthBucket: WidthBucket?
    /// How many times a grid change would have shown the cols × rows overlay (`-windowProbe`
    /// only): a layout switch must not add to it.
    var resizeOverlayShows = 0

    /// New Window (⌘N): the same hosts, on the same tab; from then on its own.
    func newWindow() {
        openWindow?(.like(self))
    }

    /// Open in New Window from a tab's context menu (or a tab dragged out on iPad).
    func openInNewWindow(_ ref: TabRef) {
        var request = WindowRequest(hosts: ref.hostId == HostGroups.localId ? [] : [ref.hostId], tab: ref)
        if let workspace = workspaces[ref.hostId], let tab = workspace.session.tabs.first(where: { $0.id == ref.tab }) {
            request.pane = tab.focused.rawValue
        }
        openWindow?(request)
    }

    /// Open in New Window from a host group's context menu.
    func openInNewWindow(host id: String) {
        let tab = workspaces[id]?.session.activeTab.map { TabRef(hostId: id, tab: $0.id) }
        openWindow?(WindowRequest(hosts: [id], tab: tab))
    }

    /// A new window's request: open its hosts and show its tab.
    func open(_ request: WindowRequest) {
        groups.restore(request.hosts)
        syncWorkspaces()
        if let tab = request.tab {
            select(tab, pane: request.pane.map(PaneId.init))
        } else if let first = request.hosts.first {
            show(.host(first))
        }
    }

    /// A Handoff (or a tab dragged out of another window): the same host, tab and pane, or the
    /// words for why not and a way to add the host.
    func `continue`(_ payload: HandoffPayload) {
        lastContinued = payload
        let resolution = payload.resolve(records: app.hosts.records)
        continuedResult = String(describing: resolution)
        switch resolution {
        case .host(let id, let tab, let pane):
            if let tab {
                select(TabRef(hostId: id, tab: tab), pane: pane)
            } else {
                destination = .terminal
                show(.host(id))
            }
            if let drawing = payload.drawing, let pane, payload.kind == .daemon {
                continueDrawing(drawing, pane: pane)
            }
        case .local(let tab, let pane):
            if let tab { select(TabRef(hostId: HostGroups.localId, tab: tab), pane: pane) }
        case .notPaired:
            handoffMissing = payload
        case .elsewhere:
            toasts.show(Toast(
                "That terminal runs on \(payload.device) itself, so it can't continue here",
                systemImage: "laptopcomputer.and.iphone", style: .neutral))
        }
    }

    /// Opens a continued drawing once its pane is up: draw mode on the placement (or the
    /// unplaced drawing), or the canvas pane focused. The pane connects, attaches and gets its
    /// placements after the window switched to it, so this retries for a while.
    private func continueDrawing(_ drawing: HandoffPayload.Drawing, pane: PaneId) {
        drawingContinuation?.cancel()
        continuedDrawing = nil
        drawingContinuation = Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled, ContinuousClock.now - start < .seconds(40) {
                let settled = ContinuousClock.now - start > .seconds(3)
                if let paneDrawing = PaneDrawing.of(pane), self?.workspace?.panes[pane] != nil,
                   paneDrawing.continueDrawing(drawing, settled: settled)
                {
                    self?.continuedDrawing = "\(drawing.canvas ? "canvas" : "draw"):\(drawing.artifact)"
                    AppModel.log.info("continued drawing \(drawing.artifact) on pane \(pane.rawValue)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, let self else { return }
            self.toasts.show(Toast(
                "The drawing from \(self.lastContinued?.device ?? "your other device") isn't in that pane anymore",
                systemImage: "scribble.variable", style: .neutral))
        }
    }

    @ObservationIgnored private var drawingContinuation: Task<Void, Never>?
    /// The drawing a continued activity opened (`draw:<artifact>` / `canvas:<artifact>`; probe).
    private(set) var continuedDrawing: String?

    /// A continued activity whose host is not paired here (the window offers to add it).
    var handoffMissing: HandoffPayload?
    /// The last activity continued here (UI tests read it through the probe).
    @ObservationIgnored private(set) var lastContinued: HandoffPayload?
    /// How the last continued activity resolved (the probe shows it).
    private(set) var continuedResult: String?

    /// Add Host for a host another device continued from: SSH pre-filled with its address, a
    /// pairing ticket for a daemon.
    func addMissingHost() {
        guard let payload = handoffMissing else { return }
        handoffMissing = nil
        if let ssh = payload.ssh {
            addHost(mode: .ssh, destination: ssh)
        } else {
            addHost(mode: .ticket)
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

    /// Keeps this window's workspace for every host it has open whose connection exists (a new
    /// one when a host's connection object is replaced, plain SSH → daemon), and the target's on
    /// screen. Hosts other windows opened are listed, but get a workspace here only once shown.
    func syncWorkspaces() {
        guard isStarted, !isClosed else { return }
        var next: [String: Workspace] = [:]
        if let local = workspaces[HostGroups.localId] ?? app.makeWorkspace(for: .local) { next[HostGroups.localId] = local }
        var wanted = Set(groups.openHosts)
        if case .host(let id) = target { wanted.insert(id) }
        for group in groups.groups where !group.isLocal && wanted.contains(group.id) {
            guard let connection = app.hosts.connection(group.id) else { continue }
            let identity = ObjectIdentifier(connection)
            if let existing = workspaces[group.id], workspaceConnections[group.id] == identity {
                next[group.id] = existing
            } else if let made = app.makeWorkspace(for: .host(group.id)) {
                next[group.id] = made
                workspaceConnections[group.id] = identity
            }
        }
        // Workspaces on a replaced connection (or a host gone from this window) end here.
        for (id, old) in workspaces where next[id] !== old {
            old.close(ending: true)
            if next[id] == nil { workspaceConnections[id] = nil }
        }
        if next.count != workspaces.count || next.contains(where: { workspaces[$0.key] !== $0.value }) {
            workspaces = next
        }
        let shown: Workspace? = switch target {
        case .local: next[HostGroups.localId]
        case .host(let id): next[id]
        }
        if shown !== workspace {
            #if os(iOS)
            // Typing went to a terminal: the new host's focused pane takes the keyboard as it
            // appears (iOS has no window first responder to fall back to).
            let typing = workspace?.panes.values.filter { $0.view.isFirstResponder } ?? []
            // The old host's terminal leaves the window but would stay first responder,
            // detached: keys (⌘ shortcuts included) would go to a responder chain that no
            // longer reaches the scene, and be lost. Resign it before switching.
            for pane in typing { pane.view.resignFirstResponder() }
            if let shown, !typing.isEmpty {
                shown.inheritsKeyboardFocus = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    shown.inheritsKeyboardFocus = false
                }
            }
            #endif
            workspace = shown
        }
    }

    // MARK: What the daemons hear

    /// Tells each daemon what this window shows of it: the shown host's visible panes and
    /// focus, nothing for the hosts it does not show (stream priorities, attention seen, push
    /// suppression; DAEMON.md).
    /// With a mixed tab or Two Columns on screen, every host with a visible pane hears it; only
    /// the focused pane's host hears a focus (`screenViews`).
    func reportViews() {
        let views = destination == .terminal && isOnScreen && !isClosed ? screenViews() : [:]
        for (id, open) in workspaces {
            guard let daemon = open.host as? DaemonConnection else { continue }
            let view = views[id] ?? (nil, [])
            daemon.setWindowView(self, focused: view.focused, visible: view.visible)
        }
    }

    /// Re-reports when the shown workspace's tab, focus or splits change (or a mixed tab's, or
    /// the other column's).
    private func followView() {
        guard !isClosed else { return }
        let observed = workspace
        reportViews()
        withObservationTracking {
            _ = observed?.layout.view
            _ = screenViews()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.workspace === observed else { return }
                self.followView()
            }
        }
    }

    /// Re-syncs when hosts open, close, are forgotten or swap their connection.
    private func followGroups() {
        withObservationTracking {
            _ = groups.openHosts
            _ = app.hosts.records.count
            for connection in app.hosts.connections.values { _ = ObjectIdentifier(connection) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.syncWorkspaces()
                self.followGroups()
            }
        }
    }

    // MARK: Connection state

    /// Mirrors the window's host status into `liveConnection`, remembering when it went down so
    /// the reconnect notice can say when the host was last heard from, and shows the host's
    /// one-time notices as toasts.
    private func followConnection() {
        let status = workspace?.host?.status
        // A suspended app is not "down": coming back from the background starts the clock anew.
        if status.map({ $0.isLive || $0 == .suspended }) ?? true {
            downSince = nil
        } else if downSince == nil {
            downSince = .now
        }
        // No host: this device's own shell is "connected"; an iPhone or iPad without one is not.
        let next = status.map { ConnectionState($0, since: downSince ?? .now) } ?? (LaunchOptions.hasLocalShell ? .connected : .disconnected)
        if next != liveConnection { liveConnection = next }
        guard let host = workspace?.host else { return }
        let observed = workspace
        let daemon = host as? DaemonConnection
        if let notice = daemon?.notice {
            toasts.show(Toast(notice.text, systemImage: "arrow.uturn.backward", style: .neutral))
            daemon?.dismissNotice()
        }
        withObservationTracking {
            _ = host.status
            _ = daemon?.notice
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
    /// the link went down.
    init(_ status: ConnectionStatus, since: Date) {
        switch status {
        case .connected(let rtt):
            if status.isSlow, let rtt { self = .slow(rtt: rtt) } else { self = .connected }
        case .idle:
            self = .disconnected
        case .connecting(let phase):
            // Dialling needs no words beyond "Connecting…"; later phases say what they wait for.
            self = .connecting(phase: phase == .dialing ? nil : phase.summary)
        case .suspended:
            self = .paused
        case .reconnecting(let attempt, _):
            self = .reconnecting(attempt: Int(max(attempt, 1)), since: since)
        case .offline:
            self = .offline(since: since)
        case .needsAttention(let reason):
            self = .needsAttention(reason: reason, action: nil)
        }
    }
}

/// Launch arguments for design review and screenshots:
/// `-mock` fills the screens with sample hosts, agents and statuses; `-screen <name>` opens
/// straight to one screen.
/// See `WindowModel.newAgentSeed`.
struct NewAgentSeed {
    var prompt: String?
    var host: String?
    var repo: String?
}

enum LaunchOptions {
    /// `-mock`, or `UNNAMED_MOCK` in the environment (in-process snapshot tests).
    static let mock = ProcessInfo.processInfo.arguments.contains("-mock") || ProcessInfo.processInfo.environment["UNNAMED_MOCK"] != nil
    /// Hosting unit tests: no windows of its own, never active.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let screen: String? = UserDefaults.standard.string(forKey: "screen")
    /// Every host header and the Inbox show a fixed usage report (`FakeUsageFeed`): UI tests.
    static let fakeUsage = UserDefaults.standard.bool(forKey: "fakeUsage")
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

private extension Double {
    /// Nil for 0 (an unset default).
    var nonZeroWidth: Double? { self > 0 ? self : nil }
}
