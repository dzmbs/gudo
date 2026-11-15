import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import TerminalRenderer

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
    /// Sets the divider at `leaf`'s trailing edge along `axis` to `ratio`.
    func setRatio(leaf: PaneId, _ axis: PaneLayout.Axis, ratio: Double)
    /// One terminal cell, for snapping split sizes to whole cells.
    var cellSize: CGSize? { get }
    var padding: CGFloat { get }
    /// The tree mixes hosts: each pane header names its host.
    var namesHosts: Bool { get }
    /// The VS Code editor a leaf shows, when it is an editor leaf.
    func editor(_ leaf: PaneId) -> EditorMember?
    /// The page a leaf shows, when it is a browser leaf.
    func browser(_ leaf: PaneId) -> BrowserMember?
    /// The tool a leaf shows, when it is a tool leaf.
    func tool(_ leaf: PaneId) -> ToolMember?
    /// The host workspace whose panes this tree arranges by dragging (nil: a mixed tab, whose
    /// panes stay where they are).
    var arranges: Workspace? { get }
}

extension PaneTree {
    func editor(_ leaf: PaneId) -> EditorMember? { nil }
    func browser(_ leaf: PaneId) -> BrowserMember? { nil }
    func tool(_ leaf: PaneId) -> ToolMember? { nil }
    var arranges: Workspace? { nil }
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

    func setRatio(leaf: PaneId, _ axis: PaneLayout.Axis, ratio: Double) {
        workspace.apply(.setRatio(leaf, axis, ratio: ratio))
    }

    var cellSize: CGSize? { workspace.cellSize }
    var padding: CGFloat { workspace.appearance.padding }
    var namesHosts: Bool { false }
    var arranges: Workspace? { isActive ? workspace : nil }
}

/// The floating windows over a tab, as its canvas draws them.
struct FloatScene: Equatable {
    struct Window: Equatable {
        let window: FloatWindow
        /// The window's own layout (its subtree of its tab's tree).
        let root: Node
    }

    /// Back to front: the tab's own windows and the ones pinned over every tab.
    var windows: [Window] = []
    /// Out of sight for a moment (⌥⌘F): kept alive, drawn nowhere.
    var hidden = false

    static let none = FloatScene()

    /// The windows over the active tab of `workspace`.
    @MainActor
    init(workspace: Workspace, tab: Tab, hidden: Bool) {
        self.init(session: workspace.session, tab: tab, hidden: hidden)
    }

    /// The windows over `tab` of `session`.
    init(session: Session, tab: Tab, hidden: Bool) {
        let own = Set(session.windows(in: tab.id).map(\.id))
        windows = session.floats.compactMap { window in
            guard own.contains(window.id) || window.pinned, let root = session.root(of: window) else { return nil }
            return Window(window: window, root: root)
        }
        self.hidden = hidden
    }

    init() {}
}

/// Renders a tab as one flat stack of panes keyed by pane id: its tiled split tree, and the
/// floating windows over it, each pane placed at the frame the layout gives it. Flat, so a
/// pane keeps its view (terminal, header, program mark) whatever the layout does around it: a
/// split, a close, a zoom, or lifting out into a window and docking back only move and resize
/// it, in one spring with the panes making room, while the grids hold until it settles.
/// Compact (default) is Ghostty's look: flush panes, a 1 pt divider, unfocused panes dimmed.
/// Comfortable insets panes as rounded surfaces.
struct SplitTreeView: View {
    let node: Node
    let tree: any PaneTree
    /// More than one pane is visible: dim unfocused panes and show pane headers.
    let isSplit: Bool
    /// Animate changes of shape (off where the tree swaps to another pane, the iPhone's one pane).
    var animated = true
    var floats: FloatScene = .none
    /// The zoomed pane: it fills the tab (or, in a window of several panes, its window).
    var zoomed: PaneId?

    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact
    @Environment(\.displayScale) private var displayScale
    @Environment(\.terminalTheme) private var theme
    @State private var lastShape = ShapeMemo()
    @State private var lastLayout = LayoutMemo()
    @State private var ownArrangement = PaneArrangement()
    /// The zoomed pane once it has finished growing: the panes under it go out of sight.
    @State private var settledZoom: PaneId?
    @Environment(WindowModel.self) private var model

    /// The window's arrangement for the tree it arranges (so its keys and tests reach it); a
    /// tree that only shows panes keeps its own.
    private var arrangement: PaneArrangement { tree.arranges != nil ? model.arrangement : ownArrangement }

    init(node: Node, tree: any PaneTree, isSplit: Bool, animated: Bool = true, floats: FloatScene = .none, zoomed: PaneId? = nil) {
        self.node = node
        self.tree = tree
        self.isSplit = isSplit
        self.animated = animated
        self.floats = floats
        self.zoomed = zoomed
    }

    /// A host's active tab.
    init(node: Node, workspace: Workspace, isSplit: Bool, animated: Bool = true, floats: FloatScene = .none, zoomed: PaneId? = nil) {
        self.init(node: node, tree: HostTabTree(workspace: workspace), isSplit: isSplit, animated: animated, floats: floats, zoomed: zoomed)
    }

    var body: some View {
        let shape = CanvasShape(node: node, floats: floats, zoomed: zoomed)
        // Here rather than in `onChange`: the hold must start before the animation's first
        // frame resizes a terminal.
        let change = lastShape.update(shape)
        let settle = DS.Motion.structuralSettle * PaneArrangement.settleStretch
        if change != .none {
            if animated {
                TerminalSurface.holdGrids(for: .milliseconds(Int(settle * 1000)))
            }
            // The grids change with the layout, not by a resize the user makes: no cols × rows
            // overlay (a window tab's tree changes without `Workspace.apply`).
            for leaf in node.panes + floats.windows.flatMap(\.window.panes) {
                tree.resolve(leaf)?.workspace.layoutChangeUntil = .now + .milliseconds(700)
            }
        }
        let motion: Animation? = animated ? DS.Motion.structural : nil
        return GeometryReader { geometry in
            let target = CanvasLayout(
                node: node, floats: floats, zoomed: zoomed, focused: tree.focusedLeaf,
                size: geometry.size, gap: paneStyle == .comfortable ? DS.Space.row : DS.Size.hairline(scale: displayScale),
                header: PaneHeader.height, cell: tree.cellSize, padding: tree.padding, headers: isSplit, live: arrangement.live,
                zoomSettled: !animated || zoomed == settledZoom)
            // Before any terminal is told its new size: the stills are of the frames on screen.
            let _ = change != .none && animated ? beginMotion(from: lastLayout.layout, to: target, settle: settle) : ()
            let _ = arrangement.settledVersion
            let drawn = Self.drawn(target, motion: arrangement)
            let _ = arrangement.update(layout: drawn, tree: tree)
            // Every terminal is laid out once, at its new size: its grid changes once, now, and
            // its last frame stands in, under its still, until the motion settles.
            let _ = change != .none && animated ? arrangement.prepareTerminals(for: target, within: settle) : ()
            let _ = lastLayout.layout = target
            let shown = arrangement.preview ?? drawn
            let layout = arrangement.scrub.map { shown.blended(from: $0.from, progress: $0.progress) } ?? shown
            let seeds = arrangement.motion.seeds
            let dividerSeeds = arrangement.motion.dividerSeeds
            ZStack(alignment: .topLeading) {
                ForEach(layout.cards, id: \.id) { card in
                    FloatCardBackdrop(card: card)
                        .zIndex(card.z)
                }
                ForEach(layout.leaves, id: \.pane) { leaf in
                    leafContent(leaf)
                        .frame(width: leaf.frame.width, height: leaf.frame.height)
                        .surface(paneSurface(of: leaf), in: .rounded(paneRadius(of: leaf)))
                        .floatingChrome(leaf, dragging: arrangement.paneDrag?.pane == leaf.pane)
                        // Laid out once, at its new size: only where it is shown moves.
                        .transaction(value: leaf.frame.size) { $0.animation = nil }
                        .modifier(PaneTravel(
                            shown: leaf.shownFrame, frame: leaf.frame, still: arrangement.still(of: leaf.pane),
                            stillTop: leaf.header, background: theme.background, radius: paneRadius(of: leaf)))
                        // A pane zooming over its neighbours, or shrinking back onto them,
                        // keeps an edge against them on the way.
                        .shadow(.panel, visible: leaf.z == CanvasLayout.zoomZ && arrangement.isMoving) // style-exempt: a pane zooming over its neighbours, only while it moves
                        .liftBeat(floating: leaf.window != nil, anchor: Self.anchor(.center, of: leaf))
                        .scaleEffect(leaf.scale, anchor: Self.anchor(leaf.hiddenAnchor, of: leaf))
                        .animation(arrangement.scrub == nil ? Self.fade(of: leaf) : nil) {
                            $0.opacity(leaf.opacity)
                        }
                        .allowsHitTesting(leaf.visible)
                        .accessibilityHidden(!leaf.visible)
                        .zIndex(leaf.z)
                        .arrives(from: seeds[leaf.pane], into: leaf.frame)
                }
                ForEach(layout.dividers, id: \.id) { divider in
                    SplitDivider(divider: divider.divider, tree: tree)
                        .frame(width: divider.divider.frame.width, height: divider.divider.frame.height)
                        .transaction(value: divider.divider.frame.size) { $0.animation = nil }
                        .modifier(PaneTravel(shown: divider.shownFrame, frame: divider.divider.frame))
                        .opacity(divider.opacity)
                        .allowsHitTesting(divider.visible && !divider.departing)
                        .zIndex(divider.z)
                        // A new divider rides the edge it sits on from the first frame.
                        .arrives(from: dividerSeeds[divider.id], into: divider.divider.frame, fades: false)
                }
                if tree.arranges != nil {
                    ForEach(layout.cards.filter(\.visible), id: \.id) { card in
                        FloatCardHandles(card: card)
                            .zIndex(card.z + 3)
                    }
                    FloatTray(layout: layout)
                        .zIndex(CanvasLayout.trayZ)
                    ArrangementOverlay(layout: layout)
                        .zIndex(CanvasLayout.overlayZ)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(.named(PaneArrangement.space))
        }
        .environment(arrangement)
        // Only shape changes animate: a divider drag or a moving window must track the pointer
        // frame for frame.
        .animation(arrangement.scrub == nil ? motion : nil, value: shape)
        .task(id: zoomed) {
            if animated { try? await Task.sleep(for: .milliseconds(Int(DS.Motion.structuralSettle * PaneArrangement.settleStretch * 1000))) }
            guard !Task.isCancelled else { return }
            settledZoom = zoomed
        }
    }

    /// A leaf's content: its pane, or a closed pane's background while its still goes.
    @ViewBuilder private func leafContent(_ leaf: CanvasLayout.Leaf) -> some View {
        if leaf.departing {
            theme.background
                .overlay(alignment: .top) {
                    if leaf.header > 0, let header = arrangement.header(of: leaf.pane) {
                        PaneHeaderStill(still: header)
                    }
                }
        } else {
            PaneLeaf(leaf: leaf.pane, tree: tree, isSplit: isSplit || leaf.window != nil)
                .environment(\.paneTerminalHidden, arrangement.hidesTerminal(of: leaf.pane))
        }
    }

    /// How a leaf's opacity changes. Closed: it fades in the spring it is squeezed out in. Out of
    /// sight (under a zoomed pane, into the tray): solid while it shrinks, fading at the end.
    /// Coming back: solid at once, then it grows.
    static func fade(of leaf: CanvasLayout.Leaf) -> Animation {
        if leaf.departing { return DS.Motion.structural }
        return leaf.visible ? DS.Motion.micro : DS.Motion.micro.delay(DS.Motion.arrivalDelay)
    }

    /// `point` of `leaf`'s frame as a unit point of the box a leaf is laid out in: its frame's
    /// size at the canvas origin, drawn moved to where it is shown.
    static func anchor(_ point: UnitPoint, of leaf: CanvasLayout.Leaf) -> UnitPoint {
        let frame = leaf.frame
        return UnitPoint(
            x: (frame.minX + point.x * frame.width) / max(frame.width, 1),
            y: (frame.minY + point.y * frame.height) / max(frame.height, 1))
    }

    /// The layout as drawn while a motion runs: new panes under the panes making room, the one
    /// unzoomed over the panes it shrinks back onto, and what is leaving on its way out.
    static func drawn(_ target: CanvasLayout, motion arrangement: PaneArrangement) -> CanvasLayout {
        var drawn = target
        drawn.lower(Set(arrangement.motion.seeds.keys))
        drawn.raise(arrangement.raised)
        drawn.depart(arrangement.motion)
        return drawn
    }

    /// Starts the motion from `before` to `target`: stills of every pane it moves, taken from
    /// the frames on screen, and of every pane leaving.
    private func beginMotion(from before: CanvasLayout?, to target: CanvasLayout, settle: Double) {
        guard let before else { return }
        arrangement.begin(
            CanvasMotion(from: before, to: target), in: target, raising: lastShape.unzoomed, for: settle,
            image: { leaf in
                guard let (workspace, pane) = tree.resolve(leaf) else { return nil }
                return workspace.panes[pane]?.view.surface.snapshot()
            },
            departed: { leaf in tree.resolve(leaf)?.workspace.takeDepartedFrame(of: leaf) },
            holding: { [tree] leaf in
                guard let (workspace, pane) = tree.resolve(leaf) else { return false }
                return workspace.panes[pane]?.view.surface.isHoldingFrame ?? false
            })
    }

    private func paneRadius(of leaf: CanvasLayout.Leaf) -> CGFloat {
        paneStyle == .comfortable && (isSplit || leaf.window != nil) ? DS.Radius.pane : 0
    }
}

extension SplitTreeView {
    /// A comfortable pane in a split is a surface of its own; a compact one, a lone one and one in
    /// a floating window (whose window is the surface) are tiles.
    func paneSurface(of leaf: CanvasLayout.Leaf) -> Surface {
        paneStyle == .comfortable && isSplit && leaf.window == nil ? .pane : .tile
    }
}

/// The canvas's last layout (not state SwiftUI observes).
private final class LayoutMemo {
    var layout: CanvasLayout?
}

/// What a canvas last showed (not state SwiftUI observes), and which kind of change it was.
private final class ShapeMemo {
    enum Change { case none, split, float }
    private var shape: CanvasShape?
    private(set) var lastChange = Change.split
    /// The pane zoomed before the last change, on its way back into the tree.
    private(set) var unzoomed: PaneId?

    /// Records `shape`; a change, or a tree just shown (a tab turning into a window tab swaps
    /// the whole view, and its panes move with it).
    func update(_ shape: CanvasShape) -> Change {
        defer { self.shape = shape }
        guard let old = self.shape else { return .split }
        guard old != shape else { return .none }
        lastChange = old.windows != shape.windows || old.hidden != shape.hidden ? .float : .split
        unzoomed = old.zoomed != shape.zoomed ? old.zoomed : nil
        return lastChange
    }
}

/// A canvas without ratios and frames: what changes when panes split, close, move, zoom, float
/// or dock. Moving or resizing a window is not a change of shape (it follows the hand).
private struct CanvasShape: Hashable {
    struct Window: Hashable {
        let id: FloatId
        let root: SplitShape
        let minimized: Bool
    }

    let tiled: SplitShape
    let windows: [Window]
    let hidden: Bool
    let zoomed: PaneId?

    init(node: Node, floats: FloatScene, zoomed: PaneId?) {
        tiled = SplitShape(node)
        windows = floats.windows.map { Window(id: $0.window.id, root: SplitShape($0.root), minimized: $0.window.minimized) }
        hidden = floats.hidden
        self.zoomed = zoomed
    }
}

/// A tree without its ratios.
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
        /// The pane against the line on its trailing side.
        let next: PaneId
        /// The visible line.
        var frame: CGRect
        /// Where the split starts along its axis.
        let start: CGFloat
        /// The length the ratio divides: the split's, less the line and, across a vertical
        /// split, both panes' headers.
        let available: CGFloat
        /// The header length the first pane has over its share.
        let headers: CGFloat

        /// The ratio that puts the line's leading edge at `position` along the axis.
        func ratio(placingLineAt position: CGFloat) -> Double {
            Double((position - start - headers) / max(available, 1))
        }
    }

    private(set) var leaves: [Leaf] = []
    private(set) var dividers: [Divider] = []

    init(node: Node, size: CGSize, gap: CGFloat, header: CGFloat, cell: CGSize?, padding: CGFloat) {
        self.init(node: node, in: CGRect(origin: .zero, size: size), gap: gap, header: header, cell: cell, padding: padding)
    }

    init(node: Node, in rect: CGRect, gap: CGFloat, header: CGFloat, cell: CGSize?, padding: CGFloat) {
        place(node, in: rect, gap: gap, header: header, cell: cell, padding: padding)
    }

    private mutating func place(_ node: Node, in rect: CGRect, gap: CGFloat, header: CGFloat, cell: CGSize?, padding: CGFloat) {
        switch node {
        case .leaf(let pane):
            leaves.append(Leaf(pane: pane, frame: rect))
        case .split(let axis, let storedRatio, let first, let second):
            let ratio = Node.sanitizedRatio(storedRatio)
            let horizontal = axis == .horizontal
            let extent = horizontal ? rect.width : rect.height
            // Whole cells per pane; in a vertical split each side also carries its pane header.
            let headers: CGFloat = horizontal ? 0 : header
            let available = extent - gap - 2 * headers
            let firstLength = headers + SplitSnapping.firstLength(
                available: available, ratio: ratio,
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
                first: first, next: second.leadingPane(along: axis), frame: line, start: horizontal ? rect.minX : rect.minY, available: available, headers: headers))
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

    /// Where in the line the drag took hold of it, so the line keeps that spot under the pointer.
    @State private var grabOffset: CGFloat?

    var body: some View {
        let horizontal = divider.axis == .horizontal
        let hitThickness = ResizeZones.dividerThickness(gap: horizontal ? divider.frame.width : divider.frame.height)
        Rectangle()
            .fill(paneStyle == .comfortable ? Color.clear : theme.splitDivider)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? hitThickness : nil, height: horizontal ? nil : hitThickness)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    #else
                    // The pointer takes the line's shape, not the whole zone's.
                    .contentShape(.hoverEffect, DividerBar(along: divider.axis))
                    .hoverEffect(.highlight)
                    #endif
                    .gesture(drag)
                    .onTapGesture(count: 2) { equalize() }
            }
            .accessibilityElement()
            .accessibilityLabel(horizontal ? "Horizontal split divider" : "Vertical split divider")
            .accessibilityHint(horizontal ? "Drag to resize the left and right panes" : "Drag to resize the top and bottom panes")
            .accessibilityValue(divider.ratio.formatted(.percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                setRatio(divider.ratio + (direction == .increment ? 0.025 : -0.025))
            }
    }

    /// The line follows the pointer: each position becomes the ratio that puts it there, so
    /// nothing accumulates and a late answer from the host cannot leave it behind.
    private var drag: some Gesture {
        // The canvas's space: the divider moves under the pointer, its own space with it.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(PaneArrangement.space))
            .onChanged { value in
                let horizontal = divider.axis == .horizontal
                let pointer = horizontal ? value.location.x : value.location.y
                let grab = grabOffset ?? (horizontal ? value.startLocation.x - divider.frame.minX : value.startLocation.y - divider.frame.minY)
                grabOffset = grab
                setRatio(divider.ratio(placingLineAt: pointer - grab))
            }
            .onEnded { _ in grabOffset = nil }
    }

    private func setRatio(_ ratio: Double) {
        let ratio = min(max(ratio, Node.ratioRange.lowerBound), Node.ratioRange.upperBound)
        tree.setRatio(leaf: divider.first.trailingPane(along: divider.axis), divider.axis, ratio: ratio)
    }

    private func equalize() {
        withAnimation(DS.Motion.standard) { setRatio(0.5) }
    }
}

#if os(iOS)
/// A divider's line as the iPad pointer highlights it: a short-ended bar a few points wide.
nonisolated private struct DividerBar: Shape {
    let along: PaneLayout.Axis

    func path(in rect: CGRect) -> Path {
        let thickness: CGFloat = 6
        let bar = along == .horizontal
            ? CGRect(x: rect.midX - thickness / 2, y: rect.minY, width: thickness, height: rect.height)
            : CGRect(x: rect.minX, y: rect.midY - thickness / 2, width: rect.width, height: thickness)
        return Path(roundedRect: bar, cornerRadius: thickness / 2)
    }
}
#endif

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
                .overlay { SketchLeafShield(leaf: leaf, workspace: tree.resolve(leaf)?.workspace) }
        } else if let browser = tree.browser(leaf) {
            BrowserLeafView(member: browser, isFocused: tree.focusedLeaf == leaf, focus: { tree.focus(leaf: leaf) })
                .overlay { SketchLeafShield(leaf: leaf, workspace: tree.resolve(leaf)?.workspace) }
        } else if let tool = tree.tool(leaf) {
            ToolLeafView(member: tool, isSplit: isSplit, isFocused: tree.focusedLeaf == leaf, focus: { tree.focus(leaf: leaf) })
                .overlay { SketchLeafShield(leaf: leaf, workspace: tree.resolve(leaf)?.workspace) }
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
    @Environment(\.paneTerminalHidden) private var terminalHidden
    @AppStorage(TerminalPreferences.Key.unfocusedSplitOpacity) private var unfocusedOpacity = TerminalPreferences.Default.unfocusedSplitOpacity
    @AppStorage(TerminalPreferences.Key.resizeOverlay) private var resizeOverlay = TerminalPreferences.ResizeOverlay.afterFirst
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact
    @AppStorage(TerminalPreferences.Key.paneActiveBorder) private var activeBorder = TerminalPreferences.Default.paneActiveBorder
    @AppStorage(TerminalPreferences.Key.paneInactiveFade) private var inactiveFade = TerminalPreferences.Default.paneInactiveFade

    var body: some View {
        let focused = isFocused
        let notice = workspace.notices[id] ?? PaneNotice()
        // A drawing always has its header: its close and pane controls, docked alone or not.
        let showsHeader = isSplit || workspace.canvasTitles[id] != nil
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
                PaneSearchBar(model: model, pane: workspace.pane(id))
            }
        }
        .hostLinkOverlay(groupId: workspace.groupId, enabled: namesHost)
        // The terminal is laid out once, below where the header goes; the header itself only
        // fades, so the first split never pushes the grid down in one step.
        .padding(.top, showsHeader ? PaneHeader.height : 0)
        .overlay(alignment: .top) {
            if showsHeader {
                PaneHeader(id: id, workspace: workspace, isFocused: focused, namesHost: namesHost, focus: focus)
                    .overlay {
                        if isSplit && !focused && inactiveFade == .header {
                            UnfocusedDim(unfocusedSplitOpacity: unfocusedOpacity, fill: theme.background)
                        }
                    }
                    .motionTransition(PaneHeader.arrival)
            }
        }
        .overlay {
            // Ghostty unfocused-split-opacity: the background color at 1 - opacity, header included.
            if isSplit && !focused && inactiveFade.dimsContent {
                UnfocusedDim(unfocusedSplitOpacity: unfocusedOpacity, fill: theme.background)
            }
        }
        .overlay {
            if isSplit && activeBorder {
                ActivePaneRing(isActive: focused, cornerRadius: paneStyle == .comfortable ? DS.Radius.pane : 0)
            } else if isSplit && paneStyle == .comfortable {
                PaneFocusEdge(isFocused: focused)
            }
        }
        .background(theme.background, ignoresSafeAreaEdges: [])
        // Header, banners and bars sit on the terminal: its colours, even in a window kept apart.
        .terminalSurfaceChrome()
        // A mixed tab's panes stay with it: tabs merge into host tabs only.
        .tabDropTarget(pane: id, workspace: workspace, enabled: !namesHost)
    }

    @ViewBuilder private var content: some View {
        if let pane = workspace.pane(id) {
            paneContent(pane)
        } else if let failure = workspace.failures[id] {
            EmptyState("Pane Failed to Start", systemImage: "exclamationmark.triangle", message: failure) {
                Button("Close Pane") { workspace.apply(.close(id)) }
            }
            .foregroundStyle(theme.foreground)
        } else {
            theme.background
        }
    }

    @ViewBuilder private func paneContent(_ pane: Pane) -> some View {
        #if os(iOS)
        if let state = pane.chat, state.agent != nil, let daemon = workspace.host as? DaemonConnection {
            PaneChatView(pane: pane, state: state, hub: daemon.workspace,
                         approval: SharedApproval(workspace: workspace, session: daemon.multiplayer,
                                                  pane: pane.id.rawValue, placement: .chatComposer),
                         permitsSending: daemon.multiplayer.isOwner,
                         readsToolDetails: daemon.multiplayer.canPrompt,
                         working: daemon.meta[pane.id]?.agent?.state == .running) { active in
                terminalContent(pane, isActive: active)
            }
        } else { terminalContent(pane) }
        #else
        terminalContent(pane)
        #endif
    }

    private func terminalContent(_ pane: Pane, isActive: Bool = true) -> some View {
        // Identity must include the host: otherwise a reused container can keep typing into the previous pane.
        TerminalHost(pane: pane, isFocused: isFocused, workspace: workspace, isActive: isActive, isConcealed: terminalHidden)
            .id(HostPane(hostId: workspace.groupId, pane: id))
            // A moving pane shows its still (`PaneTravel`), an arriving one its background:
            // platform views do not follow SwiftUI transforms or clips.
            .opacity(terminalHidden ? 0 : 1)
            .clipped()
            .fadedTowardTerminalBackground(pane.showsSavedScreen ? 0.25 : 0)
            .overlay { SavedScreenOverlay(pane: pane) }
            .overlay(alignment: .top) { PaneSizingOverlay(pane: pane, workspace: workspace) }
            .overlay(alignment: .bottomLeading) { RunAgainOverlay(pane: pane, workspace: workspace) }
            .overlay {
                StalePaneOverlay(connection: pane.connection, paneId: id,
                    hostIsLive: namesHost ? model.connectionState(ofGroup: workspace.groupId).isLive : nil)
            }
    }
}

/// Split / zoom / search / close for one pane, shared by the pane header and the toolbar.
/// Where a browser opens from a pane: beside it, below it, or in a tab of its own.
struct BrowserPlacementItems: View {
    let workspace: Workspace
    let model: WindowModel
    let pane: PaneId
    let act: (() -> Void) -> Void

    var body: some View {
        Button("Browser Right", systemImage: "globe") {
            act { model.openBrowser(besidePane: pane, onGroup: workspace.groupId) }
        }
        .accessibilityIdentifier("browser-right")
        Button("Browser Below", systemImage: "globe") {
            act { model.openBrowser(besidePane: pane, onGroup: workspace.groupId, axis: .vertical) }
        }
        .accessibilityIdentifier("browser-below")
        Button("Browser Tab", systemImage: "globe") {
            act { model.openBrowserTab(fromPane: pane, onGroup: workspace.groupId) }
        }
        .accessibilityIdentifier("browser-tab")
    }
}

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
        if let target = pane ?? workspace.focusedPane {
            BrowserPlacementItems(workspace: workspace, model: model, pane: target, act: focusThen)
        }
        Button("Split with Host…", systemImage: "rectangle.split.2x1.fill") {
            focusThen { WorkspaceAction.splitWithHost.perform(on: workspace, window: model) }
        }
        .disabled(!model.canSplitWithHost)
        // One title for both directions, like Ghostty's "Zoom Split" toggle.
        Button("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right") {
            focusThen { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) }
        }
        if model.activeMixedTab == nil, let target = pane ?? workspace.focusedPane {
            FloatMenuItems(workspace: workspace, model: model, pane: target)
        }
        moveItems
        Divider()
        Button("Find…", systemImage: "magnifyingglass") { focusThen { model.showSearch() } }
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

extension EnvironmentValues {
    /// A layout motion moves the pane or brings it in: its live terminal hides under its still
    /// or its background until the motion settles.
    @Entry var paneTerminalHidden = false
}

extension Node {
    /// The pane touching this subtree's leading edge along `axis` (left edge for horizontal).
    func leadingPane(along axis: Axis) -> PaneId {
        switch self {
        case .leaf(let pane): pane
        case .split(_, _, let first, _): first.leadingPane(along: axis)
        }
    }

    /// The pane touching this subtree's trailing edge along `axis` (right edge for horizontal).
    func trailingPane(along axis: Axis) -> PaneId {
        switch self {
        case .leaf(let pane): pane
        case .split(let splitAxis, _, let first, let second):
            splitAxis == axis ? second.trailingPane(along: axis) : first.trailingPane(along: axis)
        }
    }
}
