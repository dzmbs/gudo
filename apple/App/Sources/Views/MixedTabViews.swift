import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

// Mixed tabs (panes from several hosts in one tab) and Two Columns in the window
// (docs/APP-ARCHITECTURE.md §19; the model side is Model/MixedTabs.swift).

/// A mixed tab's tree: each leaf resolves through its own host's workspace in this window.
struct MixedTabTree: PaneTree {
    let model: WindowModel
    let id: TabId
    /// Whether this tab holds the window's focus (false: the other column).
    var isActive = true

    private var tab: CompositeTab? { model.composites.tab(id) }

    func resolve(_ leaf: PaneId) -> (workspace: Workspace, pane: PaneId)? {
        guard let member = tab?.members[leaf], let workspace = model.workspace(ofGroup: member.hostId) else { return nil }
        return (workspace, member.pane)
    }

    var focusedLeaf: PaneId? { isActive ? tab?.focusedLeaf : nil }

    func editor(_ leaf: PaneId) -> EditorMember? { tab?.editors[leaf] }

    func browser(_ leaf: PaneId) -> BrowserMember? { tab?.browsers[leaf] }

    func focus(leaf: PaneId) {
        model.focusLeaf(leaf, inMixedTab: id)
    }

    func resize(leaf: PaneId, _ direction: Direction, amount: Double) {
        model.composites.apply(.resize(leaf, direction, amount: amount), to: id)
    }

    /// Every host draws with the same font, so any measured pane's cell will do.
    var cellSize: CGSize? { model.workspace?.cellSize ?? model.workspaces.values.lazy.compactMap(\.cellSize).first }
    var padding: CGFloat { model.workspace?.appearance.padding ?? model.workspaces.values.first?.appearance.padding ?? 0 }
    var namesHosts: Bool { true }
}

/// What the terminal area shows: two columns, a mixed tab, or the active host tab.
struct TerminalArea: View {
    let workspace: Workspace
    var compact = false
    @Environment(WindowModel.self) private var model

    var body: some View {
        if model.isEditorFullScreen, let editor = model.activeMixed?.focusedEditor {
            FullScreenEditorView(member: editor)
        } else if !compact, model.columns != nil {
            TwoColumnsView()
        } else if let mixed = model.activeMixed {
            MixedTabView(id: mixed.id, compact: compact)
                // Never reuse one tab's pane views for another's.
                .id(WindowModel.mixedRef(mixed.id))
        } else {
            ActiveTabView(workspace: workspace, compact: compact)
                // Pane ids are per host: never reuse one host's pane views for another's.
                .id(ObjectIdentifier(workspace))
        }
    }
}

/// An editor alone in the window (⌃⌘F): the workbench edge to edge. The way back stays out of
/// the workbench's way: ⌃⌘F again, or the top edge, where a pointer resting or a tap brings up
/// Exit Full Screen for a few seconds (Escape is VS Code's).
struct FullScreenEditorView: View {
    let member: EditorMember
    @Environment(WindowModel.self) private var model
    @State private var isExitShown = false
    @State private var hide: Task<Void, Never>?

    var body: some View {
        EditorLeafView(member: member, isSplit: false, isFocused: true, focus: {}, isFullScreen: true)
            .overlay(alignment: .top) {
                VStack(spacing: DS.Space.xs) {
                    Color.clear
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                        .onContinuousHover { phase in
                            if case .active = phase { reveal() }
                        }
                        .onTapGesture { reveal() }
                        .accessibilityHidden(true)
                    if isExitShown {
                        Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left") {
                            model.toggleEditorFullScreen()
                        }
                        .buttonStyle(.glass)
                        .help("Exit Full Screen (⌃⌘F)")
                        .onHover { inside in if inside { reveal() } }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("editor-exit-full-screen")
                    }
                }
                .animation(DS.Motion.snappy, value: isExitShown)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-full-screen-view")
            #if os(iOS)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            #endif
    }

    private func reveal() {
        isExitShown = true
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isExitShown = false
        }
    }
}

/// A mixed tab: its split tree across hosts. Each pane carries its host in its header and its
/// own host's connection state: one host going down dims that pane only, with the reconnect
/// notice or card over it, while the others stay live.
struct MixedTabView: View {
    let id: TabId
    var isActive = true
    var compact = false
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    var body: some View {
        if let tab = model.composites.tab(id) {
            // Compact width shows the focused pane alone, as for a host tab.
            let single = compact ? tab.focusedLeaf : tab.layout.zoomed
            let isSplit = single == nil && tab.leaves.count > 1
            SplitTreeView(node: single.map(Node.leaf) ?? tab.layout.root, tree: MixedTabTree(model: model, id: id, isActive: isActive), isSplit: isSplit)
                .padding(paneStyle == .comfortable && isSplit ? DS.Space.row : 0)
                .background(paneStyle == .comfortable && isSplit ? theme.splitDivider : theme.background, ignoresSafeAreaEdges: [])
                .background(theme.background, ignoresSafeAreaEdges: [])
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    if isActive, !model.isPresentation, model.terminalArea != size { model.terminalArea = size }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mixed-tab")
        } else {
            theme.background
        }
    }
}

/// A pane's host in a mixed tab's pane header: its glyph (the link's state glyph while it is
/// not healthy) and name.
struct HostChip: View {
    let group: HostGroup
    let emphasized: Bool
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ConnectionGlyph(group.connectionState, healthy: Image(systemName: group.systemImage))
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
            Text(group.name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? DS.Palette.textSecondary : DS.Palette.textTertiary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(DS.Palette.hoverFill, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("on \(group.name)")
    }
}

extension View {
    /// A mixed tab's pane: its own host's connection overlay (dimmed with a notice or card while
    /// that host is down, as a host tab is), so the other hosts' panes stay live.
    @ViewBuilder func hostLinkOverlay(groupId: String, enabled: Bool) -> some View {
        if enabled {
            modifier(HostLinkOverlay(groupId: groupId))
        } else {
            self
        }
    }
}

private struct HostLinkOverlay: ViewModifier {
    let groupId: String
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        content.connectionOverlay(
            model.connectionState(ofGroup: groupId), hostName: model.groupName(groupId),
            onRetry: { model.hosts.retry(groupId) },
            onDisconnect: { model.closeHost(groupId) })
    }
}

/// The hosts of a mixed tab, as glyphs and names ("server alpha · server beta").
struct MixedHostsLine: View {
    let tab: CompositeTab
    @Environment(WindowModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(tab.hosts.enumerated()), id: \.element) { index, host in
                if index > 0 {
                    Text("+").foregroundStyle(DS.Palette.textTertiary)
                }
                HStack(spacing: 2) {
                    let group = model.groups.group(host)
                    ConnectionGlyph(model.connectionState(ofGroup: host), healthy: Image(systemName: group?.systemImage ?? "server.rack"))
                        .font(.caption2)
                        .imageScale(.small)
                    Text(model.groupName(host)).lineLimit(1)
                }
            }
        }
        .font(DS.Font.sidebarSubtitle)
        .foregroundStyle(DS.Palette.textSecondary)
    }
}

// MARK: - Sidebar and strip

/// The window's own tabs at the top of the sidebar: VS Code tabs under "VS Code", browser tabs
/// under "Browser", then mixed tabs under "Mixed". Each row names its hosts.
struct MixedSidebarSection: View {
    let numbers: [TabRef: Int]
    @Environment(WindowModel.self) private var model

    var body: some View {
        let ordered = model.composites.ordered
        section(ordered.filter(\.isEditorOnly), title: "VS Code", systemImage: "chevron.left.forwardslash.chevron.right", id: "host-group-editors")
        section(ordered.filter(\.isBrowserOnly), title: "Browser", systemImage: "globe", id: "host-group-browsers")
        section(ordered.filter { !$0.isEditorOnly && !$0.isBrowserOnly }, title: "Mixed", systemImage: "rectangle.split.2x1", id: "host-group-mixed")
    }

    @ViewBuilder private func section(_ tabs: [CompositeTab], title: String, systemImage: String, id: String) -> some View {
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: systemImage)
                        .font(DS.Font.section.weight(.regular))
                        .imageScale(.small)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .opacity(DS.Opacity.mutedGlyph)
                        .frame(width: 16)
                    Text(title)
                        .font(DS.Font.section)
                        .foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                }
                .padding(.leading, DS.Space.l)
                .padding(.trailing, DS.Space.gap10)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.xs)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(id)
                VStack(spacing: 1) {
                    ForEach(tabs) { tab in
                        let ref = WindowModel.mixedRef(tab.id)
                        MixedTabRow(tab: tab, number: numbers[ref] ?? 0)
                    }
                }
            }
            .transition(.opacity)
        }
    }
}

private struct MixedTabRow: View {
    let tab: CompositeTab
    let number: Int
    @Environment(WindowModel.self) private var model
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        let ref = WindowModel.mixedRef(tab.id)
        let isActive = model.destination == .terminal && model.currentTab == ref
        let title = model.title(ofMixedTab: tab)
        let program = model.programIdentity(ofMixedTab: tab)
        let state = tab.leaves.compactMap { tab.members[$0] }
            .compactMap { model.agentState(ofPane: $0.pane, onGroup: $0.hostId) }
            .min { $0.urgency < $1.urgency }
        Button {
            withAnimation(DS.Motion.snappy) { model.focus(ref) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.gap10) {
                Text("\(number)")
                    .font(DS.Font.sidebarSubtitle.monospacedDigit())
                    .foregroundStyle(isActive ? DS.Palette.textSecondary : DS.Palette.textTertiary)
                    .frame(width: 20, alignment: .trailing)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Space.row) {
                        TabLeadingMark(program: program, state: isActive ? nil : state)
                        Text(title)
                            .font(DS.Font.sidebarTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    MixedHostsLine(tab: tab)
                        .padding(.leading, ProgramMark.rowSlot + DS.Space.row)
                }
                Spacer(minLength: DS.Space.xs)
                if CommandKeyState.shared.held, let shortcut = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(shortcut)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .transition(.opacity)
                }
            }
            .sidebarRow(selected: isActive)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                draft = tab.title ?? ""
                renaming = true
            }
            Button("Close Tab", systemImage: "xmark", role: .destructive) { model.closeMixedTab(tab.id) }
        }
        .alert("Rename Tab", isPresented: $renaming) {
            TextField("Title", text: $draft)
            Button("Rename") { model.composites.apply(.rename(tab.id, draft), to: tab.id) }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.isEditorOnly
            ? "\(title), VS Code on \(tab.hosts.map(model.groupName).joined(separator: " and "))"
            : tab.isBrowserOnly ? "\(title), browser"
            : "\(title), mixed: \(tab.hosts.map(model.groupName).joined(separator: " and "))")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tab-row-\(number)")
    }
}

/// A mixed tab in the tab strip (sidebar hidden): its title over its hosts.
struct MixedTabChip: View {
    let tab: CompositeTab
    let isActive: Bool
    @Environment(WindowModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        let ref = WindowModel.mixedRef(tab.id)
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: DS.Radius.tabPill)
                    .fill(DS.Palette.selectedFill)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.tabPill).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
                    .padding(.vertical, 3)
            } else if isHovered {
                RoundedRectangle(cornerRadius: DS.Radius.tabPill)
                    .fill(DS.Palette.hoverFill)
                    .padding(.vertical, 3)
            }
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.xs) {
                    if tab.isEditorOnly {
                        ProgramMark(.vscode, size: 12)
                    } else if tab.isBrowserOnly {
                        ProgramMark(.browser, size: 12)
                    }
                    Text(model.title(ofMixedTab: tab))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(tab.hosts.map(model.groupName).joined(separator: " + "))
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            .font(.callout.weight(isActive ? .medium : .regular))
            .foregroundStyle(isActive ? DS.Palette.text : DS.Palette.textSecondary)
            .padding(.horizontal, 40)
            HStack(spacing: 0) {
                Button("Close Tab", systemImage: "xmark") { model.closeMixedTab(tab.id) }
                    .help("Close Tab (⌘W)")
                    .font(.caption2.weight(.bold))
                    .frame(width: 22, height: 22)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(!isHovered)
                Spacer(minLength: 0)
                if let number = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(number)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .padding(.trailing, DS.Space.s)
                }
            }
            .padding(.leading, 3)
        }
        .frame(height: 34)
        .contentShape(.rect)
        .onTapGesture { model.focus(ref) }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close Tab", systemImage: "xmark", role: .destructive) { model.closeMixedTab(tab.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tabbar-\(ref)")
    }
}

// MARK: - Two Columns

/// Two tabs side by side, each column its own tab (View ▸ Two Columns; on by itself on a
/// foldable's open inner screen, one column each side of the fold). The columns stay put while
/// focus moves between them: the current tab's column is the one taking the keyboard, a tab
/// picked in the sidebar replaces it, and the other column keeps its tab.
struct TwoColumnsView: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        if let columns = model.columns {
            HStack(spacing: 0) {
                column(columns.left, isActive: model.currentColumnIsLeft)
                    .accessibilityIdentifier("column-left")
                Rectangle()
                    .fill(theme.splitDivider)
                    .frame(width: DS.Size.dividerVisible)
                column(columns.right, isActive: !model.currentColumnIsLeft)
                    .accessibilityIdentifier("column-right")
            }
            .background(theme.background, ignoresSafeAreaEdges: [])
        }
    }

    @ViewBuilder private func column(_ ref: TabRef?, isActive: Bool) -> some View {
        Group {
            if let ref {
                TabColumn(ref: ref, isActive: isActive)
                    .id(ref)
            } else {
                EmptyColumn()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// One column: a header naming the tab and its host, then the tab's panes. The column without
/// focus dims like an unfocused split (Ghostty's unfocused-split-opacity).
private struct TabColumn: View {
    let ref: TabRef
    let isActive: Bool
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.unfocusedSplitOpacity) private var unfocusedOpacity = TerminalPreferences.Default.unfocusedSplitOpacity

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(ref: ref, isActive: isActive)
            content
                .overlay {
                    if !isActive { UnfocusedDim(unfocusedSplitOpacity: unfocusedOpacity, fill: theme.background).allowsHitTesting(false) }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if ref.hostId == HostGroups.mixedId {
            MixedTabView(id: ref.tab, isActive: isActive)
        } else if let workspace = model.workspace(ofGroup: ref.hostId),
                  let tab = workspace.session.tabs.first(where: { $0.id == ref.tab })
        {
            let isSplit = tab.zoomed == nil && tab.root.panes.count > 1
            SplitTreeView(
                node: tab.zoomed.map(Node.leaf) ?? tab.root,
                tree: HostTabTree(workspace: workspace, tab: tab.id, model: model, isActive: isActive), isSplit: isSplit)
                .connectionOverlay(
                    model.connectionState(ofGroup: ref.hostId), hostName: model.groupName(ref.hostId),
                    onRetry: { model.hosts.retry(ref.hostId) }, onDisconnect: { model.closeHost(ref.hostId) })
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    if isActive, !model.isPresentation, model.terminalArea != size { model.terminalArea = size }
                }
        } else {
            theme.background
        }
    }
}

/// A column's title strip: the tab's mark and name, and its host; tap to work in that column.
private struct ColumnHeader: View {
    let ref: TabRef
    let isActive: Bool
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        let (title, host, program) = describe()
        HStack(spacing: DS.Space.row) {
            ProgramMark(program, size: 12)
                .foregroundStyle(isActive ? DS.Palette.text : DS.Palette.textSecondary)
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? DS.Palette.text : DS.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let host {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: 26)
        .background(theme.background, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(theme.splitDivider).frame(height: 1) }
        .contentShape(.rect)
        .onTapGesture { if !isActive { model.focus(ref) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func describe() -> (String, String?, ProgramIdentity) {
        if ref.hostId == HostGroups.mixedId, let tab = model.composites.tab(ref.tab) {
            return (model.title(ofMixedTab: tab), tab.hosts.map(model.groupName).joined(separator: " + "), model.programIdentity(ofMixedTab: tab))
        }
        guard let workspace = model.workspace(ofGroup: ref.hostId),
              let tab = workspace.session.tabs.first(where: { $0.id == ref.tab })
        else { return ("", nil, .shell) }
        let multiHost = model.groups.groups.count > 1
        return (workspace.title(of: tab), multiHost ? model.groupName(ref.hostId) : nil, model.programIdentity(of: tab, onGroup: ref.hostId))
    }
}

/// The second column before there is a second tab: pick one in the sidebar, or open one here.
private struct EmptyColumn: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "rectangle.righthalf.inset.filled")
                .font(.title)
                .imageScale(.large)
                .foregroundStyle(DS.Palette.textTertiary)
            Text("Choose a tab for this column, or open a new one.")
                .font(.callout)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Button("New Tab", systemImage: "plus") { model.newTabInOtherColumn() }
                .help("New Tab in This Column")
                .buttonStyle(.glass)
                .accessibilityIdentifier("column-new-tab")
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background, ignoresSafeAreaEdges: [])
    }
}
