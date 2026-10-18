import DesignSystem
import PaneLayout
import SwiftUI

/// Where tabs are listed in regular-width windows.
enum TabStyle: String {
    /// A vertical tab list in a collapsible sidebar (the default on iPad and Mac).
    case sidebar
    /// A horizontal tab strip above the panes.
    case bar
}

/// A window: tabs (sidebar, strip, or the compact layout on iPhone) around the active tab's panes,
/// plus the window-wide overlays (command palette, toasts) and sheets.
struct WorkspaceView: View {
    @State private var workspace = Workspace()
    @State private var model = AppModel()
    @AppStorage("tabStyle") private var tabStyle = TabStyle.sidebar
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.system
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @Environment(\.dismiss) private var dismiss
    #endif

    private var theme: TerminalTheme { ThemeCatalog.theme(named: themeName) }

    var body: some View {
        content
            .overlay(alignment: .top) {
                if model.isPaletteShown {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.0001)
                            .ignoresSafeArea()
                            .onTapGesture { model.isPaletteShown = false }
                        CommandPalette(isPresented: $model.isPaletteShown, commands: PaletteCommands.all(workspace: workspace, model: model))
                            .padding(.top, 44)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
            }
            .animation(DS.Motion.overlay, value: model.isPaletteShown)
            .toastHost(model.toasts)
            .sheet(item: $model.sheet) { route in
                SheetContent(route: route, workspace: workspace)
                    .environment(model)
            }
            .environment(model)
            .environment(\.terminalTheme, theme)
            .focusedSceneValue(workspace)
            .focusedSceneValue(model)
            .preferredColorScheme(preferredScheme)
            .renameTabPrompt(workspace)
            .task {
                DesignFixtures.apply(LaunchOptions.screen, workspace: workspace, model: model)
                if LaunchOptions.screen == "toggle" {
                    // Regression fixture: strip first, then vertical tabs, as a user would switch.
                    tabStyle = .bar
                    try? await Task.sleep(for: .seconds(1))
                    tabStyle = .sidebar
                }
            }
            #if os(macOS)
            // Closing the last pane closes the window, as in Ghostty.
            .onChange(of: workspace.session.tabs.isEmpty) { _, isEmpty in
                if isEmpty && LaunchOptions.screen == nil { dismiss() }
            }
            #endif
    }

    /// Ghostty `window-theme`: follow the system (default), the terminal background, or force one.
    private var preferredScheme: ColorScheme? {
        switch windowTheme {
        #if os(macOS)
        // With tabs on top the window is all terminal and titlebar, as in Ghostty: follow the
        // terminal so the title and tabs read on its background.
        case .system where tabStyle == .bar: theme.isLight ? .light : .dark
        #endif
        case .system: nil
        case .auto: theme.isLight ? .light : .dark
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

    @ViewBuilder private var regular: some View {
        switch tabStyle {
        case .sidebar:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                WorkspaceSidebar(workspace: workspace)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 248, max: 340)
            } detail: {
                DetailColumn(workspace: workspace, tabStyle: $tabStyle)
            }
            // Choosing vertical tabs always shows them, whatever the sidebar was last collapsed to.
            .onAppear { columnVisibility = .all }
        case .bar:
            VStack(spacing: 0) {
                TabBar(workspace: workspace, style: $tabStyle)
                ActiveTabView(workspace: workspace)
            }
            .background(theme.background.ignoresSafeArea())
            .environment(\.colorScheme, theme.isLight ? .light : .dark)
            #if os(macOS)
            // Ghostty's window title: the directory, with its folder as the proxy icon.
            .navigationTitle(workspace.session.activeTab.map(workspace.title(of:)) ?? Brand.name)
            .modifier(RepresentedDirectory(path: workspace.session.activeTab.flatMap { workspace.foregrounds[$0.focused]?.directory }))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu("Pane", systemImage: "rectangle.split.2x1") {
                        PaneMenuItems(workspace: workspace, model: model)
                    }
                    .menuIndicator(.hidden)
                    .accessibilityIdentifier("pane-menu")
                    Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                    TabStyleToggle(style: $tabStyle)
                }
            }
            .toolbarBackground(theme.background, for: .windowToolbar)
            .toolbarColorScheme(theme.isLight ? .light : .dark, for: .windowToolbar)
            #endif
        }
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

/// The detail column: the active tab's panes, the Inbox or Hosts.
private struct DetailColumn: View {
    let workspace: Workspace
    @Binding var tabStyle: TabStyle
    @Environment(AppModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        switch model.destination {
        case .terminal:
            // When the window and the terminal agree on light/dark (the default: dark theme, dark
            // mode) the terminal runs up under the floating toolbar, seamless like Ghostty's
            // transparent titlebar. When they disagree the toolbar band keeps the window's own
            // background, so the status bar and title stay legible over both columns.
            let terminalScheme: ColorScheme = theme.isLight ? .light : .dark
            let seamless = terminalScheme == systemScheme
            ActiveTabView(workspace: workspace)
                .environment(\.colorScheme, terminalScheme)
                .navigationTitle(workspace.session.activeTab.map(workspace.title(of:)) ?? Brand.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationSubtitle(subtitle)
                .toolbar { TerminalToolbar(workspace: workspace, tabStyle: $tabStyle) }
                // Never under the sidebar: its glass would sample the terminal and turn muddy.
                // Always behind the key bar and keyboard, which float over the terminal.
                .background(theme.background.ignoresSafeArea(.all, edges: seamless ? [.top, .bottom] : [.bottom]))
        case .inbox:
            NavigationStack {
                InboxView(feed: model.agents, onLaunch: { model.sheet = .launchAgent })
            }
        case .hosts:
            NavigationStack {
                HostsView(directory: model.hosts, onAdd: { model.sheet = .pairing }, onOpen: { _ in model.destination = .terminal })
            }
        }
    }

    private var subtitle: String {
        guard let tab = workspace.session.activeTab else { return "" }
        let count = tab.root.panes.count
        let panes = count > 1 ? (tab.zoomed == nil ? " · \(count) panes" : " · zoomed") : ""
        return "Local\(panes)"
    }
}

/// Trailing toolbar of the terminal: presence, find, pane menu, palette, tab placement.
private struct TerminalToolbar: ToolbarContent {
    let workspace: Workspace
    @Binding var tabStyle: TabStyle
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        if LaunchOptions.mock {
            ToolbarItem(placement: .primaryAction) {
                Button { model.sheet = .invite } label: {
                    PresenceStack(MockPresence.participants)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share Session")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Find", systemImage: "magnifyingglass") { model.isSearchShown.toggle() }
                .help("Find (⌘F)")
            Menu("Pane", systemImage: "rectangle.split.2x1") {
                PaneMenuItems(workspace: workspace, model: model)
            }
            .menuIndicator(.hidden)
            .disabled(workspace.focusedPane == nil)
            .accessibilityIdentifier("pane-menu")
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

#if os(iOS)
/// iPhone: Terminal, Inbox and Hosts as tabs in the system's floating Liquid Glass tab bar.
private struct CompactRoot: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.destination) {
            SwiftUI.Tab("Terminal", systemImage: "terminal", value: Destination.terminal) {
                CompactTerminalView(workspace: workspace)
            }
            SwiftUI.Tab("Inbox", systemImage: "tray", value: Destination.inbox) {
                NavigationStack {
                    InboxView(feed: model.agents, onLaunch: { model.sheet = .launchAgent })
                }
            }
            .badge(model.needsYouCount)
            SwiftUI.Tab("Hosts", systemImage: "server.rack", value: Destination.hosts) {
                NavigationStack {
                    HostsView(directory: model.hosts, onAdd: { model.sheet = .pairing }, onOpen: { _ in model.destination = .terminal })
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
    @Environment(AppModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    var body: some View {
        Group {
            if let tab = workspace.session.activeTab {
                let single = compact ? tab.focused : tab.zoomed
                let isSplit = single == nil && tab.root.panes.count > 1
                SplitTreeView(node: single.map(Node.leaf) ?? tab.root, workspace: workspace, isSplit: isSplit)
                    .padding(paneStyle == .comfortable && isSplit ? DS.Space.xs + 2 : 0)
                    .background(paneStyle == .comfortable && isSplit ? theme.splitDivider : theme.background)
                    .connectionOverlay(
                        model.connection, hostName: "studio",
                        onRetry: { model.connection = .connected },
                        onDisconnect: { model.connection = .connected })
            } else {
                WelcomeView(workspace: workspace)
            }
        }
        .background(theme.background)
    }
}

private struct WelcomeView: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(spacing: DS.Space.xxl) {
            VStack(spacing: DS.Space.s) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(theme.foreground.opacity(0.5))
                Text("No Open Tabs")
                    .font(DS.Font.title)
                    .foregroundStyle(theme.foreground)
                Text("Open a shell here, or connect to a host to pick up its sessions.")
                    .font(.callout)
                    .foregroundStyle(theme.foreground.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 2) {
                welcomeRow("New Tab", systemImage: "plus", keys: ["⌘", "T"]) { workspace.apply(.newTab) }
                welcomeRow("Connect to a Host…", systemImage: "server.rack", keys: nil) { model.sheet = .pairing }
                welcomeRow("Start an Agent…", systemImage: "sparkle", keys: nil) { model.sheet = .launchAgent }
                welcomeRow("Command Palette", systemImage: "command", keys: ["⌘", "K"]) { model.isPaletteShown = true }
            }
            .frame(width: 300)
        }
        .padding(DS.Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("welcome")
    }

    private func welcomeRow(_ title: String, systemImage: String, keys: [String]?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(theme.foreground.opacity(0.6))
                Text(title).foregroundStyle(theme.foreground)
                Spacer()
                if let keys { ShortcutLabel(keys) }
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
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch route {
        case .pairing:
            PairingSheet(directory: model.hosts)
        case .launchAgent:
            LaunchAgentSheet(feed: model.agents, hosts: model.hosts.hosts)
        case .invite:
            InviteSheet(
                sessionTitle: workspace.session.activeTab.map(workspace.title(of:)) ?? Brand.name,
                participants: MockPresence.participants)
        case .links:
            LinksSheet(links: MockLinks.links)
        case .diff:
            sheetStack { DiffReviewView(source: model.diffs) }
        case .files:
            sheetStack {
                FilesBrowserView(source: model.files) { _ in model.sheet = .editor }
            }
        case .browser:
            BrowserView(initialURL: URL(string: "https://ghostty.org/docs")!)
                .frame(minWidth: 640, minHeight: 480)
                .presentationSizing(.page)
        case .editor:
            EditorView(source: model.files, path: "~/projects/unnamed/Cargo.toml")
                .frame(minWidth: 640, minHeight: 480)
                .presentationSizing(.page)
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
        .frame(minWidth: 640, minHeight: 520)
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
