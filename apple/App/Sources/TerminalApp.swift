import DesignSystem
import HostKit
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
        #if os(macOS)
        // Tabs are ours (⌘T); AppKit's window tabbing would compete for the same shortcuts.
        NSWindow.allowsAutomaticWindowTabbing = false
        WorkspaceShortcuts.install()
        #if DEBUG
        WindowSnapshot.scheduleIfRequested()
        #endif
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WindowRoot()
                .environment(app)
        }
        .commands { WorkspaceCommands() }
        .onChange(of: scenePhase) { _, phase in
            // 04-mobile-ux C3 "background and foreground contract": suspend with resume state
            // kept, probe and resume at once on return (R1, R5, R10). macOS keeps connections
            // up in the background.
            AppNotifications.shared.appIsActive = phase == .active
            switch phase {
            case .active: app.hosts.foreground()
            case .background:
                #if os(iOS)
                app.hosts.background()
                #endif
            default: break
            }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

/// One window: every open host at once (the sidebar groups them), the target's workspace in the
/// detail column, inside the design's chrome. Deep links, the hosts list, the sidebar and the
/// launch test hooks pick the target; the window model (sidebar destination, sheets, palette,
/// open hosts) survives switching targets. Which hosts were open, which groups were collapsed and
/// the last-focused tab are restored on launch.
struct WindowRoot: View {
    @Environment(AppModel.self) private var app
    /// Legacy single-target restore (before multi-host windows).
    @SceneStorage("target") private var storedTarget: String?
    @SceneStorage("openHosts") private var storedHosts: String?
    @SceneStorage("collapsedHosts") private var storedCollapsed: String?
    @SceneStorage("focusedTab") private var storedFocus: String?
    @State private var restored = false
    /// Created once, when the window first appears. A `@State` initial value is evaluated every
    /// time SwiftUI re-creates this struct, and each spare `WindowModel` built its own local
    /// workspace: the screen then showed one model's panes while shortcuts, fixtures and the
    /// palette acted on another.
    @State private var model: WindowModel?

    var body: some View {
        if let model {
            window(model)
        } else {
            Color.clear.onAppear { model = WindowModel(app: AppModel.shared) }
        }
    }

    private func window(_ model: WindowModel) -> some View {
        Group {
            if let workspace = model.workspace {
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
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .environment(model)
        .onAppear { ActiveWindow.register(model) }
        .onChange(of: app.lastError) { _, error in
            if let error { model.toasts.show(Toast(error, systemImage: "exclamationmark.triangle.fill", style: .failure)) }
        }
        .onChange(of: model.groups.openHosts) { _, _ in persist(model) }
        .onChange(of: model.groups.collapsed) { _, _ in persist(model) }
        .onChange(of: model.currentTab) { _, _ in persist(model) }
        .modifier(HostKeyPromptModifier(prompts: app.hosts.hostKeyPrompts))
        .onOpenURL { url in
            // An invite opens the Join sheet: joining is always the user's tap.
            if AppLinks.isInvite(url) {
                model.joinInvite = url.absoluteString
                model.sheet = .join
                return
            }
            if let (host, pane) = AppLinks.openTarget(url) {
                AppNotifications.openPane(hostId: host, pane: pane)
                return
            }
            Task {
                if let target = await app.handle(url: url) {
                    model.show(target)
                    model.destination = .terminal
                    model.toasts.show(Toast("Paired with \(model.hostName)", systemImage: "checkmark.circle.fill", style: .success))
                }
            }
        }
        .task {
            guard !restored else { return }
            restored = true
            app.hosts.foreground()
            let hooked = await app.runLaunchHooks()
            if !hooked.isEmpty {
                // Open every hooked host (they stay connected), show the first.
                for target in hooked { model.show(target) }
                model.show(hooked[0])
            } else if shouldRestore {
                restore(model)
            }
            // `-openHost <name or id>`: open that saved host (screenshots, manual checks).
            if let wanted = UserDefaults.standard.string(forKey: "openHost"),
               let record = app.hosts.records.first(where: { $0.id == wanted || $0.name == wanted })
            {
                model.show(.host(record.id))
            }
            // `-destination hosts|inbox`: open on that screen (screenshots of live data).
            switch UserDefaults.standard.string(forKey: "destination") {
            case "hosts": model.destination = .hosts
            case "inbox": model.destination = .inbox
            default: break
            }
        }
    }

    /// Restore by default in normal launches; never for design fixtures, `-mock` or dogfood
    /// runs unless `-restoreLastTarget YES` asks for it.
    private var shouldRestore: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "restoreLastTarget") != nil { return defaults.bool(forKey: "restoreLastTarget") }
        return LaunchOptions.screen == nil && !LaunchOptions.mock && defaults.string(forKey: "dogfood") == nil
    }

    /// The window's open hosts and focused tab: the scene's own storage, else what the last
    /// window saved (a new scene on iPad, a Mac window restored without state), else the
    /// single host of a window saved before multi-host.
    private func restore(_ model: WindowModel) {
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
        model.restore(openHosts: hosts ?? [], collapsed: Set(collapsed), focus: focus)
    }

    private static let lastHostsKey = "window.openHosts"
    private static let lastCollapsedKey = "window.collapsedHosts"
    private static let lastFocusKey = "window.focusedTab"

    /// Saves what a relaunch restores, per window and as the app's latest.
    private func persist(_ model: WindowModel) {
        guard restored, shouldRestore else { return }
        let encoder = JSONEncoder()
        func encode(_ value: some Encodable) -> String? {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        storedHosts = encode(model.groups.openHosts)
        storedCollapsed = encode(model.groups.collapsed.sorted())
        storedFocus = model.currentTab.flatMap(encode)
        storedTarget = nil
        let defaults = UserDefaults.standard
        defaults.set(storedHosts, forKey: Self.lastHostsKey)
        defaults.set(storedCollapsed, forKey: Self.lastCollapsedKey)
        defaults.set(storedFocus, forKey: Self.lastFocusKey)
    }
}
