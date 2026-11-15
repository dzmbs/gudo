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
/// reach, under `still` while it has one. Only `shown` animates, so nothing inside lays out
/// again on the way. Under Reduce Motion it stays at `frame`: a change only crossfades.
struct PaneTravel: ViewModifier, Animatable {
    var shown: CGRect
    let frame: CGRect
    var still: CGImage?
    /// How far down the pane its terminal starts (its header): it travels too, so headers
    /// arriving on a first split make room in the spring.
    var stillTop: CGFloat = 0
    var background: Color?
    var radius: CGFloat = 0
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

    func body(content: Content) -> some View {
        let place = Self.placement(frame: frame, shown: reduceMotion ? frame : shown)
        let shape = TravelShape(rect: place.clip, radius: radius)
        content
            .background(alignment: .topLeading) {
                if let background { shape.fill(background) }
            }
            .overlay(alignment: .topLeading) {
                if let still {
                    Image(decorative: still, scale: displayScale)
                        .padding(.top, stillTop)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(shape)
            .offset(place.offset)
    }
}

/// A new pane or divider arriving: it grows out of `seed` into `frame` (where its own
/// `PaneTravel` already draws it), solid from its first frame, so the edge it comes in at shows
/// at once whichever way it splits. Under Reduce Motion a pane fades in where it lands (a line
/// is there at once). At rest it leaves the view alone, so a later move of the pane is not cut
/// to where it arrived.
struct ArrivalTransition: Transition {
    let seed: CGRect?
    let frame: CGRect
    var fades = true

    func body(content: Content, phase: TransitionPhase) -> some View {
        let away = seed.map { CGRect(x: $0.minX - frame.minX, y: $0.minY - frame.minY, width: $0.width - frame.width, height: $0.height - frame.height) }
        return content.modifier(ArrivalEffect(
            change: phase.isIdentity ? .zero : (away ?? .zero), frame: frame,
            opacity: phase.isIdentity || !fades ? 1 : 0))
    }
}

private struct ArrivalEffect: ViewModifier, Animatable {
    /// How far the shown rectangle is from `frame`: its origin's offset and its size's change.
    var change: CGRect
    let frame: CGRect
    var opacity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: AnimatablePair<CGRect.AnimatableData, Double> {
        get { AnimatablePair(change.animatableData, opacity) }
        set {
            change.animatableData = newValue.first
            opacity = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let change = reduceMotion ? .zero : change
        let atRest = abs(change.minX) < 0.01 && abs(change.minY) < 0.01 && abs(change.width) < 0.01 && abs(change.height) < 0.01
        let clip = atRest
            ? frame.insetBy(dx: -frame.width - 10_000, dy: -frame.height - 10_000)
            : CGRect(origin: frame.origin, size: CGSize(width: max(0, frame.width + change.width), height: max(0, frame.height + change.height)))
        content
            .clipShape(TravelShape(rect: clip, radius: 0))
            .offset(x: change.minX, y: change.minY)
            .opacity(reduceMotion ? opacity : 1)
    }
}

/// A rectangle at a given place, whatever the bounds it is drawn in.
nonisolated private struct TravelShape: Shape {
    var rect: CGRect
    let radius: CGFloat

    func path(in _: CGRect) -> Path {
        radius > 0 ? Path(roundedRect: rect, cornerRadius: radius, style: .continuous) : Path(rect)
    }
}

extension View {
    /// Inserted growing out of `seed` into `frame` (`fades`: under Reduce Motion); removed at once (a departing pane stays in
    /// the layout while it goes, `CanvasLayout.depart`).
    func arrives(from seed: CGRect?, into frame: CGRect, fades: Bool = true) -> some View {
        // motion-lint-allow: rides the structural change it is inserted in, from the edge it splits from.
        transition(.asymmetric(insertion: AnyTransition(ArrivalTransition(seed: seed, frame: frame, fades: fades)), removal: .identity))
    }
}
