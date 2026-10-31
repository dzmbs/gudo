import TerminalCore

/// CPU side of a frame: everything the GPU passes read, in Ghostty's layout.
struct FrameContents {
    var cols = 0
    var rows = 0
    /// One sRGB RGBA per cell, row-major; alpha 0 means "default background".
    var bgCells: [SIMD4<UInt8>] = []
    /// Instances for the `cell_text` pass: block cursor first (drawn under the text it inverts),
    /// then every row's glyphs and decorations, then overlays and any other cursor shape on top.
    var text: [CellText] = []
    var background = SIMD4<UInt8>(0, 0, 0, 255)
    /// Cell whose glyph is recoloured by a block cursor, if any.
    var blockCursor: (pos: SIMD2<UInt16>, wide: Bool, textColor: SIMD4<UInt8>)?
}

/// Per-frame dirty-tracking counters, for measurement.
struct BuildStats {
    var rowsRebuilt = 0
    var rowsReused = 0
}

/// Cells drawn over the terminal's own content without touching its state: echo predictions and
/// IME preedit text. They hide whatever the grid has in those cells.
struct OverlayCell: Equatable {
    var x: Int
    var y: Int
    var text: String
    /// 2 for wide characters.
    var span: Int
    var underline: Cell.Underline
}

/// Per-frame state that is not part of the terminal: blink phases, overlays and hover.
struct FrameOverlay: Equatable {
    var focused = true
    /// Cursor blink phase (true = drawn).
    var cursorBlinkOn = true
    /// SGR 5 text blink phase (true = drawn).
    var textBlinkOn = true
    var cells: [OverlayCell] = []
    /// Where the cursor is drawn instead of the terminal's cursor (after predictions or preedit).
    var cursorOverride: GridPoint?
    /// A bar cursor for IME composition, regardless of the terminal's cursor style.
    var barCursor = false
    /// Cells of the hyperlink under the pointer (underlined, as Ghostty does on hover).
    var hoveredLink: (row: Int, columns: ClosedRange<Int>)?
    /// Scrollback search matches in the viewport, recolored like Ghostty's (`search-*` colors).
    var searchHighlights: [SearchHighlight] = []

    static func == (a: Self, b: Self) -> Bool {
        a.focused == b.focused && a.cursorBlinkOn == b.cursorBlinkOn && a.textBlinkOn == b.textBlinkOn
            && a.cells == b.cells && a.cursorOverride == b.cursorOverride && a.barCursor == b.barCursor
            && a.hoveredLink?.row == b.hoveredLink?.row && a.hoveredLink?.columns == b.hoveredLink?.columns
            && a.searchHighlights == b.searchHighlights
    }
}

/// Colors and policies from `TerminalAppearance` the builder needs.
struct FrameStyle {
    var selectionBackground: RGB?
    var selectionForeground: RGB?
    var faintAlpha: UInt8 = 128
    var search = SearchColors()
}

/// Background and text colors of search matches (all, and the selected one).
struct SearchColors {
    var background = RGB(r: 0xFF, g: 0xE0, b: 0x82)
    var foreground = RGB(r: 0, g: 0, b: 0)
    var selectedBackground = RGB(r: 0xF2, g: 0xA5, b: 0x7E)
    var selectedForeground = RGB(r: 0, g: 0, b: 0)
}

/// Turns a `RenderState` into `FrameContents`, rebuilding only dirty rows.
///
/// Port of the row-rebuild part of Ghostty's `generic.zig` (`rebuildCells`/`rebuildRow`), except
/// that per-row GPU data is cached by the render state's stable row id rather than by screen y, so
/// rows that merely moved can be reused once libghostty-vt stops marking them dirty.
final class FrameBuilder {
    private struct CachedRow {
        var bg: [SIMD4<UInt8>]
        /// Instances with `gridPos.y == 0`; the row's current y is patched in at assembly.
        var text: [CellText]
        /// Columns holding the first half of a wide character (for the cursor width).
        var wide: [Bool]
        /// The row has SGR 5 cells, so it must be rebuilt when the blink phase flips.
        var hasBlink: Bool
        /// The text blink phase the row was built with.
        var blinkOn: Bool
        /// Inverted text color for each column under a block cursor.
        var fg: [SIMD4<UInt8>]
        /// Every glyph was drawn (none deferred to a later frame).
        var complete = true
    }

    /// One cell's data, gathered in a first pass so the second can look at neighbours.
    private struct CellInfo {
        var scalars: [UInt32] = []
        var style: Cell.Style?
        var width: Cell.Width = .narrow
        var fg: RGB?
        var bg: RGB?
    }

    private var cache: [RowID: CachedRow] = [:]
    private var infos: [CellInfo] = []
    var style = FrameStyle() {
        // Cached rows carry the old selection and search colors.
        didSet { cache.removeAll(keepingCapacity: true) }
    }
    /// The last frame showed SGR 5 (blinking) text.
    private(set) var hasBlinkingText = false
    /// The last frame left glyphs out (rasterization deadline, full atlas); build again soon.
    private(set) var isIncomplete = false
    /// The atlas epoch the cached rows were built in.
    private var cacheEpoch: Int?

    /// Builds the frame.
    func build(_ state: RenderState, fonts: FontGrid, overlay: FrameOverlay, into frame: inout FrameContents) -> BuildStats {
        let deferrals = fonts.deferrals
        let epoch = fonts.epoch
        var stats = assemble(state, fonts: fonts, overlay: overlay, forceFull: epoch != cacheEpoch, into: &frame)
        if fonts.epoch != epoch {
            // The atlas started over during this frame: rows built before point into the old one.
            fonts.resetAllowed = false
            stats = assemble(state, fonts: fonts, overlay: overlay, forceFull: true, into: &frame)
            fonts.resetAllowed = true
        }
        cacheEpoch = fonts.epoch
        isIncomplete = fonts.deferrals != deferrals
        return stats
    }

    private func assemble(
        _ state: RenderState, fonts: FontGrid, overlay: FrameOverlay, forceFull: Bool, into frame: inout FrameContents
    ) -> BuildStats {
        let (cols, rows) = state.size
        let colors = state.colors
        let fullRebuild = forceFull || state.dirty == .full || frame.cols != Int(cols) || frame.rows != Int(rows)
        if fullRebuild { cache.removeAll(keepingCapacity: true) }

        frame.cols = Int(cols)
        frame.rows = Int(rows)
        frame.background = rgba(colors.background)
        frame.bgCells.removeAll(keepingCapacity: true)
        frame.bgCells.reserveCapacity(frame.cols * frame.rows)
        frame.text.removeAll(keepingCapacity: true)

        // Overlay cells per row, and the columns they hide.
        var overlayRows: [Int: [OverlayCell]] = [:]
        for cell in overlay.cells where cell.y >= 0 && cell.y < Int(rows) {
            overlayRows[cell.y, default: []].append(cell)
        }
        // Search matches per row: (columns, selected).
        var highlightRows: [Int: [(ClosedRange<Int>, Bool)]] = [:]
        for h in overlay.searchHighlights where h.row >= 0 && h.row < Int(rows) {
            highlightRows[h.row, default: []].append((h.columns, h.selected))
        }

        var stats = BuildStats()
        var next: [RowID: CachedRow] = [:]
        next.reserveCapacity(frame.rows)
        var rowWide: [[Bool]] = []
        var rowFg: [[SIMD4<UInt8>]] = []
        state.forEachRow { row in
            let y = row.viewportY
            guard y >= 0, y < Int32(rows) else { return }
            let id = row.id
            let cached: CachedRow
            if !fullRebuild, !row.isDirty, let hit = cache[id], hit.complete, !hit.hasBlink || hit.blinkOn == overlay.textBlinkOn {
                cached = hit
                stats.rowsReused += 1
            } else {
                cached = buildRow(row, cols: Int(cols), colors: colors, fonts: fonts, blinkOn: overlay.textBlinkOn)
                stats.rowsRebuilt += 1
            }
            next[id] = cached
            let rowStart = frame.bgCells.count
            let textStart = frame.text.count
            frame.bgCells.append(contentsOf: cached.bg)

            if let cells = overlayRows[Int(y)] {
                var hidden = Set<Int>()
                for cell in cells {
                    for dx in 0..<cell.span where cell.x + dx < Int(cols) {
                        hidden.insert(cell.x + dx)
                        frame.bgCells[rowStart + cell.x + dx] = frame.background
                    }
                }
                for var instance in cached.text where !hidden.contains(Int(instance.gridPos.x)) {
                    instance.gridPos.y = UInt16(y)
                    frame.text.append(instance)
                }
            } else {
                for var instance in cached.text {
                    instance.gridPos.y = UInt16(y)
                    frame.text.append(instance)
                }
            }
            if let ranges = highlightRows[Int(y)] {
                highlight(ranges, rowStart: rowStart, textStart: textStart, cols: Int(cols), frame: &frame)
            }
            rowWide.append(cached.wide)
            rowFg.append(cached.fg)
        }
        cache = next
        hasBlinkingText = next.values.contains { $0.hasBlink }

        addOverlayCells(overlay, colors: colors, cols: Int(cols), fonts: fonts, frame: &frame)
        if let link = overlay.hoveredLink, link.row < Int(rows) {
            let fg = rgba(colors.foreground)
            for x in link.columns where x < Int(cols) {
                guard let sprite = fonts.sprite(.underline, span: 1) else { break }
                var glyph = instance(sprite, x: x, color: rowFg.indices.contains(link.row) ? rowFg[link.row][x] : fg)
                glyph.gridPos.y = UInt16(link.row)
                frame.text.append(glyph)
            }
        }

        frame.blockCursor = nil
        if overlay.cursorBlinkOn || !overlay.focused {
            addCursor(state.cursor, overlay: overlay, colors: colors, rowWide: rowWide, rowFg: rowFg, fonts: fonts, frame: &frame)
        }
        return stats
    }

    /// Recolors a row's search matches after assembly (the cached row stays as the terminal has
    /// it): the match color behind, the match text color on its glyphs and decorations. The
    /// selected match wins where two overlap.
    private func highlight(_ ranges: [(ClosedRange<Int>, Bool)], rowStart: Int, textStart: Int, cols: Int, frame: inout FrameContents) {
        let colors = style.search
        var cellColor = [Int: (bg: SIMD4<UInt8>, fg: SIMD4<UInt8>)]()
        for (columns, selected) in ranges.sorted(by: { !$0.1 && $1.1 }) {
            let bg = rgba(selected ? colors.selectedBackground : colors.background)
            let fg = rgba(selected ? colors.selectedForeground : colors.foreground)
            for x in columns where x >= 0 && x < cols { cellColor[x] = (bg, fg) }
        }
        for (x, color) in cellColor { frame.bgCells[rowStart + x] = color.bg }
        for i in textStart..<frame.text.count {
            guard let color = cellColor[Int(frame.text[i].gridPos.x)] else { continue }
            // Faint text stays faint on the match color.
            let alpha = frame.text[i].color.w
            frame.text[i].color = SIMD4(color.fg.x, color.fg.y, color.fg.z, alpha)
        }
    }

    private func buildRow(_ row: Row, cols: Int, colors: RenderState.Colors, fonts: FontGrid, blinkOn: Bool) -> CachedRow {
        var out = CachedRow(
            bg: .init(repeating: .zero, count: cols),
            text: [],
            wide: .init(repeating: false, count: cols),
            hasBlink: false,
            blinkOn: blinkOn,
            fg: .init(repeating: rgba(colors.background), count: cols)
        )
        let deferrals = fonts.deferrals
        // Pass 1: gather cells.
        // Work on a local copy (moved out, not copied): class-property access costs an exclusivity
        // check and a uniqueness check per cell.
        var infos: [CellInfo] = []
        swap(&infos, &self.infos)
        defer { swap(&infos, &self.infos) }
        if infos.count < cols { infos = .init(repeating: CellInfo(), count: cols) }
        var x = 0
        row.forEachCell { cell in
            defer { x += 1 }
            guard x < cols else { return }
            let count = cell.graphemeCount
            // Reuse each slot's array storage: no allocation per cell on the common path.
            infos[x].scalars.removeAll(keepingCapacity: true)
            if count == 1 { infos[x].scalars.append(cell.codepoint) } else if count > 1 { infos[x].scalars.append(contentsOf: cell.graphemes) }
            infos[x].style = cell.style
            infos[x].width = cell.width
            infos[x].fg = cell.foreground
            infos[x].bg = cell.background
        }
        let filled = min(x, cols)
        let selection = row.selection

        // Pass 2: emit backgrounds, glyphs and decorations.
        let defaultFg = colors.foreground
        for x in 0..<filled {
            let info = infos[x]
            let style = info.style
            var fg = info.fg ?? defaultFg
            var bg = info.bg
            if style?.inverse == true {
                (fg, bg) = (bg ?? colors.background, fg)
            }
            if let selection, selection.contains(x) {
                // Ghostty without selection colors configured: swap the cell's colors.
                let cellBg = bg ?? colors.background
                bg = self.style.selectionBackground ?? fg
                fg = self.style.selectionForeground ?? cellBg
            }
            if let bg { out.bg[x] = rgba(bg) }
            out.fg[x] = rgba(bg ?? colors.background)

            let width = info.width
            guard width == .narrow || width == .wide, style?.invisible != true else { continue }
            let span = width == .wide ? 2 : 1
            out.wide[x] = width == .wide
            var color = rgba(fg)
            if style?.faint == true { color.w = self.style.faintAlpha }

            if style?.blink == true { out.hasBlink = true }
            let blinkHidden = style?.blink == true && !blinkOn
            if !info.scalars.isEmpty, info.scalars != [0x20], !blinkHidden {
                // Ghostty lets a narrow symbol (Nerd Font icon) grow into a following blank cell.
                let maxSpan = NerdFontConstraint.constraintWidth(
                    codepoint: info.scalars[0], span: span,
                    previous: x > 0 ? infos[x - 1].scalars.first ?? 0 : nil,
                    next: x + 1 < cols ? (x + 1 < filled ? infos[x + 1].scalars.first ?? 0 : 0) : nil)
                if let glyph = fonts.glyph(
                    for: info.scalars,
                    style: FontStyle(bold: style?.bold ?? false, italic: style?.italic ?? false),
                    span: span, maxSpan: maxSpan)
                {
                    out.text.append(instance(glyph, x: x, color: color))
                }
            }
            guard let style else { continue }
            if style.underline != .none {
                let underlineColor: SIMD4<UInt8> = switch style.underlineColor {
                case .none: color
                case .palette(let index): rgba(colors.palette[Int(index)])
                case .rgb(let rgb): rgba(rgb)
                }
                if let sprite = fonts.sprite(Self.sprite(for: style.underline), span: span) {
                    out.text.append(instance(sprite, x: x, color: underlineColor))
                }
            }
            if style.overline, let sprite = fonts.sprite(.overline, span: span) {
                out.text.append(instance(sprite, x: x, color: color))
            }
            if style.strikethrough, let sprite = fonts.sprite(.strikethrough, span: span) {
                out.text.append(instance(sprite, x: x, color: color))
            }
        }
        out.complete = fonts.deferrals == deferrals
        return out
    }

    private static func isBlank(_ info: CellInfo) -> Bool {
        info.width == .narrow && (info.scalars.isEmpty || info.scalars == [0x20])
    }

    static func sprite(for underline: Cell.Underline) -> Sprite {
        switch underline {
        case .double: .underlineDouble
        case .curly: .underlineCurly
        case .dotted: .underlineDotted
        case .dashed: .underlineDashed
        case .single, .none: .underline
        }
    }

    /// Prediction and preedit cells: opaque default background, the glyph, and an underline.
    private func addOverlayCells(_ overlay: FrameOverlay, colors: RenderState.Colors, cols: Int, fonts: FontGrid, frame: inout FrameContents) {
        let color = rgba(colors.foreground)
        for cell in overlay.cells where cell.x < cols {
            let scalars = cell.text.unicodeScalars.map(\.value)
            if !scalars.isEmpty, scalars != [0x20], let glyph = fonts.glyph(for: scalars, style: .regular, span: cell.span, maxSpan: cell.span) {
                var g = instance(glyph, x: cell.x, color: color)
                g.gridPos.y = UInt16(cell.y)
                frame.text.append(g)
            }
            if cell.underline != .none, let sprite = fonts.sprite(Self.sprite(for: cell.underline), span: cell.span) {
                var u = instance(sprite, x: cell.x, color: color)
                u.gridPos.y = UInt16(cell.y)
                frame.text.append(u)
            }
        }
    }

    /// Ghostty's `addCursor` plus the block-cursor uniforms from `rebuildCells`.
    private func addCursor(
        _ cursor: RenderState.Cursor, overlay: FrameOverlay, colors: RenderState.Colors, rowWide: [[Bool]], rowFg: [[SIMD4<UInt8>]],
        fonts: FontGrid, frame: inout FrameContents
    ) {
        guard cursor.visible, let position = cursor.position else { return }
        var x = Int(position.x)
        var y = Int(position.y)
        var onWideTail = cursor.onWideTail
        if let override = overlay.cursorOverride {
            x = override.x
            y = override.y
            onWideTail = false
        }
        guard y >= 0, y < rowWide.count, x >= 0, x < rowWide[y].count else { return }
        var wide = rowWide[y][x] && overlay.cursorOverride == nil
        if onWideTail, x > 0 {
            x -= 1
            wide = true
        }

        var style = cursor.style
        // Ghostty draws every cursor as a hollow block in an unfocused surface.
        if !overlay.focused { style = .blockHollow }
        if overlay.barCursor, overlay.focused { style = .bar }
        let sprite: Sprite = switch style {
        case .block: .cursorRect
        case .blockHollow: .cursorHollowRect
        case .bar: .cursorBar
        case .underline: .cursorUnderline
        }
        guard let rendered = fonts.sprite(sprite, span: wide ? 2 : 1) else { return }
        var glyph = instance(rendered, x: x, color: rgba(colors.cursor ?? colors.foreground))
        glyph.gridPos.y = UInt16(y)
        glyph.flags = CellText.Flags.isCursorGlyph.rawValue

        if style == .block {
            frame.text.insert(glyph, at: 0)
            frame.blockCursor = (SIMD2(UInt16(x), UInt16(y)), wide, rowFg[y][x])
        } else {
            frame.text.append(glyph)
        }
    }

    private func instance(_ glyph: RenderedGlyph, x: Int, color: SIMD4<UInt8>) -> CellText {
        CellText(
            glyphPos: SIMD2(UInt32(glyph.region.x), UInt32(glyph.region.y)),
            glyphSize: SIMD2(UInt32(glyph.region.width), UInt32(glyph.region.height)),
            bearings: SIMD2(Int16(clamping: glyph.offsetX), Int16(clamping: glyph.offsetY)),
            gridPos: SIMD2(UInt16(x), 0),
            color: color,
            atlas: glyph.atlas.rawValue,
            flags: 0
        )
    }

    private func rgba(_ c: RGB) -> SIMD4<UInt8> { SIMD4(c.r, c.g, c.b, 255) }
}
