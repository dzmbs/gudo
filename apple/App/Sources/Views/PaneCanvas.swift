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
    struct Leaf {
        let pane: PaneId
        var frame: CGRect
        let z: Double
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
    private(set) var leaves: [Leaf] = []
    private(set) var dividers: [Divider] = []
    private(set) var cards: [Card] = []
    private(set) var chips: [Chip] = []
    /// The tiled panes' frames.
    private(set) var tiled: [(PaneId, CGRect)] = []
    /// Every visible pane's frame, front to back: what a dragged pane can land beside.
    private(set) var targets: [(PaneId, CGRect)] = []

    init(
        node: Node, floats: FloatScene, zoomed: PaneId?, focused: PaneId?, size: CGSize, gap: CGFloat,
        header: CGFloat, cell: CGSize?, padding: CGFloat, live: [FloatId: CGRect] = [:]
    ) {
        bounds = CGRect(origin: .zero, size: size)
        let zoomedWindow = zoomed.flatMap { z in floats.windows.first { $0.window.panes.contains(z) } }

        // Tiled panes: the zoomed one alone, or the tree.
        let tiledNode: Node = if let zoomed, zoomedWindow == nil, node.contains(zoomed) { .leaf(zoomed) } else { node }
        let base = SplitLayout(node: tiledNode, in: bounds, gap: gap, header: header, cell: cell, padding: padding)
        // A zoomed window hides the tiled panes under it; they stay laid out.
        tiled = base.leaves.map { ($0.pane, $0.frame) }
        for leaf in base.leaves {
            leaves.append(Leaf(
                pane: leaf.pane, frame: leaf.frame, z: 0, radii: .init(), window: nil, lifted: false,
                focusedWindow: false, visible: true, hiddenScale: 1, hiddenAnchor: .center))
        }
        dividers += base.dividers.map { Divider(id: "tiled-\($0.id)", divider: $0, z: 1, visible: true) }

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
        // The fixed point p of a scale s about p that maps the window's centre onto the chip's.
        let p = CGPoint(
            x: (chip.midX - scale * window.midX) / (1 - scale), y: (chip.midY - scale * window.midY) / (1 - scale))
        return (scale, UnitPoint(x: (p.x - window.minX) / max(window.width, 1), y: (p.y - window.minY) / max(window.height, 1)))
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

    @ObservationIgnored private(set) var layout: CanvasLayout?
    @ObservationIgnored private var landingPane: (PaneId, CGRect)?
    @ObservationIgnored private(set) var tree: (any PaneTree)?
    @ObservationIgnored private var startFrame: CGRect?
    @ObservationIgnored private var dockDrop: FloatGeometry.Drop?
    @ObservationIgnored private var dwell: Task<Void, Never>?
    @ObservationIgnored private var dwellingOn: FloatGeometry.Drop?

    /// The canvas's latest layout (each layout pass; not observed).
    func update(layout: CanvasLayout, tree: any PaneTree) {
        self.layout = layout
        self.tree = tree
        // The host has moved the pane: the lit region fades as it settles there.
        if landing != nil, let (pane, from) = landingPane, layout.leaves.contains(where: { $0.pane == pane && $0.frame != from }) {
            landingPane = nil
            Task { @MainActor [weak self] in
                withAnimation(DS.Motion.overlay) { self?.landing = nil }
            }
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
            guard !Task.isCancelled, let self, let layout = self.layout else { return }
            self.dockDrop = drop
            withAnimation(DS.Motion.menu) { self.dockPreview = FloatGeometry.preview(of: drop, in: layout.bounds, panes: layout.tiled) }
        }
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

    func drag(_ pane: PaneId, to point: CGPoint) {
        guard let layout, let workspace, workspace.canMovePanes else { return }
        let floatTarget = workspace.canFloat ? layout.floatTarget : nil
        let drop = FloatGeometry.drop(at: point, in: layout.bounds, panes: layout.targets, dragged: pane, floatTarget: floatTarget)
        let preview = FloatGeometry.preview(of: drop, in: layout.bounds, panes: layout.targets)
        untracked {
            if paneDrag == nil, let tab = workspace.session.tab(containing: pane), tab.focused != pane { workspace.apply(.focus(pane)) }
            paneDrag = PaneDrag(pane: pane, point: point, drop: paneDrag?.drop ?? drop, preview: paneDrag?.preview ?? preview)
        }
        guard paneDrag?.drop != drop else { return }
        withAnimation(DS.Motion.menu) {
            paneDrag?.drop = drop
            paneDrag?.preview = preview
        }
    }

    func endDrag(_ pane: PaneId, at point: CGPoint) {
        guard let drag = paneDrag, let layout, let workspace else {
            paneDrag = nil
            return
        }
        let drop = drag.drop
        TerminalSurface.holdGrids(for: .milliseconds(Int(DS.Motion.liftDuration * 1000)))
        withAnimation(DS.Motion.lift) {
            paneDrag = nil
            landing = drag.preview
            landingPane = drag.preview == nil ? nil : layout.leaves.first { $0.pane == pane }.map { (pane, $0.frame) }
            switch drop {
            case .beside(let target, let side):
                workspace.apply(.movePane(pane, beside: target, side: side))
            case .edge(let side):
                if let tab = workspace.session.activeTab?.id { workspace.apply(.movePaneToEdge(pane, tab: tab, side: side)) }
            case .float:
                // Where it was let go: a window centred there, two fifths of the tab.
                let size = CGSize(width: layout.bounds.width * 0.42, height: layout.bounds.height * 0.46)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - 16, width: size.width, height: size.height)
                if workspace.canToggleFloat(pane) || workspace.session.isFloating(pane) {
                    workspace.apply(.float(pane, frame: FloatFrame(rect, in: layout.bounds).clamped))
                }
            case .cancel:
                break
            }
        }
        // A host answers a move a round trip later: the region stays lit until the pane
        // arrives there (`update`), or this long at most.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(DS.Motion.overlay) { self?.landing = nil }
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
        let f = card.frame
        ZStack(alignment: .topLeading) {
            handle([.left], CGRect(x: f.minX - edge / 2, y: f.minY + corner / 2, width: edge, height: max(0, f.height - corner)))
            handle([.right], CGRect(x: f.maxX - edge / 2, y: f.minY + corner / 2, width: edge, height: max(0, f.height - corner)))
            handle([.top], CGRect(x: f.minX + corner / 2, y: f.minY - edge / 2, width: max(0, f.width - corner), height: edge))
            handle([.bottom], CGRect(x: f.minX + corner / 2, y: f.maxY - edge / 2, width: max(0, f.width - corner), height: edge))
            handle([.left, .top], CGRect(x: f.minX - corner / 2, y: f.minY - corner / 2, width: corner, height: corner))
            handle([.right, .top], CGRect(x: f.maxX - corner / 2, y: f.minY - corner / 2, width: corner, height: corner))
            handle([.left, .bottom], CGRect(x: f.minX - corner / 2, y: f.maxY - corner / 2, width: corner, height: corner))
            handle([.right, .bottom], CGRect(x: f.maxX - corner / 2, y: f.maxY - corner / 2, width: corner, height: corner))
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
