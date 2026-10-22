import GhosttyVt

/// A selection in *screen* coordinates (`y` counts from the top of the scrollback), so it stays
/// put while the viewport scrolls. Both ends are inclusive and in the order they were made
/// (`anchor` where the selection started, `head` where it was extended to).
///
/// The terminal owns the live selection (libghostty-vt tracks it through scrolling, scrollback
/// pruning and reflow); this value is a snapshot of it.
public struct Selection: Sendable, Equatable {
    public var anchor: GridPoint
    public var head: GridPoint
    /// A block selection: the ends are opposite corners.
    public var rectangle: Bool

    public init(anchor: GridPoint, head: GridPoint, rectangle: Bool = false) {
        self.anchor = anchor
        self.head = head
        self.rectangle = rectangle
    }

    /// The ends in reading order.
    public var start: GridPoint { min(anchor, head) }
    public var end: GridPoint { max(anchor, head) }

    /// Whether a screen cell is selected.
    public func contains(_ point: GridPoint) -> Bool {
        guard rectangle else { return start <= point && point <= end }
        return (min(anchor.x, head.x)...max(anchor.x, head.x)).contains(point.x)
            && (min(anchor.y, head.y)...max(anchor.y, head.y)).contains(point.y)
    }
}

extension Terminal {
    // MARK: Coordinates

    /// Converts a viewport cell to screen coordinates (nil when outside the grid).
    public func screenPoint(fromViewport point: GridPoint) -> GridPoint? {
        withHandle { t in
            guard var ref = Self.gridRef(t, point, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
            return Self.point(t, &ref, GHOSTTY_POINT_TAG_SCREEN)
        }
    }

    /// Converts a screen cell to the viewport (nil when scrolled out of view).
    public func viewportPoint(fromScreen point: GridPoint) -> GridPoint? {
        withHandle { t in
            guard var ref = Self.gridRef(t, point, GHOSTTY_POINT_TAG_SCREEN) else { return nil }
            return Self.point(t, &ref, GHOSTTY_POINT_TAG_VIEWPORT)
        }
    }

    static func point(_ t: GhosttyTerminal, _ ref: inout GhosttyGridRef, _ tag: GhosttyPointTag) -> GridPoint? {
        var out = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(t, &ref, tag, &out) == GHOSTTY_SUCCESS else { return nil }
        return GridPoint(x: Int(out.x), y: Int(out.y))
    }

    // MARK: Active selection

    /// The terminal's current selection, or nil.
    public var selection: Selection? {
        withHandle { t in
            var s = GhosttySelection()
            s.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SELECTION, &s) == GHOSTTY_SUCCESS else { return nil }
            return Self.selection(t, s)
        }
    }

    static func selection(_ t: GhosttyTerminal, _ s: GhosttySelection) -> Selection? {
        var start = s.start, end = s.end
        guard let a = point(t, &start, GHOSTTY_POINT_TAG_SCREEN), let b = point(t, &end, GHOSTTY_POINT_TAG_SCREEN) else { return nil }
        return Selection(anchor: a, head: b, rectangle: s.rectangle)
    }

    /// Installs (or with nil clears) the selection. Out-of-range points are clamped to the grid.
    public func setSelection(_ selection: Selection?) {
        withHandle { t in
            guard let selection else {
                ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
                return
            }
            guard var s = Self.ghosttySelection(t, selection) else { return }
            ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &s)
        }
    }

    static func ghosttySelection(_ t: GhosttyTerminal, _ selection: Selection) -> GhosttySelection? {
        let (cols, total) = screenExtent(t)
        func clamp(_ p: GridPoint) -> GridPoint {
            GridPoint(x: min(max(p.x, 0), cols - 1), y: min(max(p.y, 0), total - 1))
        }
        guard let a = gridRef(t, clamp(selection.anchor), GHOSTTY_POINT_TAG_SCREEN),
              let b = gridRef(t, clamp(selection.head), GHOSTTY_POINT_TAG_SCREEN) else { return nil }
        var s = GhosttySelection()
        s.size = MemoryLayout<GhosttySelection>.size
        s.start = a
        s.end = b
        s.rectangle = selection.rectangle
        return s
    }

    static func screenExtent(_ t: GhosttyTerminal) -> (cols: Int, rows: Int) {
        var cols: UInt16 = 0
        var total = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
        return (max(1, Int(cols)), max(1, total))
    }

    public func clearSelection() { setSelection(nil) }

    /// Selects the word under a viewport cell (Ghostty's word boundaries) and installs it.
    @discardableResult
    public func selectWord(atViewport point: GridPoint) -> Selection? {
        withHandle { t in
            guard let ref = Self.gridRef(t, point, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
            var options = GhosttyTerminalSelectWordOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
            options.ref = ref
            var s = GhosttySelection()
            s.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_select_word(t, &options, &s) == GHOSTTY_SUCCESS else { return nil }
            ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &s)
            return Self.selection(t, s)
        }
    }

    /// Selects the URL or path under a viewport cell whole (word boundaries stop at `:` and `/`),
    /// else the word.
    @discardableResult
    public func selectLinkOrWord(atViewport point: GridPoint) -> Selection? {
        guard let link = link(atViewport: point),
              let start = screenPoint(fromViewport: GridPoint(x: link.columns.lowerBound, y: link.row)),
              let end = screenPoint(fromViewport: GridPoint(x: link.columns.upperBound, y: link.row))
        else { return selectWord(atViewport: point) }
        let selection = Selection(anchor: start, head: end)
        setSelection(selection)
        return selection
    }

    /// Selects the (soft-wrapped) line under a viewport cell, trimmed, and installs it.
    @discardableResult
    public func selectLine(atViewport point: GridPoint) -> Selection? {
        withHandle { t in
            guard let ref = Self.gridRef(t, point, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
            var options = GhosttyTerminalSelectLineOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
            options.ref = ref
            options.semantic_prompt_boundary = true
            var s = GhosttySelection()
            s.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_select_line(t, &options, &s) == GHOSTTY_SUCCESS else { return nil }
            ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &s)
            return Self.selection(t, s)
        }
    }

    @discardableResult
    public func selectAll() -> Selection? {
        withHandle { t in
            var s = GhosttySelection()
            s.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_select_all(t, &s) == GHOSTTY_SUCCESS else { return nil }
            ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &s)
            return Self.selection(t, s)
        }
    }

    /// The selected text as plain text: soft-wrapped rows joined, trailing blanks trimmed, rows of a
    /// block selection separated by newlines. nil without a selection.
    public func selectionText() -> String? {
        withHandle { t in
            var options = GhosttyTerminalSelectionFormatOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.unwrap = true
            options.trim = true
            options.selection = nil
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(t, nil, options, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
            defer { ghostty_free(nil, ptr, len) }
            return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
        }
    }
}

/// Mouse/trackpad selection: libghostty-vt's selection gesture state machine (click counting for
/// double/triple click word/line selection, drag extension with word/line granularity, rectangle
/// selection, autoscroll at the edges). Each event that produces a selection installs it.
///
/// Positions are surface pixels (origin top-left of the view, padding included); cells are viewport
/// coordinates.
public final class SelectionGesture {
    public struct Geometry: Sendable, Equatable {
        public var columns: UInt32
        public var cellWidth: UInt32
        public var paddingLeft: UInt32
        public var screenHeight: UInt32

        public init(columns: UInt32, cellWidth: UInt32, paddingLeft: UInt32, screenHeight: UInt32) {
            self.columns = columns
            self.cellWidth = cellWidth
            self.paddingLeft = paddingLeft
            self.screenHeight = screenHeight
        }
    }

    public enum Autoscroll: Sendable { case none, up, down }

    private let terminal: Terminal
    private let gesture: GhosttySelectionGesture
    private let press: GhosttySelectionGestureEvent
    private let drag: GhosttySelectionGestureEvent
    private let release: GhosttySelectionGestureEvent
    private let tick: GhosttySelectionGestureEvent

    /// Ghostty's defaults: clicks within 500 ms and a few points of each other repeat.
    public var repeatInterval: Double = 0.5
    public var repeatDistance: Double = 8

    public init(terminal: Terminal) {
        self.terminal = terminal
        var gesture: GhosttySelectionGesture?
        var press: GhosttySelectionGestureEvent?, drag: GhosttySelectionGestureEvent?
        var release: GhosttySelectionGestureEvent?, tick: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_new(nil, &gesture) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_new(nil, &press, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_new(nil, &drag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_new(nil, &release, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_new(nil, &tick, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK) == GHOSTTY_SUCCESS,
              let gesture, let press, let drag, let release, let tick
        else { fatalError("libghostty-vt allocation failed") }
        self.gesture = gesture
        self.press = press
        self.drag = drag
        self.release = release
        self.tick = tick
    }

    deinit {
        ghostty_selection_gesture_event_free(press)
        ghostty_selection_gesture_event_free(drag)
        ghostty_selection_gesture_event_free(release)
        ghostty_selection_gesture_event_free(tick)
        terminal.withHandle { ghostty_selection_gesture_free(gesture, $0) }
    }

    /// A button press. Returns the selection a double/triple click made (single clicks select
    /// nothing until dragged; the caller clears any old selection).
    /// - Parameter time: monotonic seconds, for click counting.
    @discardableResult
    public func press(cell: GridPoint, x: Double, y: Double, time: Double) -> Selection? {
        terminal.withHandle { t in
            guard var ref = Terminal.gridRef(t, cell, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
            var position = GhosttySurfacePosition(x: x, y: y)
            var ns = UInt64(max(0, time) * 1e9)
            var interval = UInt64(repeatInterval * 1e9)
            var distance = repeatDistance
            ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &ns)
            ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
            ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
            return apply(t, press)
        }
    }

    /// Pointer moved with the button held. `rectangle` (Option held) makes a block selection.
    @discardableResult
    public func drag(cell: GridPoint, x: Double, y: Double, rectangle: Bool, geometry: Geometry) -> Selection? {
        terminal.withHandle { t in
            guard var ref = Terminal.gridRef(t, cell, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
            var position = GhosttySurfacePosition(x: x, y: y)
            var rect = rectangle
            var geo = geometry.ghostty
            ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)
            ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geo)
            return apply(t, drag)
        }
    }

    public func release(cell: GridPoint?) {
        terminal.withHandle { t in
            if let cell, var ref = Terminal.gridRef(t, cell, GHOSTTY_POINT_TAG_VIEWPORT) {
                ghostty_selection_gesture_event_set(release, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            } else {
                ghostty_selection_gesture_event_set(release, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
            }
            _ = ghostty_selection_gesture_event(gesture, t, release, nil)
        }
    }

    /// Whether the last drag left the view vertically and wants autoscroll ticks.
    public var autoscroll: Autoscroll {
        terminal.withHandle { t in
            var value = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
            ghostty_selection_gesture_get(gesture, t, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &value)
            return switch value {
            case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP: .up
            case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN: .down
            default: .none
            }
        }
    }

    /// Whether the current/last press was dragged (a click without a drag is a plain click).
    public var dragged: Bool {
        terminal.withHandle { t in
            var value = false
            ghostty_selection_gesture_get(gesture, t, GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED, &value)
            return value
        }
    }

    public var clickCount: Int {
        terminal.withHandle { t in
            var value: UInt8 = 0
            ghostty_selection_gesture_get(gesture, t, GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &value)
            return Int(value)
        }
    }

    /// Call after scrolling the viewport one step during autoscroll: extends the selection to the
    /// pointer's cell in the new viewport.
    @discardableResult
    public func autoscrollTick(cell: GridPoint, x: Double, y: Double, rectangle: Bool, geometry: Geometry) -> Selection? {
        terminal.withHandle { t in
            var viewport = GhosttyPointCoordinate(x: UInt16(clamping: max(0, cell.x)), y: UInt32(clamping: max(0, cell.y)))
            var position = GhosttySurfacePosition(x: x, y: y)
            var rect = rectangle
            var geo = geometry.ghostty
            ghostty_selection_gesture_event_set(tick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport)
            ghostty_selection_gesture_event_set(tick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            ghostty_selection_gesture_event_set(tick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)
            ghostty_selection_gesture_event_set(tick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geo)
            return apply(t, tick)
        }
    }

    public func reset() {
        terminal.withHandle { ghostty_selection_gesture_reset(gesture, $0) }
    }

    private func apply(_ t: GhosttyTerminal, _ event: GhosttySelectionGestureEvent) -> Selection? {
        var s = GhosttySelection()
        s.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_selection_gesture_event(gesture, t, event, &s) == GHOSTTY_SUCCESS else { return nil }
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &s)
        return Terminal.selection(t, s)
    }
}

extension SelectionGesture.Geometry {
    var ghostty: GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(columns: columns, cell_width: cellWidth, padding_left: paddingLeft, screen_height: screenHeight)
    }
}
