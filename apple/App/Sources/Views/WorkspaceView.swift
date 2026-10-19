import DesignSystem
import PaneLayout
import TerminalRenderer
import SwiftUI
import TerminalCore

/// Where tabs are listed in regular-width windows.
enum TabStyle: String {
    /// A vertical tab list in a collapsible sidebar (the default on iPad and Mac).
    case sidebar
    /// A horizontal tab strip above the panes.
    case bar
}

/// A window: tabs (sidebar, strip, or the compact layout on iPhone) around the active tab's panes,
/// plus the window-wide overlays (command palette, toasts) and sheets. The workspace is the
/// window's target (this device or a host, `WindowRoot`); the window model outlives it.
struct WorkspaceView: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @AppStorage("tabStyle") private var tabStyle = TabStyle.sidebar
    @AppStorage("sidebarShown") private var sidebarShown = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 248.0
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
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
                            placeholder: PaletteCommands.placeholder(model.paletteMode))
                            // A fresh query and selection per mode (⌘K, ⌘P, ⌥⌘T).
                            .id(model.paletteMode)
                            .padding(.top, 44)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
            }
            .animation(DS.Motion.overlay, value: model.isPaletteShown)
            .toastHost(model.toasts)
            .dictationIndicator()
            .portOffers(model)
            .editorPresentation(model)
            .sheet(item: $model.sheet) { route in
                SheetContent(route: route, workspace: workspace)
                    .environment(model)
                    .environment(model.app)
            }
            .environment(\.terminalTheme, theme)
            .focusedSceneValue(workspace)
            .focusedSceneValue(model)
            .preferredColorScheme(preferredScheme)
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
                    // Regression fixture: strip first, then vertical tabs, as a user would switch.
                    tabStyle = .bar
                    try? await Task.sleep(for: .seconds(1))
                    tabStyle = .sidebar
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


    /// Ghostty `window-theme`: the terminal background decides light or dark (the default,
    /// "Match Terminal"), or the system, or forced. The chrome never shows a white sidebar or
    /// toolbar next to a dark terminal.
    private var preferredScheme: ColorScheme? {
        switch windowTheme {
        case .system: nil
        case .auto: theme.colorScheme
        case .light: .light
        case .dark: .dark
        }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if sizeClass == .compact {
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
            if tabStyle == .sidebar && sidebarShown {
                SidebarColumn(workspace: workspace)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SidebarDivider(width: $sidebarWidth)
            }
            NavigationStack {
                DetailColumn(workspace: workspace, tabStyle: $tabStyle, sidebarShown: $sidebarShown)
            }
        }
        .animation(DS.Motion.panel, value: tabStyle == .sidebar && sidebarShown)
        .background(theme.background.ignoresSafeArea())
        // Choosing vertical tabs always shows them, whatever the sidebar was last collapsed to.
        .onChange(of: tabStyle) { _, style in if style == .sidebar { sidebarShown = true } }
        .onAppear { if tabStyle == .sidebar { sidebarShown = true } }
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

/// The sidebar column on the terminal's background family. On iPad it has its own bar (the
/// app name and New Tab) level with the detail's; on the Mac it runs up under the titlebar.
private struct SidebarColumn: View {
    let workspace: Workspace
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        #if os(iOS)
        NavigationStack {
            WorkspaceSidebar()
                .navigationTitle(Brand.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        NewTabButton(workspace: workspace)
                    }
                }
                .toolbarBackground(theme.sidebarBackground, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        }
        .background(theme.sidebarBackground.ignoresSafeArea())
        .environment(\.colorScheme, theme.colorScheme)
        // The keyboard and its key bar float over the sidebar; its footer stays at the bottom.
        .ignoresSafeArea(.keyboard)
        #else
        WorkspaceSidebar()
            .background(theme.sidebarBackground.ignoresSafeArea())
            .environment(\.colorScheme, theme.colorScheme)
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

/// The 1 pt line between sidebar and terminal (the split divider's color), draggable to resize
/// the sidebar; double-click/tap restores the default width.
private struct SidebarDivider: View {
    @Binding var width: Double
    @Environment(\.terminalTheme) private var theme
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(theme.splitDivider)
            .frame(width: 1)
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
                                width = min(max(origin + value.translation.width, 200), 360)
                            }
                            .onEnded { _ in start = nil })
                    .onTapGesture(count: 2) { width = 248 }
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
    @Binding var tabStyle: TabStyle
    @Binding var sidebarShown: Bool
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if tabStyle == .bar {
                TabBar(workspace: workspace, style: $tabStyle)
            }
            switch model.destination {
            case .terminal:
                ActiveTabView(workspace: workspace)
                    // Pane ids are per host: never reuse one host's pane views for another's.
                    .id(ObjectIdentifier(workspace))
                    // Behind the key bar and keyboard, which float over the terminal.
                    .background(theme.background.ignoresSafeArea(.all, edges: .bottom))
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
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        #endif
        .navigationSubtitle(model.destination == .terminal ? subtitle : "")
        .toolbar { TerminalToolbar(workspace: workspace, tabStyle: $tabStyle, sidebarShown: $sidebarShown) }
        .background(theme.background.ignoresSafeArea())
    }

    private var title: String {
        switch model.destination {
        case .terminal: workspace.session.activeTab.map(workspace.title(of:)) ?? Brand.name
        case .inbox: "Inbox"
        case .hosts: "Hosts"
        }
    }

    /// The split state only: the host is named once, by the toolbar's host button.
    private var subtitle: String {
        guard let tab = workspace.session.activeTab, tab.root.panes.count > 1 else { return "" }
        return tab.zoomed == nil ? "\(tab.root.panes.count) panes" : "Zoomed"
    }
}

/// The window toolbar, identical in both tab placements: the sidebar toggle leading; presence,
/// Hosts, Find, the pane menu and the palette as one monochrome glass group; the tab placement
/// toggle on its own.
private struct TerminalToolbar: ToolbarContent {
    let workspace: Workspace
    @Binding var tabStyle: TabStyle
    @Binding var sidebarShown: Bool
    @Environment(WindowModel.self) private var model

    var body: some ToolbarContent {
        if tabStyle == .sidebar {
            ToolbarItem(placement: .navigation) {
                Button(sidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.leading") {
                    withAnimation(DS.Motion.panel) { sidebarShown.toggle() }
                }
                .help("Toggle Sidebar")
                .tint(.primary)
                .accessibilityIdentifier("toggle-sidebar")
            }
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Find", systemImage: "magnifyingglass") { model.isSearchShown.toggle() }
                .help("Find (⌘F)")
                .disabled(model.destination != .terminal)
            Menu("Pane", systemImage: "rectangle.split.2x1") {
                PaneMenuItems(workspace: workspace, model: model)
            }
            .menuIndicator(.hidden)
            .disabled(workspace.focusedPane == nil || model.destination != .terminal)
            .accessibilityIdentifier("pane-menu")
            Button("Draw", systemImage: "pencil.tip") { DrawingCommands.toggleDrawing(in: workspace) }
                .help("Draw on Pane (⌃⌘D)")
                .disabled(!DrawingCommands.canDraw(in: workspace) || model.destination != .terminal)
                .accessibilityIdentifier("draw-button")
            Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                .help("Command Palette (⌘K)")
                .accessibilityIdentifier("open-palette")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            TabStyleToggle(style: $tabStyle)
        }
    }
}


/// name, the icon replaced by the state glyph only while the link is not healthy. The popover is
/// the one place the round trip is shown. On this device's own window it opens Hosts.
private struct HostToolbarButton: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        if workspace.isRemote {
            Button { showsDetails.toggle() } label: {
                Label {
                    Text(model.hostName)
                } icon: {
                    ConnectionGlyph(model.connection, healthy: Image(systemName: "server.rack"))
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(model.connection.isQuiet ? .primary : .secondary)
            }
            .help(model.connection.isQuiet ? model.hostName : "\(model.hostName) · \(model.connection.title)")
            .accessibilityIdentifier("hosts-button")
            .popover(isPresented: $showsDetails) { details }
        } else {
            Button("Hosts", systemImage: "server.rack") { toggleHosts() }
                .help("Hosts (⇧⌘H)")
                .accessibilityIdentifier("hosts-button")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(model.hostName).font(.headline)
            if let address = model.hosts.hosts.first(where: { $0.id == workspace.hostId })?.address, !address.isEmpty {
                Text(address)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: DS.Space.xs + 2) {
                ConnectionGlyph(model.connection)
                Text(workspace.host?.status.summary ?? model.connection.title)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Divider().padding(.vertical, DS.Space.xs)
            HStack {
                Button("All Hosts") {
                    showsDetails = false
                    toggleHosts()
                }
                Spacer()
                Button("Disconnect", role: .destructive) {
                    showsDetails = false
                    model.disconnect()
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(DS.Space.l)
        .frame(minWidth: 260)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("host-details")
    }

    private func toggleHosts() {
        withAnimation(DS.Motion.snappy) { model.destination = model.destination == .hosts ? .terminal : .hosts }
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
                    .padding(paneStyle == .comfortable && isSplit ? DS.Space.xs + 2 : 0)
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
    }
}

/// words, the system spinner only after a 1 s grace, and actions only when something failed
private struct ConnectingView: View {
    let hostName: String
    let state: ConnectionState
    let onRetry: () -> Void
    let onDisconnect: () -> Void
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(spacing: DS.Space.m) {
            ConnectionGlyph(state)
                .font(.title2)
                .frame(height: 28)
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(theme.foreground)
            if let detail {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(context.date))
                        .font(.callout)
                        .foregroundStyle(theme.foreground.opacity(0.6))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            if let action {
                HStack(spacing: DS.Space.s) {
                    Button("Disconnect", action: onDisconnect)
                        .buttonStyle(.glass)
                    Button(action, action: onRetry)
                        .buttonStyle(.glassProminent)
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
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(spacing: DS.Space.xxl) {
            VStack(spacing: DS.Space.s) {
                Image(systemName: workspace.canOpenTabs ? "terminal" : "server.rack")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(theme.foreground.opacity(0.5))
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(theme.foreground)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(theme.foreground.opacity(0.6))
                    .multilineTextAlignment(.center)
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
            HStack(spacing: DS.Space.m) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(theme.foreground.opacity(0.6))
                Text(title).foregroundStyle(theme.foreground)
                Spacer()
                if let keys, showsShortcuts { ShortcutLabel(keys) }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s + 1)
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
