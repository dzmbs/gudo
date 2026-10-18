// Ported from Ghostty src/font/Glyph.zig (`RenderOptions.Constraint`), src/font/nerd_font_attributes.zig
// and src/renderer/cell.zig (`constraintWidth`, `isSymbol`) (MIT).

/// A glyph's bounding box in pixels, cell-relative: `x` from the left of the cell, `y` from the
/// bottom of the cell up to the bottom of the glyph.
struct GlyphBox: Equatable {
    var width: Double
    var height: Double
    var x: Double
    var y: Double
}

/// How a glyph is scaled and aligned into its cell(s): Nerd Font icons (rules from the Nerd Fonts
/// patcher), emoji, and other symbols.
struct NerdFontConstraint: Equatable {
    enum Size { case none, fit, cover, fitCover1, stretch }
    enum Align { case none, start, end, center, center1 }
    enum Height { case cell, icon }

    var size: Size = .none
    var height: Height = .cell
    var maxConstraintWidth = 2
    var alignHorizontal: Align = .none
    var alignVertical: Align = .none
    var padTop = 0.0
    var padLeft = 0.0
    var padRight = 0.0
    var padBottom = 0.0
    /// Size and position of the glyph within the bounding box of its scale group.
    var relativeWidth = 1.0
    var relativeHeight = 1.0
    var relativeX = 0.0
    var relativeY = 0.0
    var maxXYRatio: Double?

    init(
        size: Size = .none, height: Height = .cell, maxConstraintWidth: Int = 2,
        alignHorizontal: Align = .none, alignVertical: Align = .none,
        padTop: Double = 0, padLeft: Double = 0, padRight: Double = 0, padBottom: Double = 0,
        relativeWidth: Double = 1, relativeHeight: Double = 1, relativeX: Double = 0, relativeY: Double = 0,
        maxXYRatio: Double? = nil
    ) {
        self.size = size
        self.height = height
        self.maxConstraintWidth = maxConstraintWidth
        self.alignHorizontal = alignHorizontal
        self.alignVertical = alignVertical
        self.padTop = padTop
        self.padLeft = padLeft
        self.padRight = padRight
        self.padBottom = padBottom
        self.relativeWidth = relativeWidth
        self.relativeHeight = relativeHeight
        self.relativeX = relativeX
        self.relativeY = relativeY
        self.maxXYRatio = maxXYRatio
    }

    static let none = NerdFontConstraint()

    /// Ghostty's rule for symbols without a Nerd Font entry: shrink to fit, never move.
    static let symbol = NerdFontConstraint(size: .fit)

    /// Ghostty's rule for every color (emoji) glyph.
    static let emoji = NerdFontConstraint(size: .cover, alignHorizontal: .center, alignVertical: .center, padLeft: 0.025, padRight: 0.025)

    var doesAnything: Bool { size != .none || alignHorizontal != .none || alignVertical != .none }

    /// The Nerd Font constraint for `cp`, if it is a patched icon.
    static func nerdFont(_ cp: UInt32) -> NerdFontConstraint? {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if cp < r.first { hi = mid - 1 } else if cp > r.last { lo = mid + 1 } else { return table[Int(r.index)] }
        }
        return nil
    }

    /// The constraint Ghostty's renderer applies to a cell's base codepoint (before the emoji
    /// override, which depends on the face).
    static func forCodepoint(_ cp: UInt32) -> NerdFontConstraint {
        nerdFont(cp) ?? (isSymbol(cp) ? .symbol : .none)
    }

    // MARK: Constraint width

    /// Ghostty's "symbol-like" characters: private use areas and the arrows, dingbats, emoticons,
    /// miscellaneous symbols, enclosed alphanumerics, pictographs and transport blocks.
    static func isSymbol(_ cp: UInt32) -> Bool {
        switch cp {
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD,
             0x2190...0x21FF, 0x2460...0x24FF, 0x2600...0x26FF, 0x2700...0x27BF,
             0x1F100...0x1F1FF, 0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF:
            true
        default: false
        }
    }

    /// Box drawing, blocks, legacy computing and Powerline: symbols meant to tile, which do not
    /// stop the next symbol from growing into a free cell.
    static func isGraphicsElement(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x2500...0x259F, 0x1FB00...0x1FBFF, 0x1CC00...0x1CEBF, 0xE0B0...0xE0D7: true
        default: false
        }
    }

    /// How many cells a narrow cell's glyph may grow into (Ghostty's `constraintWidth`): 2 for a
    /// symbol followed by a blank cell, unless the previous cell is also a (non-graphics) symbol
    /// so that runs of icons stay aligned. `previous`/`next` are the neighbouring cells' base
    /// codepoints (0 for empty), nil at the edges of the row. Wide cells always get 2.
    static func constraintWidth(codepoint cp: UInt32, span: Int, previous: UInt32?, next: UInt32?) -> Int {
        guard span < 2 else { return span }
        guard isSymbol(cp), let next else { return 1 }
        if let previous, isSymbol(previous), !isGraphicsElement(previous) { return 1 }
        return next == 0 || next == 0x20 || next == 0x2002 ? 2 : 1
    }

    // MARK: Constrain

    /// Grid metrics the constraint arithmetic needs (Ghostty's `Metrics` subset).
    struct Metrics {
        var cellWidth: Double
        var cellHeight: Double
        var faceWidth: Double
        var faceHeight: Double
        var faceY: Double
        var iconHeight: Double
        var iconHeightSingle: Double
    }

    /// Scales and positions `glyph` within `constraintWidth` cells.
    func constrain(_ glyph: GlyphBox, metrics: Metrics, constraintWidth: Int) -> GlyphBox {
        guard doesAnything else { return glyph }
        guard size == .stretch else { return constrainInner(glyph, metrics, constraintWidth) }
        // Stretched glyphs align to the grid, not the face, and need no negative padding.
        var m = metrics
        m.faceWidth = m.cellWidth
        m.faceHeight = m.cellHeight
        m.faceY = 0
        var c = self
        c.padBottom = max(0, c.padBottom)
        c.padTop = max(0, c.padTop)
        c.padLeft = max(0, c.padLeft)
        c.padRight = max(0, c.padRight)
        return c.constrainInner(glyph, m, constraintWidth)
    }

    private func constrainInner(_ glyph: GlyphBox, _ m: Metrics, _ constraintWidth: Int) -> GlyphBox {
        // Never stretch across two cells for extra-wide faces (as font_patcher).
        let width = size == .stretch && m.faceWidth > 0.9 * m.faceHeight ? 1 : min(maxConstraintWidth, constraintWidth)

        let groupWidth = glyph.width / relativeWidth
        let groupHeight = glyph.height / relativeHeight
        var group = GlyphBox(
            width: groupWidth, height: groupHeight,
            x: glyph.x - groupWidth * relativeX, y: glyph.y - groupHeight * relativeY)

        let (wf, hf) = scaleFactors(group, m, width)
        let centerX = group.x + group.width / 2
        let centerY = group.y + group.height / 2
        group.width *= wf
        group.height *= hf
        group.x = centerX - group.width / 2
        group.y = centerY - group.height / 2

        group.y = alignedY(group, m)
        group.x = alignedX(group, m, width)

        return GlyphBox(
            width: wf * glyph.width, height: hf * glyph.height,
            x: group.x + group.width * relativeX, y: group.y + group.height * relativeY)
    }

    private func scaleFactors(_ group: GlyphBox, _ m: Metrics, _ width: Int) -> (Double, Double) {
        guard size != .none else { return (1, 1) }
        let multiCell = width > 1
        let targetWidth = (Double(width) - (padLeft + padRight)) * m.faceWidth
        let targetHeight = (1 - (padBottom + padTop)) * (height == .cell ? m.faceHeight : multiCell ? m.iconHeight : m.iconHeightSingle)
        var wf = targetWidth / group.width
        var hf = targetHeight / group.height
        switch size {
        case .none: break
        case .fit:
            hf = min(1, wf, hf)
            wf = hf
        case .cover:
            hf = min(wf, hf)
            wf = hf
        case .fitCover1:
            hf = min(wf, hf)
            if multiCell, hf > 1 {
                // As large as for a single cell, never shrinking when a space opens up after it.
                hf = max(1, scaleFactors(group, m, 1).1)
            }
            wf = hf
        case .stretch: break
        }
        if let ratio = maxXYRatio, group.width * wf > group.height * hf * ratio {
            wf = group.height * hf * ratio / group.width
        }
        return (wf, hf)
    }

    private func alignedY(_ group: GlyphBox, _ m: Metrics) -> Double {
        if size == .none, alignVertical == .none { return group.y }
        let startY = m.faceY + padBottom * m.faceHeight
        let endY = m.faceY + (m.faceHeight - group.height - padTop * m.faceHeight)
        let centerY = (startY + endY) / 2
        return switch alignVertical {
        case .none: endY < startY ? centerY : max(startY, min(group.y, endY))
        case .start: startY
        case .end: endY
        case .center, .center1: centerY
        }
    }

    private func alignedX(_ group: GlyphBox, _ m: Metrics, _ width: Int) -> Double {
        if size == .none, alignHorizontal == .none { return group.x }
        let fullFaceSpan = m.faceWidth + Double(width - 1) * m.cellWidth
        let startX = padLeft * m.faceWidth
        let endX = fullFaceSpan - group.width - padRight * m.faceWidth
        return switch alignHorizontal {
        case .none: max(startX, min(group.x, endX))
        case .start: startX
        case .end: max(startX, endX)
        case .center: max(startX, (startX + endX) / 2)
        case .center1: max(startX, (startX + (m.faceWidth - group.width - padRight * m.faceWidth)) / 2)
        }
    }
}
