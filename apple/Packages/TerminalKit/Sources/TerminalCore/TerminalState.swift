import GhosttyVt

/// The terminal modes the host's input handling depends on, read in one locked call.
public struct TerminalModes: Sendable, Equatable {
    /// Any mouse tracking mode (X10, 1000, 1002, 1003) is on.
    public var mouseTracking = false
    /// The alternate screen is active.
    public var altScreen = false
    /// DECSET 2004.
    public var bracketedPaste = false
    /// DECSET 1007: wheel → arrow keys on the alt screen when no mouse mode is on (on by default
    /// in Ghostty).
    public var alternateScroll = false
    /// DECSET 1004: report focus in/out.
    public var focusEvents = false
    /// DECCKM: application cursor keys.
    public var cursorKeysApplication = false

    public init() {}
}

/// A cell position. `y` is relative to the coordinate space named where it is used.
public struct GridPoint: Hashable, Sendable, Comparable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static func < (a: Self, b: Self) -> Bool { (a.y, a.x) < (b.y, b.x) }
}

extension Terminal {
    /// OSC 0/2 title; "" when none was set.
    public var title: String { string(GHOSTTY_TERMINAL_DATA_TITLE) }

    /// OSC 7 working directory (usually a `file://host/path` URL); "" when none was set.
    public var pwd: String { string(GHOSTTY_TERMINAL_DATA_PWD) }

    private func string(_ data: GhosttyTerminalData) -> String {
        withHandle { t in
            var s = GhosttyString()
            guard ghostty_terminal_get(t, data, &s) == GHOSTTY_SUCCESS, let ptr = s.ptr, s.len > 0 else { return "" }
            return String(decoding: UnsafeBufferPointer(start: ptr, count: s.len), as: UTF8.self)
        }
    }

    public var modes: TerminalModes {
        withHandle { t in
            var modes = TerminalModes()
            var tracking = false
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            modes.mouseTracking = tracking
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            modes.altScreen = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
            modes.bracketedPaste = Self.mode(t, 2004)
            modes.alternateScroll = Self.mode(t, 1007)
            modes.focusEvents = Self.mode(t, 1004)
            modes.cursorKeysApplication = Self.mode(t, 1)
            return modes
        }
    }

    private static func mode(_ t: GhosttyTerminal, _ value: UInt16, ansi: Bool = false) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    /// Whether the cursor is in a shell prompt or its input area per OSC 133 marks (false without
    /// shell integration or on the alt screen).
    public var cursorAtPrompt: Bool {
        withHandle { t in
            var value = false
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &value)
            return value
        }
    }

    /// Cursor position in the active area (the bottom `rows` rows), regardless of scrolling.
    public var cursorPosition: GridPoint {
        withHandle { t in
            var x: UInt16 = 0, y: UInt16 = 0
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
            return GridPoint(x: Int(x), y: Int(y))
        }
    }

    public var size: (cols: Int, rows: Int) {
        withHandle { t in
            var cols: UInt16 = 0, rows: UInt16 = 0
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            return (Int(cols), Int(rows))
        }
    }

    /// Scrollback position: total rows, the viewport's offset into them and its height.
    public var scrollbar: (total: Int, offset: Int, visible: Int) {
        withHandle { t in
            var bar = GhosttyTerminalScrollbar()
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
            return (Int(bar.total), Int(bar.offset), Int(bar.len))
        }
    }

    /// Whether the viewport follows the active area (not scrolled into history).
    public var viewportAtBottom: Bool {
        withHandle { t in
            var value = true
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &value)
            return value
        }
    }

    /// The grapheme cluster in a cell of the active area ("" for an empty cell or a wide tail).
    public func text(atActive point: GridPoint) -> String {
        withHandle { t in
            guard let ref = Self.gridRef(t, point, GHOSTTY_POINT_TAG_ACTIVE) else { return "" }
            return Self.graphemes(ref)
        }
    }

    /// Whether a cell of the active area holds the first half of a wide character.
    public func isWide(atActive point: GridPoint) -> Bool {
        withHandle { t in
            guard var ref = Self.gridRef(t, point, GHOSTTY_POINT_TAG_ACTIVE) else { return false }
            var cell: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { return false }
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            return wide == GHOSTTY_CELL_WIDE_WIDE
        }
    }

    static func gridRef(_ t: GhosttyTerminal, _ point: GridPoint, _ tag: GhosttyPointTag) -> GhosttyGridRef? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var p = GhosttyPoint()
        p.tag = tag
        p.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: point.x), y: UInt32(clamping: point.y))
        return ghostty_terminal_grid_ref(t, p, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    static func graphemes(_ ref: GhosttyGridRef) -> String {
        var ref = ref
        var buffer = [UInt32](repeating: 0, count: 16)
        var count = 0
        guard ghostty_grid_ref_graphemes(&ref, &buffer, buffer.count, &count) == GHOSTTY_SUCCESS else { return "" }
        var s = ""
        s.unicodeScalars.append(contentsOf: buffer.prefix(count).compactMap(Unicode.Scalar.init))
        return s
    }

    /// The viewport as plain text, one line per row with trailing blanks trimmed (accessibility).
    public func visibleText() -> String {
        withHandle { t in
            var cols: UInt16 = 0, rows: UInt16 = 0
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            var lines: [String] = []
            for y in 0..<Int(rows) {
                var line = ""
                for x in 0..<Int(cols) {
                    guard let ref = Self.gridRef(t, GridPoint(x: x, y: y), GHOSTTY_POINT_TAG_VIEWPORT) else { continue }
                    let g = Self.graphemes(ref)
                    line += g.isEmpty ? " " : g
                }
                while line.last == " " { line.removeLast() }
                lines.append(line)
            }
            while lines.last?.isEmpty == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }

    /// The OSC 8 hyperlink URI of a viewport cell, if any.
    public func hyperlink(atViewport point: GridPoint) -> String? {
        withHandle { t in
            guard var ref = Self.gridRef(t, point, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
            var buffer = [UInt8](repeating: 0, count: 2048)
            var length = 0
            guard ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length) == GHOSTTY_SUCCESS, length > 0 else { return nil }
            return String(decoding: buffer.prefix(length), as: UTF8.self)
        }
    }

    // MARK: Focus

    /// The focus-in/out report to send when mode 1004 is on, else nothing.
    public func encodeFocus(_ focused: Bool) -> [UInt8] {
        guard modes.focusEvents else { return [] }
        var buffer = [CChar](repeating: 0, count: 8)
        var written = 0
        guard ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, &buffer, buffer.count, &written) == GHOSTTY_SUCCESS
        else { return [] }
        return buffer.prefix(written).map { UInt8(bitPattern: $0) }
    }
}
