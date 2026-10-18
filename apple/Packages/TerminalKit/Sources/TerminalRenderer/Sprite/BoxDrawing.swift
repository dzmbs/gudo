import CoreGraphics

// Ported from Ghostty src/font/sprite/draw/box.zig (MIT).
// Box Drawing | U+2500...U+257F

enum BoxDrawing {
    /// The line style from each edge of the cell to its centre.
    struct Lines {
        enum Style { case none, light, heavy, double }
        var up = Style.none
        var right = Style.none
        var down = Style.none
        var left = Style.none
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func draw(_ cp: UInt32, _ c: SpriteCanvas, _ m: CellMetrics) {
        let light = Thickness.light.px(m.boxThickness)
        let heavy = Thickness.heavy.px(m.boxThickness)
        let dashGap = max(4, light)
        func l(up: Lines.Style = .none, right: Lines.Style = .none, down: Lines.Style = .none, left: Lines.Style = .none) {
            linesChar(m, c, Lines(up: up, right: right, down: down, left: left))
        }
        switch cp {
        case 0x2500: l(right: .light, left: .light)
        case 0x2501: l(right: .heavy, left: .heavy)
        case 0x2502: l(up: .light, down: .light)
        case 0x2503: l(up: .heavy, down: .heavy)
        case 0x2504: dashHorizontal(m, c, 3, light, dashGap)
        case 0x2505: dashHorizontal(m, c, 3, heavy, dashGap)
        case 0x2506: dashVertical(m, c, 3, light, dashGap)
        case 0x2507: dashVertical(m, c, 3, heavy, dashGap)
        case 0x2508: dashHorizontal(m, c, 4, light, dashGap)
        case 0x2509: dashHorizontal(m, c, 4, heavy, dashGap)
        case 0x250A: dashVertical(m, c, 4, light, dashGap)
        case 0x250B: dashVertical(m, c, 4, heavy, dashGap)
        case 0x250C: l(right: .light, down: .light)
        case 0x250D: l(right: .heavy, down: .light)
        case 0x250E: l(right: .light, down: .heavy)
        case 0x250F: l(right: .heavy, down: .heavy)
        case 0x2510: l(down: .light, left: .light)
        case 0x2511: l(down: .light, left: .heavy)
        case 0x2512: l(down: .heavy, left: .light)
        case 0x2513: l(down: .heavy, left: .heavy)
        case 0x2514: l(up: .light, right: .light)
        case 0x2515: l(up: .light, right: .heavy)
        case 0x2516: l(up: .heavy, right: .light)
        case 0x2517: l(up: .heavy, right: .heavy)
        case 0x2518: l(up: .light, left: .light)
        case 0x2519: l(up: .light, left: .heavy)
        case 0x251A: l(up: .heavy, left: .light)
        case 0x251B: l(up: .heavy, left: .heavy)
        case 0x251C: l(up: .light, right: .light, down: .light)
        case 0x251D: l(up: .light, right: .heavy, down: .light)
        case 0x251E: l(up: .heavy, right: .light, down: .light)
        case 0x251F: l(up: .light, right: .light, down: .heavy)
        case 0x2520: l(up: .heavy, right: .light, down: .heavy)
        case 0x2521: l(up: .heavy, right: .heavy, down: .light)
        case 0x2522: l(up: .light, right: .heavy, down: .heavy)
        case 0x2523: l(up: .heavy, right: .heavy, down: .heavy)
        case 0x2524: l(up: .light, down: .light, left: .light)
        case 0x2525: l(up: .light, down: .light, left: .heavy)
        case 0x2526: l(up: .heavy, down: .light, left: .light)
        case 0x2527: l(up: .light, down: .heavy, left: .light)
        case 0x2528: l(up: .heavy, down: .heavy, left: .light)
        case 0x2529: l(up: .heavy, down: .light, left: .heavy)
        case 0x252A: l(up: .light, down: .heavy, left: .heavy)
        case 0x252B: l(up: .heavy, down: .heavy, left: .heavy)
        case 0x252C: l(right: .light, down: .light, left: .light)
        case 0x252D: l(right: .light, down: .light, left: .heavy)
        case 0x252E: l(right: .heavy, down: .light, left: .light)
        case 0x252F: l(right: .heavy, down: .light, left: .heavy)
        case 0x2530: l(right: .light, down: .heavy, left: .light)
        case 0x2531: l(right: .light, down: .heavy, left: .heavy)
        case 0x2532: l(right: .heavy, down: .heavy, left: .light)
        case 0x2533: l(right: .heavy, down: .heavy, left: .heavy)
        case 0x2534: l(up: .light, right: .light, left: .light)
        case 0x2535: l(up: .light, right: .light, left: .heavy)
        case 0x2536: l(up: .light, right: .heavy, left: .light)
        case 0x2537: l(up: .light, right: .heavy, left: .heavy)
        case 0x2538: l(up: .heavy, right: .light, left: .light)
        case 0x2539: l(up: .heavy, right: .light, left: .heavy)
        case 0x253A: l(up: .heavy, right: .heavy, left: .light)
        case 0x253B: l(up: .heavy, right: .heavy, left: .heavy)
        case 0x253C: l(up: .light, right: .light, down: .light, left: .light)
        case 0x253D: l(up: .light, right: .light, down: .light, left: .heavy)
        case 0x253E: l(up: .light, right: .heavy, down: .light, left: .light)
        case 0x253F: l(up: .light, right: .heavy, down: .light, left: .heavy)
        case 0x2540: l(up: .heavy, right: .light, down: .light, left: .light)
        case 0x2541: l(up: .light, right: .light, down: .heavy, left: .light)
        case 0x2542: l(up: .heavy, right: .light, down: .heavy, left: .light)
        case 0x2543: l(up: .heavy, right: .light, down: .light, left: .heavy)
        case 0x2544: l(up: .heavy, right: .heavy, down: .light, left: .light)
        case 0x2545: l(up: .light, right: .light, down: .heavy, left: .heavy)
        case 0x2546: l(up: .light, right: .heavy, down: .heavy, left: .light)
        case 0x2547: l(up: .heavy, right: .heavy, down: .light, left: .heavy)
        case 0x2548: l(up: .light, right: .heavy, down: .heavy, left: .heavy)
        case 0x2549: l(up: .heavy, right: .light, down: .heavy, left: .heavy)
        case 0x254A: l(up: .heavy, right: .heavy, down: .heavy, left: .light)
        case 0x254B: l(up: .heavy, right: .heavy, down: .heavy, left: .heavy)
        case 0x254C: dashHorizontal(m, c, 2, light, light)
        case 0x254D: dashHorizontal(m, c, 2, heavy, heavy)
        case 0x254E: dashVertical(m, c, 2, light, heavy)
        case 0x254F: dashVertical(m, c, 2, heavy, heavy)
        case 0x2550: l(right: .double, left: .double)
        case 0x2551: l(up: .double, down: .double)
        case 0x2552: l(right: .double, down: .light)
        case 0x2553: l(right: .light, down: .double)
        case 0x2554: l(right: .double, down: .double)
        case 0x2555: l(down: .light, left: .double)
        case 0x2556: l(down: .double, left: .light)
        case 0x2557: l(down: .double, left: .double)
        case 0x2558: l(up: .light, right: .double)
        case 0x2559: l(up: .double, right: .light)
        case 0x255A: l(up: .double, right: .double)
        case 0x255B: l(up: .light, left: .double)
        case 0x255C: l(up: .double, left: .light)
        case 0x255D: l(up: .double, left: .double)
        case 0x255E: l(up: .light, right: .double, down: .light)
        case 0x255F: l(up: .double, right: .light, down: .double)
        case 0x2560: l(up: .double, right: .double, down: .double)
        case 0x2561: l(up: .light, down: .light, left: .double)
        case 0x2562: l(up: .double, down: .double, left: .light)
        case 0x2563: l(up: .double, down: .double, left: .double)
        case 0x2564: l(right: .double, down: .light, left: .double)
        case 0x2565: l(right: .light, down: .double, left: .light)
        case 0x2566: l(right: .double, down: .double, left: .double)
        case 0x2567: l(up: .light, right: .double, left: .double)
        case 0x2568: l(up: .double, right: .light, left: .light)
        case 0x2569: l(up: .double, right: .double, left: .double)
        case 0x256A: l(up: .light, right: .double, down: .light, left: .double)
        case 0x256B: l(up: .double, right: .light, down: .double, left: .light)
        case 0x256C: l(up: .double, right: .double, down: .double, left: .double)
        case 0x256D: arc(m, c, .br, .light)
        case 0x256E: arc(m, c, .bl, .light)
        case 0x256F: arc(m, c, .tl, .light)
        case 0x2570: arc(m, c, .tr, .light)
        case 0x2571: lightDiagonalUpperRightToLowerLeft(m, c)
        case 0x2572: lightDiagonalUpperLeftToLowerRight(m, c)
        case 0x2573: lightDiagonalCross(m, c)
        case 0x2574: l(left: .light)
        case 0x2575: l(up: .light)
        case 0x2576: l(right: .light)
        case 0x2577: l(down: .light)
        case 0x2578: l(left: .heavy)
        case 0x2579: l(up: .heavy)
        case 0x257A: l(right: .heavy)
        case 0x257B: l(down: .heavy)
        case 0x257C: l(right: .heavy, left: .light)
        case 0x257D: l(up: .light, down: .heavy)
        case 0x257E: l(right: .light, left: .heavy)
        case 0x257F: l(up: .heavy, down: .light)
        default: break
        }
    }

    // swiftlint:disable:next function_body_length
    static func linesChar(_ m: CellMetrics, _ c: SpriteCanvas, _ lines: Lines) {
        let lightPx = Thickness.light.px(m.boxThickness)
        let heavyPx = Thickness.heavy.px(m.boxThickness)

        let hLightTop = sat(m.cellHeight, lightPx) / 2
        let hLightBottom = hLightTop + lightPx
        let hHeavyTop = sat(m.cellHeight, heavyPx) / 2
        let hHeavyBottom = hHeavyTop + heavyPx
        let hDoubleTop = sat(hLightTop, lightPx)
        let hDoubleBottom = hLightBottom + lightPx

        let vLightLeft = sat(m.cellWidth, lightPx) / 2
        let vLightRight = vLightLeft + lightPx
        let vHeavyLeft = sat(m.cellWidth, heavyPx) / 2
        let vHeavyRight = vHeavyLeft + heavyPx
        let vDoubleLeft = sat(vLightLeft, lightPx)
        let vDoubleRight = vLightRight + lightPx

        let upBottom: Int = if lines.left == .heavy || lines.right == .heavy {
            hHeavyBottom
        } else if lines.left != lines.right || lines.down == lines.up {
            lines.left == .double || lines.right == .double ? hDoubleBottom : hLightBottom
        } else if lines.left == .none && lines.right == .none {
            hLightBottom
        } else {
            hLightTop
        }

        let downTop: Int = if lines.left == .heavy || lines.right == .heavy {
            hHeavyTop
        } else if lines.left != lines.right || lines.up == lines.down {
            lines.left == .double || lines.right == .double ? hDoubleTop : hLightTop
        } else if lines.left == .none && lines.right == .none {
            hLightTop
        } else {
            hLightBottom
        }

        let leftRight: Int = if lines.up == .heavy || lines.down == .heavy {
            vHeavyRight
        } else if lines.up != lines.down || lines.left == lines.right {
            lines.up == .double || lines.down == .double ? vDoubleRight : vLightRight
        } else if lines.up == .none && lines.down == .none {
            vLightRight
        } else {
            vLightLeft
        }

        let rightLeft: Int = if lines.up == .heavy || lines.down == .heavy {
            vHeavyLeft
        } else if lines.up != lines.down || lines.right == lines.left {
            lines.up == .double || lines.down == .double ? vDoubleLeft : vLightLeft
        } else if lines.up == .none && lines.down == .none {
            vLightLeft
        } else {
            vLightRight
        }

        switch lines.up {
        case .none: break
        case .light: c.box(vLightLeft, 0, vLightRight, upBottom)
        case .heavy: c.box(vHeavyLeft, 0, vHeavyRight, upBottom)
        case .double:
            let leftBottom = lines.left == .double ? hLightTop : upBottom
            let rightBottom = lines.right == .double ? hLightTop : upBottom
            c.box(vDoubleLeft, 0, vLightLeft, leftBottom)
            c.box(vLightRight, 0, vDoubleRight, rightBottom)
        }

        switch lines.right {
        case .none: break
        case .light: c.box(rightLeft, hLightTop, m.cellWidth, hLightBottom)
        case .heavy: c.box(rightLeft, hHeavyTop, m.cellWidth, hHeavyBottom)
        case .double:
            let topLeft = lines.up == .double ? vLightRight : rightLeft
            let bottomLeft = lines.down == .double ? vLightRight : rightLeft
            c.box(topLeft, hDoubleTop, m.cellWidth, hLightTop)
            c.box(bottomLeft, hLightBottom, m.cellWidth, hDoubleBottom)
        }

        switch lines.down {
        case .none: break
        case .light: c.box(vLightLeft, downTop, vLightRight, m.cellHeight)
        case .heavy: c.box(vHeavyLeft, downTop, vHeavyRight, m.cellHeight)
        case .double:
            let leftTop = lines.left == .double ? hLightBottom : downTop
            let rightTop = lines.right == .double ? hLightBottom : downTop
            c.box(vDoubleLeft, leftTop, vLightLeft, m.cellHeight)
            c.box(vLightRight, rightTop, vDoubleRight, m.cellHeight)
        }

        switch lines.left {
        case .none: break
        case .light: c.box(0, hLightTop, leftRight, hLightBottom)
        case .heavy: c.box(0, hHeavyTop, leftRight, hHeavyBottom)
        case .double:
            let topRight = lines.up == .double ? vLightLeft : leftRight
            let bottomRight = lines.down == .double ? vLightLeft : leftRight
            c.box(0, hDoubleTop, topRight, hLightTop)
            c.box(0, hLightBottom, bottomRight, hDoubleBottom)
        }
    }

    static func lightDiagonalUpperRightToLowerLeft(_ m: CellMetrics, _ c: SpriteCanvas) {
        let w = Double(m.cellWidth), h = Double(m.cellHeight)
        // Overshoot the corners slightly, keeping the slope, so diagonals join across cells.
        let sx = min(1, w / h), sy = min(1, h / w)
        c.line(CGPoint(w + 0.5 * sx, -0.5 * sy), CGPoint(-0.5 * sx, h + 0.5 * sy),
               thickness: CGFloat(Thickness.light.px(m.boxThickness)))
    }

    static func lightDiagonalUpperLeftToLowerRight(_ m: CellMetrics, _ c: SpriteCanvas) {
        let w = Double(m.cellWidth), h = Double(m.cellHeight)
        let sx = min(1, w / h), sy = min(1, h / w)
        c.line(CGPoint(-0.5 * sx, -0.5 * sy), CGPoint(w + 0.5 * sx, h + 0.5 * sy),
               thickness: CGFloat(Thickness.light.px(m.boxThickness)))
    }

    static func lightDiagonalCross(_ m: CellMetrics, _ c: SpriteCanvas) {
        lightDiagonalUpperRightToLowerLeft(m, c)
        lightDiagonalUpperLeftToLowerRight(m, c)
    }

    /// A rounded corner joining the centre lines of two edges. `corner` names the quadrant the
    /// arc bends towards.
    static func arc(_ m: CellMetrics, _ c: SpriteCanvas, _ corner: Corner, _ thickness: Thickness) {
        let t = thickness.px(m.boxThickness)
        let w = Double(m.cellWidth), h = Double(m.cellHeight), ft = Double(t)
        let cx = Double(sat(m.cellWidth, t) / 2) + ft / 2
        let cy = Double(sat(m.cellHeight, t) / 2) + ft / 2
        let r = min(w, h) / 2
        let s = 0.25

        let path = CGMutablePath()
        switch corner {
        case .tl:
            path.move(to: CGPoint(cx, 0))
            path.addLine(to: CGPoint(cx, cy - r))
            path.addCurve(to: CGPoint(cx - r, cy), control1: CGPoint(cx, cy - s * r), control2: CGPoint(cx - s * r, cy))
            path.addLine(to: CGPoint(0, cy))
        case .tr:
            path.move(to: CGPoint(cx, 0))
            path.addLine(to: CGPoint(cx, cy - r))
            path.addCurve(to: CGPoint(cx + r, cy), control1: CGPoint(cx, cy - s * r), control2: CGPoint(cx + s * r, cy))
            path.addLine(to: CGPoint(w, cy))
        case .bl:
            path.move(to: CGPoint(cx, h))
            path.addLine(to: CGPoint(cx, cy + r))
            path.addCurve(to: CGPoint(cx - r, cy), control1: CGPoint(cx, cy + s * r), control2: CGPoint(cx - s * r, cy))
            path.addLine(to: CGPoint(0, cy))
        case .br:
            path.move(to: CGPoint(cx, h))
            path.addLine(to: CGPoint(cx, cy + r))
            path.addCurve(to: CGPoint(cx + r, cy), control1: CGPoint(cx, cy + s * r), control2: CGPoint(cx + s * r, cy))
            path.addLine(to: CGPoint(w, cy))
        }
        c.stroke(path, lineWidth: CGFloat(ft))
    }

    /// `count` dashes with half gaps at both ends, so the pattern tiles evenly across cells.
    static func dashHorizontal(_ m: CellMetrics, _ c: SpriteCanvas, _ count: Int, _ thick: Int, _ desiredGap: Int) {
        let gapCount = count
        guard m.cellWidth >= count + gapCount else { return hlineMiddle(m, c, .light) }
        let gapWidth = min(desiredGap, m.cellWidth / (2 * count))
        let totalDash = m.cellWidth - gapCount * gapWidth
        let dashWidth = totalDash / count
        var extra = totalDash % count
        let y = sat(m.cellHeight, thick) / 2
        var x = gapWidth / 2
        for _ in 0..<count {
            var x1 = x + dashWidth
            if extra > 0 {
                extra -= 1
                x1 += 1
            }
            hline(c, x, x1, y, thick)
            x = x1 + gapWidth
        }
    }

    /// `count` dashes with a full gap at the bottom, so the pattern tiles evenly down a column.
    static func dashVertical(_ m: CellMetrics, _ c: SpriteCanvas, _ count: Int, _ thick: Int, _ desiredGap: Int) {
        let gapCount = count
        guard m.cellHeight >= count + gapCount else { return vlineMiddle(m, c, .light) }
        let gapHeight = min(desiredGap, m.cellHeight / (2 * count))
        let totalDash = m.cellHeight - gapCount * gapHeight
        let dashHeight = totalDash / count
        var extra = totalDash % count
        let x = sat(m.cellWidth, thick) / 2
        var y = 0
        for _ in 0..<count {
            var y1 = y + dashHeight
            if extra > 0 {
                extra -= 1
                y1 += 1
            }
            vline(c, y, y1, x, thick)
            y = y1 + gapHeight
        }
    }
}
