import CoreGraphics
import Foundation

// Ported from Ghostty src/font/sprite/draw/powerline.zig and branch.zig (MIT).

/// Powerline + Powerline Extra Symbols | U+E0B0...U+E0D4 (the geometric ones, as in Ghostty).
enum Powerline {
    static let codepoints: Set<UInt32> = [
        0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3, 0xE0B4, 0xE0B5, 0xE0B6, 0xE0B7,
        0xE0B8, 0xE0B9, 0xE0BA, 0xE0BB, 0xE0BC, 0xE0BD, 0xE0BE, 0xE0BF, 0xE0D2, 0xE0D4,
    ]

    static func draw(_ cp: UInt32, _ c: SpriteCanvas, width: Int, height: Int, _ m: CellMetrics) {
        let w = Double(width), h = Double(height)
        switch cp {
        case 0xE0B0: c.polygon([CGPoint(0, 0), CGPoint(w, h / 2), CGPoint(0, h)])
        case 0xE0B2: c.polygon([CGPoint(w, 0), CGPoint(0, h / 2), CGPoint(w, h)])
        case 0xE0B8: c.polygon([CGPoint(0, 0), CGPoint(w, h), CGPoint(0, h)])
        case 0xE0BA: c.polygon([CGPoint(w, 0), CGPoint(w, h), CGPoint(0, h)])
        case 0xE0BC: c.polygon([CGPoint(0, 0), CGPoint(w, 0), CGPoint(0, h)])
        case 0xE0BE: c.polygon([CGPoint(0, 0), CGPoint(w, 0), CGPoint(w, h)])
        case 0xE0B9, 0xE0BF: BoxDrawing.lightDiagonalUpperLeftToLowerRight(m, c)
        case 0xE0BB, 0xE0BD: BoxDrawing.lightDiagonalUpperRightToLowerLeft(m, c)
        case 0xE0B1:
            chevron(c, w, h, m)
        case 0xE0B3:
            chevron(c, w, h, m)
            c.flipHorizontal()
        case 0xE0B4:
            halfCircle(c, w, h)
        case 0xE0B6:
            halfCircle(c, w, h)
            c.flipHorizontal()
        case 0xE0B5:
            halfCircleOutline(c, w, h, m)
        case 0xE0B7:
            halfCircleOutline(c, w, h, m)
            c.flipHorizontal()
        case 0xE0D2:
            flameSplit(c, w, h, m)
        case 0xE0D4:
            flameSplit(c, w, h, m)
            c.flipHorizontal()
        default: break
        }
    }

    private static func chevron(_ c: SpriteCanvas, _ w: Double, _ h: Double, _ m: CellMetrics) {
        let path = CGMutablePath()
        path.move(to: CGPoint(0, 0))
        path.addLine(to: CGPoint(w, h / 2))
        path.addLine(to: CGPoint(0, h))
        c.stroke(path, lineWidth: CGFloat(Thickness.light.px(m.boxThickness)))
    }

    /// Coefficient for approximating a circular arc with a cubic Bézier.
    private static let kappa = (2.0.squareRoot() - 1) * 4 / 3

    private static func halfCirclePath(_ w: Double, _ h: Double, inset: Double) -> CGMutablePath {
        let r = min(w, h / 2)
        let c = kappa
        let path = CGMutablePath()
        path.move(to: CGPoint(0, 0))
        if inset > 0 { path.addLine(to: CGPoint(inset, 0)) }
        path.addCurve(to: CGPoint(r, r), control1: CGPoint(r * c, 0), control2: CGPoint(r, r - r * c))
        path.addLine(to: CGPoint(r, h - r))
        path.addCurve(to: CGPoint(inset, h), control1: CGPoint(r, h - r + r * c), control2: CGPoint(r * c, h))
        return path
    }

    private static func halfCircle(_ c: SpriteCanvas, _ w: Double, _ h: Double) {
        let path = halfCirclePath(w, h, inset: 0)
        path.closeSubpath()
        c.fill(path)
    }

    private static func halfCircleOutline(_ c: SpriteCanvas, _ w: Double, _ h: Double, _ m: CellMetrics) {
        // The leading horizontal segments keep the butt ends perpendicular.
        let path = halfCirclePath(w, h, inset: 1)
        path.addLine(to: CGPoint(0, h))
        let region = halfCirclePath(w, h, inset: 0)
        region.closeSubpath()
        c.innerStroke(path, region: region, lineWidth: CGFloat(m.boxThickness))
    }

    private static func flameSplit(_ c: SpriteCanvas, _ w: Double, _ h: Double, _ m: CellMetrics) {
        let t = Double(m.boxThickness)
        c.polygon([CGPoint(0, 0), CGPoint(w, 0), CGPoint(w / 2, h / 2 - t / 2), CGPoint(0, h / 2 - t / 2)])
        c.polygon([CGPoint(0, h), CGPoint(w, h), CGPoint(w / 2, h / 2 + t / 2), CGPoint(0, h / 2 + t / 2)])
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
    static func draw(_ cp: UInt32, _ c: SpriteCanvas, _ m: CellMetrics) {
        func arc(_ corner: Corner) { BoxDrawing.arc(m, c, corner, .light) }
        func v() { vlineMiddle(m, c, .light) }
        func h() { hlineMiddle(m, c, .light) }
        switch cp {
        case 0xF5D0: h()
        case 0xF5D1: v()
        case 0xF5D2: fadingLine(m, c, .right)
        case 0xF5D3: fadingLine(m, c, .left)
        case 0xF5D4: fadingLine(m, c, .bottom)
        case 0xF5D5: fadingLine(m, c, .top)
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
            let index = Int(cp - 0xF5EE)
            var node = nodes[index / 2]
            if index % 2 == 0 { node.insert(.filled) }
            branchNode(m, c, node)
        default: break
        }
    }

    private static func branchNode(_ m: CellMetrics, _ c: SpriteCanvas, _ node: Node) {
        let t = Thickness.light.px(m.boxThickness)
        let w = Double(m.cellWidth), h = Double(m.cellHeight), ft = Double(t)
        let hTop = sat(m.cellHeight, t) / 2
        let hBottom = hTop + t
        let vLeft = sat(m.cellWidth, t) / 2
        let vRight = vLeft + t
        // Centred like the box-drawing lines, which are pixel-aligned rather than exactly centred.
        let cx = Double(vLeft) + ft / 2
        let cy = Double(hTop) + ft / 2
        let r = min(min(cx, cy), min(w - cx, h - cy))

        if node.contains(.up) { c.box(vLeft, 0, vRight, Int((cy - r + ft / 2).rounded(.up))) }
        if node.contains(.right) { c.box(Int((cx + r - ft / 2).rounded(.down)), hTop, m.cellWidth, hBottom) }
        if node.contains(.down) { c.box(vLeft, Int((cy + r - ft / 2).rounded(.down)), vRight, m.cellHeight) }
        if node.contains(.left) { c.box(0, hTop, Int((cx - r + ft / 2).rounded(.up)), hBottom) }

        if node.contains(.filled) {
            c.fill(CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil))
        } else {
            let rr = r - ft / 2
            c.stroke(CGPath(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: 2 * rr, height: 2 * rr), transform: nil), lineWidth: ft)
        }
    }

    /// A centre line whose coverage fades linearly towards `edge`.
    private static func fadingLine(_ m: CellMetrics, _ c: SpriteCanvas, _ edge: Edge) {
        let t = Thickness.light.px(m.boxThickness)
        let hTop = sat(m.cellHeight, t) / 2
        let vLeft = sat(m.cellWidth, t) / 2
        var color: Double = edge == .top || edge == .left ? 0 : 255
        let inc: Double = switch edge {
        case .top: 255 / Double(m.cellHeight)
        case .bottom: -255 / Double(m.cellHeight)
        case .left: 255 / Double(m.cellWidth)
        case .right: -255 / Double(m.cellWidth)
        }
        switch edge {
        case .top, .bottom:
            for y in 0..<m.cellHeight {
                for x in vLeft..<(vLeft + t) { c.pixel(x, y, UInt8(clamping: Int(color.rounded()))) }
                color += inc
            }
        case .left, .right:
            for x in 0..<m.cellWidth {
                for y in hTop..<(hTop + t) { c.pixel(x, y, UInt8(clamping: Int(color.rounded()))) }
                color += inc
            }
        }
    }
}
