import DesignSystem
import PaneLayout
import SwiftUI

/// Renders a split tree recursively: leaves are panes, splits are two subtrees around a draggable
/// divider. Compact (default) is Ghostty's look: flush panes, a 1 pt divider in the background
struct SplitTreeView: View {
    let node: Node
    let workspace: Workspace
    /// More than one pane is visible: dim unfocused panes and show pane headers.
    let isSplit: Bool

    var body: some View {
        switch node {
        case .leaf(let id):
            PaneSlot(id: id, workspace: workspace, isSplit: isSplit)
        case .split(let axis, let ratio, let first, let second):
            SplitContainer(axis: axis, ratio: ratio, first: first, second: second, workspace: workspace)
        }
    }
}

private struct SplitContainer: View {
    let axis: Axis
    let ratio: Double
    let first: Node
    let second: Node
    let workspace: Workspace

    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    /// Drag translation already applied, so each change sends only the new delta.
    @State private var appliedTranslation: CGFloat?

    private var gap: CGFloat { paneStyle == .comfortable ? DS.Space.xs + 2 : DS.Size.dividerVisible }

    var body: some View {
        GeometryReader { geometry in
            let extent = axis == .horizontal ? geometry.size.width : geometry.size.height
            // Whole cells per pane; in a vertical split each side also carries its pane header.
            let header: CGFloat = axis == .vertical ? PaneHeader.height : 0
            let firstLength = header + SplitSnapping.firstLength(
                available: extent - gap - 2 * header, ratio: ratio,
                cell: workspace.cellSize.map { axis == .horizontal ? $0.width : $0.height },
                padding: workspace.appearance.padding)
            if axis == .horizontal {
                HStack(spacing: 0) {
                    SplitTreeView(node: first, workspace: workspace, isSplit: true).frame(width: firstLength)
                    divider(extent: extent)
                    SplitTreeView(node: second, workspace: workspace, isSplit: true)
                }
            } else {
                VStack(spacing: 0) {
                    SplitTreeView(node: first, workspace: workspace, isSplit: true).frame(height: firstLength)
                    divider(extent: extent)
                    SplitTreeView(node: second, workspace: workspace, isSplit: true)
                }
            }
        }
    }

    /// Ghostty SplitView.Divider: a visible line plus an invisible hit area, the resize pointer,
    /// double-click to equalize, and an adjustable accessibility element.
    private func divider(extent: CGFloat) -> some View {
        let horizontal = axis == .horizontal
        #if os(macOS)
        let hit = DS.Size.dividerVisible + DS.Size.dividerHitPointer
        #else
        let hit = DS.Size.dividerHitTouch
        #endif
        return Rectangle()
            .fill(paneStyle == .comfortable ? Color.clear : theme.splitDivider)
            .frame(width: horizontal ? gap : nil, height: horizontal ? nil : gap)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? hit : nil, height: horizontal ? nil : hit)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    #else
                    .hoverEffect(.highlight)
                    #endif
                    .gesture(drag(extent: extent))
                    .onTapGesture(count: 2) { equalize() }
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel(horizontal ? "Horizontal split divider" : "Vertical split divider")
            .accessibilityHint(horizontal ? "Drag to resize the left and right panes" : "Drag to resize the top and bottom panes")
            .accessibilityValue("\(Int((ratio * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                move(by: direction == .increment ? 0.025 : -0.025)
            }
    }

    /// Moves the divider by resizing the pane on its leading side towards it, which `resize`
    /// resolves to exactly this split.
    private func drag(extent: CGFloat) -> some Gesture {
        // Global space: the divider moves under the finger, so local translations would undercount.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let translation = axis == .horizontal ? value.translation.width : value.translation.height
                let delta = translation - (appliedTranslation ?? 0)
                appliedTranslation = translation
                move(by: delta / max(extent, 1))
            }
            .onEnded { _ in appliedTranslation = nil }
    }

    private func move(by amount: Double) {
        let pane = first.trailingPane(along: axis)
        workspace.apply(.resize(pane, axis == .horizontal ? .right : .down, amount: amount))
    }

    private func equalize() {
        withAnimation(DS.Motion.snappy) { move(by: 0.5 - ratio) }
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

/// One pane in the tree: its header in splits, the terminal (or why it failed to start), and
/// Ghostty's surface overlays.
struct PaneSlot: View {
    let id: PaneId
    let workspace: Workspace
    let isSplit: Bool

    @Environment(\.terminalTheme) private var theme
    @Environment(WindowModel.self) private var model
    @AppStorage(TerminalPreferences.Key.unfocusedSplitOpacity) private var unfocusedOpacity = TerminalPreferences.Default.unfocusedSplitOpacity
    @AppStorage(TerminalPreferences.Key.resizeOverlay) private var resizeOverlay = TerminalPreferences.ResizeOverlay.afterFirst
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    var body: some View {
        let focused = workspace.focusedPane == id
        let notice = workspace.notices[id] ?? PaneNotice()
        VStack(spacing: 0) {
            if isSplit {
                PaneHeader(id: id, workspace: workspace, isFocused: focused)
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
                if model.isSearchShown && focused {
                    TerminalSearchBar(
                        needle: Bindable(model).searchNeedle,
                        // Totals over the whole scrollback from the daemon's search; stepping
                        // through matches needs the renderer's highlights (not wired yet).
                        selected: model.searchNeedle.isEmpty || !LaunchOptions.mock ? nil : 2,
                        total: model.searchNeedle.isEmpty ? nil : model.searchTotal,
                        onNext: {}, onPrevious: {},
                        onClose: { model.isSearchShown = false })
                }
            }
        }
        .overlay {
            // Ghostty unfocused-split-opacity: the background color at 1 - opacity, header included.
            if isSplit && !focused {
                UnfocusedDim(unfocusedSplitOpacity: unfocusedOpacity, fill: theme.background)
            }
        }
        .background(theme.background, ignoresSafeAreaEdges: [])
        .clipShape(.rect(cornerRadius: paneStyle == .comfortable && isSplit ? DS.Radius.pane : 0))
    }

    @ViewBuilder private var content: some View {
        if let pane = workspace.panes[id] {
            // One host per pane: without the id, switching between two single-pane tabs reuses
            // the representable (same structural identity), so its container keeps showing,
            // and its first responder keeps typing into, the previous tab's pane.
            TerminalHost(pane: pane, isFocused: workspace.focusedPane == id, workspace: workspace)
                .id(id)
                .overlay { StalePaneOverlay(connection: pane.connection, paneId: id) }
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
    static let height: CGFloat = 24

    let id: PaneId
    let workspace: Workspace
    let isFocused: Bool

    @Environment(\.terminalTheme) private var theme
    @Environment(WindowModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        let state = model.paneStatus.state(of: id.description)
        HStack(spacing: DS.Space.xs + 2) {
            if let state {
                StatusIndicator(state, size: 10)
            }
            Text(model.paneStatus.program(of: id.description) ?? workspace.programName(of: id))
                .font(.caption.weight(isFocused ? .semibold : .regular))
                .foregroundStyle(theme.foreground.opacity(isFocused ? 0.9 : 0.6))
                .lineLimit(1)
            if let state, state != .idle {
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(state.color)
            }
            Spacer(minLength: 0)
            PanePresence(workspace: workspace, pane: id)
            Menu {
                PaneMenuItems(workspace: workspace, model: model, pane: id)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.foreground.opacity(0.7))
                    .frame(width: 24, height: 20)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isFocused || isHovered ? 1 : 0)
            .accessibilityLabel("Pane Menu")
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.xxs)
        .frame(height: Self.height)
        .background(theme.background, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.splitDivider).frame(height: 1)
        }
        .contentShape(.rect)
        .onTapGesture { workspace.apply(.focus(id)) }
        .onHover { isHovered = $0 }
    }
}

/// Split / zoom / search / close for one pane, shared by the pane header and the toolbar.
struct PaneMenuItems: View {
    let workspace: Workspace
    let model: WindowModel
    var pane: PaneId?

    var body: some View {
        Button("Split Right", systemImage: "rectangle.split.2x1") { focusThen { workspace.split(.horizontal) } }
        Button("Split Down", systemImage: "rectangle.split.1x2") { focusThen { workspace.split(.vertical) } }
        // One title for both directions, like Ghostty's "Zoom Split" toggle.
        Button("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right") {
            focusThen { workspace.apply(.toggleZoom) }
        }
        Divider()
        Button("Find…", systemImage: "magnifyingglass") { focusThen { model.isSearchShown = true } }
        Button("Links & Paths…", systemImage: "link") { focusThen { model.sheet = .links } }
        Button("Share Session…", systemImage: "person.crop.circle.badge.plus") { model.sheet = .invite }
        Divider()
        Button("Close Pane", systemImage: "xmark", role: .destructive) { focusThen { workspace.closeFocusedPane() } }
    }

    private func focusThen(_ action: () -> Void) {
        if let pane, workspace.focusedPane != pane { workspace.apply(.focus(pane)) }
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
