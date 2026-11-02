import CoreGraphics
import Foundation

// Ported from Ghostty src/font/sprite/draw/powerline.zig and branch.zig (MIT).

/// Powerline + Powerline Extra Symbols | U+E0B0...U+E0D4 (the geometric ones, as in Ghostty).
enum Powerline {
    static let codepoints: Set<UInt32> = [
        0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3, 0xE0B4, 0xE0B5, 0xE0B6, 0xE0B7,
        0xE0B8, 0xE0B9, 0xE0BA, 0xE0BB, 0xE0BC, 0xE0BD, 0xE0BE, 0xE0BF, 0xE0D2, 0xE0D4,
    ]

    static func draw(_ codepoint: UInt32, _ canvas: SpriteCanvas, width: Int, height: Int, _ metrics: CellMetrics) {
        let w = Double(width), h = Double(height)
        switch codepoint {
        case 0xE0B0: canvas.polygon([CGPoint(0, 0), CGPoint(w, h / 2), CGPoint(0, h)])
        case 0xE0B2: canvas.polygon([CGPoint(w, 0), CGPoint(0, h / 2), CGPoint(w, h)])
        case 0xE0B8: canvas.polygon([CGPoint(0, 0), CGPoint(w, h), CGPoint(0, h)])
        case 0xE0BA: canvas.polygon([CGPoint(w, 0), CGPoint(w, h), CGPoint(0, h)])
        case 0xE0BC: canvas.polygon([CGPoint(0, 0), CGPoint(w, 0), CGPoint(0, h)])
        case 0xE0BE: canvas.polygon([CGPoint(0, 0), CGPoint(w, 0), CGPoint(w, h)])
        case 0xE0B9, 0xE0BF: BoxDrawing.lightDiagonalUpperLeftToLowerRight(metrics, canvas)
        case 0xE0BB, 0xE0BD: BoxDrawing.lightDiagonalUpperRightToLowerLeft(metrics, canvas)
        case 0xE0B1:
            chevron(canvas, w, h, metrics)
        case 0xE0B3:
            chevron(canvas, w, h, metrics)
            canvas.flipHorizontal()
        case 0xE0B4:
            halfCircle(canvas, w, h)
        case 0xE0B6:
            halfCircle(canvas, w, h)
            canvas.flipHorizontal()
        case 0xE0B5:
            halfCircleOutline(canvas, w, h, metrics)
        case 0xE0B7:
            halfCircleOutline(canvas, w, h, metrics)
            canvas.flipHorizontal()
        case 0xE0D2:
            flameSplit(canvas, w, h, metrics)
        case 0xE0D4:
            flameSplit(canvas, w, h, metrics)
            canvas.flipHorizontal()
        default: break
        }
    }

    private static func chevron(_ canvas: SpriteCanvas, _ w: Double, _ h: Double, _ metrics: CellMetrics) {
        let path = CGMutablePath()
        path.move(to: CGPoint(0, 0))
        path.addLine(to: CGPoint(w, h / 2))
        path.addLine(to: CGPoint(0, h))
        canvas.stroke(path, lineWidth: CGFloat(Thickness.light.px(metrics.boxThickness)))
    }

    /// Coefficient for approximating a circular arc with a cubic Bézier.
    private static let kappa = (2.0.squareRoot() - 1) * 4 / 3

    private static func halfCirclePath(_ w: Double, _ h: Double, inset: Double) -> CGMutablePath {
        let r = min(w, h / 2)
        let handle = kappa
        let path = CGMutablePath()
        path.move(to: CGPoint(0, 0))
        if inset > 0 { path.addLine(to: CGPoint(inset, 0)) }
        path.addCurve(to: CGPoint(r, r), control1: CGPoint(r * handle, 0), control2: CGPoint(r, r - r * handle))
        path.addLine(to: CGPoint(r, h - r))
        path.addCurve(to: CGPoint(inset, h), control1: CGPoint(r, h - r + r * handle), control2: CGPoint(r * handle, h))
        return path
    }

    private static func halfCircle(_ canvas: SpriteCanvas, _ w: Double, _ h: Double) {
        let path = halfCirclePath(w, h, inset: 0)
        path.closeSubpath()
        canvas.fill(path)
    }

    private static func halfCircleOutline(_ canvas: SpriteCanvas, _ w: Double, _ h: Double, _ metrics: CellMetrics) {
        // The leading horizontal segments keep the butt ends perpendicular.
        let path = halfCirclePath(w, h, inset: 1)
        path.addLine(to: CGPoint(0, h))
        let region = halfCirclePath(w, h, inset: 0)
        region.closeSubpath()
        canvas.innerStroke(path, region: region, lineWidth: CGFloat(metrics.boxThickness))
    }

    private static func flameSplit(_ canvas: SpriteCanvas, _ w: Double, _ h: Double, _ metrics: CellMetrics) {
        let t = Double(metrics.boxThickness)
        canvas.polygon([CGPoint(0, 0), CGPoint(w, 0), CGPoint(w / 2, h / 2 - t / 2), CGPoint(0, h / 2 - t / 2)])
        canvas.polygon([CGPoint(0, h), CGPoint(w, h), CGPoint(w / 2, h / 2 + t / 2), CGPoint(0, h / 2 + t / 2)])
    }
}

/// Branch Drawing Characters | U+F5D0...U+F60D (git graphs; the kitty spec, Ghostty's drawing).
enum BranchDrawing {
    struct Node: OptionSet {
        let rawValue: UInt8
        static let up = Node(rawValue: 1)
        static let right = Node(rawValue: 2)
        static let down = Node(rawValue: 4)
        static let left = Node(rawValue: 8)
        static let filled = Node(rawValue: 16)
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func draw(_ codepoint: UInt32, _ canvas: SpriteCanvas, _ metrics: CellMetrics) {
        func arc(_ corner: Corner) { BoxDrawing.arc(metrics, canvas, corner, .light) }
        func v() { vlineMiddle(metrics, canvas, .light) }
        func h() { hlineMiddle(metrics, canvas, .light) }
        switch codepoint {
        case 0xF5D0: h()
        case 0xF5D1: v()
        case 0xF5D2: fadingLine(metrics, canvas, .right)
        case 0xF5D3: fadingLine(metrics, canvas, .left)
        case 0xF5D4: fadingLine(metrics, canvas, .bottom)
        case 0xF5D5: fadingLine(metrics, canvas, .top)
        case 0xF5D6: arc(.br)
        case 0xF5D7: arc(.bl)
        case 0xF5D8: arc(.tr)
        case 0xF5D9: arc(.tl)
        case 0xF5DA: v(); arc(.tr)
        case 0xF5DB: v(); arc(.br)
        case 0xF5DC: arc(.tr); arc(.br)
        case 0xF5DD: v(); arc(.tl)
        case 0xF5DE: v(); arc(.bl)
        case 0xF5DF: arc(.tl); arc(.bl)
        case 0xF5E0: arc(.bl); h()
        case 0xF5E1: arc(.br); h()
        case 0xF5E2: arc(.br); arc(.bl)
        case 0xF5E3: arc(.tl); h()
        case 0xF5E4: arc(.tr); h()
        case 0xF5E5: arc(.tr); arc(.tl)
        case 0xF5E6: v(); arc(.tl); arc(.tr)
        case 0xF5E7: v(); arc(.bl); arc(.br)
        case 0xF5E8: h(); arc(.bl); arc(.tl)
        case 0xF5E9: h(); arc(.tr); arc(.br)
        case 0xF5EA: v(); arc(.tl); arc(.br)
        case 0xF5EB: v(); arc(.tr); arc(.bl)
        case 0xF5EC: h(); arc(.tl); arc(.br)
        case 0xF5ED: h(); arc(.tr); arc(.bl)
        case 0xF5EE...0xF60D:
            let nodes: [Node] = [
                [], [.right], [.left], [.left, .right], [.down], [.up], [.up, .down], [.right, .down],
                [.left, .down], [.up, .right], [.up, .left], [.up, .down, .right], [.up, .down, .left],
                [.down, .left, .right], [.up, .left, .right], [.up, .down, .left, .right],
            ]
            let index = Int(codepoint - 0xF5EE)
            var node = nodes[index / 2]
            if index % 2 == 0 { node.insert(.filled) }
            branchNode(metrics, canvas, node)
        default: break
        }
    }

    private static func branchNode(_ metrics: CellMetrics, _ canvas: SpriteCanvas, _ node: Node) {
        let t = Thickness.light.px(metrics.boxThickness)
        let w = Double(metrics.cellWidth), h = Double(metrics.cellHeight), ft = Double(t)
        let hTop = sat(metrics.cellHeight, t) / 2
        let hBottom = hTop + t
        let vLeft = sat(metrics.cellWidth, t) / 2
        let vRight = vLeft + t
        // Centred like the box-drawing lines, which are pixel-aligned rather than exactly centred.
        let cx = Double(vLeft) + ft / 2
        let cy = Double(hTop) + ft / 2
        let r = min(min(cx, cy), min(w - cx, h - cy))

        if node.contains(.up) { canvas.box(vLeft, 0, vRight, Int((cy - r + ft / 2).rounded(.up))) }
        if node.contains(.right) { canvas.box(Int((cx + r - ft / 2).rounded(.down)), hTop, metrics.cellWidth, hBottom) }
        if node.contains(.down) { canvas.box(vLeft, Int((cy + r - ft / 2).rounded(.down)), vRight, metrics.cellHeight) }
        if node.contains(.left) { canvas.box(0, hTop, Int((cx - r + ft / 2).rounded(.up)), hBottom) }

        if node.contains(.filled) {
            canvas.fill(CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil))
        } else {
            let rr = r - ft / 2
            canvas.stroke(CGPath(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: 2 * rr, height: 2 * rr), transform: nil), lineWidth: ft)
        }
    }

    /// A centre line whose coverage fades linearly towards `edge`.
    private static func fadingLine(_ metrics: CellMetrics, _ canvas: SpriteCanvas, _ edge: Edge) {
        let t = Thickness.light.px(metrics.boxThickness)
        let hTop = sat(metrics.cellHeight, t) / 2
        let vLeft = sat(metrics.cellWidth, t) / 2
        var color: Double = edge == .top || edge == .left ? 0 : 255
        let inc: Double = switch edge {
        case .top: 255 / Double(metrics.cellHeight)
        case .bottom: -255 / Double(metrics.cellHeight)
        case .left: 255 / Double(metrics.cellWidth)
        case .right: -255 / Double(metrics.cellWidth)
        }
        switch edge {
        case .top, .bottom:
            for y in 0..<metrics.cellHeight {
                for x in vLeft..<(vLeft + t) { canvas.pixel(x, y, UInt8(clamping: Int(color.rounded()))) }
                color += inc
            }
        case .left, .right:
            for x in 0..<metrics.cellWidth {
                for y in hTop..<(hTop + t) { canvas.pixel(x, y, UInt8(clamping: Int(color.rounded()))) }
                color += inc
            }
        }
    }
}
