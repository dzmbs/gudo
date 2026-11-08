import DesignSystem
import PaneLayout
import SwiftUI

/// What a tool's screens need to know when they are a leaf of the split tree.
struct ToolLeafContext {
    let member: ToolMember
    let isSplit: Bool
    let isFocused: Bool
    let focus: () -> Void
    let close: () -> Void
    /// Mac: the tool in a window of its own instead (nil where there are none).
    let openInWindow: (() -> Void)?
}

extension EnvironmentValues {
    /// Set inside a tool leaf: screens draw the leaf's bar instead of a navigation bar or the
    /// window's toolbar, which belong to the whole window there.
    @Entry var toolLeaf: ToolLeafContext?
    /// History for tools shown where nothing pushes (a leaf, a Mac tool window).
    @Entry var toolNavigation: ToolNavigation?
}

/// Back, forward and the places around the one shown (Finder's toolbar and title menu).
struct ToolNavigation {
    struct Stop: Identifiable {
        var id: String
        var title: String
        var systemImage: String
        var go: () -> Void
    }

    var back: (() -> Void)?
    var forward: (() -> Void)?
    /// The places enclosing this one, nearest first: the title's menu; ⌘↑ goes to the first.
    var enclosing: [Stop] = []
    /// The whole location, for the title's help.
    var location: String?
    /// A NavigationStack draws the way back itself (a sheet on iPhone and iPad).
    var isStacked = false
}

extension View {
    /// A tool screen's title, subtitle and actions: the navigation bar and toolbar in a sheet or
    /// tool window, the leaf's own bar in the split tree.
    func toolChrome(_ title: String, subtitle: String = "", @ViewBuilder actions: () -> some View) -> some View {
        modifier(ToolChrome(title: title, subtitle: subtitle, actions: actions()))
    }

    func toolChrome(_ title: String, subtitle: String = "") -> some View {
        toolChrome(title, subtitle: subtitle) { EmptyView() }
    }

    /// A tool's keyboard shortcut. In a leaf only while it has the focus: the window's panes
    /// take keys too.
    func toolShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        modifier(ToolShortcut(shortcut: KeyboardShortcut(key, modifiers: modifiers)))
    }

    /// A sheet's or tool window's least size; a leaf takes the room its split gives it.
    func toolMinimumSize(width: CGFloat, height: CGFloat) -> some View {
        modifier(ToolMinimumSize(width: width, height: height))
    }
}

private struct ToolChrome<Actions: View>: ViewModifier {
    let title: String
    let subtitle: String
    let actions: Actions
    @Environment(\.toolLeaf) private var leaf
    @Environment(\.toolNavigation) private var navigation

    func body(content: Content) -> some View {
        Group {
            if let leaf {
                VStack(spacing: 0) {
                    ToolLeafBar(leaf: leaf, title: title, subtitle: subtitle, navigation: navigation) { actions }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationBarBackButtonHidden()
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
            } else {
                content
                    .navigationTitle(title)
                    .navigationSubtitle(subtitle)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        if let navigation, !navigation.isStacked {
                            ToolbarItemGroup(placement: .navigation) { HistoryButtons(navigation: navigation) }
                        }
                        ToolbarItemGroup(placement: .primaryAction) { actions }
                    }
                    .toolbarTitleMenu {
                        if let navigation { EnclosingMenu(navigation: navigation) }
                    }
            }
        }
        .background {
            if let navigation, leaf?.isFocused ?? true { HistoryShortcuts(navigation: navigation) }
        }
    }
}

private struct HistoryButtons: View {
    let navigation: ToolNavigation

    var body: some View {
        Button("Back", systemImage: "chevron.backward") { navigation.back?() }
            .disabled(navigation.back == nil)
            .help("Back (⌘[)")
            .accessibilityIdentifier("tool-back")
        Button("Forward", systemImage: "chevron.forward") { navigation.forward?() }
            .disabled(navigation.forward == nil)
            .help("Forward (⌘])")
            .accessibilityIdentifier("tool-forward")
    }
}

private struct EnclosingMenu: View {
    let navigation: ToolNavigation

    var body: some View {
        ForEach(navigation.enclosing) { stop in
            Button(stop.title, systemImage: stop.systemImage, action: stop.go)
        }
    }
}

private struct HistoryShortcuts: View {
    let navigation: ToolNavigation

    var body: some View {
        Group {
            Button("Back") { navigation.back?() }
                .keyboardShortcut("[")
                .disabled(navigation.back == nil)
            Button("Forward") { navigation.forward?() }
                .keyboardShortcut("]")
                .disabled(navigation.forward == nil)
            Button("Enclosing Folder") { navigation.enclosing.first?.go() }
                .keyboardShortcut(.upArrow)
                .disabled(navigation.enclosing.isEmpty)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct ToolShortcut: ViewModifier {
    let shortcut: KeyboardShortcut
    @Environment(\.toolLeaf) private var leaf

    func body(content: Content) -> some View {
        content.keyboardShortcut(leaf.map(\.isFocused) ?? true ? shortcut : nil)
    }
}

private struct ToolMinimumSize: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    @Environment(\.toolLeaf) private var leaf

    func body(content: Content) -> some View {
        if leaf == nil { content.macMinimumSize(width: width, height: height) } else { content }
    }
}

/// A tool leaf's header bar; 24 pt when split, to match the pane headers beside it.
private struct ToolLeafBar<Actions: View>: View {
    let leaf: ToolLeafContext
    let title: String
    let subtitle: String
    let navigation: ToolNavigation?
    @ViewBuilder let actions: Actions
    @Environment(\.terminalTheme) private var theme
    @Environment(\.isPresented) private var isPushed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: leaf.isSplit ? DS.Space.xs + 2 : DS.Space.s) {
            Button("Close \(leaf.member.tool.title)", systemImage: "xmark", action: leaf.close)
                .help("Close (⌘W)")
                .accessibilityIdentifier("tool-close")
            if let navigation {
                HStack(spacing: 0) { HistoryButtons(navigation: navigation) }
            } else if isPushed {
                Button("Back", systemImage: "chevron.backward") { dismiss() }
                    .help("Back")
                    .accessibilityIdentifier("BackButton")
            } else {
                Image(systemName: leaf.member.tool.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityHidden(true)
            }
            titleMenu
                .layoutPriority(1)
                .help(navigation?.location ?? title)
            Spacer(minLength: DS.Space.s)
            actions
                .fixedSize()
            if let openInWindow = leaf.openInWindow {
                Menu("More", systemImage: "ellipsis") {
                    Button("Open in New Window", systemImage: "macwindow", action: openInWindow)
                        .accessibilityIdentifier("tool-new-window")
                }
                .menuIndicator(.hidden)
                .accessibilityIdentifier("tool-more")
            }
        }
        .font(leaf.isSplit ? .caption : nil)
        .labelStyle(.iconOnly)
        .buttonStyle(.bar)
        .padding(.leading, leaf.isSplit ? DS.Space.xs : DS.Space.m)
        .padding(.trailing, leaf.isSplit ? DS.Space.xxs : DS.Space.m)
        .frame(height: leaf.isSplit ? 24 : DS.Size.tabBar)
        .background(theme.background)
        .overlay(alignment: .bottom) { theme.splitDivider.frame(height: 1) }
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(.rect)
        .onTapGesture { if !leaf.isFocused { leaf.focus() } }
    }

    private var titles: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(verbatim: title)
                .font(leaf.isSplit ? .caption.weight(leaf.isFocused ? .semibold : .regular) : .callout.weight(.medium))
                .foregroundStyle(leaf.isFocused ? DS.Palette.text : DS.Palette.textSecondary)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tool-title")
    }

    @ViewBuilder private var titleMenu: some View {
        if let navigation, !navigation.enclosing.isEmpty {
            Menu {
                EnclosingMenu(navigation: navigation)
            } label: {
                titles.contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        } else {
            titles
        }
    }
}

/// A tool's screens for the window's model, as a tool window or a leaf shows them.
struct ToolContent: View {
    let tool: ToolMember.Tool
    @Environment(WindowModel.self) private var model

    var body: some View {
        switch tool {
        case .files:
            NavigationStack {
                FilesBrowserView(
                    source: model.files,
                    onOpenInEditor: model.files.unavailableReason == nil ? { path in model.openEditor(path: path) } : nil,
                    onRevealInTerminal: { model.revealInTerminal($0) },
                    onInsertPath: { model.insertInTerminal($0) })
            }
        case .changes:
            NavigationStack { DiffReviewView(source: model.diffs) }
        case .ports:
            BrowserSheet()
        case .replays:
            SessionReplaysSheet(request: model.replayRequest)
                // Asked again for other sessions: start over on them.
                .id(model.replayRequest)
        case .viewer:
            if let target = model.fileViewerTarget { FileViewerScreen(target: target) }
        }
    }
}

/// A tool shown as a leaf of the split tree.
struct ToolLeafView: View {
    let member: ToolMember
    let isSplit: Bool
    let isFocused: Bool
    let focus: () -> Void
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        Group {
            if member.tool == .viewer, let path = member.path {
                FileViewerScreen(target: FileTarget(
                    hostId: member.hostId == HostGroups.localId ? nil : member.hostId, path: path, line: member.line,
                    column: member.column))
            } else {
                ToolContent(tool: member.tool)
            }
        }
        .environment(\.isToolWindow, true)
        .environment(\.toolLeaf, ToolLeafContext(
            member: member, isSplit: isSplit, isFocused: isFocused, focus: focus,
            close: { model.closeTool(member.id) },
            openInWindow: model.hasToolWindows && member.tool != .viewer ? { model.moveToolToWindow(member) } : nil))
        .background(theme.background)
        .simultaneousGesture(TapGesture().onEnded { if !isFocused { focus() } })
        .overlay(alignment: .topLeading) {
            // A marker: an identifier on the container would replace its controls' own.
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(member.tool.title)
                .accessibilityIdentifier("tool-leaf-\(member.tool.rawValue)")
        }
        // One leaf's screens are never another's.
        .id(member.id)
    }
}
