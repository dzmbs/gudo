import PaneLayout
import SwiftUI
import TerminalCore

/// Where tabs are listed in regular-width windows.
enum TabStyle: String {
    /// A vertical tab list in a collapsible sidebar (the default on iPad and Mac).
    case sidebar
    /// A horizontal tab strip above the panes.
    case bar
}

/// A window: tabs (sidebar, strip, or the compact switcher on iPhone) around the active tab's panes.
struct WorkspaceView: View {
    @State private var workspace = Workspace()
    @AppStorage("tabStyle") private var tabStyle = TabStyle.sidebar
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        content
            .focusedSceneValue(workspace)
            .preferredColorScheme(.dark)
            .renameTabPrompt(workspace)
            #if os(macOS)
            // Closing the last pane closes the window, as in Ghostty.
            .onChange(of: workspace.session.tabs.isEmpty) { _, isEmpty in
                if isEmpty { dismiss() }
            }
            #endif
            #if DEBUG && os(macOS)
            // `-dogfood <scenario.json>`: the in-app scenario runner (App/Sources/Debug).
            .task { DogfoodRunner.startIfRequested(workspace: workspace) }
            #endif
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if sizeClass == .compact {
            CompactWorkspaceView(workspace: workspace)
        } else {
            regular
        }
        #else
        regular
        #endif
    }

    @ViewBuilder private var regular: some View {
        switch tabStyle {
        case .sidebar:
            NavigationSplitView {
                TabSidebar(workspace: workspace)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            } detail: {
                ActiveTabView(workspace: workspace)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            PaneMenu(workspace: workspace)
                            TabStyleToggle(style: $tabStyle)
                        }
                    }
            }
        case .bar:
            VStack(spacing: 0) {
                TabBar(workspace: workspace, style: $tabStyle)
                ActiveTabView(workspace: workspace)
            }
        }
    }
}

/// The active tab's panes: its split tree, the zoomed pane alone, or only the focused pane in
/// compact width (no splits on iPhone, 04-mobile-ux C3).
struct ActiveTabView: View {
    let workspace: Workspace
    var compact = false

    var body: some View {
        Group {
            if let tab = workspace.session.activeTab {
                let single = compact ? tab.focused : tab.zoomed
                SplitTreeView(
                    node: single.map(Node.leaf) ?? tab.root,
                    workspace: workspace,
                    showsFocus: single == nil && tab.root.panes.count > 1)
            } else {
                ContentUnavailableView {
                    Label("No Tabs", systemImage: "terminal")
                } actions: {
                    Button("New Tab") { workspace.apply(.newTab) }
                }
            }
        }
        .background(Color.terminalBackground)
    }
}

/// Split, zoom and close without a keyboard: touch on iPad, or the mouse.
struct PaneMenu: View {
    let workspace: Workspace

    var body: some View {
        Menu("Pane", systemImage: "rectangle.split.2x1") {
            ForEach([WorkspaceAction.splitRight, .splitDown, .toggleZoom, .closePane], id: \.self) { action in
                Button(action.title) { action.perform(on: workspace) }
            }
            Divider()
            KeyboardSettingsMenu()
        }
        .disabled(workspace.focusedPane == nil)
        .accessibilityIdentifier("pane-menu")
    }
}

/// Option-as-Meta (Ghostty's `macos-option-as-alt`) and, on iOS, the ASCII-capable keyboard.
struct KeyboardSettingsMenu: View {
    @AppStorage(KeyboardSettings.optionAsMeta) private var optionAsMeta = OptionAsMeta.none.rawValue
    #if os(iOS)
    @AppStorage(KeyboardSettings.asciiKeyboard) private var asciiKeyboard = false
    #endif

    var body: some View {
        Menu("Keyboard", systemImage: "keyboard") {
            Picker("Option as Meta", selection: $optionAsMeta) {
                Text("Off").tag(OptionAsMeta.none.rawValue)
                Text("Left Option").tag(OptionAsMeta.left.rawValue)
                Text("Right Option").tag(OptionAsMeta.right.rawValue)
                Text("Both").tag(OptionAsMeta.both.rawValue)
            }
            #if os(iOS)
            Toggle("ASCII Keyboard", isOn: $asciiKeyboard)
            #endif
        }
    }
}

struct TabStyleToggle: View {
    @Binding var style: TabStyle

    var body: some View {
        Button(
            style == .sidebar ? "Tabs on Top" : "Tabs in Sidebar",
            systemImage: style == .sidebar ? "rectangle.topthird.inset.filled" : "sidebar.left"
        ) {
            style = style == .sidebar ? .bar : .sidebar
        }
        .help("Switch between vertical and horizontal tabs")
    }
}

/// Rename / Close for a tab, shared by the sidebar, the strip and the compact switcher.
struct TabMenu: View {
    let tab: Tab
    let workspace: Workspace

    var body: some View {
        Button("Rename…", systemImage: "pencil") { workspace.renamingTab = tab.id }
        Button("Close Tab", systemImage: "xmark", role: .destructive) { workspace.apply(.closeTab(tab.id)) }
    }
}

private struct RenameTabPrompt: ViewModifier {
    let workspace: Workspace
    @State private var draft = ""

    func body(content: Content) -> some View {
        content.alert(
            "Rename Tab",
            isPresented: Binding(get: { workspace.renamingTab != nil }, set: { if !$0 { workspace.renamingTab = nil } })
        ) {
            TextField("Title", text: $draft)
            Button("Rename") {
                if let id = workspace.renamingTab { workspace.apply(.rename(id, draft)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to use the default title.")
        }
        .onChange(of: workspace.renamingTab) { _, id in
            draft = workspace.session.tabs.first { $0.id == id }?.title ?? ""
        }
    }
}

extension View {
    func renameTabPrompt(_ workspace: Workspace) -> some View {
        modifier(RenameTabPrompt(workspace: workspace))
    }
}
