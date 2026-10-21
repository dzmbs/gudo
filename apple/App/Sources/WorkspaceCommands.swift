import SwiftUI

/// The menus. On macOS they are the menu bar; on iPadOS the same commands drive the iPadOS menu
/// bar and the ⌘-hold shortcut overlay as `UIKeyCommand`s. ⌘ is never sent to the terminal
/// (04-mobile-ux C7).
struct WorkspaceCommands: Commands {
    @FocusedValue(Workspace.self) private var focusedWorkspace
    @FocusedValue(WindowModel.self) private var focusedModel
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true

    /// The focused window's workspace, else the one last worked in. The items are never disabled
    /// for a missing focused value: SwiftUI reports none at times while a window is key (after it
    /// rebuilds its content), and an item disabled then stayed disabled, so ⌘D or ⌘T silently did
    /// nothing. The actions resolve the window when they run.
    private var workspace: Workspace? { focusedWorkspace ?? ActiveWindow.workspace }
    private var model: WindowModel? { focusedModel ?? ActiveWindow.model }
    /// VS Code is in front: every key goes to it (⌘P, ⌘⇧P, ⌘F, ⌘D, ⌘K chords…), so the app's
    /// own shortcuts step aside.
    private var editorHasKeys: Bool { model?.isEditorShown == true }

    var body: some Commands {
        #if os(iOS)
        // iPadOS: New Window opens the same hosts on the same tab (`WindowRequest.like`); the
        // window then goes its own way. The Mac's File ▸ New Window does the same through
        // `WindowGroup(for:)` with no request (it restores the last window's hosts).
        CommandGroup(replacing: .newItem) {
            buttons([.newWindow])
            buttons(WorkspaceAction.fileActions)
        }
        #else
        CommandGroup(after: .newItem) {
            buttons(WorkspaceAction.fileActions)
        }
        #endif
        CommandGroup(after: .textEditing) {
            buttons([.find, .findNext, .findPrevious])
        }
        // A terminal has no rich text: the system's Format ▸ Font items (Bold ⌘B, Italic ⌘I,
        // Underline ⌘U) and Print (⌘P) would answer those chords before the terminal and the
        // app's own shortcuts (⌘B sidebar, ⌘P Go to Tab) ever saw them.
        CommandGroup(replacing: .textFormatting) {}
        CommandGroup(replacing: .printItem) {}
        CommandMenu("Pane") {
            buttons(WorkspaceAction.paneActions)
            Divider()
            buttons(WorkspaceAction.drawActions)
            Divider()
            buttons([.links])
        }
        CommandMenu("Tab") {
            buttons(WorkspaceAction.tabActions)
            Divider()
            Button("Rename Tab…") { workspace?.renamingTab = workspace?.session.activeTabId }
                .disabled(workspace?.session.activeTab == nil)
        }
        CommandMenu("Git") {
            Button("New Task…") { model?.sheet = .launchAgent }
                .disabled(editorHasKeys)
            Button("Run Script") { model?.git.runDefault() }
                .keyboardShortcut("r")
                // Sheets with their own ⌘R (Diff, Browser reload) keep it.
                .disabled(editorHasKeys || model?.sheet != nil)
            Divider()
            Button("Open Pull Request on GitHub") { model?.git.openOnGitHub() }
                .keyboardShortcut("g", modifiers: [.command, .control])
                .disabled(editorHasKeys)
            Button("Merge Pull Request…") { model?.git.requestMerge() }
            Button("Re-run Failed Checks") { model?.git.rerunFailed() }
            Button("Create Pull Request") { model?.git.createPR() }
            Button("Check Out Pull Request…") { model?.git.isCheckoutPromptShown = true }
            Divider()
            Button("Archive Worktree") { if let wt = model?.git.worktree { model?.git.archive(wt) } }
        }
        CommandGroup(before: .sidebar) {
            Button(model?.isSidebarShown == false ? "Show Sidebar" : "Hide Sidebar") {
                if let model { WorkspaceAction.toggleSidebar.perform(window: model) }
            }
                .keyboardShortcut(WorkspaceAction.toggleSidebar.shortcut)
                .disabled(editorHasKeys)
            Toggle("Tab Bar When the Sidebar Is Hidden", isOn: $showsTabBar)
            // Two tabs side by side (on by itself on a foldable's open inner screen).
            Toggle("Two Columns", isOn: Binding(get: { model?.isTwoColumns ?? false }, set: { _ in model?.toggleTwoColumns() }))
                .disabled(editorHasKeys || model == nil)
            Divider()
            buttons([.commandPalette, .commandPaletteGhostty, .inbox, .jumpToWaitingAgent, .hosts, .shortcuts])
            Button("Add Host…") { model?.addHost() }
            Divider()
        }
    }

    private func buttons(_ actions: [WorkspaceAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            Button(action.title) {
                if let workspace {
                    action.perform(on: workspace, window: model ?? ActiveWindow.model(for: workspace))
                } else if let model, let workspace = model.workspace {
                    action.perform(on: workspace, window: model)
                }
            }
                .keyboardShortcut(action.shortcut)
                .disabled(editorHasKeys)
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

    /// The window showing `workspace` (on screen, else as one of its hosts: a mixed tab's or the
    /// other column's pane).
    static func model(for workspace: Workspace) -> WindowModel? {
        models.allObjects.first { $0.workspace === workspace }
            ?? models.allObjects.first { $0.workspaces.values.contains { $0 === workspace } }
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
