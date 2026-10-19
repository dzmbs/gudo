import DesignSystem
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

/// One window: the workspace it shows (this device or a host) inside the design's chrome. Deep
/// links, the hosts list and the launch test hooks pick the target; the window model (sidebar
/// destination, sheets, palette) survives switching targets.
struct WindowRoot: View {
    @Environment(AppModel.self) private var app
    @SceneStorage("target") private var storedTarget: String?
    @State private var target = WorkspaceTarget.local
    @State private var restored = false
    @State private var model = WindowModel(app: AppModel.shared)
    /// The workspace on screen, resolved when the target changes (never during `body`).
    @State private var workspace: Workspace?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
                    .id(ObjectIdentifier(workspace))
            } else {
                EmptyState(
                    "Host Unavailable", systemImage: "exclamationmark.triangle",
                    message: app.lastError ?? "The host could not be opened."
                ) {
                    Button("Show Hosts") { show(.local, destination: .hosts) }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .environment(model)
        .onChange(of: connectionIdentity) { _, _ in
            // A host whose connection was replaced (plain SSH upgraded to the daemon) gets a
            // workspace on the new connection; the window stays on the host.
            refresh()
        }
        .onChange(of: app.lastError) { _, error in
            if let error { model.toasts.show(Toast(error, systemImage: "exclamationmark.triangle.fill", style: .failure)) }
        }
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
                    show(target)
                    model.toasts.show(Toast("Paired with \(model.hostName)", systemImage: "checkmark.circle.fill", style: .success))
                }
            }
        }
        .task {
            guard !restored else { return }
            restored = true
            model.show = { show($0) }
            refresh()
            app.hosts.foreground()
            if let hooked = await app.runLaunchHooks() {
                show(hooked)
            } else if UserDefaults.standard.bool(forKey: "restoreLastTarget")
                        || (LaunchOptions.screen == nil && !LaunchOptions.mock && UserDefaults.standard.object(forKey: "restoreLastTarget") == nil),
                      let storedTarget, let data = storedTarget.data(using: .utf8),
                      let saved = try? JSONDecoder().decode(WorkspaceTarget.self, from: data),
                      case .host(let id) = saved, app.hosts.record(id) != nil
            {
                show(saved)
            }
            // `-openHost <name or id>`: open that saved host (screenshots, manual checks).
            if let wanted = UserDefaults.standard.string(forKey: "openHost"),
               let record = app.hosts.records.first(where: { $0.id == wanted || $0.name == wanted })
            {
                show(.host(record.id))
            }
            // `-destination hosts|inbox`: open on that screen (screenshots of live data).
            switch UserDefaults.standard.string(forKey: "destination") {
            case "hosts": model.destination = .hosts
            case "inbox": model.destination = .inbox
            default: break
            }
        }
    }

    /// The current target's connection object, so `onChange` sees an upgrade.
    private var connectionIdentity: ObjectIdentifier? {
        guard case .host(let id) = target else { return nil }
        return app.hosts.connections[id].map { ObjectIdentifier($0) }
    }

    private func refresh() {
        workspace = app.workspace(for: target)
        model.workspace = workspace
    }

    private func show(_ selected: WorkspaceTarget, destination: Destination = .terminal) {
        model.destination = destination
        AppModel.log.info("show \(String(describing: selected), privacy: .public)")
        target = selected
        refresh()
        storedTarget = (try? JSONEncoder().encode(selected)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
