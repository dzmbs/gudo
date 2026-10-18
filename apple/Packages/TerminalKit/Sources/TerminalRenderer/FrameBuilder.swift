import TerminalCore

/// CPU side of a frame: everything the GPU passes read, in Ghostty's layout.
struct FrameContents {
    var cols = 0
    var rows = 0
    /// One sRGB RGBA per cell, row-major; alpha 0 means "default background".
    var bgCells: [SIMD4<UInt8>] = []
    /// Instances for the `cell_text` pass: block cursor first (drawn under the text it inverts),
    /// then every row's glyphs and decorations, then any other cursor shape on top.
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
    }

    private var cache: [RowID: CachedRow] = [:]
    private var scalars: [UInt32] = []

    /// Builds the frame. `focused` selects Ghostty's unfocused cursor (hollow block).
    func build(_ state: RenderState, fonts: FontGrid, focused: Bool, into frame: inout FrameContents) -> BuildStats {
        let (cols, rows) = state.size
        let colors = state.colors
        let fullRebuild = state.dirty == .full || frame.cols != Int(cols) || frame.rows != Int(rows)
        if fullRebuild { cache.removeAll(keepingCapacity: true) }

        frame.cols = Int(cols)
        frame.rows = Int(rows)
        frame.background = rgba(colors.background)
        frame.bgCells.removeAll(keepingCapacity: true)
        frame.bgCells.reserveCapacity(frame.cols * frame.rows)
        frame.text.removeAll(keepingCapacity: true)

        var stats = BuildStats()
        var next: [RowID: CachedRow] = [:]
        next.reserveCapacity(frame.rows)
        var rowWide: [[Bool]] = []
        state.forEachRow { row in
            let y = row.viewportY
            guard y >= 0, y < Int32(rows) else { return }
            let id = row.id
            let cached: CachedRow
            if !fullRebuild, !row.isDirty, let hit = cache[id] {
                cached = hit
                stats.rowsReused += 1
            } else {
                cached = buildRow(row, cols: Int(cols), colors: colors, fonts: fonts)
                stats.rowsRebuilt += 1
            }
            next[id] = cached
            frame.bgCells.append(contentsOf: cached.bg)
            for var instance in cached.text {
                instance.gridPos.y = UInt16(y)
                frame.text.append(instance)
            }
            rowWide.append(cached.wide)
        }
        cache = next

        frame.blockCursor = nil
        addCursor(state.cursor, colors: colors, focused: focused, rowWide: rowWide, fonts: fonts, frame: &frame)
        return stats
    }

    private func buildRow(_ row: Row, cols: Int, colors: RenderState.Colors, fonts: FontGrid) -> CachedRow {
        var out = CachedRow(
            bg: .init(repeating: .zero, count: cols),
            text: [],
            wide: .init(repeating: false, count: cols)
        )
        let defaultFg = colors.foreground
        var x = 0
        row.forEachCell { cell in
            defer { x += 1 }
            guard x < cols else { return }
            let style = cell.style
            var fg = cell.foreground ?? defaultFg
            var bg = cell.background
            if style?.inverse == true {
                (fg, bg) = (bg ?? colors.background, fg)
            }
            if let bg { out.bg[x] = rgba(bg) }

            let width = cell.width
            guard width == .narrow || width == .wide, style?.invisible != true else { return }
            let span = width == .wide ? 2 : 1
            out.wide[x] = width == .wide
            var color = rgba(fg)
            if style?.faint == true { color.w = 128 }  // Ghostty's default faint-opacity 0.5

            let count = cell.graphemeCount
            if count > 0 {
                scalars = count == 1 ? [cell.codepoint] : cell.graphemes
                if scalars != [0x20],
                   let glyph = fonts.glyph(
                       for: scalars,
                       style: FontStyle(bold: style?.bold ?? false, italic: style?.italic ?? false),
                       span: span)
                {
                    out.text.append(instance(glyph, x: x, color: color))
                }
            }
            if style?.underline == true {
                out.text.append(instance(fonts.sprite(.underline, span: span), x: x, color: color))
            }
            if style?.strikethrough == true {
                out.text.append(instance(fonts.sprite(.strikethrough, span: span), x: x, color: color))
            }
        }
        return out
    }

    /// Ghostty's `addCursor` plus the block-cursor uniforms from `rebuildCells`.
    private func addCursor(
        _ cursor: RenderState.Cursor, colors: RenderState.Colors, focused: Bool, rowWide: [[Bool]],
        fonts: FontGrid, frame: inout FrameContents
    ) {
        guard cursor.visible, let position = cursor.position else { return }
        var x = Int(position.x)
        let y = Int(position.y)
        guard y < rowWide.count, x < rowWide[y].count else { return }
        var wide = rowWide[y][x]
        if cursor.onWideTail, x > 0 {
            x -= 1
            wide = true
        }

        var style = cursor.style
        if !focused, style == .block { style = .blockHollow }
        let sprite: Sprite = switch style {
        case .block: .cursorRect
        case .blockHollow: .cursorHollowRect
        case .bar: .cursorBar
        case .underline: .cursorUnderline
        }
        var glyph = instance(fonts.sprite(sprite, span: wide ? 2 : 1), x: x, color: rgba(colors.cursor ?? colors.foreground))
        glyph.gridPos.y = UInt16(y)
        glyph.flags = CellText.Flags.isCursorGlyph.rawValue

        if style == .block {
            frame.text.insert(glyph, at: 0)
            frame.blockCursor = (SIMD2(UInt16(x), UInt16(y)), wide, rgba(colors.background))
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
