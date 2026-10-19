import SwiftUI

/// The menus. On macOS they are the menu bar; on iPadOS the same commands drive the iPadOS menu
/// bar and the ⌘-hold shortcut overlay as `UIKeyCommand`s. ⌘ is never sent to the terminal
/// (04-mobile-ux C7).
struct WorkspaceCommands: Commands {
    @FocusedValue(Workspace.self) private var focusedWorkspace
    @FocusedValue(WindowModel.self) private var focusedModel
    @AppStorage("tabStyle") private var tabStyle = TabStyle.sidebar

    /// The focused window's workspace, else the one last worked in. The items are never disabled
    /// for a missing focused value: SwiftUI reports none at times while a window is key (after it
    /// rebuilds its content), and an item disabled then stayed disabled, so ⌘D or ⌘T silently did
    /// nothing. The actions resolve the window when they run.
    private var workspace: Workspace? { focusedWorkspace ?? ActiveWindow.workspace }
    private var model: WindowModel? { focusedModel ?? ActiveWindow.model }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            buttons(WorkspaceAction.fileActions)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model?.isSearchShown = true }
                .keyboardShortcut("f")
        }
        CommandMenu("Pane") {
            buttons(WorkspaceAction.paneActions)
            Divider()
            buttons(WorkspaceAction.drawActions)
            Divider()
            Button("Links & Paths…") { model?.sheet = .links }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu("Tab") {
            buttons(WorkspaceAction.tabActions)
            Divider()
            Button("Rename Tab…") { workspace?.renamingTab = workspace?.session.activeTabId }
                .disabled(workspace?.session.activeTab == nil)
            Toggle("Vertical Tabs", isOn: Binding(get: { tabStyle == .sidebar }, set: { tabStyle = $0 ? .sidebar : .bar }))
        }
        CommandGroup(before: .sidebar) {
            // Ghostty binds the palette to ⇧⌘P; ⌘K is Raycast's and Linear's.
            Button("Command Palette") { model?.isPaletteShown.toggle() }
                .keyboardShortcut("k")
            Button("Command Palette") { model?.isPaletteShown.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Inbox") { model?.destination = .inbox }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Hosts") { model?.destination = model?.destination == .hosts ? .terminal : .hosts }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Add Host…") { model?.addHost() }
            Divider()
        }
    }

    private func buttons(_ actions: [WorkspaceAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            Button(action.title) { if let workspace { action.perform(on: workspace, window: model ?? ActiveWindow.model(for: workspace)) } }
                .keyboardShortcut(action.shortcut)
        }
    }
}

/// The window the user last worked in, for menu commands while SwiftUI reports no focused scene
/// value (see `WorkspaceCommands.workspace`).
@MainActor
enum ActiveWindow {
    static weak var workspace: Workspace?
    private static let models = NSHashTable<WindowModel>.weakObjects()

    static func register(_ model: WindowModel) {
        models.add(model)
    }

    static var model: WindowModel? {
        models.allObjects.first { workspace != nil && $0.workspace === workspace } ?? models.allObjects.first
    }

    /// The window showing `workspace`.
    static func model(for workspace: Workspace) -> WindowModel? {
        models.allObjects.first { $0.workspace === workspace }
    }

    #if os(macOS)
    /// The workspace shown in `window`: the one whose panes live there, else the last active.
    static func workspace(in window: NSWindow) -> Workspace? {
        for model in models.allObjects {
            if let candidate = model.workspace, candidate.panes.values.contains(where: { $0.view.window === window }) {
                return candidate
            }
        }
        return workspace
    }
    #endif
}
