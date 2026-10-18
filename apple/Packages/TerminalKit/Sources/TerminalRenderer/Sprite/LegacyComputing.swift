import CoreGraphics

// Ported from Ghostty src/font/sprite/draw/symbols_for_legacy_computing.zig and
// symbols_for_legacy_computing_supplement.zig (MIT).

/// Symbols for Legacy Computing | U+1FB00...U+1FBFF (the subset Ghostty draws).
enum LegacyComputing {
    static func covers(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x1FB00...0x1FBAF, 0x1FBBD...0x1FBBF, 0x1FBCE...0x1FBEF: true
        default: false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func draw(_ cp: UInt32, _ c: SpriteCanvas, width: Int, height: Int, _ m: CellMetrics) {
        switch cp {
        case 0x1FB00...0x1FB3B:
            // Sextants: the codepoints enumerate the 6-bit patterns, skipping the ones that
            // already exist elsewhere (empty, left half, right half, full).
            let idx = cp - 0x1FB00
            let bits = idx + idx / 0x14 + 1
            if bits & 0x01 != 0 { fill(m, c, .zero, .half, .zero, .third) }
            if bits & 0x02 != 0 { fill(m, c, .half, .one, .zero, .third) }
            if bits & 0x04 != 0 { fill(m, c, .zero, .half, .third, .twoThirds) }
            if bits & 0x08 != 0 { fill(m, c, .half, .one, .third, .twoThirds) }
            if bits & 0x10 != 0 { fill(m, c, .zero, .half, .twoThirds, .one) }
            if bits & 0x20 != 0 { fill(m, c, .half, .one, .twoThirds, .one) }
        case 0x1FB3C...0x1FB67:
            smoothMosaic(m, c, smoothMosaics[Int(cp - 0x1FB3C)])
        case 0x1FB68...0x1FB6B:
            let edges: [Edge] = [.left, .top, .right, .bottom]
            edgeTriangle(m, c, edges[Int(cp - 0x1FB68)])
            c.invert()
            c.clipToCell()
        case 0x1FB6C...0x1FB6F:
            let edges: [Edge] = [.left, .top, .right, .bottom]
            edgeTriangle(m, c, edges[Int(cp - 0x1FB6C)])
        case 0x1FB70...0x1FB75:
            let n = Int(cp + 1 - 0x1FB70)
            fill(m, c, Fraction.eighths[n], Fraction.eighths[n + 1], .zero, .one)
        case 0x1FB76...0x1FB7B:
            let n = Int(cp + 1 - 0x1FB76)
            fill(m, c, .zero, .one, Fraction.eighths[n], Fraction.eighths[n + 1])
        case 0x1FB7C:
            BlockElements.block(m, c, .left, 0.125, 1)
            BlockElements.block(m, c, .lower, 1, 0.125)
        case 0x1FB7D:
            BlockElements.block(m, c, .left, 0.125, 1)
            BlockElements.block(m, c, .upper, 1, 0.125)
        case 0x1FB7E:
            BlockElements.block(m, c, .right, 0.125, 1)
            BlockElements.block(m, c, .upper, 1, 0.125)
        case 0x1FB7F:
            BlockElements.block(m, c, .right, 0.125, 1)
            BlockElements.block(m, c, .lower, 1, 0.125)
        case 0x1FB80:
            BlockElements.block(m, c, .upper, 1, 0.125)
            BlockElements.block(m, c, .lower, 1, 0.125)
        case 0x1FB81:
            // Horizontal one eighth blocks 1, 3, 5 and 8.
            for n in [0, 2, 4, 7] { fill(m, c, .zero, .one, Fraction.eighths[n], Fraction.eighths[n + 1]) }
        case 0x1FB82: BlockElements.block(m, c, .upper, 1, 0.25)
        case 0x1FB83: BlockElements.block(m, c, .upper, 1, 0.375)
        case 0x1FB84: BlockElements.block(m, c, .upper, 1, 0.625)
        case 0x1FB85: BlockElements.block(m, c, .upper, 1, 0.75)
        case 0x1FB86: BlockElements.block(m, c, .upper, 1, 0.875)
        case 0x1FB87: BlockElements.block(m, c, .right, 0.25, 1)
        case 0x1FB88: BlockElements.block(m, c, .right, 0.375, 1)
        case 0x1FB89: BlockElements.block(m, c, .right, 0.625, 1)
        case 0x1FB8A: BlockElements.block(m, c, .right, 0.75, 1)
        case 0x1FB8B: BlockElements.block(m, c, .right, 0.875, 1)
        case 0x1FB8C: BlockElements.blockShade(m, c, .left, 0.5, 1, Shade.medium)
        case 0x1FB8D: BlockElements.blockShade(m, c, .right, 0.5, 1, Shade.medium)
        case 0x1FB8E: BlockElements.blockShade(m, c, .upper, 1, 0.5, Shade.medium)
        case 0x1FB8F: BlockElements.blockShade(m, c, .lower, 1, 0.5, Shade.medium)
        case 0x1FB90: BlockElements.fullBlockShade(m, c, Shade.medium)
        case 0x1FB91:
            BlockElements.fullBlockShade(m, c, Shade.medium)
            BlockElements.block(m, c, .upper, 1, 0.5)
        case 0x1FB92:
            BlockElements.fullBlockShade(m, c, Shade.medium)
            BlockElements.block(m, c, .lower, 1, 0.5)
        case 0x1FB93:
            break  // Unassigned.
        case 0x1FB94:
            BlockElements.fullBlockShade(m, c, Shade.medium)
            BlockElements.block(m, c, .right, 0.5, 1)
        case 0x1FB95: checkerboard(m, c, parity: 0)
        case 0x1FB96: checkerboard(m, c, parity: 1)
        case 0x1FB97:
            c.box(0, height / 4, width, 2 * height / 4)
            c.box(0, 3 * height / 4, width, height)
        case 0x1FB98: diagonalFill(m, c, upperLeftToLowerRight: true)
        case 0x1FB99: diagonalFill(m, c, upperLeftToLowerRight: false)
        case 0x1FB9A:
            edgeTriangle(m, c, .top)
            edgeTriangle(m, c, .bottom)
        case 0x1FB9B:
            edgeTriangle(m, c, .left)
            edgeTriangle(m, c, .right)
        case 0x1FB9C: GeometricShapes.cornerTriangleShade(m, c, .tl, Shade.medium)
        case 0x1FB9D: GeometricShapes.cornerTriangleShade(m, c, .tr, Shade.medium)
        case 0x1FB9E: GeometricShapes.cornerTriangleShade(m, c, .br, Shade.medium)
        case 0x1FB9F: GeometricShapes.cornerTriangleShade(m, c, .bl, Shade.medium)
        case 0x1FBA0...0x1FBAE:
            let sets: [Quads] = [
                [.tl], [.tr], [.bl], [.br], [.tl, .bl], [.tr, .br], [.bl, .br], [.tl, .tr], [.tl, .br], [.tr, .bl],
                [.tr, .bl, .br], [.tl, .bl, .br], [.tl, .tr, .br], [.tl, .tr, .bl], [.tl, .tr, .bl, .br],
            ]
            cornerDiagonalLines(m, c, sets[Int(cp - 0x1FBA0)])
        case 0x1FBAF:
            BoxDrawing.linesChar(m, c, .init(up: .heavy, right: .light, down: .heavy, left: .light))
        case 0x1FBBD:
            BoxDrawing.lightDiagonalCross(m, c)
            c.invert()
            c.clipToCell()
        case 0x1FBBE:
            cornerDiagonalLines(m, c, [.br])
            c.invert()
            c.clipToCell()
        case 0x1FBBF:
            cornerDiagonalLines(m, c, [.tl, .tr, .bl, .br])
            c.invert()
            c.clipToCell()
        case 0x1FBCE: BlockElements.block(m, c, .left, 2.0 / 3.0, 1)
        case 0x1FBCF: BlockElements.block(m, c, .left, 1.0 / 3.0, 1)
        case 0x1FBD0: cellDiagonal(m, c, .middleRight, .lowerLeft)
        case 0x1FBD1: cellDiagonal(m, c, .upperRight, .middleLeft)
        case 0x1FBD2: cellDiagonal(m, c, .upperLeft, .middleRight)
        case 0x1FBD3: cellDiagonal(m, c, .middleLeft, .lowerRight)
        case 0x1FBD4: cellDiagonal(m, c, .upperLeft, .lowerCenter)
        case 0x1FBD5: cellDiagonal(m, c, .upperCenter, .lowerRight)
        case 0x1FBD6: cellDiagonal(m, c, .upperRight, .lowerCenter)
        case 0x1FBD7: cellDiagonal(m, c, .upperCenter, .lowerLeft)
        case 0x1FBD8:
            cellDiagonal(m, c, .upperLeft, .middleCenter)
            cellDiagonal(m, c, .middleCenter, .upperRight)
        case 0x1FBD9:
            cellDiagonal(m, c, .upperRight, .middleCenter)
            cellDiagonal(m, c, .middleCenter, .lowerRight)
        case 0x1FBDA:
            cellDiagonal(m, c, .lowerLeft, .middleCenter)
            cellDiagonal(m, c, .middleCenter, .lowerRight)
        case 0x1FBDB:
            cellDiagonal(m, c, .upperLeft, .middleCenter)
            cellDiagonal(m, c, .middleCenter, .lowerLeft)
        case 0x1FBDC:
            cellDiagonal(m, c, .upperLeft, .lowerCenter)
            cellDiagonal(m, c, .lowerCenter, .upperRight)
        case 0x1FBDD:
            cellDiagonal(m, c, .upperRight, .middleLeft)
            cellDiagonal(m, c, .middleLeft, .lowerRight)
        case 0x1FBDE:
            cellDiagonal(m, c, .lowerLeft, .upperCenter)
            cellDiagonal(m, c, .upperCenter, .lowerRight)
        case 0x1FBDF:
            cellDiagonal(m, c, .upperLeft, .middleRight)
            cellDiagonal(m, c, .middleRight, .lowerLeft)
        case 0x1FBE0: circle(m, c, .upper, filled: false)
        case 0x1FBE1: circle(m, c, .right, filled: false)
        case 0x1FBE2: circle(m, c, .lower, filled: false)
        case 0x1FBE3: circle(m, c, .left, filled: false)
        case 0x1FBE4: BlockElements.block(m, c, .upperCenter, 0.5, 0.5)
        case 0x1FBE5: BlockElements.block(m, c, .lowerCenter, 0.5, 0.5)
        case 0x1FBE6: BlockElements.block(m, c, .middleLeft, 0.5, 0.5)
        case 0x1FBE7: BlockElements.block(m, c, .middleRight, 0.5, 0.5)
        case 0x1FBE8: circle(m, c, .upper, filled: true)
        case 0x1FBE9: circle(m, c, .right, filled: true)
        case 0x1FBEA: circle(m, c, .lower, filled: true)
        case 0x1FBEB: circle(m, c, .left, filled: true)
        case 0x1FBEC: circle(m, c, .upperRight, filled: true)
        case 0x1FBED: circle(m, c, .lowerLeft, filled: true)
        case 0x1FBEE: circle(m, c, .lowerRight, filled: true)
        case 0x1FBEF: circle(m, c, .upperLeft, filled: true)
        default: break
        }
    }

    // MARK: Smooth mosaics

    /// Which of the ten outline points of a smooth mosaic are corners of its filled polygon.
    struct SmoothMosaic {
        var tl, ul, ll, bl, bc, br, lr, ur, tr, tc: Bool

        /// `pattern` is a 3×4 drawing ("abc\ndef\nghi\njkl"); `#` marks a filled sample point.
        init(_ pattern: String) {
            let p = Array(pattern.utf8).map { $0 == UInt8(ascii: "#") }
            tl = p[0]
            ul = p[4] && (!p[0] || !p[8])
            ll = p[8] && (!p[4] || !p[12])
            bl = p[12]
            bc = p[13] && (!p[12] || !p[14])
            br = p[14]
            lr = p[10] && (!p[14] || !p[6])
            ur = p[6] && (!p[10] || !p[2])
            tr = p[2]
            tc = p[1] && (!p[2] || !p[0])
        }
    }

    static let smoothMosaics: [SmoothMosaic] = [
        "...\n...\n#..\n##.", "...\n...\n#\\.\n###", "...\n#..\n#\\.\n##.", "...\n#..\n##.\n###",
        "#..\n#..\n##.\n##.", "/##\n###\n###\n###", "./#\n###\n###\n###", ".##\n.##\n###\n###",
        "..#\n.##\n###\n###", ".##\n.##\n.##\n###", "...\n./#\n###\n###", "...\n...\n..#\n.##",
        "...\n...\n./#\n###", "...\n..#\n./#\n.##", "...\n..#\n.##\n###", "..#\n..#\n.##\n.##",
        "##\\\n###\n###\n###", "#\\.\n###\n###\n###", "##.\n##.\n###\n###", "#..\n##.\n###\n###",
        "##.\n##.\n##.\n###", "...\n#\\.\n###\n###", "###\n###\n###\n\\##", "###\n###\n###\n.\\#",
        "###\n###\n.##\n.##", "###\n###\n.##\n..#", "###\n.##\n.##\n.##", "##.\n#..\n...\n...",
        "###\n#/.\n...\n...", "##.\n#/.\n#..\n...", "###\n##.\n#..\n...", "##.\n##.\n#..\n#..",
        "###\n###\n#/.\n...", "###\n###\n###\n##/", "###\n###\n###\n#/.", "###\n###\n##.\n##.",
        "###\n###\n##.\n#..", "###\n##.\n##.\n##.", ".##\n..#\n...\n...", "###\n.\\#\n...\n...",
        ".##\n.\\#\n..#\n...", "###\n.##\n..#\n...", ".##\n.##\n..#\n..#", "###\n###\n.\\#\n...",
    ].map(SmoothMosaic.init)

    private static func smoothMosaic(_ m: CellMetrics, _ c: SpriteCanvas, _ mosaic: SmoothMosaic) {
        let top = 0.0
        let upper = Fraction.third.float(m.cellHeight)
        let lower = Fraction.twoThirds.float(m.cellHeight)
        let bottom = Double(m.cellHeight)
        let left = 0.0
        let center = Fraction.half.float(m.cellWidth)
        let right = Double(m.cellWidth)
        var points: [CGPoint] = []
        if mosaic.tl { points.append(CGPoint(left, top)) }
        if mosaic.ul { points.append(CGPoint(left, upper)) }
        if mosaic.ll { points.append(CGPoint(left, lower)) }
        if mosaic.bl { points.append(CGPoint(left, bottom)) }
        if mosaic.bc { points.append(CGPoint(center, bottom)) }
        if mosaic.br { points.append(CGPoint(right, bottom)) }
        if mosaic.lr { points.append(CGPoint(right, lower)) }
        if mosaic.ur { points.append(CGPoint(right, upper)) }
        if mosaic.tr { points.append(CGPoint(right, top)) }
        if mosaic.tc { points.append(CGPoint(center, top)) }
        c.polygon(points)
    }

    // MARK: Helpers

    static func edgeTriangle(_ m: CellMetrics, _ c: SpriteCanvas, _ edge: Edge) {
        let upper = 0.0
        let middle = (Double(m.cellHeight) / 2).rounded()
        let lower = Double(m.cellHeight)
        let left = 0.0
        let center = (Double(m.cellWidth) / 2).rounded()
        let right = Double(m.cellWidth)
        let (p0, p1): (CGPoint, CGPoint) = switch edge {
        case .top: (CGPoint(right, upper), CGPoint(left, upper))
        case .left: (CGPoint(left, upper), CGPoint(left, lower))
        case .bottom: (CGPoint(left, lower), CGPoint(right, lower))
        case .right: (CGPoint(right, lower), CGPoint(right, upper))
        }
        c.polygon([CGPoint(center, middle), p0, p1])
    }

    static func cornerDiagonalLines(_ m: CellMetrics, _ c: SpriteCanvas, _ corners: Quads) {
        let t = CGFloat(Thickness.light.px(m.boxThickness))
        let w = Double(m.cellWidth), h = Double(m.cellHeight)
        let cx = Double(m.cellWidth / 2 + m.cellWidth % 2)
        let cy = Double(m.cellHeight / 2 + m.cellHeight % 2)
        if corners.contains(.tl) { c.line(CGPoint(cx, 0), CGPoint(0, cy), thickness: t) }
        if corners.contains(.tr) { c.line(CGPoint(cx, 0), CGPoint(w, cy), thickness: t) }
        if corners.contains(.bl) { c.line(CGPoint(cx, h), CGPoint(0, cy), thickness: t) }
        if corners.contains(.br) { c.line(CGPoint(cx, h), CGPoint(w, cy), thickness: t) }
    }

    private static func point(_ m: CellMetrics, _ a: Alignment) -> CGPoint {
        let w = Double(m.cellWidth), h = Double(m.cellHeight)
        let x: Double = switch a.horizontal {
        case .left: 0
        case .right: w
        case .center: w / 2
        }
        let y: Double = switch a.vertical {
        case .top: 0
        case .bottom: h
        case .middle: h / 2
        }
        return CGPoint(x, y)
    }

    static func cellDiagonal(_ m: CellMetrics, _ c: SpriteCanvas, _ from: Alignment, _ to: Alignment) {
        c.line(point(m, from), point(m, to), thickness: CGFloat(Thickness.light.px(m.boxThickness)))
    }

    private static func checkerboard(_ m: CellMetrics, _ c: SpriteCanvas, parity: Int) {
        let xSize = 4
        let ySize = Int((4 * (Double(m.cellHeight) / Double(m.cellWidth))).rounded())
        for x in 0..<xSize {
            let x0 = m.cellWidth * x / xSize, x1 = m.cellWidth * (x + 1) / xSize
            for y in 0..<ySize where (x + y) % 2 == parity {
                let y0 = m.cellHeight * y / ySize, y1 = m.cellHeight * (y + 1) / ySize
                c.rect(x: x0, y: y0, width: sat(x1, x0), height: sat(y1, y0))
            }
        }
    }

    private static func diagonalFill(_ m: CellMetrics, _ c: SpriteCanvas, upperLeftToLowerRight: Bool) {
        c.clipToCell()
        let t = Thickness.light.px(m.boxThickness)
        let lineCount = max(1, m.cellWidth / (2 * t))
        let w = Double(m.cellWidth), h = Double(m.cellHeight)
        let stride = (w / Double(lineCount)).rounded()
        for i in -lineCount...lineCount {
            let offset = Double(i) * stride
            if upperLeftToLowerRight {
                c.line(CGPoint(offset, 0), CGPoint(w + offset, h), thickness: CGFloat(t))
            } else {
                c.line(CGPoint(w + offset, 0), CGPoint(offset, h), thickness: CGFloat(t))
            }
        }
    }

    static func circle(_ m: CellMetrics, _ c: SpriteCanvas, _ position: Alignment, filled: Bool) {
        c.clipToCell()
        let p = point(m, position)
        let r = 0.5 * Double(min(m.cellWidth, m.cellHeight))
        let lineWidth = Double(Thickness.light.px(m.boxThickness))
        if filled {
            c.fill(CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil))
        } else {
            let rr = r - lineWidth / 2
            c.stroke(CGPath(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr), transform: nil), lineWidth: lineWidth)
        }
    }
}

/// Symbols for Legacy Computing Supplement | U+1CC00...U+1CEBF (the subset Ghostty draws).
enum LegacyComputingSupplement {
    static func covers(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x1CD00...0x1CDE5, 0x1CC21...0x1CC2F, 0x1CC30...0x1CC3F, 0x1CC1B...0x1CC1E,
             0x1CE00, 0x1CE01, 0x1CE0B, 0x1CE0C, 0x1CE16...0x1CE19, 0x1CE51...0x1CE8F, 0x1CE90...0x1CEAF:
            true
        default: false
        }
    }

    /// Octant patterns for U+1CD00…U+1CDE5, bit n-1 = octant n (1 2 / 3 4 / 5 6 / 7 8), from
    /// Ghostty's octants.txt.
    static let octants: [UInt8] = [
        0x04, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x10, 0x11, 0x12, 0x13, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
        0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A,
        0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x51, 0x52, 0x53, 0x54, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C, 0x5D,
        0x5E, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E,
        0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E,
        0x7F, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F,
        0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F,
        0xA1, 0xA2, 0xA3, 0xA4, 0xA6, 0xA7, 0xA8, 0xA9, 0xAB, 0xAC, 0xAD, 0xAE, 0xB0, 0xB1, 0xB2, 0xB3,
        0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC1, 0xC2, 0xC3, 0xC4,
        0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4,
        0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4,
        0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF, 0xF1, 0xF2, 0xF3, 0xF4, 0xF6,
        0xF7, 0xF8, 0xF9, 0xFB, 0xFD, 0xFE,
    ]

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func draw(_ cp: UInt32, _ c: SpriteCanvas, width: Int, height: Int, _ m: CellMetrics) {
        let w = width, h = height, t = m.boxThickness
        switch cp {
        case 0x1CD00...0x1CDE5:
            let o = octants[Int(cp - 0x1CD00)]
            let q = Fraction.quarters
            for n in 0..<8 where o & (1 << n) != 0 {
                let row = n / 2
                if n % 2 == 0 {
                    fill(m, c, .zero, .half, q[row], q[row + 1])
                } else {
                    fill(m, c, .half, .one, q[row], q[row + 1])
                }
            }
        case 0x1CC21...0x1CC2F:
            let bits = cp - 0x1CC20
            let gap = max(1, w / 12)
            let midX = gap * 2 + w % 2
            let midY = gap * 2 + h % 2
            let bw = (w - gap * 2 - midX) / 2
            let bh = (h - gap * 2 - midY) / 2
            if bits & 1 != 0 { c.box(gap, gap, gap + bw, gap + bh) }
            if bits & 2 != 0 { c.box(gap + bw + midX, gap, gap + 2 * bw + midX, gap + bh) }
            if bits & 4 != 0 { c.box(gap, gap + bh + midY, gap + bw, gap + 2 * bh + midY) }
            if bits & 8 != 0 { c.box(gap + bw + midX, gap + bh + midY, gap + 2 * bw + midX, gap + 2 * bh + midY) }
        case 0x1CC30...0x1CC3F:
            let pieces: [(Double, Double, Double, Double, Corner)] = [
                (0, 0, 2, 2, .tl), (1, 0, 2, 2, .tl), (2, 0, 2, 2, .tr), (3, 0, 2, 2, .tr),
                (0, 1, 2, 2, .tl), (0, 0, 1, 1, .tl), (1, 0, 1, 1, .tr), (3, 1, 2, 2, .tr),
                (0, 2, 2, 2, .bl), (0, 1, 1, 1, .bl), (1, 1, 1, 1, .br), (3, 2, 2, 2, .br),
                (0, 3, 2, 2, .bl), (1, 3, 2, 2, .bl), (2, 3, 2, 2, .br), (3, 3, 2, 2, .br),
            ]
            let p = pieces[Int(cp - 0x1CC30)]
            circlePiece(c, w, h, m, p.0, p.1, p.2, p.3, p.4)
        case 0x1CC1B:
            BoxDrawing.linesChar(m, c, .init(right: .light, left: .light))
            c.box(w - t, 0, w, h / 2)
        case 0x1CC1C:
            BoxDrawing.linesChar(m, c, .init(right: .light, left: .light))
            c.box(w - t, h / 2, w, h)
        case 0x1CC1D:
            c.box(0, 0, w, t)
            c.box(0, 0, t, h / 2)
        case 0x1CC1E:
            c.box(0, h - t, w, h)
            c.box(0, h / 2, t, h)
        case 0x1CE00:
            LegacyComputing.circle(m, c, .left, filled: false)
            LegacyComputing.circle(m, c, .right, filled: false)
        case 0x1CE01:
            LegacyComputing.circle(m, c, .upper, filled: false)
            LegacyComputing.circle(m, c, .lower, filled: false)
        case 0x1CE0B:
            circlePiece(c, w, h, m, 0, 0, 1, 0.5, .tl)
            circlePiece(c, w, h, m, 0, 0, 1, 0.5, .bl)
        case 0x1CE0C:
            circlePiece(c, w, h, m, 1, 0, 1, 0.5, .tr)
            circlePiece(c, w, h, m, 1, 0, 1, 0.5, .br)
        case 0x1CE16:
            BoxDrawing.linesChar(m, c, .init(up: .light, down: .light))
            c.box(w / 2, 0, w, t)
        case 0x1CE17:
            BoxDrawing.linesChar(m, c, .init(up: .light, down: .light))
            c.box(w / 2, h - t, w, h)
        case 0x1CE18:
            BoxDrawing.linesChar(m, c, .init(up: .light, down: .light))
            c.box(0, 0, w / 2, t)
        case 0x1CE19:
            BoxDrawing.linesChar(m, c, .init(up: .light, down: .light))
            c.box(0, h - t, w / 2, h)
        case 0x1CE51...0x1CE8F:
            let bits = cp - 0x1CE50
            let gap = max(1, w / 12)
            let midX = gap * 2 + w % 2
            let midY = gap * 2 + (h % 3) / 2
            let bw = (w - gap * 2 - midX) / 2
            let bh = (h - gap * 2 - midY * 2) / 3
            let bhm = h - gap * 2 - midY * 2 - bh * 2
            let rows = [(gap, bh), (gap + bh + midY, bhm), (gap + bh + midY + bhm + midY, bh)]
            for (n, row) in rows.enumerated() {
                if bits & (1 << (2 * n)) != 0 { c.box(gap, row.0, gap + bw, row.0 + row.1) }
                if bits & (1 << (2 * n + 1)) != 0 { c.box(gap + bw + midX, row.0, gap + 2 * bw + midX, row.0 + row.1) }
            }
        case 0x1CE90...0x1CEAF:
            let q = Fraction.quarters
            let boxes: [(Int, Int, Int, Int)] = [
                (0, 1, 0, 1), (1, 2, 0, 1), (2, 3, 0, 1), (3, 4, 0, 1),
                (0, 1, 1, 2), (1, 2, 1, 2), (2, 3, 1, 2), (3, 4, 1, 2),
                (0, 1, 2, 3), (1, 2, 2, 3), (2, 3, 2, 3), (3, 4, 2, 3),
                (0, 1, 3, 4), (1, 2, 3, 4), (2, 3, 3, 4), (3, 4, 3, 4),
                (2, 4, 3, 4), (1, 4, 3, 4), (0, 3, 3, 4), (0, 2, 3, 4),
                (0, 1, 2, 4), (0, 1, 1, 4), (0, 1, 0, 3), (0, 1, 0, 2),
                (0, 2, 0, 1), (0, 3, 0, 1), (1, 4, 0, 1), (2, 4, 0, 1),
                (3, 4, 0, 2), (3, 4, 0, 3), (3, 4, 1, 4), (3, 4, 2, 4),
            ]
            let b = boxes[Int(cp - 0x1CE90)]
            fill(m, c, q[b.0], q[b.1], q[b.2], q[b.3])
        default: break
        }
    }

    /// A quarter of an ellipse spanning `w`×`h` cells, of which this cell shows the part at
    /// cell offset (`x`, `y`).
    private static func circlePiece(
        _ c: SpriteCanvas, _ width: Int, _ height: Int, _ m: CellMetrics,
        _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ corner: Corner
    ) {
        let wd = Double(width) * w, hg = Double(height) * h
        let xp = Double(width) * x, yp = Double(height) * y
        c.clipToCell()
        let k = (2.0.squareRoot() - 1) * 4 / 3
        let cw = k * wd, ch = k * hg
        let ht = Double(m.boxThickness) * 0.5
        let path = CGMutablePath()
        switch corner {
        case .tl:
            path.move(to: CGPoint(wd - xp, ht - yp))
            path.addCurve(to: CGPoint(ht - xp, hg - yp), control1: CGPoint(wd - cw - xp, ht - yp), control2: CGPoint(ht - xp, hg - ch - yp))
        case .tr:
            path.move(to: CGPoint(wd - xp, ht - yp))
            path.addCurve(to: CGPoint(wd * 2 - ht - xp, hg - yp), control1: CGPoint(wd + cw - xp, ht - yp), control2: CGPoint(wd * 2 - ht - xp, hg - ch - yp))
        case .bl:
            path.move(to: CGPoint(ht - xp, hg - yp))
            path.addCurve(to: CGPoint(wd - xp, hg * 2 - ht - yp), control1: CGPoint(ht - xp, hg + ch - yp), control2: CGPoint(wd - cw - xp, hg * 2 - ht - yp))
        case .br:
            path.move(to: CGPoint(wd * 2 - ht - xp, hg - yp))
            path.addCurve(to: CGPoint(wd - xp, hg * 2 - ht - yp), control1: CGPoint(wd * 2 - ht - xp, hg + ch - yp), control2: CGPoint(wd + cw - xp, hg * 2 - ht - yp))
        }
        c.stroke(path, lineWidth: CGFloat(m.boxThickness))
    }
}
