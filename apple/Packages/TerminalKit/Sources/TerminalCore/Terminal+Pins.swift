import GhosttyVt

/// A row pinned in a terminal: a libghostty-vt tracked grid reference on its first cell, which
/// follows the row through scrolling, reflow and scrollback pruning. Inline images and draw
/// overlays hang off pins so they scroll with the output (docs/DAEMON.md §7.10–7.11).
///
/// A pin has no value once its row left the scrollback, and after a snapshot restore replaced
/// the terminal's state (the old state is freed; the pin then reports nothing and the owner
/// pins again).
public final class RowPin: @unchecked Sendable {
    fileprivate let ref: GhosttyTrackedGridRef
    fileprivate weak var owner: Terminal?

    fileprivate init(ref: GhosttyTrackedGridRef, owner: Terminal) {
        self.ref = ref
        self.owner = owner
    }

    deinit {
        // The reference is part of the terminal's bookkeeping: free it under the lock. After the
        // terminal (or the state it pinned) is gone, freeing needs no lock.
        if let owner {
            owner.withHandle { _ in ghostty_tracked_grid_ref_free(ref) }
        } else {
            ghostty_tracked_grid_ref_free(ref)
        }
    }
}

extension Terminal {
    /// Rows on the active screen including scrollback.
    public var totalRows: Int {
        withHandle { handle in Self.totalRows(handle) }
    }

    /// Pins row `screenRow` of the active screen (0 = the oldest retained row). Nil for a row
    /// outside the screen.
    public func pinRow(screenRow: Int) -> RowPin? {
        guard screenRow >= 0 else { return nil }
        return withHandle { handle in
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_SCREEN
            point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(clamping: screenRow))
            var ref: GhosttyTrackedGridRef?
            guard ghostty_terminal_grid_ref_track(handle, point, &ref) == GHOSTTY_SUCCESS, let ref else { return nil }
            return RowPin(ref: ref, owner: self)
        }
    }

    /// Pins the row `fromBottom` rows above the last row of the active screen (0 = the bottom
    /// row): the daemon's anchor convention (`RowAnchor.from_bottom`).
    public func pinRow(fromBottom: Int) -> RowPin? {
        let total = totalRows
        return pinRow(screenRow: total - 1 - fromBottom)
    }

    /// Pins a row of the viewport (0 = its top row).
    public func pinRow(viewportRow: Int) -> RowPin? {
        let top = withHandle { handle in Self.viewportTop(handle) }
        return pinRow(screenRow: top + viewportRow)
    }

    /// The pin's row in screen coordinates (0 = oldest retained row), or nil once it has no value.
    public func screenRow(of pin: RowPin) -> Int? {
        withHandle { _ in Self.screenRow(pin) }
    }

    /// How many rows the pin is above the bottom row of the screen (the anchor convention).
    public func fromBottom(of pin: RowPin) -> Int? {
        withHandle { handle in Self.screenRow(pin).map { Self.totalRows(handle) - 1 - $0 } }
    }

    /// Each pin's row in screen coordinates, read under one lock (so differences between pins
    /// are consistent even while output is being written).
    public func screenRows(of pins: [RowPin]) -> [Int?] {
        withHandle { _ in pins.map(Self.screenRow) }
    }

    /// Pins the row `offset` rows below `reference`'s row (negative: above), resolved under one
    /// lock with reading the reference. Nil when the reference has no value or the row is
    /// outside the screen.
    public func pinRow(relativeTo reference: RowPin, offset: Int) -> RowPin? {
        withHandle { handle in
            guard let base = Self.screenRow(reference) else { return nil }
            let y = base + offset
            guard y >= 0, y < Self.totalRows(handle) else { return nil }
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_SCREEN
            point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(y))
            var ref: GhosttyTrackedGridRef?
            guard ghostty_terminal_grid_ref_track(handle, point, &ref) == GHOSTTY_SUCCESS, let ref else { return nil }
            return RowPin(ref: ref, owner: self)
        }
    }

    /// Each pin's row relative to the viewport's top row (negative above it, `>= rows` below
    /// it), read under one lock for a consistent frame; nil for pins without a value.
    public func viewportRows(of pins: [RowPin]) -> [Int?] {
        withHandle { handle in
            let top = Self.viewportTop(handle)
            return pins.map { pin in Self.screenRow(pin).map { $0 - top } }
        }
    }

    /// Whether the pin's row holds a shell prompt (OSC 133 `A`, or a continuation line), as this
    /// terminal parsed it. Nil when the pin has no value. A terminal restored from a snapshot
    /// may not know which rows were prompts.
    public func isPromptRow(_ pin: RowPin) -> Bool? {
        withHandle { _ in
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.size
            guard ghostty_tracked_grid_ref_snapshot(pin.ref, &ref) == GHOSTTY_SUCCESS else { return nil }
            var row: GhosttyRow = 0
            guard ghostty_grid_ref_row(&ref, &row) == GHOSTTY_SUCCESS else { return nil }
            var semantic = GHOSTTY_ROW_SEMANTIC_NONE
            guard ghostty_row_get(row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &semantic) == GHOSTTY_SUCCESS else { return nil }
            return semantic != GHOSTTY_ROW_SEMANTIC_NONE
        }
    }

    /// The viewport's top row in screen coordinates (0 = the oldest retained row).
    public var viewportTopRow: Int {
        withHandle { handle in Self.viewportTop(handle) }
    }

    /// Scrolls so screen row `screenRow` is the viewport's top row (clamped so the viewport
    /// never passes the active area).
    public func scrollViewport(toScreenRow screenRow: Int) {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
        scroll.value.row = max(0, screenRow)
        withHandle { handle in ghostty_terminal_scroll_viewport(handle, scroll) }
    }

    /// Scrolls by `prompts` shell prompts (negative: back towards history) using the rows the
    /// shell marked with OSC 133, as Ghostty's `jump_to_prompt` does. No-op without marks.
    public func scrollViewport(byPrompts prompts: Int) {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA_PROMPT
        scroll.value.delta_prompt = prompts
        withHandle { handle in ghostty_terminal_scroll_viewport(handle, scroll) }
    }

    private static func screenRow(_ pin: RowPin) -> Int? {
        var coordinate = GhosttyPointCoordinate()
        guard ghostty_tracked_grid_ref_point(pin.ref, GHOSTTY_POINT_TAG_SCREEN, &coordinate) == GHOSTTY_SUCCESS else { return nil }
        return Int(coordinate.y)
    }

    private static func totalRows(_ handle: GhosttyTerminal) -> Int {
        var total = 0
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
        return total
    }

    /// The viewport's top row in screen coordinates.
    private static func viewportTop(_ handle: GhosttyTerminal) -> Int {
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return Int(bar.offset)
    }
}
