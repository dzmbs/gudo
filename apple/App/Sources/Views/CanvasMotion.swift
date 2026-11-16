import DesignSystem
import PaneLayout
import SwiftUI

/// How a canvas moves from one layout to the next. Every pane is laid out once, at its new
/// frame; what moves is the rectangle it is shown in (`Leaf.shown`), from where it was to where
/// it is going, as an offset and a clip over a still of its last frame. A new pane grows in
/// from the edge it splits from while its neighbours make room; a closed one is squeezed out by
/// the neighbours taking its space, and fades.
struct CanvasMotion {
    /// A pane that left the canvas, drawn as its still while it goes.
    struct Departure {
        let leaf: CanvasLayout.Leaf
        /// The sliver it shrinks to, at the edge away from the panes taking its space.
        let collapse: CGRect
    }

    /// A divider that left the canvas, travelling with the edge it was on.
    struct DividerDeparture {
        let divider: CanvasLayout.Divider
        let target: CGRect
    }

    /// Panes that move or resize: each travels over a still of its last frame.
    private(set) var moving: Set<PaneId> = []
    /// Panes going from a window of their own back into the tree.
    private(set) var docking: Set<PaneId> = []
    /// Panes lifting out of the tree into a window, or docking back: they change shape on the
    /// way, so their stills scale with them.
    private(set) var changingLayer: Set<PaneId> = []
    /// New panes, and the sliver each grows from.
    private(set) var seeds: [PaneId: CGRect] = [:]
    private(set) var departures: [Departure] = []
    /// New dividers that start where the edge they sit on was.
    private(set) var dividerSeeds: [String: CGRect] = [:]
    private(set) var departingDividers: [DividerDeparture] = []

    static let none = CanvasMotion()

    private init() {}

    init(from before: CanvasLayout, to after: CanvasLayout) {
        for leaf in after.leaves {
            if let old = before.leaf(leaf.pane) {
                let shows = old.visible || leaf.visible
                if shows, old.frame != leaf.frame || old.window != leaf.window || old.visible != leaf.visible {
                    moving.insert(leaf.pane)
                }
                if old.window != nil, leaf.window == nil { docking.insert(leaf.pane) }
                if (old.window == nil) != (leaf.window == nil) { changingLayer.insert(leaf.pane) }
            } else if leaf.visible {
                let givers = before.leaves.filter { $0.visible && $0.window == leaf.window && $0.frame.intersects(leaf.frame) }
                seeds[leaf.pane] = Self.edge(of: leaf.frame, awayFrom: givers.map(\.frame))
            }
        }
        for old in before.leaves where old.visible && after.leaf(old.pane) == nil {
            let takers = after.leaves.filter { $0.visible && $0.window == old.window && $0.frame.intersects(old.frame) }
            departures.append(Departure(leaf: old, collapse: Self.edge(of: old.frame, awayFrom: takers.map(\.frame))))
        }

        let collapses = Dictionary(departures.map { ($0.leaf.pane, $0.collapse) }, uniquingKeysWith: { first, _ in first })
        func start(_ pane: PaneId) -> CGRect? { before.leaf(pane)?.frame ?? seeds[pane] }
        func end(_ pane: PaneId) -> CGRect? { after.leaf(pane)?.frame ?? collapses[pane] }
        for divider in after.dividers where !before.dividers.contains(where: { $0.id == divider.id }) {
            guard let first = start(divider.divider.leadingSide) else { continue }
            let seed = Self.line(divider.divider, at: first)
            if seed != divider.divider.frame { dividerSeeds[divider.id] = seed }
        }
        for divider in before.dividers where divider.visible && !after.dividers.contains(where: { $0.id == divider.id }) {
            guard let first = end(divider.divider.leadingSide) else { continue }
            departingDividers.append(DividerDeparture(divider: divider, target: Self.line(divider.divider, at: first)))
        }
    }

    /// This motion, carrying on with what `earlier` still had going: panes and dividers that
    /// left then and have not come back keep going, and panes still arriving keep arriving.
    func continuing(_ earlier: CanvasMotion, in after: CanvasLayout) -> CanvasMotion {
        var merged = self
        merged.docking.formUnion(earlier.docking.filter { after.leaf($0)?.window == nil })
        merged.changingLayer.formUnion(earlier.changingLayer.filter { after.leaf($0) != nil })
        for (pane, seed) in earlier.seeds where merged.seeds[pane] == nil && after.leaf(pane)?.visible == true {
            merged.seeds[pane] = seed
        }
        let gone = Set(departures.map(\.leaf.pane))
        merged.departures += earlier.departures.filter { after.leaf($0.leaf.pane) == nil && !gone.contains($0.leaf.pane) }
        let goneDividers = Set(departingDividers.map(\.divider.id))
        merged.departingDividers += earlier.departingDividers.filter { departing in
            !goneDividers.contains(departing.divider.id) && !after.dividers.contains { $0.id == departing.divider.id }
        }
        return merged
    }

    /// `divider`'s line moved along its axis to the trailing edge of `first`, the rectangle of
    /// the pane before it.
    private static func line(_ divider: SplitLayout.Divider, at first: CGRect) -> CGRect {
        var line = divider.frame
        if divider.axis == .horizontal { line.origin.x = first.maxX } else { line.origin.y = first.maxY }
        return line
    }

    /// The sliver of `rect` along the edge farthest from `others` (the panes it takes space
    /// from, or gives it to): a new pane grows from there and a closed one shrinks to there, so
    /// it always meets its neighbours. Between neighbours on both sides, its middle; with none,
    /// its centre.
    static func edge(of rect: CGRect, awayFrom others: [CGRect]) -> CGRect {
        guard !others.isEmpty else { return CGRect(x: rect.midX, y: rect.midY, width: 0, height: 0) }
        let centre = CGPoint(
            x: others.map(\.midX).reduce(0, +) / CGFloat(others.count),
            y: others.map(\.midY).reduce(0, +) / CGFloat(others.count))
        let dx = centre.x - rect.midX, dy = centre.y - rect.midY
        let spreadX = (others.map(\.midX).max() ?? 0) - (others.map(\.midX).min() ?? 0)
        let spreadY = (others.map(\.midY).max() ?? 0) - (others.map(\.midY).min() ?? 0)
        let level = abs(dx) < 1 && abs(dy) < 1
        let horizontal = level ? spreadX >= spreadY : abs(dx) / max(rect.width, 1) >= abs(dy) / max(rect.height, 1)
        if horizontal {
            let x = abs(dx) < 1 ? rect.midX : (dx < 0 ? rect.maxX : rect.minX)
            return CGRect(x: x, y: rect.minY, width: 0, height: rect.height)
        }
        let y = abs(dy) < 1 ? rect.midY : (dy < 0 ? rect.maxY : rect.minY)
        return CGRect(x: rect.minX, y: y, width: rect.width, height: 0)
    }

    /// `from` `progress` of the way to `to`.
    static func mix(_ from: CGRect, _ to: CGRect, _ progress: Double) -> CGRect {
        let t = CGFloat(progress)
        return CGRect(
            x: from.minX + (to.minX - from.minX) * t, y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t)
    }
}

extension SplitLayout.Divider {
    /// The pane on the divider's leading side.
    var leadingSide: PaneId { first.trailingPane(along: axis) }
}

// MARK: - Drawing a pane on its way

/// Draws a view laid out at `frame` within `shown`, the rectangle it travels through: moved so
/// its top-left corner rides `shown`'s, cut to `shown`, on `background` where it does not
/// reach, under `still` while it has one (at its own size, or with `scalesStill` scaled to fit
/// `shown` whole). Only `shown` animates, so nothing inside lays out again on the way. Under
/// Reduce Motion it stays at `frame`: a change only crossfades.
struct PaneTravel: ViewModifier, Animatable {
    var shown: CGRect
    let frame: CGRect
    var still: CGImage?
    /// The still keeps its proportions and fits `shown`: for a pane changing shape (lifting into
    /// a window, docking back), whose still at its own size would be cut off or left short.
    var scalesStill = false
    /// How far down the pane its terminal starts (its header): it travels too, so headers
    /// arriving on a first split make room in the spring.
    var stillTop: CGFloat = 0
    var background: Color?
    var radius: CGFloat = 0
    /// A pane that is a window of its own, or on its way into or out of one.
    var chrome: TravelChrome?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(shown.animatableData, stillTop) }
        set {
            shown.animatableData = newValue.first
            stillTop = newValue.second
        }
    }

    /// Where the content goes on one frame of the motion: its offset from the canvas origin and
    /// the part of it that shows, in its own space. It keeps `frame`'s size throughout.
    static func placement(frame: CGRect, shown: CGRect) -> (offset: CGSize, clip: CGRect) {
        (CGSize(width: shown.minX, height: shown.minY), CGRect(origin: .zero, size: shown.size))
    }

    /// The scale that fits a still of `still` points whole into `shown`: 1 within a pixel of its
    /// own size, so it is crisp where the motion starts.
    static func stillScale(still: CGSize, shown: CGSize) -> CGFloat {
        guard still.width > 0, still.height > 0 else { return 1 }
        let scale = min(shown.width / still.width, shown.height / still.height)
        return abs(scale - 1) * max(still.width, still.height) < 1 ? 1 : max(scale, 0)
    }

    func body(content: Content) -> some View {
        let place = Self.placement(frame: frame, shown: reduceMotion ? frame : shown)
        let shape = TravelShape(rect: place.clip, radius: radius, corners: chrome?.radii)
        content
            .background(alignment: .topLeading) {
                if let background { shape.fill(background) }
            }
            .overlay(alignment: .topLeading) {
                if let still {
                    let size = CGSize(width: CGFloat(still.width) / displayScale, height: CGFloat(still.height) / displayScale)
                    let room = CGSize(width: place.clip.width, height: max(0, place.clip.height - stillTop))
                    let scale = scalesStill ? Self.stillScale(still: size, shown: room) : 1
                    Image(decorative: still, scale: displayScale)
                        .resizable()
                        .frame(width: size.width * scale, height: size.height * scale)
                        .padding(.top, stillTop)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        // Whole on the frame the terminal hides, and gone on the frame it shows:
                        // faded in, the pane would be blank for a frame; faded out, it would
                        // show two prompts while the redrawn terminal fades in under it.
                        .transition(.identity)
                }
            }
            .clipShape(shape)
            .background(alignment: .topLeading) {
                if let chrome { TravelChromeBackdrop(chrome: chrome).frame(width: place.clip.width, height: place.clip.height) }
            }
            .overlay(alignment: .topLeading) {
                if let chrome { TravelChromeRing(chrome: chrome).frame(width: place.clip.width, height: place.clip.height) }
            }
            .offset(place.offset)
    }
}

/// A floating pane's look as a window: lifted (its edges and shadow) and, while its window has
/// the focus, the accent ring. Drawn on the rectangle the pane travels through, so both stay
/// whole on every frame of a move, and fade (never switch) as it lifts out or docks.
struct TravelChrome: Equatable {
    var radii: RectangleCornerRadii
    var lifted: Bool
    var focused: Bool
}

private struct TravelChromeBackdrop: View {
    let chrome: TravelChrome

    var body: some View {
        Color.clear
            .surface(.window, in: UnevenRoundedRectangle(cornerRadii: chrome.radii, style: .continuous))
            .opacity(chrome.lifted ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TravelChromeRing: View {
    let chrome: TravelChrome

    var body: some View {
        UnevenRoundedRectangle(cornerRadii: chrome.radii, style: .continuous)
            .strokeBorder(DS.Palette.accent, lineWidth: 1)
            .opacity(chrome.lifted && chrome.focused ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A new pane or divider arriving: on its first frame it is shown in `seed`, the sliver at the
/// edge it splits from, and its own `PaneTravel` takes it to where it is laid out in the
/// structural spring the panes making room move in. Solid from that first frame, its content
/// riding its leading corner, so a new pane shows its header and background at once whichever
/// way it splits. Under Reduce Motion a pane fades in where it lands (a line is there at once).
/// Once there it is a pane like any other, so a later move is not cut to where it arrived.
struct ArrivingTravel: ViewModifier {
    let seed: CGRect?
    let travel: PaneTravel
    var fades = true
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let arriving = !landed && seed != nil
        content
            .modifier(Self.travel(travel, seed: arriving ? seed : nil))
            .opacity(arriving && fades && reduceMotion ? 0 : 1)
            .onAppear {
                if seed == nil {
                    landed = true
                } else {
                    withAnimation(DS.Motion.structural) { landed = true }
                }
            }
    }

    /// Where it is drawn: in `seed` until it sets off.
    static func travel(_ travel: PaneTravel, seed: CGRect?) -> PaneTravel {
        var travel = travel
        if let seed { travel.shown = seed }
        return travel
    }
}

/// A rectangle at a given place, whatever the bounds it is drawn in.
nonisolated private struct TravelShape: Shape {
    var rect: CGRect
    let radius: CGFloat
    var corners: RectangleCornerRadii?

    func path(in _: CGRect) -> Path {
        if let corners { return UnevenRoundedRectangle(cornerRadii: corners, style: .continuous).path(in: rect) }
        return radius > 0 ? Path(roundedRect: rect, cornerRadius: radius, style: .continuous) : Path(rect)
    }
}
