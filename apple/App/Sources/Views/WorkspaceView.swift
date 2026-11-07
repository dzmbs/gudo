import DesignSystem
import HostKit
import PaneLayout
import TerminalRenderer
import SwiftUI
import TerminalCore

/// Where tabs are listed in regular-width windows: the sidebar holds them while it is shown;
/// hidden, they show as a strip on top.
enum TabPlacement {
    static let sidebarShownKey = "sidebarShown"
    /// Off: no strip while the sidebar is hidden (the terminal gets the whole window).
    static let showsTabBarKey = "tabBarWithoutSidebar"

    /// The last sidebar choice, which a new window starts with. Migrates the legacy "tabStyle"
    /// setting once: "bar" meant the sidebar hidden.
    static var sidebarShown: Bool {
        get {
            let defaults = UserDefaults.standard
            if let legacyStyle = defaults.string(forKey: "tabStyle") {
                defaults.removeObject(forKey: "tabStyle")
                if legacyStyle == "bar" { defaults.set(false, forKey: sidebarShownKey) }
            }
            return defaults.object(forKey: sidebarShownKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: sidebarShownKey) }
    }

    static var showsTabBar: Bool {
        get { UserDefaults.standard.object(forKey: showsTabBarKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showsTabBarKey) }
    }
}

/// A window: tabs around the active tab's panes, plus the window-wide overlays and sheets. The
/// workspace is the window's target (this device or a host); the window model outlives it.
struct WorkspaceView: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @AppStorage("sidebarWidth") private var sidebarWidth = SidebarWidth.standard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The layout's frame in window points: where the fold falls within it.
    @State private var frame = CGRect.zero
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private var theme: TerminalTheme { ThemeCatalog.theme(named: themeName) }

    var body: some View {
        @Bindable var model = model
        content
            // Above the find bar and every other overlay.
            .spotlightOverlay(isPresented: model.isPaletteShown, onDismiss: { model.isPaletteShown = false }) {
                CommandPalette(
                    isPresented: $model.isPaletteShown, commands: PaletteCommands.all(workspace: workspace, model: model),
                    placeholder: PaletteCommands.placeholder(model.paletteMode),
                    // "/" scopes the palette to workflows; ⌫ on the empty query goes back.
                    onScope: model.paletteMode == .commands ? { query in
                        guard query == "/" else { return false }
                        model.paletteMode = .workflows
                        return true
                    } : nil,
                    onDeleteEmpty: model.paletteMode == .workflows ? { model.paletteMode = .commands } : nil)
                    // A fresh query and selection per mode.
                    .id(model.paletteMode)
            }
            .spotlightOverlay(isPresented: model.workflowPanel != nil, onDismiss: { model.workflowPanel = nil }) {
                if let panel = model.workflowPanel {
                    WorkflowPanelHost(panel: panel).id(panel.id)
                }
            }
            .animation(DS.Motion.palette, value: model.isPaletteShown)
            .animation(DS.Motion.palette, value: model.workflowPanel?.id)
            .onChange(of: (workspace.host as? DaemonConnection)?.workspace.workflowsRev) {
                if model.isPaletteShown { model.loadWorkflows() }
            }
            .overlay(alignment: .bottomLeading) { AgentToastStack() }
            .toastHost(model.toasts, bottomInset: PortOfferBanner.bottomInset(model)
                + (model.ports.offer != nil && !model.editorHasKeys ? PortOfferBanner.height + DS.Space.s : 0))
            .dictationIndicator()
            .portOffers(model)
            .sheet(item: $model.sheet) { route in
                SheetContent(route: route, workspace: workspace)
                    .environment(model)
                    .environment(model.app)
            }
            // The whole window follows the terminal theme, light or dark by `window-theme`.
            .chromeWindow()
            .chromeTheme(theme, windowTheme: windowTheme)
            .modifier(ThemePairFollower())
            .focusedSceneValue(workspace)
            .focusedSceneValue(model)
            .renameTabPrompt(workspace)
            .modifier(MultiplayerWindowHooks(workspace: workspace))
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
                let appearance = TerminalAppearance.fromPreferences()
                for openWorkspace in model.workspaces.values where appearance != openWorkspace.appearance { openWorkspace.appearance = appearance }
            }
            .task {
                await DesignFixtures.apply(LaunchOptions.screen, workspace: workspace, model: model)
                if LaunchOptions.screen == "toggle" {
                    // Fixture: strip first, then the sidebar, as a user would switch.
                    model.isSidebarShown = false
                    try? await Task.sleep(for: .seconds(1))
                    model.isSidebarShown = true
                }
            }
            // Closing the last tab of all closes the Mac window, but not while a host is open:
            // an empty daemon session is still a session.
            .onChange(of: TabsEmptied(workspace: ObjectIdentifier(workspace), isEmpty: workspace.session.tabs.isEmpty)) { old, new in
                // Only a tab closing here, not switching to a host that has no tabs yet.
                guard new.isEmpty, old.workspace == new.workspace, LaunchOptions.screen == nil else { return }
                if model.groups.tabs.isEmpty {
                    #if os(macOS)
                    if !workspace.isRemote, model.groups.openHosts.isEmpty { dismiss() }
                    #endif
                } else {
                    model.tabsEmptied()
                }
            }
            #if DEBUG && os(macOS)
            // `-dogfood <scenario.json>`: the in-app scenario runner.
            .task { DogfoodRunner.startIfRequested(workspace: workspace) }
            #endif
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        // By the window's width, never the device, so Split View, Slide Over and Stage Manager
        // windows get the layout their width fits.
        if model.widthBucket == .compact {
            CompactRoot(workspace: workspace)
        } else {
            regular
        }
        #else
        regular
        #endif
    }

    /// An integrated sidebar beside the detail column, which both tab placements share.
    ///
    /// On a foldable the fold places them (`FoldLayout`): as a book the sidebar is the left page;
    /// half-folded the tab is the upper screen and the deck the lower. The same views move rather
    /// than being rebuilt, so the panes keep their state.
    private var regular: some View {
        let layout = model.foldLayout
        // Only a fold that leaves room either side splits the window. The window's frame never
        // depends on what is inside it, so measuring it cannot feed back.
        let page = layout.leadingPage(from: frame.minX)
            .flatMap { $0 >= FoldLayout.minimumPage && frame.width - $0 - layout.gutter >= FoldLayout.minimumPage ? $0 : nil }
        let deck = layout.deckTop(from: frame.minY)
            .flatMap { $0 >= FoldLayout.minimumDeck && frame.height - $0 - layout.gutter >= FoldLayout.minimumDeck ? $0 : nil }
        let shown = model.isSidebarShown && !model.isEditorFullScreen && deck == nil
        let width = page ?? SidebarWidth.effective(sidebarWidth, for: dynamicTypeSize)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Always mounted and revealed by one animated width: inserting it with a
                // transition rebuilds its navigation stack and toolbar mid-animation, which stutters.
                SidebarColumn(workspace: workspace)
                    .frame(width: width)
                    .frame(width: shown ? width : 0, alignment: .trailing)
                    .clipped()
                    .overlay(alignment: .trailing) {
                        // A page ends at the fold: no divider to drag there.
                        if page == nil { SidebarDivider(width: $sidebarWidth).opacity(shown ? 1 : 0) }
                    }
                    .allowsHitTesting(shown)
                    .disabled(!shown)
                    .accessibilityHidden(!shown)
                if shown, page != nil {
                    FoldGutter().frame(width: layout.gutter)
                }
                NavigationStack {
                    DetailColumn(workspace: workspace)
                }
            }
            .frame(height: deck)
            // The keyboard rises over the deck, never the screen above: no reflow as it comes up.
            .ignoresSafeArea(.keyboard, edges: deck == nil ? [] : .bottom)
            #if os(iOS)
            if deck != nil {
                FoldGutter().frame(height: layout.gutter)
                TabletopDeck(workspace: workspace)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            #endif
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
        .animation(DS.Motion.sidebar, value: model.isSidebarShown)
        .animation(DS.Motion.panel, value: model.isEditorFullScreen)
        .chromeBackground(DS.Palette.base)
        #if os(macOS)
        .background(RepresentedDirectory(path: workspace.isRemote ? nil : workspace.session.activeTab.flatMap(workspace.absoluteDirectory(of:))))
        #endif
    }
}

private struct TabsEmptied: Equatable {
    var workspace: ObjectIdentifier
    var isEmpty: Bool
}

#if os(iOS)
/// Settings, in the sidebar's top bar (iPad).
private struct SettingsToolbarButton: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        Button("Settings", systemImage: "gearshape") { model.sheet = .settings }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityIdentifier("open-settings")
    }
}
#endif

/// The sidebar column on the terminal's background family. On iPad it has its own bar (the
/// app name and New Tab) level with the detail's; on the Mac it runs up under the titlebar.
private struct SidebarColumn: View {
    let workspace: Workspace
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        #if os(iOS)
        NavigationStack {
            WorkspaceSidebar()
                // The app's name is not drawn: in a 200–360 pt column between two glass
                // buttons a title collided with them at large text sizes. VoiceOver keeps it.
                .navigationTitle(Brand.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        SettingsToolbarButton()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NewTabButton(workspace: workspace)
                    }
                }
                .chromeBarBackground(.sidebar)
        }
        .chromeBackground(DS.Palette.sidebar)
        #else
        WorkspaceSidebar()
            .chromeBackground(DS.Palette.sidebar)
        #endif
    }
}

/// The + menu; Add Host alone where nothing can open a tab yet.
struct NewTabButton: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        let groups = model.groups.groups
        if canOpen {
            Menu {
                Button("New Terminal", systemImage: "terminal") { model.newTab() }
                    .accessibilityIdentifier("new-tab-terminal")
                Button(WorkspaceAction.newAgent.title, systemImage: "sparkle") { model.newAgent() }
                    .accessibilityIdentifier("new-tab-agent")
                Button(WorkspaceAction.newProject.title, systemImage: "folder.badge.plus") {
                    withAnimation(DS.Motion.reorder) { model.newEmptyProject() }
                }
                .accessibilityIdentifier("new-tab-project")
                if groups.count > 1 {
                    Menu("New Terminal On", systemImage: "plus.rectangle.on.rectangle") {
                        ForEach(groups) { group in
                            Button(group.name, systemImage: group.systemImage) { model.newTab(onGroup: group.id) }
                        }
                    }
                }
                Divider()
                Button("Add Host…", systemImage: "plus.circle") { model.addHost() }
            } label: {
                Label("New", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .help("New Terminal (⌘T) or New Agent (⇧⌘N)")
            .accessibilityIdentifier("new-tab")
        } else {
            Button("Add Host", systemImage: "plus") { model.newTab() }
                .labelStyle(.iconOnly)
                .help("Add Host")
                .accessibilityIdentifier("new-tab")
        }
    }

    private var canOpen: Bool { workspace.canOpenTabs || model.groups.newTabHost(preferred: nil) != nil }
}

/// The hairline between sidebar and terminal, draggable to resize the sidebar; a double click
/// restores the default width.
private struct SidebarDivider: View {
    @Binding var width: Double
    @Environment(\.displayScale) private var displayScale
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(DS.Palette.separator)
            .frame(width: DS.Size.hairline(scale: displayScale))
            .ignoresSafeArea()
            .overlay {
                Color.clear
                    .frame(width: ResizeZones.dividerThickness(gap: DS.Size.hairline(scale: displayScale)))
                    .contentShape(.rect)
                    #if os(macOS)
                    .pointerStyle(.columnResize)
                    #endif
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let origin = start ?? width
                                start = origin
                                width = min(max(origin + value.translation.width, SidebarWidth.range.lowerBound), SidebarWidth.range.upperBound)
                            }
                            .onEnded { _ in start = nil })
                    .onTapGesture(count: 2) { width = SidebarWidth.standard }
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel("Sidebar Width")
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        let step = direction == .increment ? 20.0 : direction == .decrement ? -20.0 : 0
                        width = min(max(width + step, SidebarWidth.range.lowerBound), SidebarWidth.range.upperBound)
                    }
                    .accessibilityIdentifier("sidebar-divider")
            }
    }
}

#if os(macOS)
/// The window's represented folder. Set on the window, not by a modifier applied only while a
/// folder is known, which would swap the window's whole view tree each time one came or went.
private struct RepresentedDirectory: NSViewRepresentable {
    let path: String?

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ marker: Marker, context: Context) {
        marker.url = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    final class Marker: NSView {
        var url: URL? { didSet { apply() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func apply() {
            if let window, window.representedURL != url { window.representedURL = url }
        }
    }
}
#endif

/// The tab strip, then the active tab's panes, the Inbox or Hosts, under one shared toolbar.
private struct DetailColumn: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true

    var body: some View {
        VStack(spacing: 0) {
            // Across a fold each page's header names its tab and the sidebar is the tab list: a
            // strip would run over the crease.
            if !model.isSidebarShown && showsTabBar && !model.isEditorFullScreen && !model.foldLayout.isPages {
                TabBar(workspace: workspace)
                    .chromeContent()
                    .movingTransition(.top)
            }
            switch model.destination {
            case .terminal:
                TerminalArea(workspace: workspace)
                    // Behind the key bar and keyboard, which float over the terminal.
                    .background(theme.background.ignoresSafeArea(.all, edges: .bottom))
                    // The ink goes on each destination, never above a toolbar.
                    .chromeContent()
            case .inbox:
                InboxView(feed: model.agents, onLaunch: { model.newAgent() }, onNewTerminal: { model.newTab() })
            case .hosts:
                HostsScreen()
            }
        }
        // Every destination fills the column, whatever its content's own size: an empty Inbox
        // would otherwise shrink the whole window to its message.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if DEBUG
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { model.detailFrame = $0 })
        #endif
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .chromeBarBackground(.base)
        #endif
        .navigationSubtitle(model.destination == .terminal ? subtitle : "")
        .toolbar { TerminalToolbar(workspace: workspace) }
        #if os(iOS)
        .toolbar(model.isEditorFullScreen ? .hidden : .automatic, for: .navigationBar)
        #else
        .toolbar(model.isEditorFullScreen ? .hidden : .automatic, for: .windowToolbar)
        #endif
        .modifier(GitDialogs(git: model.git))
        .onChange(of: model.git.hub?.repos != nil, initial: true) { _, hasRepos in
            if hasRepos { model.git.syncAutoDelete() }
        }
        .chromeBackground(DS.Palette.base)
    }

    private var title: String {
        switch model.destination {
        case .terminal:
            model.activeMixed.map(model.title(ofMixedTab:)) ?? workspace.session.activeTab.map(workspace.title(of:)) ?? Brand.name
        case .inbox: Destination.inbox.title
        case .hosts: "Hosts"
        }
    }

    /// Under the tab's name: its context when it says something the title does not, then the
    /// split state. The host is named by the toolbar's host button instead.
    private var subtitle: String {
        if let mixed = model.activeMixed {
            let hosts = mixed.hosts.map(model.groupName).joined(separator: " + ")
            if mixed.isBrowserOnly { return hosts.isEmpty ? "Browser" : "Browser · \(hosts)" }
            return mixed.isEditorOnly ? "VS Code · \(hosts)" : hosts
        }
        guard let tab = workspace.session.activeTab else { return "" }
        let title = workspace.title(of: tab)
        var parts: [String] = []
        if let context = workspace.context(of: tab)?.trimmingCharacters(in: .whitespaces),
           !context.isEmpty, context != "~", context != title
        {
            parts.append(context)
        }
        if tab.root.panes.count > 1 {
            parts.append(tab.zoomed == nil ? "\(tab.root.panes.count) panes" : "Zoomed")
        }
        if workspace.showsSavedWorkspace, !model.connection.isFailure { parts.append("Connecting…") }
        return parts.joined(separator: " · ")
    }
}

/// The window toolbar, identical with the sidebar shown or hidden.
private struct TerminalToolbar: ToolbarContent {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    #if os(macOS)
    @AppStorage("sidebarWidth") private var sidebarWidth = SidebarWidth.standard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some ToolbarContent {
        #if os(macOS)
        // Over the sidebar the toggle is a bare glyph beside the traffic lights and the title
        // starts where the detail column does; with the sidebar hidden it is a regular button.
        ToolbarItem(placement: .navigation) {
            SidebarToggle()
        }
        .sharedBackgroundVisibility(overSidebar ? .hidden : .visible)
        if overSidebar {
            ToolbarItem(placement: .navigation) {
                Color.clear
                    .frame(width: titleInset, height: 1)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        #else
        ToolbarItem(placement: .navigation) {
            SidebarToggle()
        }
        #endif
        #if os(iOS)
        if model.destination == .terminal, workspace.session.activeTab?.root.panes.count == 1,
           let id = workspace.focusedPane, let pane = workspace.panes[id], let chat = pane.chat, chat.agent != nil {
            ToolbarItem(placement: .principal) { PaneChatToggle(pane: pane, state: chat) }
        }
        #endif
        if let session = workspace.multiplayer {
            ToolbarItem(placement: .primaryAction) {
                PresenceToolbarButton(session: session, place: { pane in
                    workspace.session.tabs.first { $0.root.panes.contains(PaneId(pane)) }.map(workspace.title(of:))
                }) { model.sheet = .invite }
                    .buttonStyle(.plain)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        // On its own, so the host's name shows (a glass group shows icons only).
        ToolbarItem(placement: .primaryAction) {
            HostToolbarButton(workspace: workspace)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        if model.destination == .terminal, let worktree = model.git.worktree {
            ToolbarItem(placement: .primaryAction) {
                PRToolbarButton(git: model.git, worktree: worktree)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                OpenInMenu(git: model.git)
                RunMenu(git: model.git, worktree: worktree)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Find", systemImage: "magnifyingglass") { model.isSearchShown.toggle() }
                .lit(model.isSearchShown && model.destination == .terminal)
                .help(model.isSearchShown ? "Hide Find (⌘F)" : "Find (⌘F)")
                .accessibilityIdentifier("find-button")
                .disabled(model.destination != .terminal)
            Menu("Pane", systemImage: "rectangle.split.2x1") {
                PaneMenuItems(workspace: workspace, model: model)
                Divider()
                Toggle("Two Columns", systemImage: "rectangle.split.2x1", isOn: Binding(
                    get: { model.isTwoColumns }, set: { _ in model.toggleTwoColumns() }))
                    .accessibilityIdentifier("two-columns")
            }
            .help("Pane: split, zoom, close, Two Columns")
            .menuIndicator(.hidden)
            .disabled((workspace.focusedPane == nil && model.activeMixed == nil) || model.destination != .terminal)
            .accessibilityIdentifier("pane-menu")
            Menu {
                Button("Sketch on Pane", systemImage: "pencil.tip") { DrawingCommands.toggleDrawing(in: workspace) }
                    .disabled(!DrawingCommands.canDraw(in: workspace))
                    .accessibilityIdentifier("draw-sketch")
                Button("New Drawing", systemImage: "scribble.variable") { DrawingDocuments.newDrawing(window: model) }
                    .disabled(!DrawingDocuments.canCreate(in: model))
                    .accessibilityIdentifier("draw-new-drawing")
            } label: {
                Label("Sketch on Pane", systemImage: "pencil.tip")
            } primaryAction: {
                DrawingCommands.toggleDrawing(in: workspace)
            }
            .help("Sketch on Pane (⌃⌘D)")
            .disabled(model.destination != .terminal || (!DrawingCommands.canDraw(in: workspace) && !DrawingDocuments.canCreate(in: model)))
            .accessibilityIdentifier("draw-button")
            Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                .help("Command Palette (⌘K)")
                .accessibilityIdentifier("open-palette")
        }
    }

    #if os(macOS)
    private var overSidebar: Bool { model.isSidebarShown && !model.isEditorFullScreen }

    /// From the toggle to the detail column's text margin: the traffic lights, the toggle and
    /// the items' spacing take the sidebar's first 148 pt.
    private var titleInset: CGFloat {
        max(0, SidebarWidth.effective(sidebarWidth, for: dynamicTypeSize) - 148 + DS.Space.m)
    }
    #endif
}


#if os(iOS)
/// iPhone: Terminal, Inbox and Hosts as tabs in the system's floating Liquid Glass tab bar.
private struct CompactRoot: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.destination) {
            SwiftUI.Tab("Terminal", systemImage: "terminal", value: Destination.terminal) {
                CompactTerminalView(workspace: workspace)
                    .toolbar(model.isEditorFullScreen ? .hidden : .automatic, for: .tabBar)
            }
            SwiftUI.Tab(Destination.inbox.title, systemImage: Destination.inbox.systemImage, value: Destination.inbox) {
                NavigationStack {
                    InboxView(feed: model.agents, onLaunch: { model.newAgent() }, onNewTerminal: { model.newTab() })
                }
            }
            .badge(model.needsYouCount)
            SwiftUI.Tab("Hosts", systemImage: "server.rack", value: Destination.hosts) {
                NavigationStack {
                    HostsScreen()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Settings", systemImage: "gearshape") { model.sheet = .settings }
                                    .keyboardShortcut(",", modifiers: .command)
                                    .help("Settings (⌘,)")
                            }
                        }
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Without them a merge, archive or delete from the palette waits for a confirmation
        // that never shows.
        .modifier(GitDialogs(git: model.git))
        .onChange(of: model.git.hub?.repos != nil, initial: true) { _, hasRepos in
            if hasRepos { model.git.syncAutoDelete() }
        }
    }
}
#endif

/// The active tab's panes: its split tree, or only the focused pane in compact width. Without
/// tabs: the welcome state.
struct ActiveTabView: View {
    let workspace: Workspace
    var compact = false
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    var body: some View {
        Group {
            if let tab = workspace.session.activeTab {
                // Floating windows ride above the tiled panes; on iPhone the focused pane shows
                // alone and the windows become picture in picture.
                let tiled = workspace.session.tiledRoot(of: tab) ?? tab.root
                let floats = compact ? FloatScene.none : FloatScene(workspace: workspace, tab: tab, hidden: model.floatsHidden)
                // A zoomed pane keeps its header: its lit Zoom button is the way back.
                let isSplit = !compact && (tiled.panes.count > 1 || !floats.windows.isEmpty)
                SplitTreeView(
                    node: compact ? .leaf(tab.focused) : tiled, workspace: workspace, isSplit: isSplit, animated: !compact,
                    floats: floats, zoomed: compact ? nil : tab.zoomed)
                    .overlay {
                        if compact { PictureInPicture(workspace: workspace, tab: tab) }
                    }
                    // Another tab replaces the panes at once; only this tab's own changes animate.
                    .id(tab.id)
                    .padding(paneStyle == .comfortable && isSplit ? DS.Space.row : 0)
                    .background(paneStyle == .comfortable && isSplit ? theme.splitDivider : theme.background, ignoresSafeAreaEdges: [])
                    // Lost link: the last frame stays, faded toward the background, under the card.
                    .connectionOverlay(
                        model.connection, hostName: model.hostName, showsSavedState: workspace.showsSavedWorkspace,
                        onRetry: { model.retryConnection() },
                        onDisconnect: { model.disconnect() })
            } else if workspace.host?.isReady == false {
                ConnectingView(
                    hostName: model.hostName, state: model.connection,
                    onRetry: { model.retryConnection() }, onDisconnect: { model.disconnect() })
            } else {
                WelcomeView(workspace: workspace)
            }
        }
        .overlay(alignment: .top) {
            if workspace.host != nil { HostNotices(workspace: workspace) }
        }
        .background(theme.background, ignoresSafeAreaEdges: [])
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            // An external display showing this window's tab scales to this area.
            if !model.isPresentation, model.terminalArea != size { model.terminalArea = size }
        }
    }
}

/// A host's window before there is a session to show, with actions only when something failed.
/// A quick connect shows nothing: the words wait for a 1 s grace, a failure does not.
private struct ConnectingView: View {
    let hostName: String
    let state: ConnectionState
    let onRetry: () -> Void
    let onDisconnect: () -> Void
    @State private var isGraceOver = false

    var body: some View {
        Group {
            if isGraceOver || state.isFailure {
                details
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(1))
            isGraceOver = true
        }
    }

    private var details: some View {
        VStack(spacing: DS.Space.m) {
            ConnectionGlyph(state)
                .font(.title)
                .frame(height: 32)
            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(.primary)
                if let detail {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(detail(context.date))
                            .font(.subheadline)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                }
            }
            if let action {
                HStack(spacing: DS.Space.s) {
                    Button("Disconnect", action: onDisconnect)
                        .buttonStyle(.glass)
                    Button(action, action: onRetry)
                        .buttonStyle(.primaryGlass)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, DS.Space.s)
            }
        }
        .padding(DS.Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connecting")
    }

    private var title: String {
        switch state {
        case .reconnecting: "Reconnecting to \(hostName)…"
        case .offline: "Offline"
        case .needsAttention: "Can't connect to \(hostName)"
        case .unreachable: "Can't reach \(hostName)"
        default: "Connecting to \(hostName)…"
        }
    }

    /// The second line: the phase or the reason, never a repeat of the title.
    private var detail: ((Date) -> String)? {
        switch state {
        case .connecting(let phase?): { _ in phase }
        case .reconnecting(_, let since): { now in "Last contact \(Self.ago(now.timeIntervalSince(since)))" }
        case .offline: { _ in "Waiting for the network. Sessions keep running on \(hostName)." }
        case .needsAttention(let reason, _): { _ in reason }
        case .unreachable(let reason, let hint): { _ in [reason, hint].compactMap(\.self).joined(separator: " ") }
        default: nil
        }
    }

    private var action: String? {
        switch state {
        case .needsAttention(_, let action): action ?? "Retry"
        case .unreachable: "Retry"
        default: nil
        }
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, Int(seconds))).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)) + " ago"
    }
}

/// No tabs open: the next steps.
private struct WelcomeView: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: workspace.canOpenTabs ? "terminal" : "server.rack")
                .font(.title)
                .imageScale(.large)
                .foregroundStyle(DS.Palette.textSecondary)
            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            #if os(iOS)
            if !workspace.canOpenTabs {
                Button { model.addHost(mode: .scan) } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryGlass)
                .controlSize(.large)
                .frame(width: 300)
                .padding(.top, DS.Space.s)
                .accessibilityIdentifier("welcome-scan")
            }
            #endif
            VStack(spacing: 2) {
                if workspace.canOpenTabs {
                    welcomeRow("New Terminal", systemImage: "plus", keys: ["⌘", "T"]) { model.newTab(onGroup: model.currentGroupId) }
                        .disabled(!workspace.isLayoutLive)
                        .help(workspace.isLayoutLive ? "" : model.layoutUnavailableHelp)
                        .accessibilityIdentifier("welcome-new-terminal")
                    welcomeRow("New Agent…", systemImage: "sparkle", keys: WorkspaceAction.newAgent.shortcut.symbols) { model.newAgent() }
                    if !workspace.isRemote {
                        welcomeRow("Connect to a Host…", systemImage: "server.rack", keys: nil) { model.addHost() }
                    }
                } else {
                    welcomeRow("Connect with SSH…", systemImage: "terminal", keys: nil) { model.addHost(mode: .ssh) }
                        .accessibilityIdentifier("welcome-ssh")
                    welcomeRow("Paste a Pairing Ticket…", systemImage: "doc.on.clipboard", keys: nil) { model.addHost(mode: .ticket) }
                        .accessibilityIdentifier("welcome-ticket")
                }
                welcomeRow("Command Palette", systemImage: "command", keys: ["⌘", "K"]) { model.isPaletteShown = true }
            }
            .frame(width: 300)
            .padding(.top, DS.Space.s)
        }
        .padding(DS.Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A container, so the rows keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome")
    }

    private var title: String {
        if workspace.isRemote { return "No sessions on \(model.hostName)" }
        return workspace.canOpenTabs ? "No Open Tabs" : "Connect a Host"
    }

    private var message: String {
        if workspace.isRemote { return "Open a new tab to start a terminal." }
        return workspace.canOpenTabs
            ? "Open a shell here, or connect to a host to pick up its sessions."
            : PairingHint.message
    }

    /// Shortcut hints only where a hardware keyboard is likely (not on iPhone).
    private var showsShortcuts: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    private func welcomeRow(_ title: String, systemImage: String, keys: [String]?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // With shortcuts, a list read down its left edge with the keys on the right; without
            // (iPhone), each action centred under the centred title and button.
            HStack(spacing: DS.Space.gap10) {
                if !showsShortcuts { Spacer(minLength: 0) }
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.primary)
                    .opacity(DS.Opacity.mutedGlyph)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if let keys, showsShortcuts { ShortcutLabel(keys).font(.subheadline) }
            }
            .font(.body)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
        }
        .buttonStyle(.row)
    }
}

/// The sheet for each route.
private struct SheetContent: View {
    let route: SheetRoute
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // A sheet is its own presentation: it takes the theme again, so its text levels, tint
        // and surfaces are the window's.
        ThemedRoot { content }
            .chromeSheetBackground()
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .pairing:
            PairingSheet(directory: model.hosts, live: LaunchOptions.mock ? nil : model.app.hosts, initialMode: model.pairingMode, destination: model.pairingDestination, ticket: model.pairingTicket)
        case .pairDevice:
            if let hostId = model.pairDeviceHostId { PairDeviceSheet(hostId: hostId) }
        case .launchAgent, .links, .diff, .files, .browser, .editor:
            ToolSheet(route: route)
        case .invite:
            InviteSheet(workspace: workspace)
        case .sharing:
            SharingSheet()
        case .join:
            JoinSheet(invite: model.joinInvite.isEmpty ? LaunchArguments().string(forKey: "joinInvite") ?? "" : model.joinInvite)
        case .settings:
            SettingsView()
        case .shortcuts:
            ShortcutsSheet()
        case .replays:
            SessionReplaysSheet(request: model.replayRequest)
        case .tabs:
            #if os(iOS)
            TabOverview(workspace: workspace)
            #endif
        }
    }

    private func sheetStack(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .macMinimumSize(width: 640, height: 520)
        // Code and file lists need the room: a page sheet on iPad, not a form sheet.
        .presentationSizing(.page)
    }
}

private struct RenameTabPrompt: ViewModifier {
    let workspace: Workspace
    @State private var draft = ""

    func body(content: Content) -> some View {
        content.alert(
            "Rename Tab",
            isPresented: Binding(get: { workspace.renamingTab != nil }, set: { if !$0 { workspace.renamingTab = nil } })
        ) {
            TextField("Title", text: $draft)
            Button("Rename") {
                if let id = workspace.renamingTab { workspace.apply(.rename(id, draft)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to use the terminal's title.")
        }
        .onChange(of: workspace.renamingTab) { _, id in
            draft = workspace.session.tabs.first { $0.id == id }?.title ?? ""
        }
    }
}

extension View {
    func renameTabPrompt(_ workspace: Workspace) -> some View {
        modifier(RenameTabPrompt(workspace: workspace))
    }
}
