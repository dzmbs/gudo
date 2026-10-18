import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct TerminalApp: App {
    init() {
        #if os(macOS)
        // Tabs are ours (⌘T); AppKit's window tabbing would compete for the same shortcuts.
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        WindowSnapshot.scheduleIfRequested()
        #endif
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
        }
        .commands { WorkspaceCommands() }
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
