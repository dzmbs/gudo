import CoreGraphics

// Ported from Ghostty src/font/sprite/Face.zig and draw/special.zig (MIT).

/// Procedurally drawn glyphs that are not Unicode characters (Ghostty's `Sprite` enum): cursor
/// shapes and text decorations.
enum Sprite: Hashable, CaseIterable {
    case cursorRect, cursorHollowRect, cursorBar, cursorUnderline
    case underline, underlineDouble, underlineCurly, underlineDotted, underlineDashed
    case strikethrough, overline
}

/// Ghostty's built-in "sprite face": box drawing, block elements, braille, Powerline, branch
/// drawing and legacy computing symbols drawn from the cell metrics, so lines join exactly across
/// cells at any size, plus the cursor and decoration sprites.
enum SpriteFace {
    /// Whether `cp` is drawn here instead of taken from a font. Like Ghostty, the sprite face has
    /// priority over every font face for these codepoints.
    static func covers(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x2500...0x259F, 0x2800...0x28FF, 0xF5D0...0xF60D,
             0x25E2...0x25E5, 0x25F8...0x25FA, 0x25FF:
            true
        case 0xE0B0...0xE0D4: Powerline.codepoints.contains(cp)
        case 0x1FB00...0x1FBFF: LegacyComputing.covers(cp)
        case 0x1CC00...0x1CEBF: LegacyComputingSupplement.covers(cp)
        default: false
        }
    }

    /// Draws a codepoint into a fresh canvas `span` cells wide. Nil when the glyph is empty.
    static func render(_ cp: UInt32, metrics m: CellMetrics, span: Int) -> SpriteCanvas? {
        guard covers(cp) else { return nil }
        let width = m.cellWidth * max(1, span), height = m.cellHeight
        let canvas = SpriteCanvas(width: width, height: height)
        switch cp {
        case 0x2500...0x257F: BoxDrawing.draw(cp, canvas, m)
        case 0x2580...0x259F: BlockElements.draw(cp, canvas, m)
        case 0x2800...0x28FF: Braille.draw(cp, canvas, width: width, height: height)
        case 0x25E2...0x25FF: GeometricShapes.draw(cp, canvas, m)
        case 0xE0B0...0xE0D4: Powerline.draw(cp, canvas, width: width, height: height, m)
        case 0xF5D0...0xF60D: BranchDrawing.draw(cp, canvas, m)
        case 0x1FB00...0x1FBFF: LegacyComputing.draw(cp, canvas, width: width, height: height, m)
        case 0x1CC00...0x1CEBF: LegacyComputingSupplement.draw(cp, canvas, width: width, height: height, m)
        default: break
        }
        return canvas
    }

    /// Draws a cursor or decoration sprite `span` cells wide.
    static func render(_ sprite: Sprite, metrics m: CellMetrics, span: Int) -> SpriteCanvas {
        let width = m.cellWidth * max(1, span), height = m.cellHeight
        let c = SpriteCanvas(width: width, height: height)
        // Decorations may hang below the cell, but never past the canvas margin.
        let underlineY = min(m.underlinePosition, height + c.paddingY - m.underlineThickness)
        switch sprite {
        case .cursorRect:
            c.rect(x: 0, y: 0, width: width, height: height)
        case .cursorHollowRect:
            c.rect(x: 0, y: 0, width: width, height: height)
            c.rect(
                x: m.cursorThickness, y: m.cursorThickness,
                width: sat(width, m.cursorThickness * 2), height: sat(height, m.cursorThickness * 2), Shade.off)
        case .cursorBar:
            // Half its thickness over the left edge, so it sits between characters.
            c.rect(x: -((m.cursorThickness + 1) / 2), y: 0, width: m.cursorThickness, height: height)
        case .cursorUnderline:
            c.rect(x: 0, y: underlineY, width: width, height: m.cursorThickness)
        case .underline:
            c.rect(x: 0, y: underlineY, width: width, height: m.underlineThickness)
        case .underlineDouble:
            // One line above the single-underline position and one below it.
            let y = min(m.underlinePosition, height + c.paddingY - 2 * m.underlineThickness)
            c.rect(x: 0, y: sat(y, m.underlineThickness), width: width, height: m.underlineThickness)
            c.rect(x: 0, y: y + m.underlineThickness, width: width, height: m.underlineThickness)
        case .underlineDotted:
            dotted(c, m, width: width, height: height)
        case .underlineDashed:
            let dashWidth = width / 3 + 1
            let dashCount = width / dashWidth + 1
            for i in stride(from: 0, to: dashCount, by: 2) {
                c.rect(x: i * dashWidth, y: underlineY, width: dashWidth, height: m.underlineThickness)
            }
        case .underlineCurly:
            curly(c, m, width: width, height: height)
        case .strikethrough:
            c.rect(x: 0, y: m.strikethroughPosition, width: width, height: m.strikethroughThickness)
        case .overline:
            c.rect(x: 0, y: max(m.overlinePosition, -c.paddingY), width: width, height: m.overlineThickness)
        }
        return c
    }

    private static func dotted(_ c: SpriteCanvas, _ m: CellMetrics, width: Int, height: Int) {
        let w = Double(width), h = Double(height)
        let thick = Double(m.underlineThickness)
        // Dots √2 × the underline thickness across; thinner looks anaemic.
        let radius = 0.5.squareRoot() * thick
        let y = min(Double(m.underlinePosition) + 0.5 * thick, h + Double(c.paddingY) - radius.rounded(.up))
        let dotCount = max(
            min((w / (4 * radius)).rounded(.up), (w / (3 * radius)).rounded(.down), (w / (2 * radius + 1)).rounded(.down)),
            1)
        let path = CGMutablePath()
        var x = (w / dotCount) / 2
        for _ in 0..<Int(dotCount) {
            path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
            x += w / dotCount
        }
        c.fill(path)
    }

    private static func curly(_ c: SpriteCanvas, _ m: CellMetrics, width: Int, height: Int) {
        let w = Double(width), h = Double(height)
        let lineWidth = Double(m.underlineThickness)
        let amplitude = w / .pi
        let top = min(Double(m.underlinePosition), h + Double(c.paddingY) - amplitude - lineWidth)
        let bottom = top + amplitude
        let r = 0.4
        let center = 0.5 * w
        // One cycle of a wave that peaks at the centre of the cell, so neighbours continue it.
        let path = CGMutablePath()
        path.move(to: CGPoint(0, bottom))
        path.addCurve(to: CGPoint(center, top), control1: CGPoint(center * r, bottom), control2: CGPoint(center - center * r, top))
        path.addCurve(to: CGPoint(w, bottom), control1: CGPoint(center + center * r, top), control2: CGPoint(w - center * r, bottom))
        c.stroke(path, lineWidth: lineWidth, cap: .round)
    }
}
