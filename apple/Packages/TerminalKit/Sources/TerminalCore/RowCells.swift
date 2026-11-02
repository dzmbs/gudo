import GhosttyVt

/// One row's cells as parallel arrays, refilled in place by `Row.gather(into:)`.
///
/// The storage is plain memory that only grows, so a renderer can read and refill it every
/// frame without allocating, copying or checking uniqueness per cell.
public final class RowCells {
    public private(set) var count = 0
    private var capacity = 0
    /// Base codepoint per column; 0 for an empty cell.
    public private(set) var codepoints = UnsafeMutablePointer<UInt32>.allocate(capacity: 0)
    public private(set) var widths = UnsafeMutablePointer<Cell.Width>.allocate(capacity: 0)
    /// nil for an unstyled cell.
    public private(set) var styles = UnsafeMutablePointer<Cell.Style?>.allocate(capacity: 0)
    /// Explicit colors (palette resolved); nil means the default.
    public private(set) var foregrounds = UnsafeMutablePointer<RGB?>.allocate(capacity: 0)
    public private(set) var backgrounds = UnsafeMutablePointer<RGB?>.allocate(capacity: 0)
    /// Start of a multi-codepoint cluster in `clusterScalars`, or -1 for a single codepoint.
    fileprivate var clusterStarts = UnsafeMutablePointer<Int32>.allocate(capacity: 0)
    private var clusterScalars: [UInt32] = []

    public init() {}

    deinit {
        codepoints.deallocate()
        widths.deallocate()
        styles.deallocate()
        foregrounds.deallocate()
        backgrounds.deallocate()
        clusterStarts.deallocate()
    }

    /// Every codepoint of the cell at `x`, base first; empty for an empty cell.
    public func scalars(at x: Int) -> [UInt32] {
        let start = Int(clusterStarts[x])
        if start >= 0 {
            let length = Int(clusterScalars[start])
            return Array(clusterScalars[start + 1...start + length])
        }
        return codepoints[x] == 0 ? [] : [codepoints[x]]
    }

    /// The cell at `x` holds more than one codepoint.
    public func isCluster(at x: Int) -> Bool { clusterStarts[x] >= 0 }

    fileprivate func reset(count: Int) {
        if count > capacity {
            func grow<T>(_ pointer: inout UnsafeMutablePointer<T>) {
                pointer.deallocate()
                pointer = .allocate(capacity: count)
            }
            grow(&codepoints)
            grow(&widths)
            grow(&styles)
            grow(&foregrounds)
            grow(&backgrounds)
            grow(&clusterStarts)
            capacity = count
        }
        self.count = count
        clusterScalars.removeAll(keepingCapacity: true)
    }

    fileprivate func appendCluster(_ cells: GhosttyRenderStateRowCells, at x: Int) {
        var length: UInt32 = 0
        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
        guard length > 1 else { return }
        let start = clusterScalars.count
        clusterScalars.append(length)
        clusterScalars.append(contentsOf: repeatElement(0, count: Int(length)))
        clusterScalars.withUnsafeMutableBufferPointer { buffer in
            _ = ghostty_render_state_row_cells_get(
                cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buffer.baseAddress! + start + 1)
        }
        clusterStarts[x] = Int32(start)
    }
}

extension Row {
    /// Reads up to `limit` cells into `row`: the row's raw cells in one call, then per-cell calls
    /// only for cells with styling, a background color or several codepoints.
    public func gather(into row: RowCells, limit: Int) {
        var view = GhosttyCellsView()
        ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &view)
        var cellsHandle: GhosttyRenderStateRowCells? = cells
        ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle)
        let count = min(view.len, max(0, limit))
        row.reset(count: count)
        guard let rawCells = view.ptr else { return }
        for x in 0..<count {
            let raw = rawCells[x]
            var codepoint: UInt32 = 0
            var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
            var wide = GHOSTTY_CELL_WIDE_NARROW
            var styled = false
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_STYLING, &styled)
            row.codepoints[x] = codepoint
            row.widths[x] = Cell.Width(wide)
            row.styles[x] = nil
            row.foregrounds[x] = nil
            row.backgrounds[x] = nil
            row.clusterStarts[x] = -1
            let hasBackground = tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE || tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB
            let isCluster = tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME
            guard styled || hasBackground || isCluster else { continue }
            ghostty_render_state_row_cells_select(cells, UInt16(x))
            let cell = Cell(cells: cells)
            if styled {
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                row.styles[x] = Cell.Style(style)
                row.foregrounds[x] = cell.foreground
            }
            if styled || hasBackground { row.backgrounds[x] = cell.background }
            if isCluster { row.appendCluster(cells, at: x) }
        }
    }
}
