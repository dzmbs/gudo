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
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
        }
        .commands { WorkspaceCommands() }
        #if os(macOS)
        .defaultSize(width: 1100, height: 700)
        #endif
    }
}
