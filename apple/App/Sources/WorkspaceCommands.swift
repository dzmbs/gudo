import SwiftUI

/// The menus. On macOS they are the menu bar; on iPadOS the same commands drive the iPadOS menu
/// bar and the ⌘-hold shortcut overlay as `UIKeyCommand`s. ⌘ is never sent to the terminal
/// (04-mobile-ux C7).
struct WorkspaceCommands: Commands {
    @FocusedValue(Workspace.self) private var focusedWorkspace
    @FocusedValue(WindowModel.self) private var focusedModel
    @AppStorage("tabStyle") private var tabStyle = TabStyle.sidebar

    /// The focused window's workspace, else the one last worked in. SwiftUI briefly reports no
    /// focused scene value while a window rebuilds its content, and a menu item disabled at that
    /// moment can stay disabled, so ⌘D or ⌘T would silently do nothing.
    private var workspace: Workspace? { focusedWorkspace ?? ActiveWindow.workspace }
    private var model: WindowModel? { focusedModel ?? ActiveWindow.model }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            buttons(WorkspaceAction.fileActions)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model?.isSearchShown = true }
                .keyboardShortcut("f")
                .disabled(model == nil)
        }
        CommandMenu("Pane") {
            buttons(WorkspaceAction.paneActions)
            Divider()
            Button("Links & Paths…") { model?.sheet = .links }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model == nil)
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
                .disabled(model == nil)
            Button("Command Palette") { model?.isPaletteShown.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Inbox") { model?.destination = .inbox }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Hosts") { model?.destination = model?.destination == .hosts ? .terminal : .hosts }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Add Host…") { model?.addHost() }
                .disabled(model == nil)
            Divider()
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
}
