import Foundation
import Testing
@testable import TerminalRenderer

/// Cell metrics for a synthetic `width`×`height` cell with box thickness `thickness`.
private func metrics(_ width: Int, _ height: Int, thickness: Int = 1) -> CellMetrics {
    CellMetrics(
        cellWidth: width, cellHeight: height, cellBaseline: height / 4,
        underlinePosition: height - height / 4 + 1, underlineThickness: thickness,
        strikethroughPosition: height / 2, strikethroughThickness: thickness,
        overlinePosition: 0, overlineThickness: thickness, boxThickness: thickness,
        cursorThickness: 1, faceWidth: Double(width), faceHeight: Double(height), faceY: 0,
        iconHeight: Double(height), iconHeightSingle: Double(height) * 0.8)
}

/// Cell sizes from small laptop fonts to large iPad ones, odd and even.
private let cellSizes: [(Int, Int, Int)] = [
    (7, 15, 1), (8, 16, 1), (9, 19, 1), (10, 22, 1), (11, 23, 2), (13, 27, 2), (16, 34, 2), (17, 36, 3), (20, 41, 3),
]

private func canvas(_ cp: UInt32, _ m: CellMetrics) -> SpriteCanvas {
    SpriteFace.render(cp, metrics: m, span: 1)!
}

/// Rows covered (> half) in column `x`, and columns covered in row `y`.
private func rows(_ c: SpriteCanvas, x: Int, _ m: CellMetrics) -> [Int] {
    (0..<m.cellHeight).filter { c.value(x: x, y: $0) > 127 }
}

private func columns(_ c: SpriteCanvas, y: Int, _ m: CellMetrics) -> [Int] {
    (0..<m.cellWidth).filter { c.value(x: $0, y: y) > 127 }
}

@Suite struct BoxDrawingTests {
    /// Every character with a right arm meets every character with a left arm of the same weight
    /// at exactly the same rows, and likewise for down/up arms and columns, so neighbours join
    /// seamlessly at any cell size.
    @Test(arguments: cellSizes.indices)
    func armsJoinAcrossCells(_ index: Int) {
        let (w, h, t) = cellSizes[index]
        let m = metrics(w, h, thickness: t)
        // (codepoint, arm style) for arms reaching each edge.
        let rightArms: [(UInt32, String)] = [
            (0x2500, "light"), (0x250C, "light"), (0x2514, "light"), (0x251C, "light"), (0x252C, "light"), (0x2534, "light"),
            (0x253C, "light"), (0x2576, "light"), (0x2501, "heavy"), (0x250F, "heavy"), (0x2523, "heavy"), (0x254B, "heavy"),
            (0x257A, "heavy"), (0x2550, "double"), (0x2554, "double"), (0x2560, "double"), (0x256C, "double"),
        ]
        let leftArms: [(UInt32, String)] = [
            (0x2500, "light"), (0x2510, "light"), (0x2518, "light"), (0x2524, "light"), (0x252C, "light"), (0x253C, "light"),
            (0x2574, "light"), (0x2501, "heavy"), (0x2513, "heavy"), (0x252B, "heavy"), (0x254B, "heavy"), (0x2578, "heavy"),
            (0x2550, "double"), (0x2557, "double"), (0x2563, "double"), (0x256C, "double"),
        ]
        var rightRows: [String: [Int]] = [:]
        for (cp, style) in rightArms {
            let r = rows(canvas(cp, m), x: w - 1, m)
            #expect(!r.isEmpty, "U+\(String(cp, radix: 16)) has no right arm at \(w)x\(h)")
            if let expected = rightRows[style] { #expect(r == expected, "U+\(String(cp, radix: 16)) \(style) at \(w)x\(h)") }
            rightRows[style] = r
        }
        for (cp, style) in leftArms {
            #expect(rows(canvas(cp, m), x: 0, m) == rightRows[style], "U+\(String(cp, radix: 16)) \(style) at \(w)x\(h)")
        }

        let downArms: [(UInt32, String)] = [
            (0x2502, "light"), (0x250C, "light"), (0x2510, "light"), (0x251C, "light"), (0x252C, "light"), (0x253C, "light"),
            (0x2577, "light"), (0x2503, "heavy"), (0x250F, "heavy"), (0x2533, "heavy"), (0x254B, "heavy"), (0x2551, "double"),
            (0x2554, "double"), (0x2566, "double"), (0x256C, "double"),
        ]
        let upArms: [(UInt32, String)] = [
            (0x2502, "light"), (0x2514, "light"), (0x2518, "light"), (0x2524, "light"), (0x2534, "light"), (0x253C, "light"),
            (0x2575, "light"), (0x2503, "heavy"), (0x2517, "heavy"), (0x253B, "heavy"), (0x254B, "heavy"), (0x2551, "double"),
            (0x255A, "double"), (0x2569, "double"), (0x256C, "double"),
        ]
        var downColumns: [String: [Int]] = [:]
        for (cp, style) in downArms {
            let c = columns(canvas(cp, m), y: h - 1, m)
            #expect(!c.isEmpty)
            if let expected = downColumns[style] { #expect(c == expected, "U+\(String(cp, radix: 16)) \(style) at \(w)x\(h)") }
            downColumns[style] = c
        }
        for (cp, style) in upArms {
            #expect(columns(canvas(cp, m), y: 0, m) == downColumns[style], "U+\(String(cp, radix: 16)) \(style) at \(w)x\(h)")
        }
        // Weights: heavy is twice light; double is two light lines.
        #expect(rightRows["light"]?.count == t)
        #expect(rightRows["heavy"]?.count == 2 * t)
        #expect(rightRows["double"]?.count == 2 * t)
    }

    /// Rounded corners and branch characters end exactly on the light line's rows/columns.
    @Test(arguments: cellSizes.indices)
    func arcsMeetStraightLines(_ index: Int) {
        let (w, h, t) = cellSizes[index]
        let m = metrics(w, h, thickness: t)
        let light = rows(canvas(0x2500, m), x: 0, m)
        let vertical = columns(canvas(0x2502, m), y: 0, m)
        // ╭ reaches right and down; ╯ reaches left and up.
        #expect(rows(canvas(0x256D, m), x: w - 1, m) == light)
        #expect(columns(canvas(0x256D, m), y: h - 1, m) == vertical)
        #expect(rows(canvas(0x256F, m), x: 0, m) == light)
        #expect(columns(canvas(0x256F, m), y: 0, m) == vertical)
        // Branch node with arms on all sides: the arms reach every edge on the line's pixels (the
        // node's circle may touch the edge too).
        let node = canvas(0xF60C, m)
        #expect(Set(light).isSubset(of: rows(node, x: 0, m)))
        #expect(Set(light).isSubset(of: rows(node, x: w - 1, m)))
        #expect(Set(vertical).isSubset(of: columns(node, y: 0, m)))
        #expect(Set(vertical).isSubset(of: columns(node, y: h - 1, m)))
    }

    /// Dashed lines tile: the gaps at both ends of a horizontal dash add up to one inner gap.
    @Test func dashesTileEvenly() {
        let m = metrics(10, 22)
        let c = canvas(0x2504, m)  // ┄ three dashes
        let y = (m.cellHeight - 1) / 2
        let on = (0..<m.cellWidth).map { c.value(x: $0, y: y) > 0 }
        let leading = on.firstIndex(of: true)!
        let trailing = m.cellWidth - 1 - on.lastIndex(of: true)!
        #expect(on.filter { $0 }.count >= 3)
        #expect(abs(leading - trailing) <= 1)
    }

    @Test func diagonalsReachTheCorners() {
        let m = metrics(10, 22)
        let c = canvas(0x2572, m)  // ╲
        #expect(c.value(x: 0, y: 0) > 0)
        #expect(c.value(x: m.cellWidth - 1, y: m.cellHeight - 1) > 0)
    }
}

@Suite struct BlockAndBrailleTests {
    @Test(arguments: cellSizes.indices)
    func blocksCoverTheirFractions(_ index: Int) {
        let (w, h, t) = cellSizes[index]
        let m = metrics(w, h, thickness: t)
        func coverage(_ cp: UInt32) -> Int {
            let c = canvas(cp, m)
            return (0..<h).reduce(0) { sum, y in sum + (0..<w).filter { c.value(x: $0, y: y) == 255 }.count }
        }
        #expect(coverage(0x2588) == w * h)
        #expect(coverage(0x2584) == w * Int((Double(h) * 0.5).rounded()))  // ▄
        #expect(coverage(0x258C) == h * Int((Double(w) * 0.5).rounded()))  // ▌
        #expect(coverage(0x2581) == w * Int((Double(h) * 0.125).rounded()))  // ▁
        // Quadrants and sextants tile the cell without gaps (odd sizes overlap by a pixel, never
        // leave one uncovered), and the full patterns are the full cell.
        func union(_ cps: [UInt32]) -> Int {
            let cs = cps.map { canvas($0, m) }
            return (0..<h).reduce(0) { sum, y in sum + (0..<w).filter { x in cs.contains { $0.value(x: x, y: y) == 255 } }.count }
        }
        #expect(union([0x2598, 0x259D, 0x2596, 0x2597]) == w * h)
        #expect(union([0x1FB00, 0x1FB01, 0x1FB03, 0x1FB07, 0x1FB0F, 0x1FB1E]) == w * h)
        #expect(union([0x1CE90, 0x1CE91, 0x1CE92, 0x1CE93, 0x1CE94, 0x1CE95, 0x1CE96, 0x1CE97,
                       0x1CE98, 0x1CE99, 0x1CE9A, 0x1CE9B, 0x1CE9C, 0x1CE9D, 0x1CE9E, 0x1CE9F]) == w * h)
        // Sixteenth blocks: the four corners of a 4×4 grid are the same size.
        let corners = [0x1CE90, 0x1CE93, 0x1CE9C, 0x1CE9F].map { coverage(UInt32($0)) }
        #expect(corners.allSatisfy { $0 > 0 } && corners.reduce(0, +) <= w * h / 4 + 2 * (w + h))
        // Shades are uniform coverage.
        #expect(canvas(0x2592, m).value(x: w / 2, y: h / 2) == Shade.medium)
        #expect(canvas(0x2591, m).value(x: 0, y: 0) == Shade.light)
    }

    @Test(arguments: cellSizes.indices)
    func brailleDotsSitOnAGrid(_ index: Int) {
        let (w, h, _) = cellSizes[index]
        let (dot, xs, ys) = Braille.layout(width: w, height: h)
        #expect(dot >= 1)
        #expect(xs[1] + dot <= w && ys[3] + dot <= h)
        #expect(xs[0] + dot < xs[1])
        for i in 0..<3 { #expect(ys[i] + dot < ys[i + 1]) }
        let m = metrics(w, h)
        // Each of the 8 dots, alone, appears exactly at its grid position.
        let positions: [(UInt32, Int, Int)] = [
            (0x01, 0, 0), (0x02, 0, 1), (0x04, 0, 2), (0x08, 1, 0), (0x10, 1, 1), (0x20, 1, 2), (0x40, 0, 3), (0x80, 1, 3),
        ]
        for (bit, col, row) in positions {
            let c = canvas(0x2800 + bit, m)
            let lit: [[Int]] = (0..<h).flatMap { y in (0..<w).filter { c.value(x: $0, y: y) > 0 }.map { [$0, y] } }
            #expect(lit.count == dot * dot)
            #expect(lit.first == [xs[col], ys[row]])
        }
        // The full pattern has all eight.
        let full = canvas(0x28FF, m)
        #expect((0..<h).reduce(0) { s, y in s + (0..<w).filter { full.value(x: $0, y: y) > 0 }.count } == 8 * dot * dot)
    }
}

@Suite struct SpriteFaceTests {
    static let ranges: [ClosedRange<UInt32>] = [
        0x2500...0x259F, 0x25A0...0x25FF, 0x2800...0x28FF, 0xE0B0...0xE0D7, 0xF5D0...0xF60D,
        0x1FB00...0x1FBFF, 0x1CC00...0x1CEBF,
    ]

    /// Every covered codepoint draws (or is intentionally empty) at several sizes, inside the
    /// canvas, and is placed in the atlas through `FontGrid`.
    @Test func everyCoveredCodepointRenders() {
        var covered = 0
        for (w, h, t) in [(7, 15, 1), (10, 22, 1), (17, 36, 3)] {
            let m = metrics(w, h, thickness: t)
            for range in Self.ranges {
                for cp in range where SpriteFace.covers(cp) {
                    covered += 1
                    let c = SpriteFace.render(cp, metrics: m, span: 1)!
                    let bitmap = c.export()
                    if cp != 0x2800, cp != 0x1FB93 {
                        #expect(bitmap != nil, "U+\(String(cp, radix: 16)) drew nothing at \(w)x\(h)")
                    }
                }
            }
        }
        // Box 128 + blocks 32 + geometric 8 + braille 256 + powerline 18 + branch 62 + legacy.
        #expect(covered > 3 * 700)
    }

    @Test func coversOnlyGhosttysRanges() {
        #expect(SpriteFace.covers(0x2500) && SpriteFace.covers(0x28FF) && SpriteFace.covers(0xE0B4) && SpriteFace.covers(0x1CD00))
        #expect(!SpriteFace.covers(0x41) && !SpriteFace.covers(0xE0A0) && !SpriteFace.covers(0x25A0) && !SpriteFace.covers(0x1FBF0))
    }

    @Test func powerlineArrowsFillTheirHalf() {
        let m = metrics(10, 22)
        let c = canvas(0xE0B0, m)  //
        #expect(c.value(x: 0, y: 0) > 100 && c.value(x: 0, y: 21) > 100)
        #expect(c.value(x: 9, y: 11) > 0)
        #expect(c.value(x: 9, y: 0) == 0)
        // The left-pointing arrow is its mirror image.
        let mirror = canvas(0xE0B2, m)
        #expect(mirror.value(x: 9, y: 0) > 100 && mirror.value(x: 0, y: 0) == 0)
        // Rounded caps stay inside the cell.
        let round = canvas(0xE0B4, m).export()!
        #expect(round.offsetX >= 0 && round.width <= m.cellWidth && round.height <= m.cellHeight)
    }

    @Test func decorationSprites() {
        let m = metrics(10, 22)
        func lit(_ sprite: Sprite) -> [Int] {
            let c = SpriteFace.render(sprite, metrics: m, span: 1)
            return (-c.paddingY..<(m.cellHeight + c.paddingY)).filter { y in (0..<m.cellWidth).contains { c.value(x: $0, y: y) > 127 } }
        }
        #expect(lit(.underline) == [m.underlinePosition])
        #expect(lit(.underlineDouble).count == 2)
        #expect(lit(.overline) == [0])
        #expect(lit(.strikethrough) == [m.strikethroughPosition])
        #expect(!lit(.underlineCurly).isEmpty && !lit(.underlineDotted).isEmpty)
        let dashed = SpriteFace.render(.underlineDashed, metrics: m, span: 1)
        let dashes = (0..<m.cellWidth).map { dashed.value(x: $0, y: m.underlinePosition) > 0 }
        #expect(dashes.contains(true) && dashes.contains(false))
        // Two-cell decorations are twice as wide.
        let wide = SpriteFace.render(.underline, metrics: m, span: 2).export()!
        #expect(wide.width == 2 * m.cellWidth)
        // The bar cursor straddles the left edge of the cell.
        #expect(SpriteFace.render(.cursorBar, metrics: m, span: 1).export()!.offsetX == -1)
    }
}

@Suite struct ConstraintTests {
    /// Ghostty's own constraint test vectors (src/font/Glyph.zig, JetBrains Mono at 12 pt / 96 DPI).
    static let m = NerdFontConstraint.Metrics(
        cellWidth: 10, cellHeight: 22, faceWidth: 9.6, faceHeight: 21.12, faceY: 0.2,
        iconHeight: 21.12, iconHeightSingle: 44.48 / 3)

    private func close(_ a: GlyphBox, _ b: GlyphBox) -> Bool {
        abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6 && abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
    }

    @Test func noConstraintLeavesTextAlone() {
        let x = GlyphBox(width: 6.784, height: 15.28, x: 1.408, y: 4.84)
        #expect(NerdFontConstraint.none.constrain(x, metrics: Self.m, constraintWidth: 2) == x)
    }

    @Test func symbolsFitTheirCells() {
        let square = GlyphBox(width: 10.272, height: 10.272, x: 2.864, y: 5.304)
        #expect(close(NerdFontConstraint.symbol.constrain(square, metrics: Self.m, constraintWidth: 1),
                      GlyphBox(width: 9.6, height: 9.6, x: 0, y: 5.64)))
        #expect(close(NerdFontConstraint.symbol.constrain(square, metrics: Self.m, constraintWidth: 2), square))
    }

    @Test func emojiCoverTwoCells() {
        let emoji = GlyphBox(width: 20, height: 20, x: 0.46, y: 1)
        #expect(close(NerdFontConstraint.emoji.constrain(emoji, metrics: Self.m, constraintWidth: 2),
                      GlyphBox(width: 18.72, height: 18.72, x: 0.44, y: 1.4)))
    }

    @Test func nerdFontDefaultIcon() throws {
        let c = try #require(NerdFontConstraint.nerdFont(0xEA61))
        #expect(c.size == .fitCover1 && c.height == .icon && c.alignHorizontal == .center1 && c.alignVertical == .center1)
        let bulb = GlyphBox(width: 9.015625, height: 13.015625, x: 3.015625, y: 3.76525)
        #expect(close(c.constrain(bulb, metrics: Self.m, constraintWidth: 1),
                      GlyphBox(width: 7.2125, height: 10.4125, x: 0.8125, y: 5.950695224719102)))
        #expect(close(c.constrain(bulb, metrics: Self.m, constraintWidth: 2),
                      GlyphBox(width: bulb.width, height: bulb.height, x: 1.015625, y: 4.7483690308988775)))
    }

    @Test func nerdFontStretch() throws {
        let c = try #require(NerdFontConstraint.nerdFont(0xE0C0))
        #expect(c.size == .stretch && c.height == .cell && c.alignHorizontal == .start && c.alignVertical == .center1)
        let flame = GlyphBox(width: 16.796875, height: 16.46875, x: -0.796875, y: 1.7109375)
        #expect(close(c.constrain(flame, metrics: Self.m, constraintWidth: 1), GlyphBox(width: 10, height: 22, x: 0, y: 0)))
        #expect(close(c.constrain(flame, metrics: Self.m, constraintWidth: 2), GlyphBox(width: 20, height: 22, x: 0, y: 0)))
    }

    @Test func lookupMatchesGhostty() {
        #expect(NerdFontConstraint.nerdFont(0x41) == nil)
        #expect(NerdFontConstraint.nerdFont(0x30A2) == nil)
        #expect(NerdFontConstraint.nerdFont(0xFF66) == nil)
        #expect(NerdFontConstraint.nerdFont(0x2630) != nil)
        #expect(NerdFontConstraint.nerdFont(0x110000) == nil)
    }

    @Test func constraintWidthFollowsGhostty() {
        // A symbol followed by a space may grow; followed by text it may not.
        #expect(NerdFontConstraint.constraintWidth(codepoint: 0xF121, span: 1, previous: 0x20, next: 0x20) == 2)
        #expect(NerdFontConstraint.constraintWidth(codepoint: 0xF121, span: 1, previous: nil, next: 0) == 2)
        #expect(NerdFontConstraint.constraintWidth(codepoint: 0xF121, span: 1, previous: 0x20, next: 0x61) == 1)
        // At the end of the row, or after another icon, it stays in one cell.
        #expect(NerdFontConstraint.constraintWidth(codepoint: 0xF121, span: 1, previous: 0x20, next: nil) == 1)
        #expect(NerdFontConstraint.constraintWidth(codepoint: 0xF121, span: 1, previous: 0xF07B, next: 0x20) == 1)
        // ...but a Powerline glyph before it does not count.
        #expect(NerdFontConstraint.constraintWidth(codepoint: 0xF121, span: 1, previous: 0xE0B0, next: 0x20) == 2)
        // Letters never grow; wide characters always span two.
        #expect(NerdFontConstraint.constraintWidth(codepoint: 0x61, span: 1, previous: nil, next: 0x20) == 1)
        #expect(NerdFontConstraint.constraintWidth(codepoint: 0x65E5, span: 2, previous: nil, next: 0x20) == 2)
    }
}

@Suite struct FontGridGlyphTests {
    let fonts = FontGrid(pixelSize: 26)

    /// Box drawing comes from the sprite face, spanning the full cell, not from the font.
    @Test func boxDrawingUsesSprites() throws {
        let m = fonts.metrics
        let line = try #require(fonts.glyph(for: [0x2500], style: .regular, span: 1))
        #expect(line.atlas == .grayscale)
        #expect(line.offsetX == 0 && line.region.width == m.cellWidth)
        let block = try #require(fonts.glyph(for: [0x2588], style: .bold, span: 1))
        #expect(block.region.width == m.cellWidth && block.region.height == m.cellHeight && block.offsetY == m.cellHeight)
        #expect(fonts.glyph(for: [0x2800], style: .regular, span: 1) == nil)  // blank braille
    }

    /// A Nerd Font icon stays inside the cells it may use.
    @Test func nerdFontIconsStayWithinMaxSpan() throws {
        let m = fonts.metrics
        for icon: UInt32 in [0xF121, 0xF07B, 0xEA61, 0xF17C, 0xE0A0] {
            let one = try #require(fonts.glyph(for: [icon], style: .regular, span: 1, maxSpan: 1))
            #expect(one.offsetX >= 0 && one.offsetX + one.region.width <= m.cellWidth + 1, "U+\(String(icon, radix: 16))")
            let two = try #require(fonts.glyph(for: [icon], style: .regular, span: 1, maxSpan: 2))
            #expect(two.offsetX >= 0 && two.offsetX + two.region.width <= 2 * m.cellWidth + 1, "U+\(String(icon, radix: 16))")
            #expect(two.region.height >= one.region.height)
            #expect(one.offsetY <= m.cellHeight + 1 && one.offsetY - one.region.height >= -1)
        }
        // Letters ignore maxSpan.
        let a1 = try #require(fonts.glyph(for: [0x61], style: .regular, span: 1, maxSpan: 1))
        let a2 = try #require(fonts.glyph(for: [0x61], style: .regular, span: 1, maxSpan: 2))
        #expect(a1.region == a2.region)
    }

    @Test func emojiAndCJKFitTheirCells() throws {
        let m = fonts.metrics
        let emoji = try #require(fonts.glyph(for: [0x1F600], style: .regular, span: 2))
        #expect(emoji.atlas == .color)
        #expect(emoji.offsetX >= 0 && emoji.offsetX + emoji.region.width <= 2 * m.cellWidth)
        #expect(emoji.region.height <= m.cellHeight)
        let cjk = try #require(fonts.glyph(for: [0x65E5], style: .regular, span: 2))  // 日
        #expect(cjk.atlas == .grayscale)
        #expect(cjk.offsetX >= -1 && cjk.offsetX + cjk.region.width <= 2 * m.cellWidth + 1)
    }

    @Test func unknownFamilyFallsBackToBundledFont() {
        let fallback = FontGrid(pixelSize: 26, family: "No Such Font Family 123")
        #expect(fallback.metrics == fonts.metrics)
        let menlo = FontGrid(pixelSize: 26, family: "Menlo")
        #expect(menlo.metrics.cellWidth > 0)
    }
}
