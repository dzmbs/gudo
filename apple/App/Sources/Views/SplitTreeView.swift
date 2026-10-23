import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// What a split tree's leaves show and how the tree changes: one host's tab (`HostTabTree`), or
/// a mixed tab whose leaves are panes on several hosts (`MixedTabTree`). A leaf resolves to the
/// workspace of its pane's host, so one tree can hold panes that stream from different hosts.
@MainActor
protocol PaneTree {
    /// The workspace and pane a leaf shows (nil while its host is not open in this window).
    func resolve(_ leaf: PaneId) -> (workspace: Workspace, pane: PaneId)?
    /// The leaf that takes the keyboard; nil when none of this tree's does (the other column).
    var focusedLeaf: PaneId? { get }
    func focus(leaf: PaneId)
    func resize(leaf: PaneId, _ direction: Direction, amount: Double)
    /// One terminal cell, for snapping split sizes to whole cells.
    var cellSize: CGSize? { get }
    var padding: CGFloat { get }
    /// The tree mixes hosts: each pane header names its host.
    var namesHosts: Bool { get }
    /// The VS Code editor a leaf shows, when it is an editor leaf (§20).
    func editor(_ leaf: PaneId) -> EditorMember?
    /// The page a leaf shows, when it is a browser leaf.
    func browser(_ leaf: PaneId) -> BrowserMember?
    /// The tool a leaf shows, when it is a tool leaf.
    func tool(_ leaf: PaneId) -> ToolMember?
}

extension PaneTree {
    func editor(_ leaf: PaneId) -> EditorMember? { nil }
    func browser(_ leaf: PaneId) -> BrowserMember? { nil }
    func tool(_ leaf: PaneId) -> ToolMember? { nil }
}

/// A host's tab: the window's active one, or (Two Columns) another tab of the same window.
struct HostTabTree: PaneTree {
    let workspace: Workspace
    /// The tab (nil: the window's active tab on this host).
    var tab: TabId?
    /// Focusing a pane goes through the window, so a pane on another host than the one on screen
    /// brings its host and tab forward (nil: within the workspace only).
    var model: WindowModel?
    /// Whether this tree holds the window's focus (false: the other column).
    var isActive = true

    func resolve(_ leaf: PaneId) -> (workspace: Workspace, pane: PaneId)? { (workspace, leaf) }

    var focusedLeaf: PaneId? {
        guard isActive else { return nil }
        guard let tab else { return workspace.focusedPane }
        return workspace.session.tabs.first { $0.id == tab }?.focused
    }

    func focus(leaf: PaneId) {
        if let model { model.focus(pane: leaf, onGroup: workspace.groupId) } else { workspace.apply(.focus(leaf)) }
    }

    func resize(leaf: PaneId, _ direction: Direction, amount: Double) {
        workspace.apply(.resize(leaf, direction, amount: amount))
    }

    var cellSize: CGSize? { workspace.cellSize }
    var padding: CGFloat { workspace.appearance.padding }
    var namesHosts: Bool { false }
}

/// Renders a split tree as one flat stack of panes keyed by pane id, each placed at the frame the
/// tree gives it, with the dividers on top. Flat, so a pane keeps its view (terminal, header,
/// program mark) when the tree changes shape around it: a split, a close or a zoom only moves and
/// resizes it, with one spring, while the new pane fades in where it lands. Compact (default) is
/// Ghostty's look: flush panes, a 1 pt divider in the background darkened 40 %, unfocused panes
struct SplitTreeView: View {
    let node: Node
    let tree: any PaneTree
    /// More than one pane is visible: dim unfocused panes and show pane headers.
    let isSplit: Bool
    /// Animate changes of shape (off where the tree swaps to another pane, the iPhone's one pane).
    var animated = true

    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    init(node: Node, tree: any PaneTree, isSplit: Bool, animated: Bool = true) {
        self.node = node
        self.tree = tree
        self.isSplit = isSplit
        self.animated = animated
    }

    /// A host's active tab.
    init(node: Node, workspace: Workspace, isSplit: Bool, animated: Bool = true) {
        self.init(node: node, tree: HostTabTree(workspace: workspace), isSplit: isSplit, animated: animated)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = SplitLayout(
                node: node, size: geometry.size,
                gap: paneStyle == .comfortable ? DS.Space.row : DS.Size.dividerVisible,
                header: PaneHeader.height, cell: tree.cellSize, padding: tree.padding)
            ZStack(alignment: .topLeading) {
                ForEach(layout.leaves, id: \.pane) { leaf in
                    PaneLeaf(leaf: leaf.pane, tree: tree, isSplit: isSplit)
                        .frame(width: leaf.frame.width, height: leaf.frame.height)
                        .offset(x: leaf.frame.minX, y: leaf.frame.minY)
                        .transition(.opacity)
                }
                ForEach(layout.dividers, id: \.id) { divider in
                    SplitDivider(divider: divider, tree: tree)
                        .frame(width: divider.frame.width, height: divider.frame.height)
                        .offset(x: divider.frame.minX, y: divider.frame.minY)
                        // A new divider lands where the panes are heading: it shows as they arrive.
                        .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.12).delay(0.16)), removal: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // Only shape changes animate: a divider drag must track the pointer frame for frame.
        .animation(animated ? DS.Motion.split : nil, value: SplitShape(node))
    }
}

/// A tree without its ratios: what changes when panes split, close, move or zoom.
private struct SplitShape: Hashable {
    let node: Node

    init(_ node: Node) {
        self.node = Self.strip(node)
    }

    private static func strip(_ node: Node) -> Node {
        switch node {
        case .leaf: node
        case .split(let axis, _, let first, let second): .split(axis: axis, ratio: 0, first: strip(first), second: strip(second))
        }
    }
}

/// Where each pane and divider of a tree goes in a given size.
struct SplitLayout {
    struct Leaf {
        let pane: PaneId
        let frame: CGRect
    }

    struct Divider {
        /// The split's leading pane along its axis: each pane edge borders at most one divider,
        /// so this stays the same while the tree changes elsewhere.
        let id: String
        let axis: PaneLayout.Axis
        let ratio: Double
        let first: Node
        /// The visible line.
        let frame: CGRect
        /// The split's length along its axis, for turning drags into ratios.
        let extent: CGFloat
    }

    private(set) var leaves: [Leaf] = []
    private(set) var dividers: [Divider] = []

    init(node: Node, size: CGSize, gap: CGFloat, header: CGFloat, cell: CGSize?, padding: CGFloat) {
        place(node, in: CGRect(origin: .zero, size: size), gap: gap, header: header, cell: cell, padding: padding)
    }

    private mutating func place(_ node: Node, in rect: CGRect, gap: CGFloat, header: CGFloat, cell: CGSize?, padding: CGFloat) {
        switch node {
        case .leaf(let pane):
            leaves.append(Leaf(pane: pane, frame: rect))
        case .split(let axis, let ratio, let first, let second):
            let horizontal = axis == .horizontal
            let extent = horizontal ? rect.width : rect.height
            // Whole cells per pane; in a vertical split each side also carries its pane header.
            let headers: CGFloat = horizontal ? 0 : header
            let firstLength = headers + SplitSnapping.firstLength(
                available: extent - gap - 2 * headers, ratio: ratio,
                cell: cell.map { horizontal ? $0.width : $0.height }, padding: padding)
            let firstRect, line, secondRect: CGRect
            if horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
                line = CGRect(x: firstRect.maxX, y: rect.minY, width: gap, height: rect.height)
                secondRect = CGRect(x: line.maxX, y: rect.minY, width: max(0, rect.maxX - line.maxX), height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
                line = CGRect(x: rect.minX, y: firstRect.maxY, width: rect.width, height: gap)
                secondRect = CGRect(x: rect.minX, y: line.maxY, width: rect.width, height: max(0, rect.maxY - line.maxY))
            }
            place(first, in: firstRect, gap: gap, header: header, cell: cell, padding: padding)
            place(second, in: secondRect, gap: gap, header: header, cell: cell, padding: padding)
            dividers.append(Divider(
                id: "\(axis.rawValue)-\(first.trailingPane(along: axis))", axis: axis, ratio: ratio,
                first: first, frame: line, extent: extent))
        }
    }
}

/// Ghostty SplitView.Divider: a visible line plus an invisible hit area, the resize pointer,
/// double-click to equalize, and an adjustable accessibility element.
private struct SplitDivider: View {
    let divider: SplitLayout.Divider
    let tree: any PaneTree

    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    /// Drag translation already applied, so each change sends only the new delta.
    @State private var appliedTranslation: CGFloat?

    var body: some View {
        let horizontal = divider.axis == .horizontal
        #if os(macOS)
        let hit = DS.Size.dividerVisible + DS.Size.dividerHitPointer
        #else
        let hit = DS.Size.dividerHitTouch
        #endif
        Rectangle()
            .fill(paneStyle == .comfortable ? Color.clear : theme.splitDivider)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? hit : nil, height: horizontal ? nil : hit)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    #else
                    .hoverEffect(.highlight)
                    #endif
                    .gesture(drag)
                    .onTapGesture(count: 2) { equalize() }
            }
            .accessibilityElement()
            .accessibilityLabel(horizontal ? "Horizontal split divider" : "Vertical split divider")
            .accessibilityHint(horizontal ? "Drag to resize the left and right panes" : "Drag to resize the top and bottom panes")
            .accessibilityValue("\(Int((divider.ratio * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                move(by: direction == .increment ? 0.025 : -0.025)
            }
    }

    /// Moves the divider by resizing the pane on its leading side towards it, which `resize`
    /// resolves to exactly this split.
    private var drag: some Gesture {
        // Global space: the divider moves under the finger, so local translations would undercount.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let translation = divider.axis == .horizontal ? value.translation.width : value.translation.height
                let delta = translation - (appliedTranslation ?? 0)
                appliedTranslation = translation
                move(by: delta / max(divider.extent, 1))
            }
            .onEnded { _ in appliedTranslation = nil }
    }

    private func move(by amount: Double) {
        let pane = divider.first.trailingPane(along: divider.axis)
        tree.resize(leaf: pane, divider.axis == .horizontal ? .right : .down, amount: amount)
    }

    private func equalize() {
        withAnimation(DS.Motion.snappy) { move(by: 0.5 - divider.ratio) }
    }
}

/// Sizes the leading side of a split to a whole number of terminal cells plus the pane padding,
/// so it shows no partial cell; the trailing side takes the rest (its remainder becomes padding).
enum SplitSnapping {
    static func firstLength(available: CGFloat, ratio: Double, cell: CGFloat?, padding: CGFloat) -> CGFloat {
        let raw = (available * ratio).rounded()
        guard let cell, cell > 0 else { return raw }
        let minimum = 2 * padding + cell
        guard available >= 2 * minimum else { return raw }
        let snapped = 2 * padding + ((raw - 2 * padding) / cell).rounded() * cell
        return min(max(snapped, minimum), available - minimum)
    }
}

/// A leaf of a tree: the pane it resolves to on its host, or the terminal background while that
/// host is not open here.
private struct PaneLeaf: View {
    let leaf: PaneId
    let tree: any PaneTree
    let isSplit: Bool
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        if let editor = tree.editor(leaf) {
            EditorLeafView(member: editor, isSplit: isSplit, isFocused: tree.focusedLeaf == leaf, focus: { tree.focus(leaf: leaf) })
        } else if let browser = tree.browser(leaf) {
            BrowserLeafView(member: browser, isFocused: tree.focusedLeaf == leaf, focus: { tree.focus(leaf: leaf) })
        } else if let tool = tree.tool(leaf) {
            ToolLeafView(member: tool, isSplit: isSplit, isFocused: tree.focusedLeaf == leaf, focus: { tree.focus(leaf: leaf) })
        } else if let (workspace, pane) = tree.resolve(leaf) {
            PaneSlot(
                id: pane, workspace: workspace, isSplit: isSplit, isFocused: tree.focusedLeaf == leaf,
                namesHost: tree.namesHosts, focus: { tree.focus(leaf: leaf) })
        } else {
            theme.background
        }
    }
}

/// One pane in the tree: its header in splits, the terminal (or why it failed to start), and
/// Ghostty's surface overlays.
struct PaneSlot: View {
    let id: PaneId
    let workspace: Workspace
    let isSplit: Bool
    /// The pane takes the keyboard (the tree's focused leaf).
    let isFocused: Bool
    /// In a mixed tab: the header names the pane's host, and the pane dims on its own while its
    /// host's link is down (the others stay live).
    var namesHost = false
    let focus: () -> Void

    @Environment(\.terminalTheme) private var theme
    @Environment(WindowModel.self) private var model
    @AppStorage(TerminalPreferences.Key.unfocusedSplitOpacity) private var unfocusedOpacity = TerminalPreferences.Default.unfocusedSplitOpacity
    @AppStorage(TerminalPreferences.Key.resizeOverlay) private var resizeOverlay = TerminalPreferences.ResizeOverlay.afterFirst
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    var body: some View {
        let focused = isFocused
        let notice = workspace.notices[id] ?? PaneNotice()
        VStack(spacing: 0) {
            if isSplit {
                PaneHeader(id: id, workspace: workspace, isFocused: focused, namesHost: namesHost, focus: focus)
            }
            ZStack {
                content
                ResizeOverlay(size: workspace.grids[id], mode: resizeOverlay) { [workspace] in
                    ContinuousClock.now < workspace.keyboardResizeUntil
                }
                .onChange(of: workspace.grids[id]) { old, new in
                    // UI tests count the overlays a grid change shows (`-windowProbe`).
                    guard WindowProbe.isEnabled, old != nil, new != old, ContinuousClock.now >= workspace.keyboardResizeUntil else { return }
                    model.resizeOverlayShows += 1
                }
                if let url = notice.hoveredURL {
                    URLHoverBanner(url: url)
                }
                if let exit = notice.exit {
                    ProcessExitedBar(exit.message, failed: exit.failed)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                if notice.secureInput && focused {
                    SecureInputBadge()
                }
                BellBorder(ringing: notice.bell)
                MultiplayerPaneOverlay(workspace: workspace, pane: id, isFocused: focused)
                AskpassPaneOverlay(workspace: workspace, pane: id)
                if model.isSearchShown && focused {
                    PaneSearchBar(model: model, pane: workspace.panes[id])
                }
            }
            .hostLinkOverlay(groupId: workspace.groupId, enabled: namesHost)
        }
        .overlay {
            // Ghostty unfocused-split-opacity: the background color at 1 - opacity, header included.
            if isSplit && !focused {
                UnfocusedDim(unfocusedSplitOpacity: unfocusedOpacity, fill: theme.background)
            }
        }
        .background(theme.background, ignoresSafeAreaEdges: [])
        .clipShape(.rect(cornerRadius: paneStyle == .comfortable && isSplit ? DS.Radius.pane : 0))
        // Header, banners and bars sit on the terminal: its colours, even in a window kept apart.
        .terminalSurfaceChrome()
        // A mixed tab's panes stay with it: tabs merge into host tabs only.
        .tabDropTarget(pane: id, workspace: workspace, enabled: !namesHost)
    }

    @ViewBuilder private var content: some View {
        if let pane = workspace.panes[id] {
            // One host per pane: without the id, switching between two single-pane tabs reuses
            // the representable (same structural identity), so its container keeps showing,
            // and its first responder keeps typing into, the previous tab's pane.
            TerminalHost(pane: pane, isFocused: isFocused, workspace: workspace)
                // Per host and pane: pane ids repeat across hosts.
                .id(HostPane(hostId: workspace.groupId, pane: id))
                .overlay {
                    StalePaneOverlay(
                        connection: pane.connection, paneId: id,
                        hostIsLive: namesHost ? model.connectionState(ofGroup: workspace.groupId).isLive : nil)
                }
        } else if let failure = workspace.failures[id] {
            EmptyState("Pane Failed to Start", systemImage: "exclamationmark.triangle", message: failure) {
                Button("Close Pane") { workspace.apply(.close(id)) }
            }
            .foregroundStyle(theme.foreground)
        } else {
            theme.background
        }
    }
}

/// It sits on the terminal background so the pane still reads as one surface.
private struct PaneHeader: View {
    /// The pane menu's opacity on an unfocused, unhovered header: hidden on the Mac (hover shows
    /// it), quiet on touch, where there is no hover.
    #if os(macOS)
    static let restingMenuOpacity = 0.0
    #else
    static let restingMenuOpacity = DS.Opacity.mutedGlyph
    #endif
    static let height: CGFloat = 24

    let id: PaneId
    let workspace: Workspace
    let isFocused: Bool
    /// A mixed tab: name the pane's host after its program.
    var namesHost = false
    let focus: () -> Void

    @Environment(\.terminalTheme) private var theme
    @Environment(WindowModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        let state = model.paneStatus.state(of: id.description)
        let program = model.programIdentity(ofPane: id, onGroup: workspace.groupId)
        HStack(spacing: DS.Space.row) {
            ProgramMark(program, size: 12)
                .foregroundStyle(isFocused ? DS.Palette.text : DS.Palette.textSecondary)
            // Shells keep their own word ("zsh", "canvas"); programs their display name.
            Text(program.isShell ? workspace.programName(of: id) : program.displayName)
                .font(.caption.weight(isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? DS.Palette.text : DS.Palette.textSecondary)
                .lineLimit(1)
            if namesHost, let group = model.groups.group(workspace.groupId) {
                HostChip(group: group, emphasized: isFocused)
            }
            if let state, state != .idle {
                StatusIndicator(state, size: 10)
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(state.color)
            }
            Spacer(minLength: 0)
            PanePresence(workspace: workspace, pane: id)
            Menu {
                PaneMenuItems(workspace: workspace, model: model, pane: id, focusPane: focus)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: 24, height: 20)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isFocused || isHovered ? 1 : Self.restingMenuOpacity)
            .help("Pane Menu: split, zoom, find, share, close")
            .accessibilityLabel("Pane Menu")
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.xxs)
        // A fixed 24 pt band over the grid: its caption text grows only so far.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .frame(height: Self.height)
        .background(theme.background, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.splitDivider).frame(height: 1)
        }
        .contentShape(.rect)
        .onTapGesture { focus() }
        .onHover { isHovered = $0 }
    }
}

/// Split / zoom / search / close for one pane, shared by the pane header and the toolbar.
struct PaneMenuItems: View {
    let workspace: Workspace
    let model: WindowModel
    var pane: PaneId?
    /// Focuses `pane` the way its tree does (a mixed tab's leaf, the other column's tab).
    var focusPane: (() -> Void)?

    var body: some View {
        // Through the window's actions, so a mixed tab splits and closes on the pane's own host.
        Button("Split Right", systemImage: "rectangle.split.2x1") { focusThen { WorkspaceAction.splitRight.perform(on: workspace, window: model) } }
        Button("Split Down", systemImage: "rectangle.split.1x2") { focusThen { WorkspaceAction.splitDown.perform(on: workspace, window: model) } }
        Button("Split with Host…", systemImage: "rectangle.split.2x1.fill") {
            focusThen { WorkspaceAction.splitWithHost.perform(on: workspace, window: model) }
        }
        .disabled(!model.canSplitWithHost)
        // One title for both directions, like Ghostty's "Zoom Split" toggle.
        Button("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right") {
            focusThen { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) }
        }
        moveItems
        Divider()
        Button("Find…", systemImage: "magnifyingglass") { focusThen { model.isSearchShown = true } }
        Button("Links & Paths…", systemImage: "link") { focusThen { model.sheet = .links } }
        Button("Share Session…", systemImage: "person.crop.circle.badge.plus") { model.sheet = .invite }
        Divider()
        Button("Close Pane", systemImage: "xmark", role: .destructive) {
            focusThen { WorkspaceAction.closePane.perform(on: workspace, window: model) }
        }
    }

    /// Move to New Tab, and into another tab of the pane's host (not from a mixed tab, whose
    /// panes stay with it).
    @ViewBuilder private var moveItems: some View {
        if let target = pane ?? workspace.focusedPane {
            let mixed = model.composites.tab(containing: HostPane(hostId: workspace.groupId, pane: target))
            Button("Move to New Tab", systemImage: "macwindow.badge.plus") {
                focusThen { WorkspaceAction.movePaneToNewTab.perform(on: workspace, window: model) }
            }
            .disabled(mixed.map { $0.leaves.count < 2 } ?? ((workspace.session.tab(containing: target)?.root.panes.count ?? 0) < 2))
            .accessibilityIdentifier("pane-move-new-tab")
            let tabs = mixed == nil ? model.moveTargets(in: workspace, besides: workspace.session.tab(containing: target)?.id) : []
            if !tabs.isEmpty {
                Menu("Move to Tab", systemImage: "arrow.right.square") {
                    ForEach(tabs) { tab in
                        Button(workspace.title(of: tab)) { model.movePane(target, in: workspace, toTab: tab) }
                    }
                }
                .accessibilityIdentifier("pane-move-to-tab")
            }
        }
    }

    private func focusThen(_ action: () -> Void) {
        if pane != nil, let focusPane {
            focusPane()
        } else if let pane, workspace.focusedPane != pane {
            workspace.apply(.focus(pane))
        }
        action()
    }
}

extension Node {
    /// The pane touching this subtree's trailing edge along `axis` (right edge for horizontal).
    func trailingPane(along axis: Axis) -> PaneId {
        switch self {
        case .leaf(let pane): pane
        case .split(let splitAxis, _, let first, let second):
            splitAxis == axis ? second.trailingPane(along: axis) : first.trailingPane(along: axis)
        }
    }
}
