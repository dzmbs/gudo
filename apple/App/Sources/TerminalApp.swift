import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct TerminalApp: App {
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(macOS)
        // Tabs are ours (⌘T); AppKit's window tabbing would compete for the same shortcuts.
        NSWindow.allowsAutomaticWindowTabbing = false
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
        .defaultSize(width: 1100, height: 700)
        #endif
    }
}

/// One window: the workspace it shows (local or a host) and the hosts list. Deep links and the
/// launch test hooks pick the target.
struct WindowRoot: View {
    @Environment(AppModel.self) private var app
    @SceneStorage("target") private var storedTarget: String?
    @State private var target = WorkspaceTarget.local
    @State private var showingHosts = false
    @State private var restored = false
    /// The workspace on screen, resolved when the target changes (never during `body`).
    @State private var workspace: Workspace?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
                    .id(ObjectIdentifier(workspace))
            } else {
                ContentUnavailableView {
                    Label("Host unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(app.lastError ?? "")
                } actions: {
                    Button("Hosts") { showingHosts = true }
                }
            }
        }
        .onChange(of: connectionIdentity) { _, _ in
            // A host whose connection was replaced (plain SSH upgraded to the daemon) gets a
            // workspace on the new connection; the window stays on the host.
            refresh()
        }
        .environment(\.showHosts, ShowHostsAction { showingHosts = true })
        .modifier(HostKeyPromptModifier(prompts: app.hosts.hostKeyPrompts))
        .sheet(isPresented: $showingHosts) {
            HostsView { selected in
                showingHosts = false
                show(selected)
            }
            .environment(app)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 520)
            #endif
        }
        .onOpenURL { url in
            Task { if let target = await app.handle(url: url) { show(target) } }
        }
        .task {
            guard !restored else { return }
            restored = true
            refresh()
            app.hosts.foreground()
            if let hooked = await app.runLaunchHooks() {
                show(hooked)
            } else if UserDefaults.standard.object(forKey: "restoreLastTarget") == nil || UserDefaults.standard.bool(forKey: "restoreLastTarget"),
                      let storedTarget, let data = storedTarget.data(using: .utf8),
                      let saved = try? JSONDecoder().decode(WorkspaceTarget.self, from: data),
                      case .host(let id) = saved, app.hosts.record(id) != nil
            {
                show(saved)
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
    }

    private func show(_ selected: WorkspaceTarget) {
        AppModel.log.info("show \(String(describing: selected), privacy: .public)")
        target = selected
        refresh()
        storedTarget = (try? JSONEncoder().encode(selected)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
