import Foundation
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

    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.y, lhs.x) < (rhs.y, rhs.x) }
}

extension Terminal {
    /// OSC 0/2 title as it prints, cleaned as the daemon cleans titles (any program sets it,
    /// and it reaches tabs, window titles and notifications); "" when none was set.
    public var title: String { Self.printable(string(GHOSTTY_TERMINAL_DATA_TITLE), max: 512) }

    /// OSC 7 working directory (usually a `file://host/path` URL); "" when none was set or
    /// when it, or the path it encodes, holds characters that do not print.
    public var pwd: String {
        let pwd = string(GHOSTTY_TERMINAL_DATA_PWD)
        let decoded = pwd.removingPercentEncoding ?? pwd
        return Self.isPrintable(pwd) && Self.isPrintable(decoded) ? pwd : ""
    }

    /// `text` with control and format characters (bidi controls, zero-width and tag
    /// characters) dropped, whitespace runs collapsed to one space, at most `max` characters.
    static func printable(_ text: String, max: Int) -> String {
        var cleaned = String.UnicodeScalarView()
        var count = 0
        var space = false
        for scalar in text.unicodeScalars where scalar.properties.generalCategory != .format {
            if scalar.properties.generalCategory == .control || scalar.properties.isWhitespace {
                space = !cleaned.isEmpty
                continue
            }
            if count == max {
                cleaned.append("…")
                break
            }
            if space {
                cleaned.append(" ")
                space = false
            }
            cleaned.append(scalar)
            count += 1
        }
        return String(cleaned)
    }

    private static func isPrintable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }
    }

    private func string(_ data: GhosttyTerminalData) -> String {
        withHandle { handle in
            var string = GhosttyString()
            guard ghostty_terminal_get(handle, data, &string) == GHOSTTY_SUCCESS, let ptr = string.ptr, string.len > 0 else { return "" }
            return String(decoding: UnsafeBufferPointer(start: ptr, count: string.len), as: UTF8.self)
        }
    }

    public var modes: TerminalModes {
        withHandle { handle in
            var modes = TerminalModes()
            var tracking = false
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            modes.mouseTracking = tracking
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            modes.altScreen = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
            modes.bracketedPaste = Self.mode(handle, 2004)
            modes.alternateScroll = Self.mode(handle, 1007)
            modes.focusEvents = Self.mode(handle, 1004)
            modes.cursorKeysApplication = Self.mode(handle, 1)
            return modes
        }
    }

    static func mode(_ handle: GhosttyTerminal, _ value: UInt16, ansi: Bool = false) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    /// Whether the cursor is in a shell prompt or its input area per OSC 133 marks (false without
    /// shell integration or on the alt screen).
    public var cursorAtPrompt: Bool {
        withHandle { handle in
            var value = false
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &value)
            return value
        }
    }

    /// Cursor position in the active area (the bottom `rows` rows), regardless of scrolling.
    public var cursorPosition: GridPoint {
        withHandle { handle in
            var x: UInt16 = 0, y: UInt16 = 0
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
            return GridPoint(x: Int(x), y: Int(y))
        }
    }

    public var size: (cols: Int, rows: Int) {
        withHandle { handle in
            var cols: UInt16 = 0, rows: UInt16 = 0
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            return (Int(cols), Int(rows))
        }
    }

    /// Scrollback position: total rows, the viewport's offset into them and its height.
    public var scrollbar: (total: Int, offset: Int, visible: Int) {
        withHandle { handle in
            var bar = GhosttyTerminalScrollbar()
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
            return (Int(bar.total), Int(bar.offset), Int(bar.len))
        }
    }

    /// Whether the viewport follows the active area (not scrolled into history).
    public var viewportAtBottom: Bool {
        withHandle { handle in
            var value = true
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &value)
            return value
        }
    }

    /// The grapheme cluster in a cell of the active area ("" for an empty cell or a wide tail).
    public func text(atActive point: GridPoint) -> String {
        withHandle { handle in
            guard let ref = Self.gridRef(handle, point, GHOSTTY_POINT_TAG_ACTIVE) else { return "" }
            return Self.graphemes(ref)
        }
    }

    /// Whether a cell of the active area holds the first half of a wide character.
    public func isWide(atActive point: GridPoint) -> Bool {
        withHandle { handle in
            guard var ref = Self.gridRef(handle, point, GHOSTTY_POINT_TAG_ACTIVE) else { return false }
            var cell: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { return false }
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            return wide == GHOSTTY_CELL_WIDE_WIDE
        }
    }

    static func gridRef(_ handle: GhosttyTerminal, _ point: GridPoint, _ tag: GhosttyPointTag) -> GhosttyGridRef? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var gridPoint = GhosttyPoint()
        gridPoint.tag = tag
        gridPoint.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: point.x), y: UInt32(clamping: point.y))
        return ghostty_terminal_grid_ref(handle, gridPoint, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    static func graphemes(_ ref: GhosttyGridRef) -> String {
        var ref = ref
        var buffer = [UInt32](repeating: 0, count: 16)
        var count = 0
        guard ghostty_grid_ref_graphemes(&ref, &buffer, buffer.count, &count) == GHOSTTY_SUCCESS else { return "" }
        var text = ""
        text.unicodeScalars.append(contentsOf: buffer.prefix(count).compactMap(Unicode.Scalar.init))
        return text
    }

    /// The viewport as plain text, one line per row with trailing blanks trimmed (accessibility).
    public func visibleText() -> String {
        withHandle { handle in
            var cols: UInt16 = 0, rows: UInt16 = 0
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            var lines: [String] = []
            for y in 0..<Int(rows) {
                var line = ""
                for x in 0..<Int(cols) {
                    guard var ref = Self.gridRef(handle, GridPoint(x: x, y: y), GHOSTTY_POINT_TAG_VIEWPORT) else { continue }
                    // The second half of a wide character (and the padding before one that
                    // wrapped) is part of that character, not a blank: "你好", not "你 好".
                    var cell = GhosttyCell()
                    if ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS {
                        var wide = GHOSTTY_CELL_WIDE_NARROW
                        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
                        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                    }
                    let grapheme = Self.graphemes(ref)
                    line += grapheme.isEmpty ? " " : grapheme
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
        withHandle { handle in
            guard var ref = Self.gridRef(handle, point, GHOSTTY_POINT_TAG_VIEWPORT) else { return nil }
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
