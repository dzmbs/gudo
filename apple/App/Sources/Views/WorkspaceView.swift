import DesignSystem
import HostKit
import PaneLayout
import TerminalRenderer
import SwiftUI
import TerminalCore

/// Where tabs are listed in regular-width windows, Safari's way: the sidebar holds them while it
/// is shown; hidden, they show as a strip on top. One button and ⌘B switch between the two, so
/// there is no separate "tab style" to find.
enum TabPlacement {
    static let sidebarShownKey = "sidebarShown"
    /// Off: no strip while the sidebar is hidden (the terminal gets the whole window).
    static let showsTabBarKey = "tabBarWithoutSidebar"

    /// The last sidebar choice, which a new window starts with. Reads the old "tabStyle" setting
    /// once: tabs on top was the sidebar hidden.
    static var sidebarShown: Bool {
        get {
            let defaults = UserDefaults.standard
            if let old = defaults.string(forKey: "tabStyle") {
                defaults.removeObject(forKey: "tabStyle")
                if old == "bar" { defaults.set(false, forKey: sidebarShownKey) }
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

/// A window: tabs (sidebar, strip, or the compact layout on iPhone) around the active tab's panes,
/// plus the window-wide overlays (command palette, toasts) and sheets. The workspace is the
/// window's target (this device or a host, `WindowRoot`); the window model outlives it.
struct WorkspaceView: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @AppStorage("sidebarWidth") private var sidebarWidth = SidebarWidth.standard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private var theme: TerminalTheme { ThemeCatalog.theme(named: themeName) }

    var body: some View {
        @Bindable var model = model
        content
            .overlay(alignment: .top) {
                if model.isPaletteShown {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.0001)
                            .ignoresSafeArea()
                            .onTapGesture { model.isPaletteShown = false }
                        CommandPalette(
                            isPresented: $model.isPaletteShown, commands: PaletteCommands.all(workspace: workspace, model: model),
                            placeholder: PaletteCommands.placeholder(model.paletteMode),
                            // goes back to every command.
                            onScope: model.paletteMode == .commands ? { query in
                                guard query == "/" else { return false }
                                model.paletteMode = .workflows
                                return true
                            } : nil,
                            onDeleteEmpty: model.paletteMode == .workflows ? { model.paletteMode = .commands } : nil)
                            // A fresh query and selection per mode (⌘K, ⌘P, ⌥⌘T).
                            .id(model.paletteMode)
                            .padding(.top, 44)
                            // animation); a 0.15 s fade on iPad, where the glass needs a frame.
                            .transition(.opacity)
                    }
                }
            }
            .overlay(alignment: .top) {
                if let panel = model.workflowPanel {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.0001)
                            .ignoresSafeArea()
                            .onTapGesture { model.workflowPanel = nil }
                        WorkflowPanelHost(panel: panel)
                            .id(panel.id)
                            .padding(.top, 44)
                            .transition(.opacity)
                    }
                }
            }
            .animation(DS.Motion.palette, value: model.isPaletteShown)
            .animation(DS.Motion.palette, value: model.workflowPanel?.id)
            // The host's workflow files changed while the palette lists them: read them again.
            .onChange(of: (workspace.host as? DaemonConnection)?.workspace.workflowsRev) {
                if model.isPaletteShown { model.loadWorkflows() }
            }
            .toastHost(model.toasts)
            .overlay(alignment: model.widthBucket == .compact ? .top : .topTrailing) { AgentToastStack() }
            .dictationIndicator()
            .portOffers(model)
            .editorPresentation(model)
            .sheet(item: $model.sheet) { route in
                SheetContent(route: route, workspace: workspace)
                    .environment(model)
                    .environment(model.app)
            }
            // The whole window follows the terminal theme: surfaces, text, accent and states
            // (`ChromePalette`), light or dark by `window-theme` (Ghostty: Match Terminal).
            .chromeTheme(theme, windowTheme: windowTheme)
            .modifier(ThemePairFollower())
            .focusedSceneValue(workspace)
            .focusedSceneValue(model)
            .renameTabPrompt(workspace)
            .modifier(MultiplayerWindowHooks(workspace: workspace))
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                // Settings write UserDefaults; the terminals follow through `TerminalAppearance`.
                let appearance = TerminalAppearance.fromPreferences()
                for open in model.workspaces.values where appearance != open.appearance { open.appearance = appearance }
            }
            .task {
                await DesignFixtures.apply(LaunchOptions.screen, workspace: workspace, model: model)
                if LaunchOptions.screen == "toggle" {
                    // Regression fixture: strip first, then the sidebar, as a user would switch.
                    model.isSidebarShown = false
                    try? await Task.sleep(for: .seconds(1))
                    model.isSidebarShown = true
                }
            }
            // Closing a host's last tab moves to the nearest tab on another host; on the Mac,
            // closing the last tab of all closes the window, as in Ghostty (not when a host is
            // open: its tabs live on the host, and an empty daemon session is still a session).
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
            // `-dogfood <scenario.json>`: the in-app scenario runner (App/Sources/Debug).
            .task { DogfoodRunner.startIfRequested(workspace: workspace) }
            #endif
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        // By the window's width, never the device (`WidthBucket`): an iPhone, a foldable, Split
        // View, Slide Over and Stage Manager windows all get the layout their width fits.
        if model.widthBucket == .compact {
            CompactRoot(workspace: workspace)
        } else {
            regular
        }
        #else
        regular
        #endif
    }

    /// edge, the terminal's own background family, a 1 pt divider; never a floating glass card)
    /// beside the detail column. Both tab placements share the detail column and its toolbar, so
    /// the toolbar looks the same in either.
    private var regular: some View {
        HStack(spacing: 0) {
            if model.isSidebarShown {
                SidebarColumn(workspace: workspace)
                    .frame(width: SidebarWidth.effective(sidebarWidth, for: dynamicTypeSize))
                    .movingTransition(.leading)
                SidebarDivider(width: $sidebarWidth)
            }
            NavigationStack {
                DetailColumn(workspace: workspace)
            }
        }
        .animation(DS.Motion.panel, value: model.isSidebarShown)
        .background(DS.Palette.base, ignoresSafeAreaEdges: .all)
        #if os(macOS)
        // Ghostty's window title: the directory, with its folder as the proxy icon.
        .modifier(RepresentedDirectory(path: workspace.isRemote ? nil : workspace.session.activeTab.flatMap(workspace.absoluteDirectory(of:))))
        // The titlebar is the terminal's and the sidebar's own background, seamless.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
                .toolbarBackground(DS.Palette.sidebar, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        }
        .background(DS.Palette.sidebar, ignoresSafeAreaEdges: .all)
        #else
        WorkspaceSidebar()
            .background(DS.Palette.sidebar, ignoresSafeAreaEdges: .all)
        #endif
    }
}

/// New Tab on the current host (⌘T); its menu (long press, or the arrow on the Mac) opens one on
/// any other host (⌥⌘T). Add Host where nothing can open a tab yet (iPhone, iPad).
struct NewTabButton: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        let groups = model.groups.groups
        if groups.count > 1 {
            Menu {
                Section("New Tab On") {
                    ForEach(groups) { group in
                        Button(group.name, systemImage: group.isLocal ? "laptopcomputer" : group.kind == .ssh ? "terminal" : "server.rack") {
                            model.newTab(onGroup: group.id)
                        }
                    }
                }
                Divider()
                Button("Add Host…", systemImage: "plus.circle") { model.addHost() }
            } label: {
                Label("New Tab", systemImage: "plus")
            } primaryAction: {
                model.newTab()
            }
            .menuIndicator(.hidden)
            .help("New Tab on \(model.hostName) (⌘T) · hold for another host (⌥⌘T)")
            .accessibilityIdentifier("new-tab")
        } else {
            Button(canOpen ? "New Tab" : "Add Host", systemImage: "plus") { model.newTab() }
                .help(canOpen ? "New Tab (⌘T)" : "Add Host")
                .accessibilityIdentifier("new-tab")
        }
    }

    private var canOpen: Bool { workspace.canOpenTabs || model.groups.newTabHost(preferred: nil) != nil }
}

/// The hairline between sidebar and terminal (the theme's ink at 15 %), draggable to resize the
/// sidebar; double-click/tap restores the default width.
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
                    .frame(width: 7)
                    .contentShape(.rect)
                    #if os(macOS)
                    .onHover { inside in if inside { NSCursor.columnResize.push() } else { NSCursor.pop() } }
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
            }
            .accessibilityHidden(true)
    }
}

#if os(macOS)
/// The window's represented folder: the titlebar shows its icon, and ⌘-clicking it shows the path.
private struct RepresentedDirectory: ViewModifier {
    let path: String?

    func body(content: Content) -> some View {
        if let path {
            content.navigationDocument(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            content
        }
    }
}
#endif

/// The detail column: the tab strip (tabs on top), then the active tab's panes, the Inbox or
/// Hosts, under one toolbar shared by both tab placements.
private struct DetailColumn: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true

    var body: some View {
        VStack(spacing: 0) {
            if !model.isSidebarShown && showsTabBar {
                TabBar(workspace: workspace)
                    .chromeContent()
                    .movingTransition(.top)
            }
            switch model.destination {
            case .terminal:
                // The active tab, a mixed tab, or Two Columns.
                TerminalArea(workspace: workspace)
                    // Behind the key bar and keyboard, which float over the terminal.
                    .background(theme.background.ignoresSafeArea(.all, edges: .bottom))
                    // The ink goes on each destination, under its own toolbar (Inbox and Hosts
                    // add bar items): never above a toolbar.
                    .chromeContent()
            case .inbox:
                InboxView(feed: model.agents, onLaunch: { model.sheet = .launchAgent }, onNewTerminal: { model.newTab() })
            case .hosts:
                HostsScreen()
            }
        }
        // Every destination fills the column, whatever its content's own size (an empty Inbox
        // is only as wide as its message, which shrank and centred the whole window).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if DEBUG
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { model.detailFrame = $0 })
        #endif
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DS.Palette.base, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        #endif
        .navigationSubtitle(model.destination == .terminal ? subtitle : "")
        .toolbar { TerminalToolbar(workspace: workspace) }
        .modifier(GitDialogs(git: model.git))
        .onChange(of: model.git.hub?.repos != nil, initial: true) { _, has in
            if has { model.git.syncAutoDelete() }
        }
        .background(DS.Palette.base, ignoresSafeAreaEdges: .all)
    }

    private var title: String {
        switch model.destination {
        case .terminal:
            model.activeMixed.map(model.title(ofMixedTab:)) ?? workspace.session.activeTab.map(workspace.title(of:)) ?? Brand.name
        case .inbox: "Inbox"
        case .hosts: "Hosts"
        }
    }

    /// task, the program, `repo:branch` or the directory) when it says something the title
    /// does not, then the split state. The host is named once, by the toolbar's host button.
    private var subtitle: String {
        if let mixed = model.activeMixed {
            return mixed.hosts.map(model.groupName).joined(separator: " + ")
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
        return parts.joined(separator: " · ")
    }
}

/// The window toolbar, identical with the sidebar shown or hidden: the sidebar toggle leading
/// (always there, in the same place: Safari, Finder, Xcode); presence, Hosts, Find, the pane
/// menu and the palette as one monochrome glass group.
private struct TerminalToolbar: ToolbarContent {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SidebarToggle()
        }
        if let session = workspace.multiplayer {
            ToolbarItem(placement: .primaryAction) {
                PresenceToolbarButton(session: session) { model.sheet = .invite }
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
        // The focused pane's worktree: its pull request beside the host, then Open and Run.
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
                #if os(macOS)
                Button("Draw on Pane", systemImage: "pencil.tip") { DrawingCommands.toggleDrawing(in: workspace) }
                    .disabled(!DrawingCommands.canDraw(in: workspace))
                #endif
            }
            .help("Pane: split, zoom, close, Two Columns")
            .menuIndicator(.hidden)
            .disabled((workspace.focusedPane == nil && model.activeMixed == nil) || model.destination != .terminal)
            .accessibilityIdentifier("pane-menu")
            #if os(iOS)
            // A Pencil device: drawing stays one tap away. On the Mac it is in the Pane menu.
            Button("Draw", systemImage: "pencil.tip") { DrawingCommands.toggleDrawing(in: workspace) }
                .help("Draw on Pane (⌃⌘D)")
                .disabled(!DrawingCommands.canDraw(in: workspace) || model.destination != .terminal)
                .accessibilityIdentifier("draw-button")
            #endif
            Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                .help("Command Palette (⌘K)")
                .accessibilityIdentifier("open-palette")
        }
    }
}


/// name, the icon replaced by the state glyph only while the link is not healthy. Hovering opens
/// them; the popover is the one place the round trip is shown. On this device's own window it
/// opens Hosts.
private struct HostToolbarButton: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        if workspace.isRemote {
            HoverPopover(isPresented: $showsDetails) {
                // A plain stack, not a Label: iPad toolbars reduce a Label to its icon.
                HStack(spacing: DS.Space.row) {
                    ConnectionGlyph(model.connection, healthy: Image(systemName: "server.rack"))
                    Text(model.hostName).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.row)
                .contentShape(.rect)
            } content: {
                HostDetailsPopover(workspace: workspace) {
                    showsDetails = false
                    toggleHosts()
                } onDisconnect: {
                    showsDetails = false
                    model.disconnect()
                }
            }
            .help(model.connection.isQuiet ? model.hostName : "\(model.hostName) · \(model.connection.title)")
            .accessibilityLabel("\(model.hostName), \(model.connection.title)")
            .accessibilityIdentifier("hosts-button")
        } else {
            Button("Hosts", systemImage: "server.rack") { toggleHosts() }
                .help("Hosts (⇧⌘H)")
                .accessibilityIdentifier("hosts-button")
        }
    }

    private func toggleHosts() {
        withAnimation(DS.Motion.snappy) { model.destination = model.destination == .hosts ? .terminal : .hosts }
    }
}

/// one line "address · 3 tabs · 12 ms", a divider, one row per tab (its mark or agent glyph, its
/// name, its state word right-aligned), then All Hosts and Disconnect. System padding and
/// spacing (O3), 260–480 wide, scrolling past 400.
private struct HostDetailsPopover: View {
    let workspace: Workspace
    let onAllHosts: () -> Void
    let onDisconnect: () -> Void
    @Environment(WindowModel.self) private var model

    var body: some View {
        let group = model.groups.groups.first { $0.id == workspace.hostId }
        let tabs = group?.tabs ?? []
        VStack(alignment: .leading) {
            (Text(stateWord + " ").foregroundStyle(DS.Palette.textSecondary) + Text(model.hostName))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary(tabs: tabs.count))
                .font(.subheadline)
                .foregroundStyle(DS.Palette.textSecondary)
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !tabs.isEmpty, let group {
                Divider()
                ForEach(tabs) { tab in
                    let ref = group.ref(tab.id)
                    let state = tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: group.id) }.min { $0.urgency < $1.urgency }
                    let title = model.workspace(ofGroup: group.id)?.title(of: tab) ?? tab.title ?? "Shell"
                    Button {
                        model.focus(ref)
                    } label: {
                        HStack(spacing: DS.Space.row) {
                            TabLeadingMark(program: model.programIdentity(of: tab, onGroup: group.id), state: state)
                            Text(title).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: DS.Space.s)
                            Text(model.currentTab == ref ? "Open" : state.flatMap { $0 == .idle || $0 == .unknown ? nil : $0.title } ?? "")
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                        .font(.caption)
                        .padding(.vertical, DS.Space.xxs)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("host-details-tab-\(tab.id.rawValue)")
                }
            }
            Divider()
            HStack {
                Button("All Hosts", action: onAllHosts)
                    .help("Hosts (⇧⌘H)")
                Spacer()
                Button("Disconnect", role: .destructive, action: onDisconnect)
            }
            .buttonStyle(.borderless)
        }
        .hoverPopoverFrame()
        .accessibilityIdentifier("host-details")
    }

    /// The status word before the name: "Connected", "Reconnecting", …
    private var stateWord: String {
        model.connection.title
    }

    private func summary(tabs: Int) -> String {
        var parts: [String] = []
        if let address = model.hosts.hosts.first(where: { $0.id == workspace.hostId })?.address, !address.isEmpty {
            parts.append(address)
        }
        parts.append(tabs == 1 ? "1 tab" : "\(tabs) tabs")
        if let status = workspace.host?.status, case .connected(let rtt?) = status {
            parts.append("\(Int((rtt / .milliseconds(1)).rounded())) ms")
        } else if let status = workspace.host?.status, !status.isLive {
            parts.append(status.summary)
        }
        return parts.joined(separator: " · ")
    }
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
            }
            SwiftUI.Tab("Inbox", systemImage: "tray", value: Destination.inbox) {
                NavigationStack {
                    InboxView(feed: model.agents, onLaunch: { model.sheet = .launchAgent }, onNewTerminal: { model.newTab() })
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
    }
}
#endif

/// The active tab's panes: its split tree, the zoomed pane alone, or only the focused pane in
/// compact width (no splits on iPhone, 04-mobile-ux C3). Without tabs: the welcome state.
struct ActiveTabView: View {
    let workspace: Workspace
    var compact = false
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    var body: some View {
        Group {
            if let tab = workspace.session.activeTab {
                let single = compact ? tab.focused : tab.zoomed
                let isSplit = single == nil && tab.root.panes.count > 1
                SplitTreeView(node: single.map(Node.leaf) ?? tab.root, workspace: workspace, isSplit: isSplit)
                    .padding(paneStyle == .comfortable && isSplit ? DS.Space.row : 0)
                    .background(paneStyle == .comfortable && isSplit ? theme.splitDivider : theme.background, ignoresSafeAreaEdges: [])
                    // Lost link: the last frame stays, dimmed and desaturated, under the card.
                    .connectionOverlay(
                        model.connection, hostName: model.hostName,
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

/// words, the system spinner only after a 1 s grace, and actions only when something failed
private struct ConnectingView: View {
    let hostName: String
    let state: ConnectionState
    let onRetry: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
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
            VStack(spacing: 2) {
                if workspace.canOpenTabs {
                    welcomeRow("New Terminal", systemImage: "plus", keys: ["⌘", "T"]) { model.newTab(onGroup: model.currentGroupId) }
                        .disabled(!workspace.isLayoutLive)
                        .help(workspace.isLayoutLive ? "" : model.layoutUnavailableHelp)
                        .accessibilityIdentifier("welcome-new-terminal")
                    welcomeRow("Start an Agent…", systemImage: "sparkle", keys: nil) { model.sheet = .launchAgent }
                    if !workspace.isRemote {
                        welcomeRow("Connect to a Host…", systemImage: "server.rack", keys: nil) { model.addHost() }
                    }
                } else {
                    welcomeRow("Connect with SSH…", systemImage: "terminal", keys: nil) { model.addHost(mode: .ssh) }
                        .accessibilityIdentifier("welcome-ssh")
                    welcomeRow("Paste a Pairing Ticket…", systemImage: "doc.on.clipboard", keys: nil) { model.addHost(mode: .ticket) }
                        .accessibilityIdentifier("welcome-ticket")
                    #if os(iOS)
                    welcomeRow("Scan a QR Code…", systemImage: "qrcode.viewfinder", keys: nil) { model.addHost(mode: .scan) }
                        .accessibilityIdentifier("welcome-scan")
                    #endif
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
            : "Pair a machine running the helper, or connect to any SSH host. Sessions keep running there while this device sleeps."
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
            // The sidebar's row: a 16 pt glyph slot at 0.6, the label leading.
            HStack(spacing: DS.Space.gap10) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.primary)
                    .opacity(DS.Opacity.mutedGlyph)
                Text(title).foregroundStyle(.primary)
                Spacer()
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
            PairingSheet(directory: model.hosts, live: LaunchOptions.mock ? nil : model.app.hosts, initialMode: model.pairingMode, destination: model.pairingDestination)
        case .launchAgent, .links, .diff, .files, .browser, .editor:
            ToolSheet(route: route)
        case .invite:
            InviteSheet(workspace: workspace)
        case .join:
            JoinSheet(invite: model.joinInvite.isEmpty ? UserDefaults.standard.string(forKey: "joinInvite") ?? "" : model.joinInvite)
        case .settings:
            SettingsView()
        case .shortcuts:
            ShortcutsSheet()
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
