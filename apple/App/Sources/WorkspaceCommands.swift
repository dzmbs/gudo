import SwiftUI

/// The menus. On macOS they are the menu bar; on iPadOS the same commands drive the iPadOS menu
/// bar and the ⌘-hold shortcut overlay as `UIKeyCommand`s. ⌘ is never sent to the terminal
/// (04-mobile-ux C7).
struct WorkspaceCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace
    @AppStorage("tabStyle") private var tabStyle = TabStyle.sidebar

    var body: some Commands {
        CommandGroup(after: .newItem) {
            buttons(WorkspaceAction.fileActions)
        }
        CommandMenu("Pane") {
            buttons(WorkspaceAction.paneActions)
        }
        CommandMenu("Tab") {
            buttons(WorkspaceAction.tabActions)
            Divider()
            Button("Rename Tab…") { workspace?.renamingTab = workspace?.session.activeTabId }
                .disabled(workspace?.session.activeTab == nil)
            Toggle("Vertical Tabs", isOn: Binding(get: { tabStyle == .sidebar }, set: { tabStyle = $0 ? .sidebar : .bar }))
        }
    }

    private func buttons(_ actions: [WorkspaceAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            Button(action.title) { workspace.map(action.perform) }
                .keyboardShortcut(action.shortcut)
                .disabled(workspace == nil)
        }
    }
}
