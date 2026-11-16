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
        /// Where it is drawn when that is not its frame: on its way from its last frame, or
        /// (leaving) to the sliver it shrinks to. It stays laid out at `frame`.
        var shown: CGRect?
        /// Closed or moved away: drawn as its still while it goes.
        var departing = false
        /// How far down its terminal starts (its header), as drawn: part way while headers
        /// come or go.
        var header: CGFloat = 0

        var shownFrame: CGRect { shown ?? frame }
        var opacity: Double { fade ?? (visible ? 1 : 0) }
        var scale: CGFloat { hiddenScale + (1 - hiddenScale) * (growth ?? (visible ? 1 : 0)) }
    }

    struct Divider {
        let id: String
        var divider: SplitLayout.Divider
        let z: Double
        let visible: Bool
        /// Where its line is drawn when that is not its frame (see `Leaf.shown`).
        var shown: CGRect?
        /// Gone from the layout: it travels with its edge and fades.
        var departing = false
        var fade: Double?

        var shownFrame: CGRect { shown ?? divider.frame }
        var opacity: Double { fade ?? (departing ? 0 : (visible ? 1 : 0)) }
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
                hiddenScale: 1, hiddenAnchor: .center, header: headers ? header : 0))
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
                    hiddenScale: scale, hiddenAnchor: Self.anchor(anchor, of: rect, in: leaf.frame), header: header))
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

    /// A tiled pane drawn over its neighbours: the one just unzoomed, shrinking back onto them.
    mutating func raise(_ pane: PaneId?) {
        guard let pane, let index = leaves.firstIndex(where: { $0.pane == pane && $0.window == nil }) else { return }
        leaves[index].z = Self.zoomZ
    }

    /// `panes` go over the tiled panes and their dividers while they dock, and the dividers
    /// beside them wait for them: the card lands whole, and its slot's line shows as it does.
    mutating func dock(_ panes: Set<PaneId>) {
        guard !panes.isEmpty else { return }
        for index in leaves.indices where panes.contains(leaves[index].pane) && leaves[index].window == nil {
            leaves[index].z = Self.zoomZ
        }
        for index in dividers.indices where !dividers[index].departing {
            let line = dividers[index].divider
            if panes.contains(line.leadingSide) || panes.contains(line.next) { dividers[index].fade = 0 }
        }
    }

    /// `panes` go under the other tiled panes, which uncover them as they make room.
    mutating func lower(_ panes: Set<PaneId>) {
        for index in leaves.indices where panes.contains(leaves[index].pane) && leaves[index].window == nil {
            leaves[index].z = -1
        }
    }

    /// Adds `motion`'s departing panes and dividers, each heading for where it goes: laid out
    /// where they were, shown shrinking to their sliver.
    mutating func depart(_ motion: CanvasMotion) {
        for departure in motion.departures where leaf(departure.leaf.pane) == nil {
            let old = departure.leaf
            leaves.append(Leaf(
                pane: old.pane, frame: old.frame, z: old.z - 0.5, radii: old.radii, window: old.window, lifted: old.lifted,
                focusedWindow: old.focusedWindow, visible: false, hiddenScale: 1, hiddenAnchor: .center,
                shown: departure.collapse, departing: true, header: old.header))
        }
        for departure in motion.departingDividers where !dividers.contains(where: { $0.id == departure.divider.id }) {
            var divider = departure.divider
            divider.shown = departure.target
            divider.departing = true
            dividers.append(divider)
        }
    }

    /// The header above a leaf's terminal, when it has one.
    func headerHeight(of leaf: Leaf) -> CGFloat {
        metrics.headers || leaf.window != nil ? metrics.header : 0
    }

    /// The terminal's part of a leaf: its frame less the pane header.
    func terminalSize(of leaf: Leaf) -> CGSize {
        CGSize(width: leaf.frame.width, height: max(0, leaf.frame.height - headerHeight(of: leaf)))
    }

    /// The canvas `session`'s active tab gets at this layout's size: what an op would lead to.
    /// `size`: the canvas's size when it is about to change (the sidebar coming or going).
    init?(session: Session, like layout: CanvasLayout, size: CGSize? = nil) {
        guard let tab = session.activeTab else { return nil }
        let metrics = layout.metrics
        self.init(
            node: session.tiledRoot(of: tab) ?? tab.root, floats: FloatScene(session: session, tab: tab, hidden: layout.floatsHidden),
            zoomed: tab.zoomed, focused: tab.focused, size: size ?? layout.bounds.size, gap: metrics.gap, header: metrics.header, cell: metrics.cell,
            padding: metrics.padding, headers: metrics.headers)
    }

    /// Each pane where it is and whether it shows: two layouts that draw the panes alike.
    func placesPanes(like other: CanvasLayout) -> Bool {
        leaves.count == other.leaves.count && leaves.allSatisfy { leaf in
            other.leaf(leaf.pane).map { $0.frame == leaf.frame && $0.visible == leaf.visible && $0.window == leaf.window } ?? false
        }
    }

    /// This layout `progress` of the way from `from` (0) to here (1), as an animation between
    /// the two draws it: every pane laid out where it is going and shown on its way, new ones
    /// growing in, closed ones shrinking out, what appears or goes fading. For design review,
    /// where a window off every display gets no animation frames.
    func blended(from: CanvasLayout, progress t: Double) -> CanvasLayout {
        let motion = CanvasMotion(from: from, to: self)
        var out = self
        out.depart(motion)
        out.leaves = out.leaves.map { leaf in
            var leaf = leaf
            if leaf.departing, let departure = motion.departures.first(where: { $0.leaf.pane == leaf.pane }) {
                leaf.shown = CanvasMotion.mix(departure.leaf.frame, departure.collapse, t)
                leaf.fade = 1 - t
            } else if let old = from.leaves.first(where: { $0.pane == leaf.pane }) {
                leaf.shown = CanvasMotion.mix(old.frame, leaf.frame, t)
                leaf.header = old.header + (leaf.header - old.header) * t
                // As drawn: solid while it shrinks, fading at the end; solid at once coming back.
                let going = leaf.opacity < old.opacity
                leaf.fade = old.opacity + (leaf.opacity - old.opacity) * (going ? t * t : 1 - (1 - t) * (1 - t))
                let (from, to): (Double, Double) = (old.visible ? 1 : 0, leaf.visible ? 1 : 0)
                leaf.growth = from + (to - from) * t
            } else if let seed = motion.seeds[leaf.pane] {
                leaf.shown = CanvasMotion.mix(seed, leaf.frame, t)
            }
            return leaf
        }
        out.cards = cards.map { card in
            var card = card
            if let old = from.card(card.id) {
                card.frame = CanvasMotion.mix(old.frame, card.frame, t)
                card.fade = old.opacity + (card.opacity - old.opacity) * t
            }
            return card
        }
        out.dividers = out.dividers.map { divider in
            var divider = divider
            if divider.departing, let departure = motion.departingDividers.first(where: { $0.divider.id == divider.id }) {
                divider.shown = CanvasMotion.mix(departure.divider.divider.frame, departure.target, t)
                divider.fade = 1 - t * t
            } else if let old = from.dividers.first(where: { $0.id == divider.id }) {
                divider.shown = CanvasMotion.mix(old.divider.frame, divider.divider.frame, t)
            } else if let seed = motion.dividerSeeds[divider.id] {
                divider.shown = CanvasMotion.mix(seed, divider.divider.frame, t)
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

/// What a terminal has drawn so far: a count of its frames, and a picture of the latest.
struct DrawnFrame {
    let generation: Int
    let image: () -> CGImage?
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

    /// Panes drawn as a still of their last frame while a layout motion moves them: a picture
    /// travels and fades with the motion, crisp, and the terminal under it reflows once.
    @ObservationIgnored private var stills: [PaneId: CGImage] = [:]
    /// The layout motion under way (not observed: its end is, through `settledVersion`).
    @ObservationIgnored private(set) var motion = CanvasMotion.none
    /// The pane drawn over the others while it moves (one shrinking back from a zoom).
    @ObservationIgnored private(set) var raised: PaneId?
    @ObservationIgnored private(set) var isMoving = false
    @ObservationIgnored private var motionGeneration = 0
    /// Bumped when a layout motion settles: the stills give way to the terminals, departing
    /// panes go, and a zoomed pane's shadow fades.
    private(set) var settledVersion = 0
    /// Bumped when an arriving pane's terminal draws a frame, which shows as its still.
    private(set) var arrivalsDrawn = 0

    func still(of pane: PaneId) -> CGImage? { stills[pane] }
    /// The pane moves over its still or arrives: its live terminal waits until the motion settles.
    func hidesTerminal(of pane: PaneId) -> Bool { stills[pane] != nil || motion.seeds[pane] != nil }

    /// A pane header as it last showed: a closed pane goes with it.
    struct HeaderStill: Equatable {
        let headline: PaneHeadline
        let isFocused: Bool
    }

    @ObservationIgnored private var headers: [PaneId: HeaderStill] = [:]

    func remember(_ header: HeaderStill, of pane: PaneId) { headers[pane] = header }
    func header(of pane: PaneId) -> HeaderStill? { headers[pane] }
    /// The least time stills stand in (a capture keeps them longer).
    static var stillDuration = DS.Motion.structuralSettle
    /// Stretches how long a layout motion may take to settle (design review draws it slowly).
    static var settleStretch = 1.0

    /// A layout motion starts for `seconds`: stills of the panes it moves (`image` draws one;
    /// `departed` gives a closed pane's last frame), and what it raises. A motion that starts
    /// while another runs carries on from it.
    ///
    /// `holding` tells whether a pane's terminal still shows its held frame (its program's
    /// redraw has not come in): its still waits for it, so the crossfade never reveals a frame
    /// that is about to jump. `drawn` gives what an arriving pane's terminal has drawn so far:
    /// each frame shows as its still while it arrives, so its prompt comes in with it.
    func begin(
        _ motion: CanvasMotion, in layout: CanvasLayout, raising: PaneId?, for seconds: Double,
        image: (PaneId) -> CGImage?, departed: (PaneId) -> CGImage?,
        holding: @escaping (PaneId) -> Bool = { _ in false },
        drawn: @escaping (PaneId) -> DrawnFrame? = { _ in nil }
    ) {
        for pane in motion.moving where stills[pane] == nil {
            if let still = image(pane) { stills[pane] = still }
        }
        for departure in motion.departures where stills[departure.leaf.pane] == nil {
            if let still = departed(departure.leaf.pane) { stills[departure.leaf.pane] = still }
        }
        self.motion = isMoving ? motion.continuing(self.motion, in: layout) : motion
        raised = raising
        isMoving = true
        motionGeneration += 1
        let generation = motionGeneration
        if !self.motion.seeds.isEmpty { showArrivals(drawn, until: generation) }
        let length = max(seconds, Self.stillDuration)
        Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(Int(length * 1000)))
            let latest = start + .milliseconds(Int(length * 1000)) + TerminalSurface.redrawWait
            while let self, self.motionGeneration == generation, ContinuousClock.now < latest,
                  self.redrawing.contains(where: holding) {
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard let self, self.motionGeneration == generation else { return }
            self.settle()
        }
    }

    /// The panes whose live terminal the motion hides.
    private var redrawing: [PaneId] { Array(stills.keys) + Array(motion.seeds.keys) }

    /// Each frame an arriving pane's terminal draws becomes its still at once, until motion
    /// `generation` is over: a new pane shows its first frame on its way in, never only its
    /// background until it lands.
    private func showArrivals(_ drawn: @escaping (PaneId) -> DrawnFrame?, until generation: Int) {
        Task { @MainActor [weak self] in
            var shown: [PaneId: Int] = [:]
            while let self, self.motionGeneration == generation, self.isMoving {
                var changed = false
                for pane in self.motion.seeds.keys {
                    guard let frame = drawn(pane), frame.generation != shown[pane], let image = frame.image() else { continue }
                    shown[pane] = frame.generation
                    self.stills[pane] = image
                    changed = true
                }
                if changed { self.untracked { self.arrivalsDrawn += 1 } }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    /// The motion is at rest and the terminals have drawn: each still crossfades to its live
    /// terminal.
    private func settle() {
        for departure in motion.departures { headers[departure.leaf.pane] = nil }
        if let layout { headers = headers.filter { pane, _ in layout.leaf(pane).map { !$0.departing } ?? false } }
        stills.removeAll()
        motion = .none
        raised = nil
        isMoving = false
        withAnimation(DS.Motion.micro) { settledVersion += 1 }
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
        withAnimation(DS.Motion.structural) { preview = nil }
        withAnimation(DS.Motion.standard) { landing = nil }
        // Panes the preview held go to where the layout has them.
        if let layout { prepareTerminals(for: layout, within: DS.Motion.structuralSettle) }
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

    /// The canvas is about to grow by `change` (shrinking when negative): the sidebar comes or
    /// goes, with the tab strip. Each terminal's grid changes once, now, for where it is going,
    /// so its program has redrawn by the time the slide settles, and its last frame shows until
    /// then.
    func prepareTerminals(resizingCanvasBy change: CGSize, within duration: Double) {
        guard let layout, let session = workspace?.session else { return }
        let size = CGSize(width: layout.bounds.width + change.width, height: layout.bounds.height + change.height)
        guard let target = CanvasLayout(session: session, like: layout, size: size) else { return }
        prepareTerminals(for: target, within: duration)
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
            TerminalSurface.holdGrids(for: .milliseconds(Int(DS.Motion.structuralSettle * 1000)))
            withAnimation(DS.Motion.structural) {
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
        withAnimation(DS.Motion.structural) {
            live[id] = nil
            guides = []
            dockPreview = nil
            workspace.apply(.setFloat(pane, frame: FloatFrame(rest, in: layout.bounds), minimized: nil, pinned: nil))
        }
    }

    private func clear(_ id: FloatId) {
        withAnimation(DS.Motion.structural) {
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
        if dockPreview != nil { withAnimation(DS.Motion.standard) { dockPreview = nil } }
        dockDrop = nil
        guard drop != .cancel, drop != .float else { return }
        dwell = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled, let self, let op = self.op(placing: pane, drop, docking: true),
                  let frame = self.outcome(of: op)?.leaf(pane)?.frame else { return }
            self.dockDrop = drop
            withAnimation(DS.Motion.standard) { self.dockPreview = frame }
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
        withAnimation(DS.Motion.structural) {
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
        withAnimation(DS.Motion.standard) {
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
        TerminalSurface.holdGrids(for: .milliseconds(Int(DS.Motion.structuralSettle * 1000)))
        withAnimation(DS.Motion.structural) {
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
    /// Washes a pane while it is being dragged. Its look as a window (`TravelChrome`) is drawn
    /// where it travels.
    func floatingChrome(_ leaf: CanvasLayout.Leaf, dragging: Bool) -> some View {
        modifier(FloatingChrome(leaf: leaf, dragging: dragging))
    }
}

extension View {
    /// The beat of a pane leaving its tab or rejoining it: lifted towards you as it floats,
    /// pressed in for a moment as it docks, in step with the frame's spring.
    func liftBeat(floating: Bool, anchor: UnitPoint = .center) -> some View {
        modifier(LiftBeat(floating: floating, anchor: anchor))
    }
}

struct LiftBeat: ViewModifier {
    let floating: Bool
    let anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: floating) { content, scale in
            content.scaleEffect(reduceMotion ? 1 : scale, anchor: anchor)
        } keyframes: { _ in
            Self.keyframes(floating: floating)
        }
    }

    /// Towards you (or pressed in) on `micro`, back to 1 on `structural`, at rest by
    /// `structuralSettle` with the frame's spring.
    @KeyframesBuilder<CGFloat>
    static func keyframes(floating: Bool) -> some Keyframes<CGFloat> {
        KeyframeTrack {
            SpringKeyframe(floating ? 1.03 : 0.985, duration: DS.Motion.arrivalDelay, spring: DS.Motion.Role.micro.spring)
            SpringKeyframe(1, duration: DS.Motion.structuralSettle - DS.Motion.arrivalDelay, spring: DS.Motion.Role.structural.spring)
        }
    }
}

private struct FloatingChrome: ViewModifier {
    let leaf: CanvasLayout.Leaf
    let dragging: Bool

    func body(content: Content) -> some View {
        content
            // An overlay, as the terminal's layer draws itself.
            .overlay {
                if dragging {
                    UnevenRoundedRectangle(cornerRadii: leaf.radii, style: .continuous)
                        .fill(DS.Palette.veil)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The card under a window of several panes: their gaps in the divider colour, the grip that
/// moves it, a window's surface.
struct FloatCardBackdrop: View {
    let card: CanvasLayout.Card
    @Environment(PaneArrangement.self) private var arrangement
    @Environment(\.terminalTheme) private var theme

    var body: some View {
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
            .surface(shown ? .window : .tile, in: shape)
            .overlay {
                shape
                    .strokeBorder(DS.Palette.accent, lineWidth: 1)
                    .opacity(card.focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(ResizeZones.window(card.frame).enumerated()), id: \.offset) { _, handle in
                self.handle(handle.edges, handle.zone)
            }
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
                    .fill(DS.Palette.accent)
                    .frame(
                        width: guide.axis == .vertical ? 1 : guide.to - guide.from,
                        height: guide.axis == .vertical ? guide.to - guide.from : 1)
                    .offset(
                        x: guide.axis == .vertical ? guide.position - 0.5 : guide.from,
                        y: guide.axis == .vertical ? guide.from : guide.position - 0.5)
                    .motionTransition(.fade)
            }
            if let region = arrangement.dockPreview ?? arrangement.paneDrag?.preview ?? arrangement.landing {
                DropRegion(rect: region)
            }
            if let drag = arrangement.paneDrag, let workspace = arrangement.workspace {
                if workspace.canFloat {
                    FloatTarget(lit: drag.drop == .float)
                        .frame(width: layout.floatTarget.width, height: layout.floatTarget.height)
                        .offset(x: layout.floatTarget.minX, y: layout.floatTarget.minY)
                        .motionTransition(.pill())
                }
                DragChip(pane: drag.pane, workspace: workspace)
                    .fixedSize()
                    .position(x: drag.point.x + 12, y: drag.point.y + 18)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: layout.bounds.width, height: layout.bounds.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(DS.Motion.standard, value: arrangement.guides)
        .animation(DS.Motion.standard, value: arrangement.paneDrag == nil)
    }
}

/// The region a drop gives a pane: the accent at a quarter, its rim, inset like a pane.
private struct DropRegion: View {
    let rect: CGRect

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.pane, style: .continuous)
        shape
            .fill(DS.Palette.accentDim)
            .overlay(shape.strokeBorder(DS.Palette.accent, lineWidth: 1.5))
            .frame(width: max(0, rect.width - 2 * DS.Space.xs), height: max(0, rect.height - 2 * DS.Space.xs))
            .offset(x: rect.minX + DS.Space.xs, y: rect.minY + DS.Space.xs)
            .motionTransition(.fade)
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
            .animation(DS.Motion.micro, value: lit)
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
            ProgramTile(program)
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
                        .motionTransition(.pill(anchor: .bottomTrailing))
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
        let state = AgentState.mostUrgent(chip.panes.compactMap { model.agentState(ofPane: $0, onGroup: workspace.groupId) })
        Button {
            withAnimation(DS.Motion.structural) { workspace.apply(.focus(pane)) }
            TerminalSurface.holdGrids(for: .milliseconds(Int(DS.Motion.structuralSettle * 1000)))
        } label: {
            HStack(spacing: DS.Space.row) {
                ProgramTile(program, state: state)
                Text(program.isShell ? workspace.programName(of: pane) : program.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DS.Palette.text)
                    .lineLimit(1)
                if chip.panes.count > 1 {
                    Text("+\(chip.panes.count - 1)")
                        .monospacedDigit()
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                if let state { StatePill(state) }
            }
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .floatingCapsule(interactive: true)
        .scaleEffect(hovered ? 1.03 : 1)
        .animation(DS.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
        .help("Restore \(program.displayName)")
        .contextMenu {
            Button("Restore", systemImage: "arrow.up.left.and.arrow.down.right") { withAnimation(DS.Motion.structural) { workspace.apply(.focus(pane)) } }
            Button("Dock Pane", systemImage: "rectangle.inset.filled.and.person.filled") { model.dock(pane, in: workspace) }
            Divider()
            Button("Close Pane", systemImage: "xmark", role: .destructive) { workspace.apply(.close(pane)) }
        }
        .accessibilityLabel("\(program.displayName), in the tray")
        .accessibilityHint("Restores the floating window")
        .accessibilityIdentifier("float-tray-chip")
    }
}
