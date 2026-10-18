import CoreGraphics

// Ported from Ghostty src/font/sprite/draw/block.zig, braille.zig and geometric_shapes.zig (MIT).

/// Block Elements | U+2580...U+259F
enum BlockElements {
    static func draw(_ cp: UInt32, _ c: SpriteCanvas, _ m: CellMetrics) {
        switch cp {
        case 0x2580: block(m, c, .upper, 1, 0.5)
        case 0x2581: block(m, c, .lower, 1, 0.125)
        case 0x2582: block(m, c, .lower, 1, 0.25)
        case 0x2583: block(m, c, .lower, 1, 0.375)
        case 0x2584: block(m, c, .lower, 1, 0.5)
        case 0x2585: block(m, c, .lower, 1, 0.625)
        case 0x2586: block(m, c, .lower, 1, 0.75)
        case 0x2587: block(m, c, .lower, 1, 0.875)
        case 0x2588: fullBlockShade(m, c, Shade.on)
        case 0x2589: block(m, c, .left, 0.875, 1)
        case 0x258A: block(m, c, .left, 0.75, 1)
        case 0x258B: block(m, c, .left, 0.625, 1)
        case 0x258C: block(m, c, .left, 0.5, 1)
        case 0x258D: block(m, c, .left, 0.375, 1)
        case 0x258E: block(m, c, .left, 0.25, 1)
        case 0x258F: block(m, c, .left, 0.125, 1)
        case 0x2590: block(m, c, .right, 0.5, 1)
        case 0x2591: fullBlockShade(m, c, Shade.light)
        case 0x2592: fullBlockShade(m, c, Shade.medium)
        case 0x2593: fullBlockShade(m, c, Shade.dark)
        case 0x2594: block(m, c, .upper, 1, 0.125)
        case 0x2595: block(m, c, .right, 0.125, 1)
        case 0x2596: quadrant(m, c, [.bl])
        case 0x2597: quadrant(m, c, [.br])
        case 0x2598: quadrant(m, c, [.tl])
        case 0x2599: quadrant(m, c, [.tl, .bl, .br])
        case 0x259A: quadrant(m, c, [.tl, .br])
        case 0x259B: quadrant(m, c, [.tl, .tr, .bl])
        case 0x259C: quadrant(m, c, [.tl, .tr, .br])
        case 0x259D: quadrant(m, c, [.tr])
        case 0x259E: quadrant(m, c, [.tr, .bl])
        case 0x259F: quadrant(m, c, [.tr, .bl, .br])
        default: break
        }
    }

    static func block(_ m: CellMetrics, _ c: SpriteCanvas, _ alignment: Alignment, _ width: Double, _ height: Double) {
        blockShade(m, c, alignment, width, height, Shade.on)
    }

    static func blockShade(
        _ m: CellMetrics, _ c: SpriteCanvas, _ alignment: Alignment, _ width: Double, _ height: Double, _ shade: UInt8
    ) {
        let w = Int((Double(m.cellWidth) * width).rounded())
        let h = Int((Double(m.cellHeight) * height).rounded())
        let x = switch alignment.horizontal {
        case .left: 0
        case .right: m.cellWidth - w
        case .center: (m.cellWidth - w) / 2
        }
        let y = switch alignment.vertical {
        case .top: 0
        case .bottom: m.cellHeight - h
        case .middle: (m.cellHeight - h) / 2
        }
        c.rect(x: x, y: y, width: w, height: h, shade)
    }

    static func fullBlockShade(_ m: CellMetrics, _ c: SpriteCanvas, _ shade: UInt8) {
        c.box(0, 0, m.cellWidth, m.cellHeight, shade)
    }

    static func quadrant(_ m: CellMetrics, _ c: SpriteCanvas, _ quads: Quads) {
        if quads.contains(.tl) { fill(m, c, .zero, .half, .zero, .half) }
        if quads.contains(.tr) { fill(m, c, .half, .one, .zero, .half) }
        if quads.contains(.bl) { fill(m, c, .zero, .half, .half, .one) }
        if quads.contains(.br) { fill(m, c, .half, .one, .half, .one) }
    }
}

/// Braille Patterns | U+2800...U+28FF
enum Braille {
    /// Dot geometry for a cell: dot size, column x positions and row y positions.
    static func layout(width: Int, height: Int) -> (dot: Int, x: [Int], y: [Int]) {
        var w = min(width / 4, height / 8)
        var xSpacing = width / 4
        var ySpacing = height / 8
        var xMargin = xSpacing / 2
        var yMargin = ySpacing / 2
        var xLeft = width - 2 * xMargin - xSpacing - 2 * w
        var yLeft = height - 2 * yMargin - 3 * ySpacing - 4 * w

        // First, try hard to ensure the dot is non-empty.
        if xLeft >= 2, yLeft >= 4, w == 0 {
            w += 1
            xLeft -= 2
            yLeft -= 4
        }
        // Second, prefer a non-zero margin.
        if xLeft >= 2, xMargin == 0 {
            xMargin = 1
            xLeft -= 2
        }
        if yLeft >= 2, yMargin == 0 {
            yMargin = 1
            yLeft -= 2
        }
        // Third, increase spacing.
        if xLeft >= 1 {
            xSpacing += 1
            xLeft -= 1
        }
        if yLeft >= 3 {
            ySpacing += 1
            yLeft -= 3
        }
        // Fourth, margins.
        if xLeft >= 2 {
            xMargin += 1
            xLeft -= 2
        }
        if yLeft >= 2 {
            yMargin += 1
            yLeft -= 2
        }
        // Last, a bigger dot.
        if xLeft >= 2, yLeft >= 4 {
            w += 1
        }
        let x = [xMargin, xMargin + w + xSpacing]
        var y = [yMargin]
        for _ in 1..<4 { y.append(y.last! + w + ySpacing) }
        return (w, x, y)
    }

    static func draw(_ cp: UInt32, _ c: SpriteCanvas, width: Int, height: Int) {
        let (w, x, y) = layout(width: width, height: height)
        let bits = UInt8(truncatingIfNeeded: cp)
        // Bit order of the codepoint: dots 1–3 (left, rows 0–2), 4–6 (right, rows 0–2), 7, 8 (row 3).
        let dots: [(bit: UInt8, col: Int, row: Int)] = [
            (0x01, 0, 0), (0x02, 0, 1), (0x04, 0, 2), (0x08, 1, 0),
            (0x10, 1, 1), (0x20, 1, 2), (0x40, 0, 3), (0x80, 1, 3),
        ]
        for dot in dots where bits & dot.bit != 0 {
            c.box(x[dot.col], y[dot.row], x[dot.col] + w, y[dot.row] + w)
        }
    }
}

/// Geometric Shapes | U+25A0...U+25FF (the corner triangles only, as in Ghostty).
enum GeometricShapes {
    static func draw(_ cp: UInt32, _ c: SpriteCanvas, _ m: CellMetrics) {
        switch cp {
        case 0x25E2: cornerTriangleShade(m, c, .br, Shade.on)
        case 0x25E3: cornerTriangleShade(m, c, .bl, Shade.on)
        case 0x25E4: cornerTriangleShade(m, c, .tl, Shade.on)
        case 0x25E5: cornerTriangleShade(m, c, .tr, Shade.on)
        case 0x25F8: cornerTriangleOutline(m, c, .tl)
        case 0x25F9: cornerTriangleOutline(m, c, .tr)
        case 0x25FA: cornerTriangleOutline(m, c, .bl)
        case 0x25FF: cornerTriangleOutline(m, c, .br)
        default: break
        }
    }

    private static func corners(_ m: CellMetrics, _ corner: Corner) -> [CGPoint] {
        let w = Double(m.cellWidth), h = Double(m.cellHeight)
        return switch corner {
        case .tl: [CGPoint(0, 0), CGPoint(0, h), CGPoint(w, 0)]
        case .tr: [CGPoint(0, 0), CGPoint(w, h), CGPoint(w, 0)]
        case .bl: [CGPoint(0, 0), CGPoint(0, h), CGPoint(w, h)]
        case .br: [CGPoint(0, h), CGPoint(w, h), CGPoint(w, 0)]
        }
    }

    static func cornerTriangleShade(_ m: CellMetrics, _ c: SpriteCanvas, _ corner: Corner, _ shade: UInt8) {
        c.polygon(corners(m, corner), shade)
    }

    static func cornerTriangleOutline(_ m: CellMetrics, _ c: SpriteCanvas, _ corner: Corner) {
        let path = CGMutablePath()
        path.addLines(between: corners(m, corner))
        path.closeSubpath()
        c.innerStroke(path, region: path, lineWidth: CGFloat(Thickness.light.px(m.boxThickness)))
    }
}
