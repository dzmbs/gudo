import CoreGraphics
import PaneLayout

/// Where a pointer or a finger takes hold of a divider or a window's edge: well past the
/// visible line, as on a Mac window's frame, so the resize pointer shows before the hand is on
/// the pixel. A divider's zone straddles its gap; a window's lies mostly outside it, so the
/// buttons in its header and text at its edge stay within reach.
enum ResizeZones {
    #if os(macOS)
    static let dividerReach: CGFloat = 6
    static let edgeOutside: CGFloat = 6
    static let edgeInside: CGFloat = 3
    static let cornerOutside: CGFloat = 10
    static let cornerInside: CGFloat = 8
    #else
    /// 44 pt to hold, the touch target guidelines' minimum.
    static let dividerReach: CGFloat = 22
    static let edgeOutside: CGFloat = 30
    static let edgeInside: CGFloat = 14
    static let cornerOutside: CGFloat = 30
    static let cornerInside: CGFloat = 22
    #endif

    /// How thick a divider's zone is across a gap of `gap` points.
    static func dividerThickness(gap: CGFloat) -> CGFloat { gap + 2 * dividerReach }

    /// A divider's zone around its visible line.
    static func divider(_ line: CGRect, axis: PaneLayout.Axis) -> CGRect {
        axis == .horizontal
            ? line.insetBy(dx: -dividerReach, dy: 0)
            : line.insetBy(dx: 0, dy: -dividerReach)
    }

    /// A window's eight zones: edges, then corners, which sit over the edges' ends.
    static func window(_ frame: CGRect) -> [(edges: FloatGeometry.Edges, zone: CGRect)] {
        let edge = edgeOutside + edgeInside
        let corner = cornerOutside + cornerInside
        let left = frame.minX - edgeOutside, right = frame.maxX - edgeInside
        let top = frame.minY - edgeOutside, bottom = frame.maxY - edgeInside
        let spanX = frame.minX + cornerInside, spanY = frame.minY + cornerInside
        let width = max(0, frame.width - 2 * cornerInside), height = max(0, frame.height - 2 * cornerInside)
        let cornerLeft = frame.minX - cornerOutside, cornerRight = frame.maxX - cornerInside
        let cornerTop = frame.minY - cornerOutside, cornerBottom = frame.maxY - cornerInside
        return [
            ([.left], CGRect(x: left, y: spanY, width: edge, height: height)),
            ([.right], CGRect(x: right, y: spanY, width: edge, height: height)),
            ([.top], CGRect(x: spanX, y: top, width: width, height: edge)),
            ([.bottom], CGRect(x: spanX, y: bottom, width: width, height: edge)),
            ([.left, .top], CGRect(x: cornerLeft, y: cornerTop, width: corner, height: corner)),
            ([.right, .top], CGRect(x: cornerRight, y: cornerTop, width: corner, height: corner)),
            ([.left, .bottom], CGRect(x: cornerLeft, y: cornerBottom, width: corner, height: corner)),
            ([.right, .bottom], CGRect(x: cornerRight, y: cornerBottom, width: corner, height: corner)),
        ]
    }

    /// The zone of `zones` a point is in: a corner before the edges it joins.
    static func edges(at point: CGPoint, in zones: [(edges: FloatGeometry.Edges, zone: CGRect)]) -> FloatGeometry.Edges? {
        zones.last { $0.zone.contains(point) }?.edges
    }
}
