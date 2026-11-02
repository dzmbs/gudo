import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import TerminalRenderer

// MARK: - Layout

/// Where everything on a tab's canvas goes: the tiled panes, each floating window's card and
/// panes, the tray's chips, and what a drag can land on. Plain values from the session and the
/// canvas size, so every frame of an animation is a layout of the same kind.
struct CanvasLayout {
    /// What the canvas lays panes out with, besides the session and its size.
    struct Metrics {
        var gap: CGFloat
        var header: CGFloat
        var cell: CGSize?
        var padding: CGFloat
        /// Tiled panes show their header (more than one pane is on the canvas).
        var headers = true
    }

    struct Leaf {
        let pane: PaneId
        var frame: CGRect
        var z: Double
        let radii: RectangleCornerRadii
        /// The window it floats in.
        let window: FloatId?
        /// Alone in its window: it is the card, with the card's edge and shadow.
        let lifted: Bool
        /// Its window has the focus.
        let focusedWindow: Bool
        let visible: Bool
        /// While out of sight: how small it is drawn, and towards where.
        let hiddenScale: CGFloat
        let hiddenAnchor: UnitPoint
        /// Part way between shown and hidden (a layout blended for review).
        var fade: Double?
        var growth: Double?

        var opacity: Double { fade ?? (visible ? 1 : 0) }
        var scale: CGFloat { hiddenScale + (1 - hiddenScale) * (growth ?? (visible ? 1 : 0)) }
    }

    struct Divider {
        let id: String
        var divider: SplitLayout.Divider
        let z: Double
        let visible: Bool
    }

    struct Card {
        let id: FloatId
        var frame: CGRect
        let z: Double
        /// Holds several panes: drawn as a backdrop with a grip above them.
        let multi: Bool
        let visible: Bool
        let focused: Bool
        let panes: [PaneId]
        var fade: Double?

        var opacity: Double { fade ?? (visible && multi ? 1 : 0) }
    }

    struct Chip {
        let id: FloatId
        let frame: CGRect
        let panes: [PaneId]
        let focused: Bool
    }

    static let radius = DS.Radius.pane
    /// The strip above a window of several panes that moves it.
    static let grip: CGFloat = 14
    static let trayZ = 5_000.0
    static let overlayZ = 6_000.0
    #if os(macOS)
    static let chipSize = CGSize(width: 188, height: 28)
    #else
    static let chipSize = CGSize(width: 204, height: 36)
    #endif

    let bounds: CGRect
    let metrics: Metrics
    /// Every window is out of sight (⌥⌘F).
    let floatsHidden: Bool
    private(set) var leaves: [Leaf] = []
    private(set) var dividers: [Divider] = []
    private(set) var cards: [Card] = []
    private(set) var chips: [Chip] = []
    /// The tiled panes' frames.
    private(set) var tiled: [(PaneId, CGRect)] = []
    /// Every visible pane's frame, front to back: what a dragged pane can land beside.
    private(set) var targets: [(PaneId, CGRect)] = []

    /// Above the tiled panes and their dividers, under the windows: a zoomed pane, which grows
    /// over its neighbours and shrinks back onto them.
    static let zoomZ = 2.0

    /// - Parameters:
    ///   - zoomSettled: the zoomed pane has finished growing: the panes under it are put out
    ///     of sight (until then they stay, so it grows over them and shrinks back onto them).
    init(
        node: Node, floats: FloatScene, zoomed: PaneId?, focused: PaneId?, size: CGSize, gap: CGFloat,
        header: CGFloat, cell: CGSize?, padding: CGFloat, headers: Bool = true, live: [FloatId: CGRect] = [:],
        zoomSettled: Bool = true
    ) {
        bounds = CGRect(origin: .zero, size: size)
        metrics = Metrics(gap: gap, header: header, cell: cell, padding: padding, headers: headers)
        floatsHidden = floats.hidden
        let zoomedWindow = zoomed.flatMap { zoomedPane in floats.windows.first { $0.window.panes.contains(zoomedPane) } }

        // Tiled panes: the tree, the zoomed one over it at the tab's size.
        let zoomedTile = zoomed.flatMap { zoomedWindow == nil && node.contains($0) ? $0 : nil }
        let base = SplitLayout(node: node, in: bounds, gap: gap, header: header, cell: cell, padding: padding)
        // A zoomed window hides the tiled panes under it; they stay laid out.
        tiled = zoomedTile.map { [($0, bounds)] } ?? base.leaves.map { ($0.pane, $0.frame) }
        for leaf in base.leaves {
            let isZoomed = leaf.pane == zoomedTile
            leaves.append(Leaf(
                pane: leaf.pane, frame: isZoomed ? bounds : leaf.frame,
                z: isZoomed ? Self.zoomZ : 0, radii: .init(), window: nil,
                lifted: false, focusedWindow: false, visible: zoomedTile == nil || isZoomed || !zoomSettled,
                hiddenScale: 1, hiddenAnchor: .center))
        }
        if zoomedTile == nil {
            dividers += base.dividers.map { Divider(id: "tiled-\($0.id)", divider: $0, z: 1, visible: true) }
        }

        // The tray: windows sent there, in a stable order.
        let trayed = floats.windows.filter(\.window.minimized).sorted { $0.window.id < $1.window.id }
        let chipFrames = FloatGeometry.trayChips(count: trayed.count, chip: Self.chipSize, in: bounds)
        var chipOf: [FloatId: CGRect] = [:]
        for (window, frame) in zip(trayed, chipFrames) {
            chipOf[window.window.id] = frame
            chips.append(Chip(id: window.window.id, frame: frame, panes: window.window.panes, focused: window.window.panes.contains(focused ?? PaneId(0))))
        }

        var front: [(PaneId, CGRect)] = []
        for (index, scene) in floats.windows.enumerated() {
            let window = scene.window
            let z = 10 + Double(index) * 10
            let single = window.panes.count == 1
            let isZoomed = zoomedWindow?.window.id == window.id
            let fillsTab = isZoomed && single
            var rect = live[window.id] ?? FloatGeometry.rect(of: window.frame, in: bounds)
            if fillsTab { rect = bounds }
            // A zoomed pane is all there is: windows step aside until it is restored.
            let visible = !floats.hidden && !window.minimized && (zoomed == nil || isZoomed)
            let hasFocus = focused.map(window.panes.contains) ?? false
            let multi = !single && !fillsTab
            let content = multi ? rect.inset(by: Self.gripInsets) : rect
            let root: Node = if isZoomed, !single, let zoomed { .leaf(zoomed) } else { scene.root }
            let inner = SplitLayout(node: root, in: content, gap: gap, header: header, cell: cell, padding: padding)
            let chip = chipOf[window.id]
            let radius = fillsTab ? 0 : Self.radius
            for leaf in inner.leaves {
                let radii = Self.radii(of: leaf.frame, in: rect, radius: radius, topSquare: multi)
                // In the tray a pane keeps its size (its grid, and so the program's, never
                // changes) and is drawn shrunk into its chip: restoring grows it back out.
                let (scale, anchor) = chip.map { Self.shrink(rect, into: $0) } ?? (0.96, .center)
                leaves.append(Leaf(
                    pane: leaf.pane, frame: leaf.frame, z: fillsTab ? Self.trayZ - 1 : z + 1, radii: radii,
                    window: window.id, lifted: single && !fillsTab, focusedWindow: hasFocus, visible: visible,
                    hiddenScale: scale, hiddenAnchor: Self.anchor(anchor, of: rect, in: leaf.frame)))
                if visible { front.append((leaf.pane, leaf.frame)) }
            }
            dividers += inner.dividers.map {
                Divider(id: "\(window.id)-\($0.id)", divider: $0, z: z + 2, visible: visible)
            }
            cards.append(Card(id: window.id, frame: rect, z: z, multi: multi, visible: visible, focused: hasFocus, panes: window.panes))
        }
        targets = front.reversed() + (zoomedWindow == nil ? tiled : [])
    }

    static let gripInsets = EdgeInsets(top: grip, leading: 1, bottom: 1, trailing: 1)

    /// The scale that fits `window` to `chip`'s width, and the point of `window` (as a unit
    /// point) that stays still while it scales: so it shrinks onto the chip.
    static func shrink(_ window: CGRect, into chip: CGRect) -> (CGFloat, UnitPoint) {
        let scale = max(min(chip.width / max(window.width, 1), 1), 0.05)
        // The fixed point of a scale about that point that maps the window's centre onto the chip's.
        let fixedPoint = CGPoint(
            x: (chip.midX - scale * window.midX) / (1 - scale), y: (chip.midY - scale * window.midY) / (1 - scale))
        return (scale, UnitPoint(x: (fixedPoint.x - window.minX) / max(window.width, 1), y: (fixedPoint.y - window.minY) / max(window.height, 1)))
    }

    /// `point`, a unit point of `outer`, as a unit point of `inner` (a pane in its window).
    static func anchor(_ point: UnitPoint, of outer: CGRect, in inner: CGRect) -> UnitPoint {
        let x = outer.minX + point.x * outer.width, y = outer.minY + point.y * outer.height
        return UnitPoint(x: (x - inner.minX) / max(inner.width, 1), y: (y - inner.minY) / max(inner.height, 1))
    }

    /// Rounded where the pane meets its card's corners.
    static func radii(of frame: CGRect, in card: CGRect, radius: CGFloat, topSquare: Bool) -> RectangleCornerRadii {
        let near: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) < 2 }
        let left = near(frame.minX, card.minX + (topSquare ? 1 : 0)), right = near(frame.maxX, card.maxX - (topSquare ? 1 : 0))
        let top = !topSquare && near(frame.minY, card.minY), bottom = near(frame.maxY, card.maxY - (topSquare ? 1 : 0))
        let inner = topSquare ? max(0, radius - 1) : radius
        return RectangleCornerRadii(
            topLeading: left && top ? inner : 0, bottomLeading: left && bottom ? inner : 0,
            bottomTrailing: right && bottom ? inner : 0, topTrailing: right && top ? inner : 0)
    }

    func card(_ id: FloatId) -> Card? { cards.first { $0.id == id } }

    func leaf(_ pane: PaneId) -> Leaf? { leaves.first { $0.pane == pane } }

    /// Tiled panes not in `before`.
    func newTiles(since before: CanvasLayout?) -> Set<PaneId> {
        guard let before else { return [] }
        return Set(leaves.filter { $0.window == nil && before.leaf($0.pane) == nil }.map(\.pane))
    }

    /// A tiled pane drawn over its neighbours: the one just unzoomed, shrinking back onto them.
    mutating func raise(_ pane: PaneId?) {
        guard let pane, let index = leaves.firstIndex(where: { $0.pane == pane && $0.window == nil }) else { return }
        leaves[index].z = Self.zoomZ
    }

    /// `panes` go under the other tiled panes, which uncover them as they make room.
    mutating func lower(_ panes: Set<PaneId>) {
        for index in leaves.indices where panes.contains(leaves[index].pane) && leaves[index].window == nil {
            leaves[index].z = -1
        }
    }

    /// The terminal's part of a leaf: its frame less the pane header.
    func terminalSize(of leaf: Leaf) -> CGSize {
        let header = metrics.headers || leaf.window != nil ? metrics.header : 0
        return CGSize(width: leaf.frame.width, height: max(0, leaf.frame.height - header))
    }

    /// The canvas `session`'s active tab gets at this layout's size: what an op would lead to.
    init?(session: Session, like layout: CanvasLayout) {
        guard let tab = session.activeTab else { return nil }
        let metrics = layout.metrics
        self.init(
            node: session.tiledRoot(of: tab) ?? tab.root, floats: FloatScene(session: session, tab: tab, hidden: layout.floatsHidden),
            zoomed: tab.zoomed, focused: tab.focused, size: layout.bounds.size, gap: metrics.gap, header: metrics.header, cell: metrics.cell,
            padding: metrics.padding, headers: metrics.headers)
    }

    /// Each pane where it is and whether it shows: two layouts that draw the panes alike.
    func placesPanes(like other: CanvasLayout) -> Bool {
        leaves.count == other.leaves.count && leaves.allSatisfy { leaf in
            other.leaf(leaf.pane).map { $0.frame == leaf.frame && $0.visible == leaf.visible && $0.window == leaf.window } ?? false
        }
    }

    /// This layout `progress` of the way from `from` (0) to here (1), as an animation between
    /// the two draws it: frames move, what appears or goes fades. For design review, where a
    /// window off every display gets no animation frames.
    func blended(from: CanvasLayout, progress t: Double) -> CanvasLayout {
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(
                x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
        }
        var out = self
        out.leaves = leaves.map { leaf in
            var leaf = leaf
            if let old = from.leaves.first(where: { $0.pane == leaf.pane }) {
                leaf.frame = mix(old.frame, leaf.frame)
                // As drawn: solid while it shrinks, fading at the end; solid at once coming back.
                let going = leaf.opacity < old.opacity
                leaf.fade = old.opacity + (leaf.opacity - old.opacity) * (going ? t * t : 1 - (1 - t) * (1 - t))
                let (from, to): (Double, Double) = (old.visible ? 1 : 0, leaf.visible ? 1 : 0)
                leaf.growth = from + (to - from) * t
            }
            return leaf
        }
        out.cards = cards.map { card in
            var card = card
            if let old = from.card(card.id) {
                card.frame = mix(old.frame, card.frame)
                card.fade = old.opacity + (card.opacity - old.opacity) * t
            }
            return card
        }
        out.dividers = dividers.map { divider in
            var divider = divider
            if let old = from.dividers.first(where: { $0.id == divider.id }) {
                divider.divider.frame = mix(old.divider.frame, divider.divider.frame)
            }
            return divider
        }
        return out
    }

    /// The Float target a dragged pane can be dropped on: top centre of the tab, below the
    /// pane headers so it never hides one.
    var floatTarget: CGRect {
        CGRect(x: bounds.midX - 64, y: bounds.minY + PaneHeader.height + 12, width: 128, height: 32)
    }
}

extension EdgeInsets {
    var cgInsets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) { (top, leading, bottom, trailing) }
}

extension CGRect {
    func inset(by insets: EdgeInsets) -> CGRect {
        CGRect(
            x: minX + insets.leading, y: minY + insets.top,
            width: max(0, width - insets.leading - insets.trailing), height: max(0, height - insets.top - insets.bottom))
    }
}

// MARK: - Arrangement (dragging, snapping, dropping)

/// One canvas's live arrangement: windows following the hand with their snap guides, a pane
/// being dragged with the region it would take, and the ops each gesture ends in.
@MainActor
@Observable
final class PaneArrangement {
    static let space = "pane-canvas"

    struct PaneDrag: Equatable {
        let pane: PaneId
        var point: CGPoint
        var drop: FloatGeometry.Drop
        var preview: CGRect?
    }

    /// A layout change drawn part way (design review): the layout before it and how far.
    struct Scrub {
        var from: CanvasLayout
        var progress: Double
    }

    /// Panes drawn as a still of their last frame while they lift, dock, go to the tray or
    /// come back: a picture scales and fades with the motion, crisp, and the terminal under
    /// it reflows once, at rest.
    @ObservationIgnored private var stills: [PaneId: CGImage] = [:]
    /// Bumped when the stills are taken away.
    private(set) var stillsVersion = 0

    func still(of pane: PaneId) -> CGImage? { stills[pane] }
    /// How long stills stand in: the motion's length (design review stretches it).
    static var stillDuration = DS.Motion.liftDuration
    /// Stretches how long a layout motion may take to settle (design review draws it slowly).
    static var settleStretch = 1.0

    /// Takes stills of `panes` (`image` draws one) for the length of the `lift` motion.
    func holdStills(of panes: [PaneId], image: (PaneId) -> CGImage?) {
        for pane in panes where stills[pane] == nil {
            if let still = image(pane) { stills[pane] = still }
        }
        guard !panes.isEmpty else { return }
        let version = stillsVersion
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.stillDuration * 1000)))
            guard let self, self.stillsVersion == version else { return }
            self.stills.removeAll()
            self.stillsVersion += 1
        }
    }

    /// Windows being moved or resized, where the hand has them.
    var live: [FloatId: CGRect] = [:]
    var scrub: Scrub?
    var guides: [FloatGeometry.Guide] = []
    var paneDrag: PaneDrag?
    /// A moved window resting over a pane's edge: where it would dock.
    var dockPreview: CGRect?
    /// A drop sent to a host: its region stays lit until the layout answers.
    var landing: CGRect?
    /// The layout the drop under the hand leads to, drawn while a pane is dragged (the panes
    /// making room, the dragged one where it lands) and until the host has made it so.
    var preview: CanvasLayout?

    @ObservationIgnored private(set) var layout: CanvasLayout?
    @ObservationIgnored private(set) var tree: (any PaneTree)?
    /// The preview a drop was sent with, until the layout matches it.
    @ObservationIgnored private var landingLayout: CanvasLayout?
    @ObservationIgnored private var landingTimeout: Task<Void, Never>?
    @ObservationIgnored private var startFrame: CGRect?
    @ObservationIgnored private var dockDrop: FloatGeometry.Drop?
    @ObservationIgnored private var dwell: Task<Void, Never>?
    @ObservationIgnored private var dwellingOn: FloatGeometry.Drop?

    /// The canvas's latest layout (each layout pass; not observed).
    func update(layout: CanvasLayout, tree: any PaneTree) {
        self.layout = layout
        self.tree = tree
        // The host has made the drop: the layout takes over from the preview (where it already
        // is), and the lit region fades.
        if let from = landingLayout, !layout.placesPanes(like: from) {
            landingLayout = nil
            Task { @MainActor [weak self] in self?.land() }
        }
    }

    /// The drop has landed, or never will: the canvas draws its own layout again.
    private func land() {
        landingLayout = nil
        landingTimeout?.cancel()
        withAnimation(DS.Motion.split) { preview = nil }
        withAnimation(DS.Motion.overlay) { landing = nil }
        // Panes the preview held go to where the layout has them.
        if let layout { prepareTerminals(for: layout, within: DS.Motion.splitSettle) }
    }

    /// Each terminal of `layout` is on its way to its size there: its grid changes once, now,
    /// and its last frame shows until it arrives (`TerminalSurface.prepareResize`).
    func prepareTerminals(for layout: CanvasLayout, within duration: Double) {
        guard let tree, layout.bounds.width > 0, layout.bounds.height > 0 else { return }
        for leaf in layout.leaves {
            let size = layout.terminalSize(of: leaf)
            guard size.width >= 1, size.height >= 1, tree.editor(leaf.pane) == nil, tree.browser(leaf.pane) == nil,
                  tree.tool(leaf.pane) == nil, let (workspace, pane) = tree.resolve(leaf.pane), let terminal = workspace.panes[pane]
            else { continue }
            terminal.view.surface.prepareResize(to: size, within: .milliseconds(Int(duration * 1000)))
        }
    }

    /// The terminals of the layout keep showing their frame while a preview moves them about.
    private func holdTerminals() {
        guard let tree, let layout else { return }
        for leaf in layout.leaves {
            guard let (workspace, pane) = tree.resolve(leaf.pane) else { continue }
            workspace.panes[pane]?.view.surface.holdFrame()
        }
    }

    var workspace: Workspace? { tree?.arranges }

    private func untracked(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    // MARK: Moving a window

    func move(_ id: FloatId, by translation: CGSize, at location: CGPoint) {
        guard let layout, let card = layout.card(id) else { return }
        if startFrame == nil {
            startFrame = card.frame
            if let workspace, let pane = card.panes.first, !card.focused { workspace.apply(.focus(pane)) }
        }
        guard let start = startFrame else { return }
        var rect = start.offsetBy(dx: translation.width, dy: translation.height)
        rect.origin.x = min(max(rect.minX, layout.bounds.minX), layout.bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, layout.bounds.minY), layout.bounds.maxY - rect.height)
        let others = layout.cards.filter { $0.id != id && $0.visible }.map(\.frame)
        let (snapped, guides) = FloatGeometry.snap(rect, in: layout.bounds, others: others)
        untracked {
            live[id] = snapped
            self.guides = guides
        }
        // A one-pane window held over a pane's edge offers to dock there.
        if card.panes.count == 1 { considerDock(card.panes[0], at: location, in: layout) }
    }

    func endMove(_ id: FloatId, by translation: CGSize, velocity: CGSize) {
        defer {
            startFrame = nil
            dwell?.cancel()
            dwellingOn = nil
        }
        guard let layout, let card = layout.card(id), let workspace, let pane = card.panes.first else { return clear(id) }
        if dockPreview != nil, let drop = dockDrop {
            dockDrop = nil
            TerminalSurface.holdGrids(for: .milliseconds(Int(DS.Motion.liftDuration * 1000)))
            withAnimation(DS.Motion.lift) {
                dockPreview = nil
                live[id] = nil
                guides = []
                switch drop {
                case .beside(let target, let side): workspace.apply(.dock(pane, beside: target, side: side))
                case .edge(let side): if let tab = workspace.session.activeTab?.id { workspace.apply(.movePaneToEdge(pane, tab: tab, side: side)) }
                case .float, .cancel: break
                }
            }
            return
        }
        let current = live[id] ?? card.frame
        let thrown = FloatGeometry.projected(current, velocity: CGVector(dx: velocity.width, dy: velocity.height), in: layout.bounds)
        let others = layout.cards.filter { $0.id != id && $0.visible }.map(\.frame)
        let rest = FloatGeometry.snap(thrown, in: layout.bounds, others: others).rect
        withAnimation(DS.Motion.settle) {
            live[id] = nil
            guides = []
            dockPreview = nil
            workspace.apply(.setFloat(pane, frame: FloatFrame(rest, in: layout.bounds), minimized: nil, pinned: nil))
        }
    }

    private func clear(_ id: FloatId) {
        withAnimation(DS.Motion.settle) {
            live[id] = nil
            guides = []
            dockPreview = nil
        }
    }

    /// Waits a moment over a dock spot before offering it, so a window passing over the panes
    /// never flickers previews.
    private func considerDock(_ pane: PaneId, at point: CGPoint, in layout: CanvasLayout) {
        var drop = FloatGeometry.drop(at: point, in: layout.bounds, panes: layout.tiled, dragged: pane)
        if case .beside(let target, let side) = drop, let rect = layout.tiled.first(where: { $0.0 == target })?.1,
           !Self.nearEdge(point, of: rect, side: side) {
            drop = .cancel
        }
        guard drop != dwellingOn else { return }
        dwellingOn = drop
        dwell?.cancel()
        if dockPreview != nil { withAnimation(DS.Motion.menu) { dockPreview = nil } }
        dockDrop = nil
        guard drop != .cancel, drop != .float else { return }
        dwell = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled, let self, let op = self.op(placing: pane, drop, docking: true),
                  let frame = self.outcome(of: op)?.leaf(pane)?.frame else { return }
            self.dockDrop = drop
            withAnimation(DS.Motion.menu) { self.dockPreview = frame }
        }
    }

    // MARK: Outcomes

    /// The op that puts `pane` where `drop` says: moving it there, or docking its window.
    func op(placing pane: PaneId, _ drop: FloatGeometry.Drop, docking: Bool = false) -> LayoutOp? {
        switch drop {
        case .beside(let target, let side):
            docking ? .dock(pane, beside: target, side: side) : .movePane(pane, beside: target, side: side)
        case .edge(let side):
            workspace?.session.activeTab.map { .movePaneToEdge(pane, tab: $0.id, side: side) }
        case .float, .cancel:
            nil
        }
    }

    /// The canvas `op` leads to, worked out on a copy of the session as the host will apply
    /// it: what a preview shows is what the drop gives.
    func outcome(of op: LayoutOp) -> CanvasLayout? {
        guard let workspace, let layout else { return nil }
        var session = workspace.session
        session.apply(op)
        return CanvasLayout(session: session, like: layout)
    }

    /// Within the outer quarter of `rect` on `side`: deliberate, not passing through.
    private static func nearEdge(_ point: CGPoint, of rect: CGRect, side: Direction) -> Bool {
        switch side {
        case .left: point.x < rect.minX + rect.width / 4
        case .right: point.x > rect.maxX - rect.width / 4
        case .up: point.y < rect.minY + rect.height / 4
        case .down: point.y > rect.maxY - rect.height / 4
        }
    }

    // MARK: Resizing a window

    func resize(_ id: FloatId, edges: FloatGeometry.Edges, by translation: CGSize) {
        guard let layout, let card = layout.card(id) else { return }
        if startFrame == nil {
            startFrame = card.frame
            if let workspace, let pane = card.panes.first, !card.focused { workspace.apply(.focus(pane)) }
        }
        guard let start = startFrame else { return }
        let rect = FloatGeometry.resized(start, edges: edges, by: translation, in: layout.bounds)
        let others = layout.cards.filter { $0.id != id && $0.visible }.map(\.frame)
        var (snapped, guides) = FloatGeometry.snap(rect, in: layout.bounds, others: others, moving: edges)
        if snapped.width < FloatGeometry.minimumSize.width || snapped.height < FloatGeometry.minimumSize.height {
            (snapped, guides) = (rect, [])
        }
        untracked {
            live[id] = snapped
            self.guides = guides
        }
    }

    func endResize(_ id: FloatId) {
        defer { startFrame = nil }
        guard let layout, let workspace, let rect = live[id], let pane = layout.card(id)?.panes.first else { return clear(id) }
        withAnimation(DS.Motion.settle) {
            live[id] = nil
            guides = []
            workspace.apply(.setFloat(pane, frame: FloatFrame(rect, in: layout.bounds), minimized: nil, pinned: nil))
        }
    }

    // MARK: Dragging a pane

    /// How far past a zone's edge the hand may stray before the zone under it changes: no
    /// flicker between two zones along their boundary.
    static let zoneHysteresis: CGFloat = 12

    func drag(_ pane: PaneId, to point: CGPoint) {
        guard let layout, let workspace, workspace.canMovePanes else { return }
        let floatTarget = workspace.canFloat ? layout.floatTarget : nil
        // Zones are the panes as they were when the drag began, not as the preview has them:
        // the panes making room never move the zones under the hand.
        func zone(at point: CGPoint) -> FloatGeometry.Drop {
            FloatGeometry.drop(at: point, in: layout.bounds, panes: layout.targets, dragged: pane, floatTarget: floatTarget)
        }
        var drop = zone(at: point)
        if let current = paneDrag?.drop, drop != current {
            let slack = Self.zoneHysteresis
            let near = [CGPoint(x: -slack, y: 0), CGPoint(x: slack, y: 0), CGPoint(x: 0, y: -slack), CGPoint(x: 0, y: slack)]
            if near.contains(where: { zone(at: CGPoint(x: point.x + $0.x, y: point.y + $0.y)) == current }) { drop = current }
        }
        let starting = paneDrag == nil
        untracked {
            if starting, let tab = workspace.session.tab(containing: pane), tab.focused != pane { workspace.apply(.focus(pane)) }
            paneDrag = PaneDrag(pane: pane, point: point, drop: paneDrag?.drop ?? .cancel, preview: paneDrag?.preview)
        }
        if starting {
            landingLayout = nil
            holdTerminals()
        }
        guard paneDrag?.drop != drop else { return }
        var outcome = op(placing: pane, drop).flatMap(outcome(of:))
        // A drop that leaves every pane where it is offers nothing.
        if let result = outcome, result.placesPanes(like: layout) {
            drop = .cancel
            outcome = nil
        }
        guard paneDrag?.drop != drop else { return }
        // The panes make room, and the dragged one shows where it lands.
        withAnimation(DS.Motion.reorder) {
            paneDrag?.drop = drop
            paneDrag?.preview = outcome?.leaf(pane)?.frame
            preview = outcome
        }
    }

    func cancelDrag() {
        paneDrag = nil
        land()
    }

    func endDrag(_ pane: PaneId, at point: CGPoint) {
        guard let drag = paneDrag, let layout, let workspace else {
            paneDrag = nil
            return
        }
        var op = op(placing: pane, drag.drop)
        if drag.drop == .float, workspace.canToggleFloat(pane) || workspace.session.isFloating(pane) {
            // Where it was let go: a window centred there, two fifths of the tab.
            let size = CGSize(width: layout.bounds.width * 0.42, height: layout.bounds.height * 0.46)
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - 16, width: size.width, height: size.height)
            op = .float(pane, frame: FloatFrame(rect, in: layout.bounds).clamped)
        }
        TerminalSurface.holdGrids(for: .milliseconds(Int(DS.Motion.liftDuration * 1000)))
        withAnimation(DS.Motion.lift) {
            paneDrag = nil
            landing = drag.preview
            if let op { workspace.apply(op) }
        }
        guard preview != nil, op != nil else { return land() }
        // A host answers a round trip later: the preview stays, and the region lit, until the
        // layout changes (`update`), or this long at most.
        landingLayout = layout
        landingTimeout?.cancel()
        landingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.land()
        }
    }
}

// MARK: - Chrome

extension View {
    /// A pane's look on the canvas: square and flat in the tree; lifted into a card when it is
    /// a window of its own (rounded, the glass rim, the panel shadow, the accent rim while it
    /// has the focus). Every value animates, so lifting out and docking are one motion.
    func floatingChrome(_ leaf: CanvasLayout.Leaf, dragging: Bool) -> some View {
        modifier(FloatingChrome(leaf: leaf, dragging: dragging))
    }
}

extension View {
    /// The beat of a pane leaving its tab or rejoining it: lifted towards you as it floats,
    /// pressed in for a moment as it docks, in step with the frame's spring.
    func liftBeat(floating: Bool) -> some View {
        modifier(LiftBeat(floating: floating))
    }
}

private struct LiftBeat: ViewModifier {
    let floating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: floating) { content, scale in
            content.scaleEffect(reduceMotion ? 1 : scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(floating ? 1.03 : 0.985, duration: 0.16, spring: .snappy)
                SpringKeyframe(1, duration: 0.36, spring: .smooth)
            }
        }
    }
}

private struct FloatingChrome: ViewModifier {
    let leaf: CanvasLayout.Leaf
    let dragging: Bool
    @Environment(\.chrome) private var chrome
    @Environment(\.terminalTheme) private var theme

    func body(content: Content) -> some View {
        let dark = chrome.scheme == .dark
        let shape = UnevenRoundedRectangle(cornerRadii: leaf.radii, style: .continuous)
        // Its rim and shadow go with it into the tray, fading as it does.
        let lifted = leaf.lifted
        content
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.1), lineWidth: 0.5)
                    .blendMode(dark ? .plusLighter : .normal)
                    .opacity(lifted && !leaf.focusedWindow ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(DS.Palette.accent.opacity(0.7), lineWidth: 1)
                    .opacity(lifted && leaf.focusedWindow ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(lifted ? DS.Shadow.panel.opacity(dark: dark) : 0),
                radius: lifted ? DS.Shadow.panel.radius : 0, y: lifted ? DS.Shadow.panel.y : 0)
            // Washed while it is being moved: an overlay, as the terminal's layer draws itself.
            .overlay {
                if dragging {
                    shape.fill(theme.background.opacity(0.55)).allowsHitTesting(false)
                }
            }
    }
}

/// The card under a window of several panes: their gaps in the divider colour, the grip that
/// moves it, the rim and the panel shadow.
struct FloatCardBackdrop: View {
    let card: CanvasLayout.Card
    @Environment(PaneArrangement.self) private var arrangement
    @Environment(\.terminalTheme) private var theme
    @Environment(\.chrome) private var chrome

    var body: some View {
        let dark = chrome.scheme == .dark
        let shape = RoundedRectangle(cornerRadius: CanvasLayout.radius, style: .continuous)
        let shown = card.multi && card.visible
        shape
            .fill(theme.splitDivider)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(DS.Palette.textTertiary)
                    .frame(width: 36, height: 4)
                    .padding(.top, 5)
            }
            .overlay {
                shape
                    .strokeBorder(card.focused ? AnyShapeStyle(DS.Palette.accent.opacity(0.7)) : AnyShapeStyle(Color.white.opacity(dark ? 0.16 : 0)), lineWidth: card.focused ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(shown ? DS.Shadow.panel.opacity(dark: dark) : 0), radius: DS.Shadow.panel.radius, y: DS.Shadow.panel.y)
            .frame(width: card.frame.width, height: card.frame.height)
            .overlay(alignment: .top) {
                // The grip strip moves the window.
                Color.clear
                    .frame(height: CanvasLayout.grip)
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(PaneArrangement.space))
                        .onChanged { arrangement.move(card.id, by: $0.translation, at: $0.location) }
                        .onEnded { arrangement.endMove(card.id, by: $0.translation, velocity: $0.velocity) })
                    #if os(macOS)
                    .pointerStyle(.grabIdle)
                    #endif
                    .accessibilityLabel("Move window")
            }
            .opacity(card.opacity)
            .allowsHitTesting(shown)
            .offset(x: card.frame.minX, y: card.frame.minY)
    }
}

/// Invisible edges and corners of a window that resize it, with the system's resize pointers.
struct FloatCardHandles: View {
    let card: CanvasLayout.Card
    @Environment(PaneArrangement.self) private var arrangement

    #if os(macOS)
    private let edge: CGFloat = 6
    private let corner: CGFloat = 14
    #else
    private let edge: CGFloat = 14
    private let corner: CGFloat = 28
    #endif

    var body: some View {
        let frame = card.frame
        ZStack(alignment: .topLeading) {
            handle([.left], CGRect(x: frame.minX - edge / 2, y: frame.minY + corner / 2, width: edge, height: max(0, frame.height - corner)))
            handle([.right], CGRect(x: frame.maxX - edge / 2, y: frame.minY + corner / 2, width: edge, height: max(0, frame.height - corner)))
            handle([.top], CGRect(x: frame.minX + corner / 2, y: frame.minY - edge / 2, width: max(0, frame.width - corner), height: edge))
            handle([.bottom], CGRect(x: frame.minX + corner / 2, y: frame.maxY - edge / 2, width: max(0, frame.width - corner), height: edge))
            handle([.left, .top], CGRect(x: frame.minX - corner / 2, y: frame.minY - corner / 2, width: corner, height: corner))
            handle([.right, .top], CGRect(x: frame.maxX - corner / 2, y: frame.minY - corner / 2, width: corner, height: corner))
            handle([.left, .bottom], CGRect(x: frame.minX - corner / 2, y: frame.maxY - corner / 2, width: corner, height: corner))
            handle([.right, .bottom], CGRect(x: frame.maxX - corner / 2, y: frame.maxY - corner / 2, width: corner, height: corner))
        }
    }

    private func handle(_ edges: FloatGeometry.Edges, _ rect: CGRect) -> some View {
        Color.clear
            .contentShape(.rect)
            .frame(width: rect.width, height: rect.height)
            #if os(macOS)
            .pointerStyle(.frameResize(position: Self.position(edges)))
            #endif
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(PaneArrangement.space))
                .onChanged { arrangement.resize(card.id, edges: edges, by: $0.translation) }
                .onEnded { _ in arrangement.endResize(card.id) })
            .offset(x: rect.minX, y: rect.minY)
            .accessibilityHidden(true)
    }

    #if os(macOS)
    private static func position(_ edges: FloatGeometry.Edges) -> FrameResizePosition {
        switch edges {
        case [.left, .top]: .topLeading
        case [.right, .top]: .topTrailing
        case [.left, .bottom]: .bottomLeading
        case [.right, .bottom]: .bottomTrailing
        case [.left]: .leading
        case [.right]: .trailing
        case [.top]: .top
        default: .bottom
        }
    }
    #endif
}

// MARK: - Overlay: guides, drop regions, the dragged pane

/// Over everything while arranging: snap guides, where a dragged pane or a held window would
/// land, the Float target and the chip following the hand.
struct ArrangementOverlay: View {
    let layout: CanvasLayout
    @Environment(PaneArrangement.self) private var arrangement
    @Environment(WindowModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(arrangement.guides.enumerated()), id: \.offset) { _, guide in
                Rectangle()
                    .fill(DS.Palette.accent.opacity(0.55))
                    .frame(
                        width: guide.axis == .vertical ? 1 : guide.to - guide.from,
                        height: guide.axis == .vertical ? guide.to - guide.from : 1)
                    .offset(
                        x: guide.axis == .vertical ? guide.position - 0.5 : guide.from,
                        y: guide.axis == .vertical ? guide.from : guide.position - 0.5)
                    .transition(.opacity)
            }
            if let region = arrangement.dockPreview ?? arrangement.paneDrag?.preview ?? arrangement.landing {
                DropRegion(rect: region)
            }
            if let drag = arrangement.paneDrag, let workspace = arrangement.workspace {
                if workspace.canFloat {
                    FloatTarget(lit: drag.drop == .float)
                        .frame(width: layout.floatTarget.width, height: layout.floatTarget.height)
                        .offset(x: layout.floatTarget.minX, y: layout.floatTarget.minY)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                DragChip(pane: drag.pane, workspace: workspace)
                    .fixedSize()
                    .position(x: drag.point.x + 12, y: drag.point.y + 18)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: layout.bounds.width, height: layout.bounds.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(DS.Motion.overlay, value: arrangement.guides)
        .animation(DS.Motion.menu, value: arrangement.paneDrag == nil)
    }
}

/// The region a drop gives a pane: the accent at a quarter, its rim, inset like a pane.
private struct DropRegion: View {
    let rect: CGRect

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.pane, style: .continuous)
        shape
            .fill(DS.Palette.accent.opacity(0.2))
            .overlay(shape.strokeBorder(DS.Palette.accent.opacity(0.65), lineWidth: 1.5))
            .frame(width: max(0, rect.width - 2 * DS.Space.xs), height: max(0, rect.height - 2 * DS.Space.xs))
            .offset(x: rect.minX + DS.Space.xs, y: rect.minY + DS.Space.xs)
            .transition(.opacity)
            .accessibilityIdentifier("pane-drop-region")
    }
}

/// "Float": drop a dragged pane here to float it.
private struct FloatTarget: View {
    let lit: Bool

    var body: some View {
        Label("Float", systemImage: "square.on.square")
            .font(.callout.weight(.medium))
            .foregroundStyle(lit ? AnyShapeStyle(DS.Palette.onProminent) : AnyShapeStyle(DS.Palette.text))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if lit { Capsule().fill(DS.Palette.prominent) }
            }
            .floatingCapsule()
            .scaleEffect(lit ? 1.06 : 1)
            .animation(DS.Motion.press, value: lit)
            .accessibilityIdentifier("pane-float-target")
    }
}

/// A small chip of the dragged pane that follows the hand: its mark and name.
private struct DragChip: View {
    let pane: PaneId
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        let program = model.programIdentity(ofPane: pane, onGroup: workspace.groupId)
        HStack(spacing: DS.Space.row) {
            ProgramMark(program, size: 12)
            Text(program.isShell ? workspace.programName(of: pane) : program.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let cwd = workspace.panes[pane]?.workingDirectory, !cwd.isEmpty {
                Text(verbatim: (cwd as NSString).abbreviatingWithTildeInPath)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 180)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.row)
        .floatingCapsule()
    }
}

// MARK: - Tray

/// Windows sent to the tray: a row of glass chips at the tab's bottom right, each with its
/// program, name and state; a click brings it back where it was, growing out of the chip.
struct FloatTray: View {
    let layout: CanvasLayout
    @Environment(PaneArrangement.self) private var arrangement
    @Environment(WindowModel.self) private var model

    var body: some View {
        if let workspace = arrangement.workspace {
            ZStack(alignment: .topLeading) {
                ForEach(layout.chips, id: \.id) { chip in
                    TrayChip(chip: chip, workspace: workspace)
                        .frame(width: chip.frame.width, height: chip.frame.height)
                        .offset(x: chip.frame.minX, y: chip.frame.minY)
                        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .frame(width: layout.bounds.width, height: layout.bounds.height, alignment: .topLeading)
        }
    }
}

private struct TrayChip: View {
    let chip: CanvasLayout.Chip
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let pane = chip.panes[0]
        let program = model.programIdentity(ofPane: pane, onGroup: workspace.groupId)
        let state = chip.panes.lazy.compactMap { model.paneStatus.state(of: $0.description) }.first
        Button {
            withAnimation(DS.Motion.lift) { workspace.apply(.focus(pane)) }
            TerminalSurface.holdGrids(for: .milliseconds(Int(DS.Motion.liftDuration * 1000)))
        } label: {
            HStack(spacing: DS.Space.row) {
                ProgramMark(program, size: 12)
                Text(program.isShell ? workspace.programName(of: pane) : program.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DS.Palette.text)
                    .lineLimit(1)
                if chip.panes.count > 1 {
                    Text("+\(chip.panes.count - 1)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                if let state, state != .idle {
                    StatusIndicator(state, size: 10)
                        .help(state.title)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .floatingCapsule(interactive: true)
        .scaleEffect(hovered ? 1.03 : 1)
        .animation(DS.Motion.press, value: hovered)
        .onHover { hovered = $0 }
        .help("Restore \(program.displayName)")
        .contextMenu {
            Button("Restore", systemImage: "arrow.up.left.and.arrow.down.right") { withAnimation(DS.Motion.lift) { workspace.apply(.focus(pane)) } }
            Button("Dock Pane", systemImage: "rectangle.inset.filled.and.person.filled") { model.dock(pane, in: workspace) }
            Divider()
            Button("Close Pane", systemImage: "xmark", role: .destructive) { workspace.apply(.close(pane)) }
        }
        .accessibilityLabel("\(program.displayName), in the tray")
        .accessibilityHint("Restores the floating window")
        .accessibilityIdentifier("float-tray-chip")
    }
}
