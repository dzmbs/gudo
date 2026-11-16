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
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The layout's frame in window points: where the fold falls within it.
    @State private var frame = CGRect.zero
    /// Whether the sidebar shows, once its last show or hide has settled.
    @State private var sidebarRests = true
    @State private var lastSidebarShown = SidebarShownMemo()
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto
    @AppStorage(ToastPosition.key) private var toastPosition = ToastPosition.standard
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact
    @AppStorage(TerminalPreferences.Key.paneContentCard) private var paneContentCard = TerminalPreferences.Default.paneContentCard
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private var theme: TerminalTheme { ThemeCatalog.theme(named: themeName) }

    /// The sidebar's width while it is shown beside the panes.
    private var sidebarInset: CGFloat {
        model.isSidebarShown && model.widthBucket != .compact ? SidebarWidth.effective(sidebarWidth, for: dynamicTypeSize) : 0
    }

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
            .overlay(alignment: toastPosition.alignment) { AgentToastStack(position: toastPosition) }
            // At the top, clear of the pane headers' buttons.
            // Clear of the sidebar's footer (New Project, Settings) at the bottom left.
            .toastHost(model.toasts, bottomInset: PortOfferBanner.bottomInset(model)
                + (model.ports.offer != nil && !model.editorHasKeys ? PortOfferBanner.height + DS.Space.s : 0),
                topInset: PaneHeader.height + DS.Space.l, leadingInset: sidebarInset)
            .dictationIndicator()
            .portOffers(model, leadingInset: sidebarInset)
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
        let card = ContentCard.isShown(style: paneStyle, isOn: paneContentCard, compact: false) && !model.isEditorFullScreen
        let width = page ?? SidebarWidth.effective(sidebarWidth, for: dynamicTypeSize)
        let gutter = shown && page != nil ? layout.gutter : 0
        // Here rather than in `onChange`: the canvas must still have the size it had before the
        // change, and hiding the sidebar widens the detail column in the same layout pass.
        if lastSidebarShown.update(shown), model.destination == .terminal, !model.isEditorFullScreen, deck == nil {
            let sidebar = width + (page != nil ? layout.gutter : 0)
            model.arrangement.prepareTerminals(
                resizingCanvasBy: CGSize(width: shown ? -sidebar : sidebar, height: stripRoom(shown: shown, pages: layout.isPages)),
                within: DS.Motion.structuralSettle)
        }
        return VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // Laid out at its resting width, so its terminals resize once: at the end
                    // when the sidebar comes in (it slides out past the edge meanwhile), at the
                    // start when it goes (held on their last frame until it settles).
                    NavigationStack {
                        DetailColumn(workspace: workspace)
                    }
                    .frame(width: SidebarSlide.detailWidth(
                        window: geometry.size.width, sidebar: width + gutter, shown: shown, resting: sidebarRests == shown))
                    .transaction(value: sidebarRests == shown) { $0.animation = nil }
                    // Interpolated here, above the frame that must not animate: a plain offset
                    // of that frame took its transaction and snapped to where it was going.
                    .modifier(SlideOffset(x: SidebarSlide.detailOffset(sidebar: width + gutter, shown: shown)))
                    if shown, page != nil {
                        FoldGutter().frame(width: layout.gutter).offset(x: width)
                    }
                    // Always mounted and slid in by its offset: inserting it with a transition
                    // rebuilds its navigation stack and toolbar mid-animation, which stutters.
                    SidebarColumn(workspace: workspace)
                        .frame(width: width)
                        // The bar over the column is the sidebar's own surface, up to the window's
                        // top edge.
                        .background { Rectangle().fill(DS.Palette.sidebar).ignoresSafeArea(edges: .top) }
                        .overlay(alignment: .trailing) {
                            // A page ends at the fold: no divider to drag there.
                            // On one colour with the card's surround, the divider drags without a line.
                            if page == nil { SidebarDivider(width: $sidebarWidth, showsLine: !card).opacity(shown ? 1 : 0) }
                        }
                        .modifier(SlideOffset(x: SidebarSlide.sidebarOffset(sidebar: width, shown: shown)))
                        .allowsHitTesting(shown)
                        .disabled(!shown)
                        .accessibilityHidden(!shown)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipShape(SidesOnly())
            }
            .task(id: shown) {
                try? await Task.sleep(for: .milliseconds(Int(DS.Motion.structuralSettle * 1000)))
                guard !Task.isCancelled else { return }
                sidebarRests = shown
            }
            .frame(height: deck)
            // The keyboard rises over the deck, never the screen above: no reflow as it comes up.
            .ignoresSafeArea(.keyboard, edges: deck == nil ? [] : .bottom)
            #if os(iOS)
            if deck != nil {
                FoldGutter().frame(height: layout.gutter)
                TabletopDeck(workspace: workspace)
                    .frame(maxHeight: .infinity)
                    // motion-lint-allow: the deck rises its whole height, in the fold's structural spring.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            #endif
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { newFrame in
            frame = newFrame
            #if os(macOS)
            model.windowWidthChanged(to: newFrame.width, sidebar: width + (page != nil ? layout.gutter : 0))
            #else
            // An iPhone on its side: the terminal keeps the width; the sidebar is a tap away.
            if UIDevice.current.userInterfaceIdiom == .phone, page == nil {
                model.windowWidthChanged(to: newFrame.width, sidebar: width)
            }
            #endif
        }
        .animation(DS.Motion.structural, value: model.isSidebarShown)
        .animation(DS.Motion.standard, value: model.isEditorFullScreen)
        .environment(\.showsContentCard, card)
        .chromeBackground(card ? DS.Palette.sidebar : DS.Palette.base)
        #if os(macOS)
        .background(RepresentedDirectory(path: workspace.isRemote ? nil : workspace.session.activeTab.flatMap(workspace.absoluteDirectory(of:))))
        #endif
    }

    /// The height the canvas gains as the sidebar shows (the strip above the panes goes) or
    /// loses as it hides. On the Mac the strip is the title bar's own row: the canvas keeps its
    /// height.
    private func stripRoom(shown: Bool, pages: Bool) -> CGFloat {
        #if os(macOS)
        return 0
        #else
        let strip = showsTabBar && !model.isEditorFullScreen && !pages ? DS.Size.tabStrip : 0
        return shown ? strip : -strip
        #endif
    }
}

/// The sidebar's shown state as the window's body last saw it.
@MainActor
final class SidebarShownMemo {
    private var shown: Bool?

    /// Records `shown`; true when it changed since the last time.
    func update(_ shown: Bool) -> Bool {
        defer { self.shown = shown }
        return self.shown.map { $0 != shown } ?? false
    }
}

/// Clips what slides past the window's sides, and nothing at the top: the sidebar's colour and
/// its divider run up under the title bar to the window's edge.
private nonisolated struct SidesOnly: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -rect.height))
    }
}

/// Where the sidebar and the detail column go as the sidebar shows or hides: both slide by
/// their offsets, and the detail keeps the width it had until the sidebar has come in.
enum SidebarSlide {
    static func detailWidth(window: CGFloat, sidebar: CGFloat, shown: Bool, resting: Bool) -> CGFloat {
        shown && resting ? max(0, window - sidebar) : window
    }

    static func detailOffset(sidebar: CGFloat, shown: Bool) -> CGFloat { shown ? sidebar : 0 }

    static func sidebarOffset(sidebar: CGFloat, shown: Bool) -> CGFloat { shown ? 0 : -sidebar }
}

/// A horizontal offset that animates as a value of its own, whatever the transaction of the
/// view it moves.
struct SlideOffset: ViewModifier, Animatable {
    var x: CGFloat

    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(x: x)
    }
}

/// The panes under the tab strip as it comes or goes. Laid out once, at their new place, they
/// start where they were and travel there in the structural spring, drawn over the strip, so a
/// pane header never jumps by the strip's height or sits under it while it fades.
struct StripRoom: ViewModifier {
    let stripShown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: stripShown) { content, offset in
            content.offset(y: reduceMotion ? 0 : offset)
        } keyframes: { _ in
            Self.keyframes(stripShown: stripShown)
        }
    }

    /// From where the panes were (above their new place when the strip arrives, below it when
    /// it goes) to rest, by `structuralSettle`.
    @KeyframesBuilder<CGFloat>
    static func keyframes(stripShown: Bool) -> some Keyframes<CGFloat> {
        KeyframeTrack {
            MoveKeyframe(stripShown ? -DS.Size.tabStrip : DS.Size.tabStrip)
            SpringKeyframe(0, duration: DS.Motion.structuralSettle, spring: DS.Motion.Role.structural.spring)
        }
    }
}

/// A Mac window or an iPhone in landscape too narrow for the sidebar beside a useful terminal
/// hides it, and shows it again once it is wide enough, unless the user showed or hid it meanwhile.
struct SidebarWidthFit {
    /// About 80 columns of terminal beside a sidebar of the standard width.
    static let hideBelow: CGFloat = 900
    /// A little wider, so a window resized around the edge does not flicker.
    static let showFrom: CGFloat = 960

    private var hidForWidth = false
    private var isNarrow = false
    private var userChoseWhileNarrow = false

    /// Whether the sidebar should show now, or nil to leave it as it is. `room` is the sidebar
    /// and the panes at their smallest: narrower than that, the sidebar goes even where the user
    /// showed it, so no pane is squeezed out of sight.
    mutating func widthChanged(to width: CGFloat, isShown: Bool, room: CGFloat = 0) -> Bool? {
        let crowded = width < room
        if width < Self.hideBelow || crowded {
            isNarrow = true
            guard isShown, crowded || !userChoseWhileNarrow else { return nil }
            hidForWidth = true
            return false
        }
        guard width >= max(Self.showFrom, room + Self.showFrom - Self.hideBelow) else { return nil }
        isNarrow = false
        userChoseWhileNarrow = false
        guard hidForWidth else { return nil }
        hidForWidth = false
        return isShown ? nil : true
    }

    /// The user showed or hid the sidebar: that holds until the window is wide again.
    mutating func userChose() {
        hidForWidth = false
        if isNarrow { userChoseWhileNarrow = true }
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
/// app name and New Tab) level with the detail's; on the Mac its colour runs up under the
/// titlebar while its rows start below it.
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
        // The list scrolls under the band, which has no background: clipped at its edge, no
        // row sits beneath the traffic lights and the sidebar toggle.
        WorkspaceSidebar()
            .clipped()
            .chromeBackground(DS.Palette.sidebar)
        #endif
    }
}

/// The + menu; Add Host alone where nothing can open a tab yet.
struct NewTabButton: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        if canOpen {
            #if os(macOS)
            LazyMenuButton("New", systemImage: "plus") { newItems }
                .help("New Terminal (⌘T) or New Agent (⇧⌘N)")
                .accessibilityIdentifier("new-tab")
            #else
            Menu { newItems } label: {
                Label("New", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .help("New Terminal (⌘T) or New Agent (⇧⌘N)")
            .accessibilityIdentifier("new-tab")
            #endif
        } else {
            Button("Add Host", systemImage: "plus") { model.newTab() }
                .labelStyle(.iconOnly)
                .help("Add Host")
                .accessibilityIdentifier("new-tab")
        }
    }

    @ViewBuilder private var newItems: some View {
        Button("New Terminal", systemImage: "terminal") { model.newTab() }
            .accessibilityIdentifier("new-tab-terminal")
        Button(WorkspaceAction.newAgent.title, systemImage: "sparkle") { model.newAgent() }
            .accessibilityIdentifier("new-tab-agent")
        Button(WorkspaceAction.newProject.title, systemImage: "folder.badge.plus") {
            withAnimation(DS.Motion.standard) { model.newEmptyProject() }
        }
        .accessibilityIdentifier("new-tab-project")
        let groups = model.groups.groups
        if groups.count > 1 {
            Menu("New Terminal On", systemImage: "plus.rectangle.on.rectangle") {
                ForEach(groups) { group in
                    Button(group.name, systemImage: group.systemImage) { model.newTab(onGroup: group.id) }
                }
            }
        }
        Divider()
        Button("Add Host…", systemImage: "plus.circle") { model.addHost() }
    }

    private var canOpen: Bool { workspace.canOpenTabs || model.groups.newTabHost(preferred: nil) != nil }
}

/// The hairline between sidebar and terminal, draggable to resize the sidebar; a double click
/// restores the default width.
private struct SidebarDivider: View {
    @Binding var width: Double
    var showsLine = true
    @Environment(\.displayScale) private var displayScale
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(DS.Palette.separator)
            .opacity(showsLine ? 1 : 0)
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
    @Environment(\.showsContentCard) private var showsContentCard
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true
    @AppStorage("sidebarWidth") private var sidebarWidth = SidebarWidth.standard
    @State private var titleBarMetrics = TitleBarMetrics()

    var body: some View {
        VStack(spacing: 0) {
            // Across a fold each page's header names its tab and the sidebar is the tab list: a
            // strip would run over the crease. On the Mac it is the title bar's own row.
            #if os(iOS)
            if showsStrip {
                TabBar(workspace: workspace)
                    .chromeContent()
                    .motionTransition(.panel(from: .top))
            }
            #endif
            switch model.destination {
            case .terminal:
                TerminalArea(workspace: workspace)
                    // Behind the key bar and keyboard, which float over the terminal.
                    .background {
                        Rectangle().fill(showsContentCard ? AnyShapeStyle(DS.Palette.sidebar) : AnyShapeStyle(theme.background))
                            .ignoresSafeArea(.all, edges: .bottom)
                    }
                    // The ink goes on each destination, never above a toolbar.
                    .chromeContent()
                    .modifier(StripRoom(stripShown: showsStrip))
                    .zIndex(1)
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
        .chromeBarBackground(showsContentCard ? .sidebar : .base)
        #endif
        #if os(iOS)
        .navigationSubtitle(model.destination == .terminal ? subtitle : "")
        #else
        // The title and its context are one line in the toolbar row (`WindowTitleLine`); the
        // window keeps its title for the Window menu and Mission Control.
        .toolbar(removing: .title)
        #endif
        .toolbar {
            // With the strip on top its selected tab names the tab: the row above it keeps only
            // the window's controls, so the two read as one band.
            TerminalToolbar(workspace: workspace, showsStrip: showsStrip, metrics: titleBarMetrics, sidebarWidth: sidebarWidth)
        }
        #if os(iOS)
        .toolbar(model.isEditorFullScreen ? .hidden : .automatic, for: .navigationBar)
        #else
        .toolbar(model.isEditorFullScreen ? .hidden : .automatic, for: .windowToolbar)
        // The bar is drawn by what lies under it: the sidebar's colour over the sidebar, the
        // window's base over the rest, so no band of the system's own colour sits on top.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .modifier(GitDialogs(git: model.git))
        .onChange(of: model.git.hub?.repos != nil, initial: true) { _, hasRepos in
            if hasRepos { model.git.syncAutoDelete() }
        }
        .chromeBackground(showsContentCard ? DS.Palette.sidebar : DS.Palette.base)
    }

    private var showsStrip: Bool {
        !model.isSidebarShown && showsTabBar && !model.isEditorFullScreen && !model.foldLayout.isPages
    }

    private var title: String { WindowTitles(workspace: workspace, model: model).title }

    private var subtitle: String { WindowTitles(workspace: workspace, model: model).subtitle }
}

/// The window's title and the line under it, for the window and for the title bar's own line.
@MainActor
struct WindowTitles {
    let workspace: Workspace
    let model: WindowModel

    var title: String {
        switch model.destination {
        case .terminal:
            model.activeMixed.map(model.title(ofMixedTab:)) ?? workspace.shownTab.map(workspace.title(of:)) ?? Brand.name
        case .inbox: Destination.inbox.title
        case .hosts: "Hosts"
        }
    }

    /// Under the tab's name: its context when it says something the title does not, then the
    /// split state. The host is named by the toolbar's host button instead.
    var subtitle: String {
        if let mixed = model.activeMixed {
            let hosts = mixed.hosts.map(model.groupName).joined(separator: " + ")
            if mixed.isBrowserOnly { return hosts.isEmpty ? "Browser" : "Browser · \(hosts)" }
            return mixed.isEditorOnly ? "VS Code · \(hosts)" : hosts
        }
        guard let tab = workspace.shownTab else { return "" }
        let subtitle = workspace.windowSubtitle(of: tab)
        let waiting = model.connection == .starting ? "Starting…" : "Connecting…"
        guard workspace.showsSavedWorkspace || model.connection == .starting, !model.connection.isFailure else { return subtitle }
        return subtitle.isEmpty ? waiting : "\(subtitle) · \(waiting)"
    }
}

extension Workspace {
    /// Under the window's title: what the tab is doing when that says something the title does
    /// not, then the split state, each once.
    func windowSubtitle(of tab: Tab) -> String {
        let title = title(of: tab)
        var parts: [String] = []
        if let context = liveContext(of: tab)?.trimmingCharacters(in: .whitespaces),
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

#if os(macOS)
private struct WindowTitleItem: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        let titles = WindowTitles(workspace: workspace, model: model)
        WindowTitleLine(title: titles.title, subtitle: model.destination == .terminal ? titles.subtitle : "")
    }
}

/// The tab's name and, after it in the secondary ink, what it is doing: one line in the toolbar
/// row, so the band is as short as the title bar allows. Receded with the window.
private struct WindowTitleLine: View {
    let title: String
    let subtitle: String
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(title)
                .font(DS.Font.rowTitleEmphasis)
                .foregroundStyle(appearsActive ? DS.Palette.text : DS.Palette.textSecondary)
                .layoutPriority(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(appearsActive ? DS.Palette.textSecondary : DS.Palette.textTertiary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .help(subtitle.isEmpty ? title : "\(title) · \(subtitle)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("window-title")
    }

    /// Long contexts end in an ellipsis before they reach the trailing controls.
    static let maxWidth: CGFloat = 520
}
#endif

/// The window toolbar, identical with the sidebar shown or hidden.
private struct TerminalToolbar: ToolbarContent {
    let workspace: Workspace
    /// The tabs as a strip: beside the traffic lights in the title bar's row on the Mac.
    let showsStrip: Bool
    let metrics: TitleBarMetrics
    @Environment(WindowModel.self) private var model
    /// Passed in rather than read here: a setting read in the bar's content is new each time
    /// its owner updates, which updates every item and has the bar rebuild their menu forms.
    let sidebarWidth: Double
    #if os(macOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some ToolbarContent {
        #if os(macOS)
        let fit = self.fit
        // Over the sidebar the toggle is a bare glyph beside the traffic lights and the title
        // starts where the detail column does; with the sidebar hidden it is a regular button.
        ToolbarItem(placement: .navigation) {
            SidebarToggle()
        }
        .sharedBackgroundVisibility(.hidden)
        if overSidebar {
            ToolbarItem(placement: .navigation) {
                Color.clear
                    .frame(width: titleInset, height: 1)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if !showsStrip {
            // The line reads the title itself: passed in, every tab switch would update the
            // whole bar, and the bar makes every item's menu form again on each update.
            ToolbarItem(placement: .navigation) {
                WindowTitleItem(workspace: workspace)
                    .frame(maxWidth: fit.room, alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if showsStrip {
            ToolbarItem(placement: .navigation) {
                TitleBarHosted {
                    TabBar(workspace: workspace, inTitleBar: true)
                        .chromeContent()
                }
                .frame(width: fit.room, height: DS.Size.tab)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            // Without the system title nothing else pushes the controls to the trailing edge.
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        if fit.foldsControls {
            ToolbarItem(placement: .primaryAction) {
                TitleBarOverflowMenu(workspace: workspace)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            trailingControls
        }
        #else
        ToolbarItem(placement: .navigation) {
            SidebarToggle()
        }
        if model.destination == .terminal, workspace.session.activeTab?.root.panes.count == 1,
           let id = workspace.focusedPane, let pane = workspace.panes[id], let chat = pane.chat, chat.agent != nil {
            ToolbarItem(placement: .principal) { PaneChatToggle(pane: pane, state: chat) }
        }
        trailingControls
        #endif
    }

    @ToolbarContentBuilder private var trailingControls: some ToolbarContent {
        // People here now: their faces, not a control (sharing starts from the palette).
        if let session = workspace.multiplayer, !session.others.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                PresenceItem(workspace: workspace, session: session)
                    .titleBarWidth(.presence, in: metrics)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // The worktree's pull request as a quiet word; Open In and Run are in the Git menu and
        // the palette.
        if model.destination == .terminal, let worktree = model.git.worktree {
            ToolbarItem(placement: .primaryAction) {
                PRToolbarButton(git: model.git, worktree: worktree)
                    .titleBarWidth(.pullRequest, in: metrics)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // A title-bar picker: its name in plain text, no capsule beside the one group.
        ToolbarItem(placement: .primaryAction) {
            HostToolbarButton(workspace: workspace)
                .titleBarWidth(.host, in: metrics)
        }
        .sharedBackgroundVisibility(.hidden)
        // Find, drawing, sharing and the editor are in the menu bar, the palette and their
        // shortcuts: the bar keeps the two things reached for most.
        #if os(macOS)
        // One style across the bar: every control a bare monochrome glyph or word that the
        // system greys with the window, never a capsule that comes and goes with it.
        paneControls.sharedBackgroundVisibility(.hidden)
        #else
        paneControls
        #endif
    }

    private var paneControls: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            PaneControls(workspace: workspace)
        }
    }

    #if os(macOS)
    private var overSidebar: Bool { model.isSidebarShown && !model.isEditorFullScreen }

    /// From the toggle to the detail column's text margin: the traffic lights, the toggle and
    /// the items' spacing take the sidebar's first `TitleBarFit.leadingReserve`.
    private var titleInset: CGFloat {
        max(0, SidebarWidth.effective(sidebarWidth, for: dynamicTypeSize) - TitleBarFit.leadingReserve + DS.Space.m)
    }

    private var fit: TitleBarFit {
        var shown: [TitleBarMetrics.Control] = [.host]
        if let session = workspace.multiplayer, !session.others.isEmpty { shown.append(.presence) }
        if model.destination == .terminal, model.git.worktree != nil { shown.append(.pullRequest) }
        return TitleBarFit(
            window: model.windowWidth,
            contentStart: overSidebar ? SidebarWidth.effective(sidebarWidth, for: dynamicTypeSize) : TitleBarFit.leadingReserve - DS.Space.m,
            controls: metrics.width(of: shown))
    }
    #endif
}

/// The people here now. Its closures are made here, not in the bar's content, so a bar update
/// that changes nothing of it leaves its menu form alone.
private struct PresenceItem: View {
    let workspace: Workspace
    let session: MultiplayerSession
    @Environment(WindowModel.self) private var model

    var body: some View {
        PresenceToolbarButton(session: session, place: { pane in
            workspace.session.tabs.first { $0.root.panes.contains(PaneId(pane)) }.map(workspace.title(of:))
        }) { model.sheet = .invite }
            .buttonStyle(.plain)
    }
}

/// Split (the pane menu) and the command palette: the two controls the bar always keeps.
private struct PaneControls: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        #if os(macOS)
        LazyMenuButton("Split", systemImage: "rectangle.split.2x1") { splitItems }
            .help("Split, zoom, float or close the pane")
            .disabled(isSplitDisabled)
            .accessibilityLabel("Split")
            .accessibilityIdentifier("pane-menu")
        #else
        Menu("Split", systemImage: "rectangle.split.2x1") { splitItems }
            .help("Split, zoom, float or close the pane")
            .menuIndicator(.hidden)
            .disabled(isSplitDisabled)
            .accessibilityLabel("Split")
            .accessibilityIdentifier("pane-menu")
        #endif
        Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
            .help("Command Palette (⌘K)")
            .accessibilityIdentifier("open-palette")
    }

    @ViewBuilder private var splitItems: some View {
        PaneMenuItems(workspace: workspace, model: model)
        Divider()
        Toggle("Two Columns", systemImage: "rectangle.split.2x1", isOn: Binding(
            get: { model.isTwoColumns }, set: { _ in model.toggleTwoColumns() }))
            .accessibilityIdentifier("two-columns")
    }

    private var isSplitDisabled: Bool {
        (workspace.focusedPane == nil && model.activeMixed == nil) || model.destination != .terminal
    }
}

/// How wide the title bar's trailing controls are as drawn, for fitting the row
/// (`TitleBarFit`). Each keeps its last width while folded away, so the choice holds steady.
@MainActor
@Observable
final class TitleBarMetrics {
    enum Control: Hashable {
        case presence, pullRequest, host
    }

    private var widths: [Control: CGFloat] = [:]

    func record(_ width: CGFloat, of control: Control) {
        if widths[control] != width { widths[control] = width }
    }

    /// `controls` and the two pane glyphs, with the spacing between items.
    func width(of controls: [Control]) -> CGFloat {
        controls.reduce(TitleBarFit.paneControls) { total, control in total + (widths[control] ?? 0) + DS.Space.s }
    }
}

private extension View {
    func titleBarWidth(_ control: TitleBarMetrics.Control, in metrics: TitleBarMetrics) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { metrics.record($0, of: control) }
    }
}

/// The title bar's one row: the title or the tab strip gets what the traffic lights, the
/// sidebar toggle and the trailing controls leave. Where that would fall under a tab's width,
/// the controls fold into one menu, so nothing is pushed out of the bar.
struct TitleBarFit {
    /// The traffic lights, the sidebar toggle and the items' spacing.
    static let leadingReserve: CGFloat = 148
    /// Split and the command palette: two toolbar glyphs.
    static let paneControls: CGFloat = 2 * DS.Size.touchTarget
    /// The one menu the controls fold into.
    static let foldedControls = DS.Size.touchTarget
    /// The least the title or the strip is given before the controls fold.
    static let minimumRoom = DS.Size.tabMinWidth
    /// The window's trailing edge and the bar's own spacing between its groups, with room to
    /// spare: a control that does not fit is dropped by the toolbar, so the fit errs short.
    static let trailingMargin = DS.Space.xxxl

    /// The window's width; zero until it is known.
    let window: CGFloat
    /// Where the title or strip begins: past the sidebar, or past the toggle.
    let contentStart: CGFloat
    let controls: CGFloat

    var foldsControls: Bool { window > 0 && room(beside: controls) < Self.minimumRoom }

    var room: CGFloat {
        guard window > 0 else { return Self.minimumRoom }
        return max(0, room(beside: foldsControls ? Self.foldedControls : controls))
    }

    private func room(beside trailing: CGFloat) -> CGFloat {
        window - contentStart - DS.Space.s - trailing - Self.trailingMargin
    }
}

#if os(macOS)
/// Content in a hosting view of its own inside a title bar item. The bar mirrors the controls of an
/// item's SwiftUI content as menu items, context menus and symbol images included, and rebuilds
/// them on every update of the item: for the tab strip, every chip and its menu naming every other
/// tab, a second of main thread as the sidebar hides. Its own host's updates stay its own.
struct TitleBarHosted<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: rooted(in: context.environment))
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        host.rootView = rooted(in: context.environment)
    }

    private func rooted(in environment: EnvironmentValues) -> AnyView {
        AnyView(content.environment(\.self, environment))
    }
}

/// A control whose menu is made as it opens. In the title bar a SwiftUI `Menu` is mirrored as
/// menu items, every command with its symbol image, and made again whenever anything it lists
/// changes: for the pane menu, which names the other tabs, and the + menu in the tab strip, on
/// every tab switch. An empty menu stays one stable item, and its menu is current when it opens.
struct LazyMenuButton<Items: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let items: () -> Items
    @Environment(\.self) private var environment
    @State private var anchor = MenuAnchor()

    init(_ title: String, systemImage: String, @ViewBuilder items: @escaping () -> Items) {
        self.title = title
        self.systemImage = systemImage
        self.items = items
    }

    var body: some View {
        // A menu of its own with nothing in it draws and reads exactly as the menu did.
        Menu {
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .background(MenuAnchorView(anchor: anchor))
        } primaryAction: {
            open()
        }
        .menuIndicator(.hidden)
    }

    private func open() {
        guard let view = anchor.view ?? Self.clickedToolbarItem() else { return }
        let menu = Self.menu(of: items(), in: environment)
        let below = view.isFlipped ? view.bounds.maxY + DS.Space.xs : view.bounds.minY - DS.Space.xs
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: below), in: view)
    }

    static func menu(of items: Items, in environment: EnvironmentValues) -> NSMenu {
        NSHostingMenu(rootView: items.environment(\.self, environment))
    }

    /// A toolbar draws its buttons itself, without the label's views: the item clicked.
    private static func clickedToolbarItem() -> NSView? {
        guard let event = NSApp.currentEvent, let window = event.window else { return nil }
        return window.toolbar?.items.lazy.compactMap(\.view).first { view in
            view.window === window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}

@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

/// Where a `LazyMenuButton` opens its menu from: the label's own bounds.
private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The trailing controls folded into one menu for a narrow window: the hosts, Split and the
/// command palette.
private struct TitleBarOverflowMenu: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        LazyMenuButton("More", systemImage: "ellipsis.circle") {
            Section("Hosts") {
                ForEach(model.switcherHosts) { host in
                    Button(host.name, systemImage: host.isCurrent ? "checkmark" : host.systemImage) { model.selectHost(id: host.id) }
                }
            }
            Menu("Split", systemImage: "rectangle.split.2x1") {
                PaneMenuItems(workspace: workspace, model: model)
            }
            .disabled((workspace.focusedPane == nil && model.activeMixed == nil) || model.destination != .terminal)
            Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
        }
        .help("\(model.hostName), Split and Command Palette")
        .accessibilityIdentifier("toolbar-overflow")
    }
}
#endif

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
                    // The key bar rides the keyboard's top, at the bottom edge with a hardware
                    // keyboard: the tab bar gives way rather than sit under it.
                    .toolbar(model.isEditorFullScreen || workspace.keyboardTop != nil ? .hidden : .automatic, for: .tabBar)
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
    @Environment(\.showsContentCard) private var showsContentCard

    private var handoff: TabHandoff { workspace.tabHandoff }

    private var isCard: Bool { showsContentCard && !compact }

    var body: some View {
        Group {
            if workspace.session.activeTab != nil {
                ZStack {
                    ForEach(handoff.layers, id: \.self) { tabId in
                        if let tab = workspace.session.tabs.first(where: { $0.id == tabId }) {
                            panes(of: tab)
                                .allowsHitTesting(tabId == handoff.layers.last)
                        }
                    }
                }
                // Lost link: the last frame stays, faded toward the background, under the card.
                .connectionOverlay(
                    model.connection, hostName: model.hostName, showsSavedState: workspace.showsSavedWorkspace,
                    isThisDevice: workspace.hostId != nil && workspace.hostId == model.app.thisDeviceHostId,
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
        .background(isCard ? AnyShapeStyle(DS.Palette.sidebar) : AnyShapeStyle(theme.background), ignoresSafeAreaEdges: [])
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            // An external display showing this window's tab scales to this area.
            if !model.isPresentation, model.terminalArea != size { model.terminalArea = size }
        }
        .onChange(of: workspace.session.activeTabId, initial: true) { _, selected in
            handoff.select(selected) { [workspace, compact] in
                selected.map { workspace.hasPresentedScreens(of: $0, focusedPaneOnly: compact) } ?? true
            }
        }
    }

    private func panes(of tab: Tab) -> some View {
        // Floating windows ride above the tiled panes; on iPhone the focused pane shows alone
        // and the windows become picture in picture.
        let tiled = workspace.session.tiledRoot(of: tab) ?? tab.root
        let floats = compact ? FloatScene.none : FloatScene(workspace: workspace, tab: tab, hidden: model.floatsHidden)
        // A zoomed pane keeps its header: its lit Zoom button is the way back.
        let isSplit = !compact && (tiled.panes.count > 1 || !floats.windows.isEmpty)
        return SplitTreeView(
            node: compact ? .leaf(tab.focused) : tiled, workspace: workspace, tab: tab.id, isSplit: isSplit, animated: !compact,
            floats: floats, zoomed: compact ? nil : tab.zoomed)
            .overlay {
                if compact { PictureInPicture(workspace: workspace, tab: tab) }
            }
            .padding(paneInset(isSplit: isSplit))
            .background(paneSurround(isSplit: isSplit), ignoresSafeAreaEdges: [])
            .environment(\.showsContentCard, isCard)
    }

    private func paneInset(isSplit: Bool) -> CGFloat {
        if isCard { return ContentCard.inset }
        return paneStyle == .comfortable && isSplit ? DS.Space.row : 0
    }

    private func paneSurround(isSplit: Bool) -> AnyShapeStyle {
        if isCard { return AnyShapeStyle(DS.Palette.sidebar) }
        return paneStyle == .comfortable && isSplit ? AnyShapeStyle(DS.Palette.base) : AnyShapeStyle(theme.background)
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
        case .starting: "Starting…"
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
        case .fileViewer:
            FileViewerSheet()
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
    @Environment(WindowModel.self) private var model
    @State private var draft = ""

    func body(content: Content) -> some View {
        content.alert(
            "Rename Tab",
            isPresented: Binding(get: { workspace.renamingTab != nil }, set: { if !$0 { workspace.renamingTab = nil } })
        ) {
            TextField("Title", text: $draft)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Rename") {
                if let id = workspace.renamingTab { workspace.apply(.rename(id, draft)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to name it automatically.")
        }
        .onChange(of: workspace.renamingTab) { _, id in
            draft = workspace.session.tabs.first { $0.id == id }?.title ?? ""
            model.overlayKeyboardChanged()
        }
    }
}

extension View {
    func renameTabPrompt(_ workspace: Workspace) -> some View {
        modifier(RenameTabPrompt(workspace: workspace))
    }
}
