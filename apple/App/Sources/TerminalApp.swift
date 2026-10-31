import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct TerminalApp: App {
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        TerminalPreferences.WindowTheme.migrate()
        #if os(macOS)
        // Tabs are ours (⌘T); AppKit's window tabbing would compete for the same shortcuts.
        NSWindow.allowsAutomaticWindowTabbing = false
        WorkspaceShortcuts.install()
        #if DEBUG
        WindowSnapshot.scheduleIfRequested()
        #endif
        #endif
        #if DEBUG && os(iOS)
        DebugMemoryWarning.install()
        #endif
    }

    var body: some Scene {
        // One window per scene (iPad windows and Stage Manager, an external display's own
        // windows, Mac windows). A window opened with a request starts on its hosts and tab
        // (New Window, Open in New Window); otherwise it restores its own, else the last
        // window's (docs/APP-ARCHITECTURE.md "Windows").
        WindowGroup(for: WindowRequest.self) { $request in
            WindowRoot(request: request)
                .environment(app)
        }
        .commands { WorkspaceCommands() }
        .onChange(of: scenePhase) { _, phase in
            // 04-mobile-ux C3 "background and foreground contract": suspend with resume state
            // kept once the background time iOS grants runs out (`BackgroundGrace`), probe and
            // resume at once on return (R1, R5, R10). macOS keeps connections up in the
            // background. The app's phase, not a window's: one window in the background while
            // another is on screen keeps every host live.
            AppNotifications.shared.appIsActive = phase == .active
            switch phase {
            case .active:
                #if os(iOS)
                BackgroundGrace.shared.returned()
                #endif
                app.hosts.foreground()
            case .background:
                #if os(iOS)
                BackgroundGrace.shared.enter()
                #endif
            default: break
            }
        }
        #if os(macOS)
        // Unit tests render their own offscreen windows; the app opens none.
        .defaultLaunchBehavior(LaunchOptions.isTesting ? .suppressed : .automatic)
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        #endif

        #if os(macOS)
        WindowGroup(id: ToolWindowRequest.sceneId, for: ToolWindowRequest.self) { $request in
            if let request { ToolWindowRoot(request: request) }
        }
        .defaultSize(width: 960, height: 680)
        .windowToolbarStyle(.unified(showsTitle: true))
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
        }
        // A titlebar as tall as the main window's, so the traffic lights keep the system's
        // margin inside the sidebar's rounded corner.
        .windowToolbarStyle(.unified)
        #endif
    }
}

/// One window: every open host at once (the sidebar groups them), the target's workspace in the
/// detail column, inside the design's chrome. Deep links, the hosts list, the sidebar and the
/// launch test hooks pick the target; the window model (sidebar destination, sheets, palette,
/// open hosts) survives switching targets. Which hosts were open, which groups were collapsed and
/// the last-focused tab are restored per window. The window publishes what it shows for Handoff
/// and continues other devices' (and dragged-out tabs') activities.
///
/// The window's model is made once per scene, when the scene first appears: SwiftUI rebuilds
/// this struct (and would re-run a `@State` initial value) several times per scene, and a
/// spare model would have its own sources and terminals and could be picked as the active
/// window.
struct WindowRoot: View {
    /// What this window was opened for (New Window, Open in New Window), if anything.
    var request: WindowRequest?
    @State private var model: WindowModel?
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme

    var body: some View {
        if let model {
            WindowContent(request: request, model: model)
        } else {
            // One frame on the terminal background while the model is made.
            ThemeCatalog.theme(named: themeName).background
                .ignoresSafeArea()
                .onAppear {
                    guard model == nil else { return }
                    let made = WindowModel(app: AppModel.shared)
                    made.start()
                    model = made
                }
        }
    }

}

/// A window's content around its model (see `WindowRoot`).
struct WindowContent: View {
    var request: WindowRequest?
    let model: WindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    /// Legacy single-target restore (before multi-host windows).
    @SceneStorage("target") private var storedTarget: String?
    @SceneStorage("openHosts") private var storedHosts: String?
    @SceneStorage("collapsedHosts") private var storedCollapsed: String?
    @SceneStorage("focusedTab") private var storedFocus: String?
    /// The window's mixed tabs (`CompositeTab`s, JSON).
    @SceneStorage("mixedTabs") private var storedMixed: String?
    /// Projects of tabs without a daemon to keep them, collapsed projects (JSON).
    @SceneStorage("projects") private var storedProjects: String?
    /// Two Columns as the user set it for this window (absent: automatic).
    @SceneStorage("twoColumns") private var storedTwoColumns: String?
    /// The request this scene already opened (a restored scene must not open it again).
    @SceneStorage("openedRequest") private var openedRequest: String?
    @State private var restored = false
    #if DEBUG
    /// UI tests: a narrower window than the simulator's screen (`<scheme>://debug/width/<pt>`,
    /// `-windowWidth <pt>`), to cross the width boundary as Split View and Stage Manager do.
    #endif

    /// The window's content with what it follows: errors, what to persist, its phase.
    private var observed: some View {
        sized
            .environment(model)
            .onChange(of: app.lastError) { _, error in showError(error) }
            .onChange(of: model.groups.openHosts) { _, _ in persist() }
            .onChange(of: model.groups.collapsed) { _, _ in persist() }
            .onChange(of: model.currentTab) { _, _ in persist() }
            .onChange(of: model.composites.tabs) { _, _ in persist() }
            .onChange(of: model.groups.projectsState) { _, _ in persist() }
            .onChange(of: model.twoColumnsChoice) { _, _ in persist() }
            .onChange(of: scenePhase, initial: true) { _, phase in model.isOnScreen = phase != .background }
    }

    private func showError(_ error: String?) {
        if let error { model.toasts.show(Toast(error, systemImage: "exclamationmark.triangle.fill", style: .failure)) }
    }

    var body: some View {
        observed
            .modifier(HostKeyPromptModifier(prompts: app.hosts.hostKeyPrompts))
            .modifier(HandoffActivity(model: model, onContinue: continueActivity))
            .onOpenURL(perform: open(url:))
            // Links (pairing, invites, a pane from a notification) go to a window that is
            // already open; activities (Handoff, a tab dragged out) may make new ones.
            .handlesExternalEvents(preferring: [WindowContent.urlScheme], allowing: ["*"])
            #if os(iOS)
            .background { SceneReader(model: model) }
            #else
            .modifier(SettingsLinkOpener())
            #endif
            .onDisappear { model.close() }
            .task {
                guard !restored else { return }
                restored = true
                model.openWindow = { request in openWindow(value: request) }
                #if os(macOS)
                // Unit tests draw tool windows offscreen themselves; never a real one.
                if !LaunchOptions.isTesting {
                    model.openTool = { request in openWindow(id: ToolWindowRequest.sceneId, value: request) }
                }
                #endif
                #if DEBUG && os(iOS)
                // `-resetWindows YES` (UI tests): start from one window, whatever iPadOS restored.
                if UserDefaults.standard.bool(forKey: "resetWindows") { WindowContent.closeOtherWindows(keeping: model) }
                #endif
                app.hosts.foreground()
                let hooked = await app.runLaunchHooks()
                if !hooked.isEmpty {
                    // Open every hooked host (they stay connected), show the first.
                    for target in hooked { model.show(target) }
                    model.show(hooked[0])
                } else if let request, openedRequest != request.id.uuidString {
                    openedRequest = request.id.uuidString
                    model.open(request)
                } else if model.lastContinued == nil, shouldRestore {
                    restore()
                }
                // `-openHost <name or id>`: open that saved host (screenshots, manual checks).
                if let wanted = LaunchArguments().string(forKey: "openHost"),
                   let record = app.hosts.records.first(where: { $0.id == wanted || $0.name == wanted })
                {
                    model.show(.host(record.id))
                }
                // `-destination hosts|inbox`: open on that screen (screenshots of live data).
                switch LaunchArguments().string(forKey: "destination") {
                case "hosts": model.destination = .hosts
                case "inbox": model.destination = .inbox
                default: break
                }
                #if DEBUG
                // `-continueActivity <json>`: continue a Handoff payload as if another device sent it.
                // (Base64 of the JSON: a launch argument that looks like a plist is parsed as one.)
                if let text = LaunchArguments().string(forKey: "continueActivity"),
                   let json = Data(base64Encoded: text) ?? text.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(HandoffPayload.self, from: json)
                {
                    continueActivity(payload)
                }
                #endif
            }
    }

    /// The window's content at its width bucket: compact (the iPhone layout) or regular (sidebar
    /// and splits), measured on the window, never the device (iOS: the whole window's size
    /// class follows it, so every screen agrees).
    @ViewBuilder private var sized: some View {
        #if os(iOS)
        content
            .environment(\.horizontalSizeClass, model.widthBucket == .compact ? .compact : .regular)
            .background {
                // The window's width, from the first layout on (`onGeometryChange` only reports
                // changes).
                GeometryReader { proxy in
                    Color.clear.onChange(of: Double(proxy.size.width), initial: true) { _, width in widthChanged(width) }
                        // Both sides: where a fold crosses the window depends on its shape.
                        .onChange(of: proxy.size, initial: true) { _, size in
                            if model.windowSize != size { model.windowSize = size }
                        }
                }
            }
            // The hinge and the fold, in the window's own coordinates.
            .background { FoldProbe(model: model).ignoresSafeArea() }
            #if DEBUG
            .frame(maxWidth: model.debugWidth.map { CGFloat($0) } ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.ignoresSafeArea())
            #endif
            .overlay(alignment: .leading) { WindowProbe() }
        #else
        content
            .overlay(alignment: .leading) { WindowProbe() }
        #endif
    }

    @ViewBuilder private var content: some View {
        if !model.isStarted {
            Color.clear
        } else if let workspace = model.workspace {
            // No `.id` per workspace: the sidebar (every host) stays put while the detail
            // column switches hosts; the panes are keyed by their workspace inside.
            WorkspaceView(workspace: workspace)
        } else {
            EmptyState(
                "Host Unavailable", systemImage: "exclamationmark.triangle",
                message: app.lastError ?? "The host could not be opened."
            ) {
                Button("Show Hosts") {
                    model.show(.local)
                    model.destination = .hosts
                }
                .buttonStyle(.primaryGlass)
            }
        }
    }

    /// A width change that crosses the boundary switches the layout; the terminals' grids then
    /// change with it, which is not a resize the user asked for (no cols × rows overlay).
    private func widthChanged(_ width: Double) {
        guard width > 0 else { return }
        let next = WidthBucket.of(width: width, current: model.widthBucket)
        guard next != model.widthBucket else { return }
        if model.widthBucket != nil {
            AppModel.log.info("window width \(Int(width)) pt: \(next.rawValue, privacy: .public) layout")
            for workspace in model.workspaces.values { workspace.layoutChangeUntil = .now + .seconds(1) }
        }
        model.widthBucket = next
    }

    private func open(url: URL) {
        #if DEBUG
        // `<scheme>://debug/width/<pt>` (0: the full width): UI tests narrow the window.
        if url.host() == "debug", url.pathComponents.count >= 3, url.pathComponents[1] == "width" {
            let value = Double(url.pathComponents[2]) ?? 0
            model.debugWidth = value > 0 ? value : nil
            return
        }
        #if os(iOS)
        // `<scheme>://debug/front/<n>`: bring the n-th open window (in opening order) to the front.
        if url.host() == "debug", url.pathComponents.count >= 3, url.pathComponents[1] == "front",
           let index = Int(url.pathComponents[2])
        {
            model.bringWindowForward(index)
            return
        }
        #endif
        #endif
        model.openLink(url)
    }

    #if DEBUG && os(iOS)
    private static var closedOtherWindows = false

    /// Destroys every scene but one (once per launch; UI tests).
    private static func closeOtherWindows(keeping window: WindowModel) {
        guard !closedOtherWindows, let keep = window.scene?.session else { return }
        closedOtherWindows = true
        let sessions = UIApplication.shared.openSessions.filter { $0.role == .windowApplication }
        for session in sessions where session !== keep {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
    }
    #endif

    /// Another device's window (Handoff), or a tab dragged out of another window here.
    private func continueActivity(_ payload: HandoffPayload) {
        AppModel.log.info("continue \(payload.kind.rawValue, privacy: .public) \(payload.hostName, privacy: .private) from \(payload.device, privacy: .private)")
        model.continue(payload)
    }

    /// The app's URL scheme (Brand.xcconfig), for routing links to open windows.
    static let urlScheme: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "unnamed"
    }()

    /// Restore by default in normal launches; never for design fixtures, `-mock` or dogfood
    /// runs unless `-restoreLastTarget YES` asks for it.
    private var shouldRestore: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "restoreLastTarget") != nil { return defaults.bool(forKey: "restoreLastTarget") }
        return LaunchOptions.screen == nil && !LaunchOptions.mock && LaunchArguments().string(forKey: "dogfood") == nil
    }

    /// The window's open hosts and focused tab: the scene's own storage, else what the last
    /// window saved (a new scene on iPad, a Mac window restored without state), else the
    /// single host of a window saved before multi-host.
    private func restore() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
            text.flatMap { $0.data(using: .utf8) }.flatMap { try? decoder.decode(type, from: $0) }
        }
        var hosts = decode([String].self, storedHosts) ?? decode([String].self, defaults.string(forKey: Self.lastHostsKey))
        var focus = decode(TabRef.self, storedFocus) ?? decode(TabRef.self, defaults.string(forKey: Self.lastFocusKey))
        if hosts == nil, case .host(let id)? = decode(WorkspaceTarget.self, storedTarget) {
            hosts = [id]
            focus = nil
            model.show(.host(id))
        }
        let collapsed = decode([String].self, storedCollapsed) ?? decode([String].self, defaults.string(forKey: Self.lastCollapsedKey)) ?? []
        let mixed = decode([CompositeTab].self, storedMixed) ?? decode([CompositeTab].self, defaults.string(forKey: Self.lastMixedKey)) ?? []
        if let twoColumns = storedTwoColumns ?? defaults.string(forKey: Self.lastTwoColumnsKey) {
            model.twoColumnsChoice = twoColumns == "auto" ? nil : twoColumns == "on"
        }
        if let projects = decode(HostGroups.ProjectsState.self, storedProjects ?? defaults.string(forKey: Self.lastProjectsKey)) {
            model.groups.projectsState = projects
        }
        model.restore(openHosts: hosts ?? [], collapsed: Set(collapsed), focus: focus, mixedTabs: mixed)
    }

    private static let lastProjectsKey = "window.projects"

    private static let lastHostsKey = "window.openHosts"
    private static let lastCollapsedKey = "window.collapsedHosts"
    private static let lastFocusKey = "window.focusedTab"
    private static let lastMixedKey = "window.mixedTabs"
    private static let lastTwoColumnsKey = "window.twoColumns"

    /// Saves what a relaunch restores, per window and as the app's latest.
    private func persist() {
        guard restored, shouldRestore else { return }
        let encoder = JSONEncoder()
        func encode(_ value: some Encodable) -> String? {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        storedHosts = encode(model.groups.openHosts)
        storedCollapsed = encode(model.groups.collapsed.sorted())
        storedFocus = model.currentTab.flatMap(encode)
        storedMixed = encode(model.composites.tabs)
        storedTwoColumns = model.twoColumnsChoice.map { $0 ? "on" : "off" } ?? "auto"
        storedTarget = nil
        let defaults = UserDefaults.standard
        defaults.set(storedHosts, forKey: Self.lastHostsKey)
        defaults.set(storedCollapsed, forKey: Self.lastCollapsedKey)
        defaults.set(storedFocus, forKey: Self.lastFocusKey)
        defaults.set(storedMixed, forKey: Self.lastMixedKey)
        defaults.set(storedTwoColumns, forKey: Self.lastTwoColumnsKey)
        storedProjects = encode(model.groups.projectsState)
        defaults.set(storedProjects, forKey: Self.lastProjectsKey)
    }
}
