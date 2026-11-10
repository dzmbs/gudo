import GhosttyVt

/// A snapshot of a terminal's viewport for drawing: libghostty-vt's render-state API (`render.h`).
///
/// Owned by one render loop; not thread-safe. `update(from:)` holds the terminal lock only for the
/// begin phase, then finishes the update without it, mirroring Ghostty's renderer.
public final class RenderState {
    public enum Dirty: Sendable {
        /// Nothing changed since the last `markClean()`.
        case clean
        /// Some rows changed; their `Row.isDirty` is set.
        case partial
        /// Global state changed (resize, palette, screen switch); redraw everything.
        case full
    }

    public enum CursorStyle: Sendable {
        case bar, block, underline, blockHollow
    }

    public struct Cursor: Sendable {
        /// Cell position in the viewport, or nil when the cursor is scrolled out of view.
        public var position: (x: UInt16, y: UInt16)?
        /// The cursor sits on the right half of a wide character.
        public var onWideTail: Bool
        public var visible: Bool
        public var blinking: Bool
        public var style: CursorStyle
    }

    public struct Colors: Sendable {
        public var background: RGB
        public var foreground: RGB
        /// Set by OSC 12; nil means "use the foreground".
        public var cursor: RGB?
        /// The 256-color palette (for resolving palette underline colors).
        public var palette: [RGB]
    }

    let state: GhosttyRenderState
    private let rowIterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells
    let imageIterator: GhosttyRenderStateImageIterator

    public init() {
        var state: GhosttyRenderState?
        var iterator: GhosttyRenderStateRowIterator?
        var cells: GhosttyRenderStateRowCells?
        var images: GhosttyRenderStateImageIterator?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS,
              ghostty_render_state_image_iterator_new(nil, &images) == GHOSTTY_SUCCESS,
              let state, let iterator, let cells, let images
        else { fatalError("libghostty-vt allocation failed") }
        self.state = state
        rowIterator = iterator
        rowCells = cells
        imageIterator = images
    }

    deinit {
        ghostty_render_state_image_iterator_free(imageIterator)
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(state)
    }

    /// Captures the terminal's current viewport. Dirty flags accumulate until `markClean()`.
    public func update(from terminal: Terminal) {
        terminal.withHandle { _ = ghostty_render_state_begin_update(state, $0) }
        ghostty_render_state_end_update(state)
    }

    /// Clears the global and per-row dirty flags after a frame was fully built.
    public func markClean() {
        ghostty_render_state_clean(state)
    }

    public var dirty: Dirty {
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        switch dirty {
        case GHOSTTY_RENDER_STATE_DIRTY_FULL: return .full
        case GHOSTTY_RENDER_STATE_DIRTY_PARTIAL: return .partial
        default: return .clean
        }
    }

    public var size: (cols: UInt16, rows: UInt16) {
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
        return (cols, rows)
    }

    public var colors: Colors {
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        let palette = withUnsafeBytes(of: colors.palette) { raw in
            raw.bindMemory(to: GhosttyColorRgb.self).map(RGB.init)
        }
        return Colors(
            background: RGB(colors.background),
            foreground: RGB(colors.foreground),
            cursor: colors.cursor_has_value ? RGB(colors.cursor) : nil,
            palette: palette
        )
    }

    public var cursor: Cursor {
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        let style: CursorStyle = switch cursor.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR: .bar
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: .underline
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: .blockHollow
        default: .block
        }
        return Cursor(
            position: cursor.viewport_has_value ? (cursor.viewport_x, cursor.viewport_y) : nil,
            onWideTail: cursor.viewport_has_value && cursor.wide_tail,
            visible: cursor.visible,
            blinking: cursor.blinking,
            style: style
        )
    }

    /// Visits every captured row from top to bottom. The `Row` is only valid inside `body`.
    public func forEachRow(_ body: (Row) -> Void) {
        var iterator: GhosttyRenderStateRowIterator? = rowIterator
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator)
        while ghostty_render_state_row_iterator_next(rowIterator) {
            body(Row(iterator: rowIterator, cells: rowCells))
        }
    }
}

/// Stable identity of a row across updates (`GHOSTTY_RENDER_STATE_ROW_DATA_ID`). Never reused, so it
/// is a safe cache key for per-row GPU data.
public struct RowID: Hashable, Sendable {
    let high: UInt64
    let low: UInt64
}

/// One row of a `RenderState`, valid only during `RenderState.forEachRow`.
public struct Row {
    let iterator: GhosttyRenderStateRowIterator
    let cells: GhosttyRenderStateRowCells

    public var id: RowID {
        var id = GhosttyRenderStateRowId()
        ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_ID, &id)
        return RowID(high: id.bits.0, low: id.bits.1)
    }

    public var isDirty: Bool {
        var dirty = false
        ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &dirty)
        return dirty
    }

    /// The selected columns of this row (inclusive), or nil when the selection misses it.
    public var selection: ClosedRange<Int>? {
        var rowSelection = GhosttyRenderStateRowSelection()
        rowSelection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        guard ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &rowSelection) == GHOSTTY_SUCCESS,
              rowSelection.start_x <= rowSelection.end_x else { return nil }
        return Int(rowSelection.start_x)...Int(rowSelection.end_x)
    }

    /// Position relative to the top of the viewport (negative for overscan rows above it).
    public var viewportY: Int32 {
        var y: Int32 = 0
        ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, &y)
        return y
    }

    /// Visits each cell left to right. The `Cell` is only valid inside `body`.
    public func forEachCell(_ body: (Cell) -> Void) {
        var cells: GhosttyRenderStateRowCells? = self.cells
        ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
        while ghostty_render_state_row_cells_next(self.cells) {
            body(Cell(cells: self.cells))
        }
    }
}

/// One cell of a `Row`. Each accessor is a single libghostty-vt call, so read only what you need.
public struct Cell {
    public enum Width: Sendable {
        case narrow
        /// First half of a two-column character.
        case wide
        /// Second half of a wide character; draws nothing.
        case spacerTail
        /// Padding at the end of a soft-wrapped row before a wide character; draws nothing.
        case spacerHead
    }

    public enum Underline: Sendable, Equatable {
        case none, single, double, curly, dotted, dashed
    }

    /// An SGR 58 underline color: unset (use the text color), a palette index or RGB.
    public enum StyleColor: Sendable, Equatable {
        case none
        case palette(UInt8)
        case rgb(RGB)
    }

    public struct Style: Sendable {
        public var bold: Bool
        public var italic: Bool
        public var faint: Bool
        public var inverse: Bool
        public var invisible: Bool
        public var strikethrough: Bool
        public var underline: Underline
        public var underlineColor: StyleColor
        public var overline: Bool
        /// SGR 5/6: text blinks.
        public var blink: Bool
    }

    let cells: GhosttyRenderStateRowCells

    private var raw: GhosttyCell {
        var raw: GhosttyCell = 0
        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
        return raw
    }

    /// Number of codepoints in the grapheme cluster; 0 for an empty cell.
    public var graphemeCount: Int {
        var len: UInt32 = 0
        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
        return Int(len)
    }

    /// The base codepoint, or 0 for an empty cell.
    public var codepoint: UInt32 {
        var cp: UInt32 = 0
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &cp)
        return cp
    }

    /// All codepoints of the grapheme cluster, base first.
    public var graphemes: [UInt32] {
        let count = graphemeCount
        guard count > 0 else { return [] }
        return [UInt32](unsafeUninitializedCapacity: count) { buffer, initialized in
            var graphemes = GhosttyCodepointBuffer(ptr: buffer.baseAddress, cap: count, len: 0)
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes)
            initialized = min(graphemes.len, count)
        }
    }

    public var width: Width {
        var wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        return Width(wide)
    }

    /// The cell's SGR flags, or nil for an unstyled cell.
    public var style: Style? {
        var hasStyling = false
        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
        guard hasStyling else { return nil }
        var style = GhosttyStyle()
        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
        return Style(style)
    }

    /// The cell carries an OSC 8 hyperlink.
    public var hasHyperlink: Bool {
        var value = false
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &value)
        return value
    }

    /// Explicit foreground (palette already resolved), or nil for the default foreground.
    public var foreground: RGB? { color(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR) }

    /// Explicit background (palette already resolved), or nil for the default background.
    public var background: RGB? { color(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR) }

    private func color(_ data: GhosttyRenderStateRowCellsData) -> RGB? {
        var rgb = GhosttyColorRgb()
        guard ghostty_render_state_row_cells_get(cells, data, &rgb) == GHOSTTY_SUCCESS else { return nil }
        return RGB(rgb)
    }
}

extension Cell.Style {
    init(_ style: GhosttyStyle) {
        underline = switch style.underlineStyle {
        case GHOSTTY_SGR_UNDERLINE_SINGLE.rawValue: .single
        case GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue: .double
        case GHOSTTY_SGR_UNDERLINE_CURLY.rawValue: .curly
        case GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue: .dotted
        case GHOSTTY_SGR_UNDERLINE_DASHED.rawValue: .dashed
        default: .none
        }
        underlineColor = switch style.underline_color.kind {
        case GHOSTTY_STYLE_COLOR_PALETTE: .palette(style.underline_color.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB: .rgb(RGB(style.underline_color.value.rgb))
        default: .none
        }
        let attributes = style.attributes
        bold = attributes.contains(.bold)
        italic = attributes.contains(.italic)
        faint = attributes.contains(.faint)
        inverse = attributes.contains(.inverse)
        invisible = attributes.contains(.invisible)
        strikethrough = attributes.contains(.strikethrough)
        overline = attributes.contains(.overline)
        blink = attributes.contains(.blink)
    }
}

/// The on/off bits of `GhosttyStyleFlags` (`style.h`). Swift does not import the
/// `GHOSTTY_STYLE_FLAG_*` macros because they cast.
struct StyleAttributes: OptionSet {
    let rawValue: GhosttyStyleFlags

    static let bold = Self(rawValue: 1 << 0)
    static let italic = Self(rawValue: 1 << 1)
    static let faint = Self(rawValue: 1 << 2)
    static let blink = Self(rawValue: 1 << 3)
    static let inverse = Self(rawValue: 1 << 4)
    static let invisible = Self(rawValue: 1 << 5)
    static let strikethrough = Self(rawValue: 1 << 6)
    static let overline = Self(rawValue: 1 << 7)
}

extension GhosttyStyle {
    var attributes: StyleAttributes { StyleAttributes(rawValue: flags) }

    /// A `GhosttySgrUnderline` value; `GHOSTTY_SGR_UNDERLINE_NONE` when not underlined.
    var underlineStyle: UInt32 { UInt32(flags >> GhosttyStyleFlags(GHOSTTY_STYLE_UNDERLINE_SHIFT)) & 0x7 }
}

extension GhosttyStyleColor {
    var kind: GhosttyStyleColorTag { GhosttyStyleColorTag(UInt32(tag)) }
}

extension Cell.Width {
    init(_ wide: GhosttyCellWide) {
        self = switch wide {
        case GHOSTTY_CELL_WIDE_WIDE: .wide
        case GHOSTTY_CELL_WIDE_SPACER_TAIL: .spacerTail
        case GHOSTTY_CELL_WIDE_SPACER_HEAD: .spacerHead
        default: .narrow
        }
    }
}
