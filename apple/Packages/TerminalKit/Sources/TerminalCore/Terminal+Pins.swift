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
        withHandle { t in Self.totalRows(t) }
    }

    /// Pins row `screenRow` of the active screen (0 = the oldest retained row). Nil for a row
    /// outside the screen.
    public func pinRow(screenRow: Int) -> RowPin? {
        guard screenRow >= 0 else { return nil }
        return withHandle { t in
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_SCREEN
            point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(clamping: screenRow))
            var ref: GhosttyTrackedGridRef?
            guard ghostty_terminal_grid_ref_track(t, point, &ref) == GHOSTTY_SUCCESS, let ref else { return nil }
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
        let top = withHandle { t in Self.viewportTop(t) }
        return pinRow(screenRow: top + viewportRow)
    }

    /// The pin's row in screen coordinates (0 = oldest retained row), or nil once it has no value.
    public func screenRow(of pin: RowPin) -> Int? {
        withHandle { _ in Self.screenRow(pin) }
    }

    /// How many rows the pin is above the bottom row of the screen (the anchor convention).
    public func fromBottom(of pin: RowPin) -> Int? {
        withHandle { t in Self.screenRow(pin).map { Self.totalRows(t) - 1 - $0 } }
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
        withHandle { t in
            guard let base = Self.screenRow(reference) else { return nil }
            let y = base + offset
            guard y >= 0, y < Self.totalRows(t) else { return nil }
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_SCREEN
            point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(y))
            var ref: GhosttyTrackedGridRef?
            guard ghostty_terminal_grid_ref_track(t, point, &ref) == GHOSTTY_SUCCESS, let ref else { return nil }
            return RowPin(ref: ref, owner: self)
        }
    }

    /// Each pin's row relative to the viewport's top row (negative above it, `>= rows` below
    /// it), read under one lock for a consistent frame; nil for pins without a value.
    public func viewportRows(of pins: [RowPin]) -> [Int?] {
        withHandle { t in
            let top = Self.viewportTop(t)
            return pins.map { pin in Self.screenRow(pin).map { $0 - top } }
        }
    }

    private static func screenRow(_ pin: RowPin) -> Int? {
        var out = GhosttyPointCoordinate()
        guard ghostty_tracked_grid_ref_point(pin.ref, GHOSTTY_POINT_TAG_SCREEN, &out) == GHOSTTY_SUCCESS else { return nil }
        return Int(out.y)
    }

    private static func totalRows(_ t: GhosttyTerminal) -> Int {
        var total = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
        return total
    }

    /// The viewport's top row in screen coordinates.
    private static func viewportTop(_ t: GhosttyTerminal) -> Int {
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return Int(bar.offset)
    }
}
