import CoreGraphics

/// The arithmetic of floating windows in points: snapping while they move and resize, where a
/// flick lands, drop zones of a pane drag, the tray's chips and the iPhone's picture in picture.
/// Pure values, so every rule is unit-tested; the views only animate what these return.
public enum FloatGeometry {
    /// How close an edge must come to a line to stick to it.
    public static let snapDistance: CGFloat = 10
    /// The margin a window keeps from the tab's edges when it snaps to them.
    public static let edgeMargin: CGFloat = 8
    /// The gap between two windows snapped side by side.
    public static let windowGap: CGFloat = 8
    /// Smallest window, in points (a usable terminal under its header).
    public static let minimumSize = CGSize(width: 240, height: 140)

    // MARK: Snapping

    /// A line a snapped edge sits on, drawn while it holds.
    public struct Guide: Hashable, Sendable {
        public enum Axis: Hashable, Sendable { case vertical, horizontal }
        public var axis: Axis
        /// x for a vertical guide, y for a horizontal one.
        public var position: CGFloat
        /// Where the line runs along its axis.
        public var from: CGFloat
        public var to: CGFloat

        public init(axis: Axis, position: CGFloat, from: CGFloat, to: CGFloat) {
            self.axis = axis
            self.position = position
            self.from = from
            self.to = to
        }
    }

    /// Which edges of a window move: all four while it moves, some while it resizes.
    public struct Edges: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1)
        public static let right = Edges(rawValue: 2)
        public static let top = Edges(rawValue: 4)
        public static let bottom = Edges(rawValue: 8)
        public static let all: Edges = [.left, .right, .top, .bottom]
    }

    /// Lines an edge can stick to along one axis, with the guide each draws.
    private struct Line {
        var value: CGFloat
        /// The edge it suits: leading (left/top) or trailing (right/bottom); nil for either.
        var leading: Bool?
        var guide: Guide
    }

    /// `rect` stuck to the nearest lines within `snapDistance`: the tab's edges (at a margin),
    /// its halves and thirds, and the edges of `others` (aligned with them, or beside them with
    /// a gap). Only `moving` edges snap; a moved window keeps its size.
    public static func snap(
        _ rect: CGRect, in bounds: CGRect, others: [CGRect], moving: Edges = .all
    ) -> (rect: CGRect, guides: [Guide]) {
        var out = rect
        var guides: [Guide] = []
        let verticals = lines(bounds: bounds, others: others, vertical: true)
        let horizontals = lines(bounds: bounds, others: others, vertical: false)

        if let (dx, guide) = best(lo: rect.minX, hi: rect.maxX, lines: verticals, lo: moving.contains(.left), hi: moving.contains(.right)) {
            if moving.contains(.left) && moving.contains(.right) {
                out.origin.x += dx
            } else if moving.contains(.left) {
                out.origin.x += dx
                out.size.width -= dx
            } else {
                out.size.width += dx
            }
            guides.append(guide)
        }
        if let (dy, guide) = best(lo: rect.minY, hi: rect.maxY, lines: horizontals, lo: moving.contains(.top), hi: moving.contains(.bottom)) {
            if moving.contains(.top) && moving.contains(.bottom) {
                out.origin.y += dy
            } else if moving.contains(.top) {
                out.origin.y += dy
                out.size.height -= dy
            } else {
                out.size.height += dy
            }
            guides.append(guide)
        }
        return (out, guides)
    }

    private static func lines(bounds: CGRect, others: [CGRect], vertical: Bool) -> [Line] {
        let lo = vertical ? bounds.minX : bounds.minY
        let hi = vertical ? bounds.maxX : bounds.maxY
        let spanFrom = vertical ? bounds.minY : bounds.minX
        let spanTo = vertical ? bounds.maxY : bounds.maxX
        let axis: Guide.Axis = vertical ? .vertical : .horizontal
        func guide(_ at: CGFloat, _ from: CGFloat = spanFrom, _ to: CGFloat = spanTo) -> Guide {
            Guide(axis: axis, position: at, from: from, to: to)
        }
        var lines = [
            Line(value: lo + edgeMargin, leading: true, guide: guide(lo + edgeMargin)),
            Line(value: hi - edgeMargin, leading: false, guide: guide(hi - edgeMargin)),
        ]
        // Halves and thirds: either edge may sit on them.
        for fraction in [1.0 / 3, 0.5, 2.0 / 3] {
            let at = lo + (hi - lo) * fraction
            lines.append(Line(value: at, leading: nil, guide: guide(at)))
        }
        for other in others {
            let (a, b) = vertical ? (other.minX, other.maxX) : (other.minY, other.maxY)
            let (from, to) = vertical ? (other.minY, other.maxY) : (other.minX, other.maxX)
            // Aligned with its edges, or beside it with a gap.
            lines += [
                Line(value: a, leading: true, guide: guide(a, from, to)),
                Line(value: b, leading: false, guide: guide(b, from, to)),
                Line(value: b + windowGap, leading: true, guide: guide(b, from, to)),
                Line(value: a - windowGap, leading: false, guide: guide(a, from, to)),
            ]
        }
        return lines
    }

    /// The smallest move that puts a moving edge on a line, if within reach.
    private static func best(lo: CGFloat, hi: CGFloat, lines: [Line], lo moveLo: Bool, hi moveHi: Bool) -> (CGFloat, Guide)? {
        var found: (CGFloat, Guide)?
        for line in lines {
            var candidates: [CGFloat] = []
            if moveLo, line.leading != false { candidates.append(line.value - lo) }
            if moveHi, line.leading != true { candidates.append(line.value - hi) }
            for delta in candidates where abs(delta) <= snapDistance {
                if found.map({ abs(delta) < abs($0.0) }) ?? true { found = (delta, line.guide) }
            }
        }
        return found
    }

    // MARK: Throwing and resizing

    /// Where a window let go at `velocity` (points per second) comes to rest: the distance a
    /// scroll view's normal deceleration would carry it, kept inside `bounds` at the margin.
    public static func projected(_ rect: CGRect, velocity: CGVector, in bounds: CGRect) -> CGRect {
        // UIScrollView.DecelerationRate.normal (0.998 per ms): distance = v · r / (1 − r) / 1000.
        let carry = 0.998 / (1 - 0.998) / 1000
        var out = rect.offsetBy(dx: velocity.dx * carry, dy: velocity.dy * carry)
        out.origin.x = min(max(out.minX, bounds.minX + edgeMargin), bounds.maxX - edgeMargin - out.width)
        out.origin.y = min(max(out.minY, bounds.minY + edgeMargin), bounds.maxY - edgeMargin - out.height)
        return out
    }

    /// `rect` with `edges` moved by `translation`, no smaller than `minimumSize` and inside
    /// `bounds`.
    public static func resized(_ rect: CGRect, edges: Edges, by translation: CGSize, in bounds: CGRect) -> CGRect {
        let minW = min(minimumSize.width, bounds.width)
        let minH = min(minimumSize.height, bounds.height)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if edges.contains(.left) { minX = min(max(rect.minX + translation.width, bounds.minX), maxX - minW) }
        if edges.contains(.right) { maxX = max(min(rect.maxX + translation.width, bounds.maxX), minX + minW) }
        if edges.contains(.top) { minY = min(max(rect.minY + translation.height, bounds.minY), maxY - minH) }
        if edges.contains(.bottom) { maxY = max(min(rect.maxY + translation.height, bounds.maxY), minY + minH) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A window's frame on screen: its fractions of `bounds`, grown to `minimumSize` where the
    /// tab allows and kept inside it.
    public static func rect(of frame: FloatFrame, in bounds: CGRect) -> CGRect {
        var rect = frame.rect(in: bounds)
        rect.size.width = min(max(rect.width, minimumSize.width), bounds.width)
        rect.size.height = min(max(rect.height, minimumSize.height), bounds.height)
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }

    // MARK: Drop zones

    /// Where a dragged pane lands.
    public enum Drop: Hashable, Sendable {
        /// Beside `pane` on `side`: the target's half on that side.
        case beside(PaneId, Direction)
        /// Along the whole `side` edge of the tab's tiled panes.
        case edge(Direction)
        /// Floating, where it was let go (the Float target, or outside the tab).
        case float
        /// Nowhere: back where it was (let go over itself).
        case cancel
    }

    /// How deep the band along the tab's edges is that offers its whole edge.
    public static let edgeBand: CGFloat = 28

    /// The drop under `point`: the Float target, then the tab's edge band, then the pane under
    /// it (the side nearest the point, by the pane's diagonals). Outside the tab it floats;
    /// over the dragged pane itself nothing happens. `panes` are front to back: a window's
    /// panes before the tiled ones under it.
    public static func drop(
        at point: CGPoint, in bounds: CGRect, panes: [(PaneId, CGRect)], dragged: PaneId, floatTarget: CGRect? = nil
    ) -> Drop {
        if floatTarget?.contains(point) == true { return .float }
        guard bounds.contains(point) else { return .float }
        let distances: [(Direction, CGFloat)] = [
            (.left, point.x - bounds.minX), (.right, bounds.maxX - point.x),
            (.up, point.y - bounds.minY), (.down, bounds.maxY - point.y),
        ]
        if let (side, distance) = distances.min(by: { $0.1 < $1.1 }), distance < edgeBand { return .edge(side) }
        guard let (pane, rect) = panes.first(where: { $0.1.contains(point) }) else { return .float }
        if pane == dragged { return .cancel }
        return .beside(pane, side(of: point, in: rect))
    }

    /// The side of `rect` nearest `point`, by its diagonals (Ghostty's four triangles).
    public static func side(of point: CGPoint, in rect: CGRect) -> Direction {
        let x = rect.width > 0 ? (point.x - rect.minX) / rect.width : 0.5
        let y = rect.height > 0 ? (point.y - rect.minY) / rect.height : 0.5
        let distances: [(Direction, CGFloat)] = [(.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// The region a drop will give the pane: exactly what it gets once dropped (half the
    /// target, a third of the tab along an edge).
    public static func preview(of drop: Drop, in bounds: CGRect, panes: [(PaneId, CGRect)]) -> CGRect? {
        switch drop {
        case .beside(let pane, let side):
            guard let rect = panes.first(where: { $0.0 == pane })?.1 else { return nil }
            return half(of: rect, side: side)
        case .edge(let side):
            return third(of: bounds, side: side)
        case .float, .cancel:
            return nil
        }
    }

    static func half(of rect: CGRect, side: Direction) -> CGRect {
        switch side {
        case .left: rect.divided(atDistance: rect.width / 2, from: .minXEdge).slice
        case .right: rect.divided(atDistance: rect.width / 2, from: .maxXEdge).slice
        case .up: rect.divided(atDistance: rect.height / 2, from: .minYEdge).slice
        case .down: rect.divided(atDistance: rect.height / 2, from: .maxYEdge).slice
        }
    }

    static func third(of rect: CGRect, side: Direction) -> CGRect {
        switch side {
        case .left: rect.divided(atDistance: rect.width / 3, from: .minXEdge).slice
        case .right: rect.divided(atDistance: rect.width / 3, from: .maxXEdge).slice
        case .up: rect.divided(atDistance: rect.height / 3, from: .minYEdge).slice
        case .down: rect.divided(atDistance: rect.height / 3, from: .maxYEdge).slice
        }
    }

    // MARK: Tray

    /// The tray's chips, right to left from the tab's bottom-right corner, wrapping upwards.
    public static func trayChips(count: Int, chip: CGSize, in bounds: CGRect, spacing: CGFloat = 6) -> [CGRect] {
        guard count > 0, chip.width > 0 else { return [] }
        let usable = bounds.width - 2 * edgeMargin
        let perRow = max(1, Int((usable + spacing) / (chip.width + spacing)))
        return (0..<count).map { index in
            let column = index % perRow
            let row = index / perRow
            return CGRect(
                x: bounds.maxX - edgeMargin - chip.width - CGFloat(column) * (chip.width + spacing),
                y: bounds.maxY - edgeMargin - chip.height - CGFloat(row) * (chip.height + spacing),
                width: chip.width, height: chip.height)
        }
    }

    // MARK: Picture in picture (iPhone)

    /// The corners a picture-in-picture window rests in: inside `bounds` at the margin, and
    /// never across `fold` (it keeps to the half its centre is on).
    public static func pipCorners(size: CGSize, in bounds: CGRect, margin: CGFloat = 12, fold: CGRect? = nil) -> [CGRect] {
        func corners(_ area: CGRect) -> [CGRect] {
            let xs = [area.minX + margin, area.maxX - margin - size.width]
            let ys = [area.minY + margin, area.maxY - margin - size.height]
            return ys.flatMap { y in xs.map { x in CGRect(origin: CGPoint(x: x, y: y), size: size) } }
        }
        guard let fold, fold.intersects(bounds) else { return corners(bounds) }
        let halves: [CGRect] = fold.height >= fold.width
            ? [CGRect(x: bounds.minX, y: bounds.minY, width: fold.minX - bounds.minX, height: bounds.height),
               CGRect(x: fold.maxX, y: bounds.minY, width: bounds.maxX - fold.maxX, height: bounds.height)]
            : [CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: fold.minY - bounds.minY),
               CGRect(x: bounds.minX, y: fold.maxY, width: bounds.width, height: bounds.maxY - fold.maxY)]
        return halves.filter { $0.width >= size.width + 2 * margin && $0.height >= size.height + 2 * margin }.flatMap(corners)
    }

    /// The corner a window let go at `center` with `velocity` settles in: the one nearest where
    /// the flick would carry it.
    public static func pipCorner(for center: CGPoint, velocity: CGVector, corners: [CGRect]) -> CGRect? {
        let carry = 0.99 / (1 - 0.99) / 1000
        let target = CGPoint(x: center.x + velocity.dx * carry, y: center.y + velocity.dy * carry)
        return corners.min { a, b in
            hypot(a.midX - target.x, a.midY - target.y) < hypot(b.midX - target.x, b.midY - target.y)
        }
    }
}
