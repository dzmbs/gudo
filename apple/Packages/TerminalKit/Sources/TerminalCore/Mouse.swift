import GhosttyVt

/// A mouse event for mouse reporting (DECSET 9/1000/1002/1003), encoded by libghostty-vt's mouse
/// encoder in whatever format the program asked for (SGR 1006, SGR-pixels 1016, UTF-8, URxvt, X10).
public struct MouseEvent: Sendable, Equatable {
    public enum Action: Sendable { case press, release, motion }

    public enum Button: Sendable, Equatable {
        case left, right, middle
        /// Wheel "buttons" 4–7, sent as presses.
        case wheelUp, wheelDown, wheelLeft, wheelRight

        var ghostty: GhosttyMouseButton {
            switch self {
            case .left: GHOSTTY_MOUSE_BUTTON_LEFT
            case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
            case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
            case .wheelUp: GHOSTTY_MOUSE_BUTTON_FOUR
            case .wheelDown: GHOSTTY_MOUSE_BUTTON_FIVE
            case .wheelLeft: GHOSTTY_MOUSE_BUTTON_SIX
            case .wheelRight: GHOSTTY_MOUSE_BUTTON_SEVEN
            }
        }
    }

    public var action: Action
    /// nil for motion with no button held (any-event tracking, pointer hover).
    public var button: Button?
    public var mods: KeyModifiers
    /// Surface position in pixels, origin at the top-left of the view (padding included).
    public var x: Double
    public var y: Double

    public init(action: Action, button: Button?, mods: KeyModifiers = [], x: Double, y: Double) {
        self.action = action
        self.button = button
        self.mods = mods
        self.x = x
        self.y = y
    }
}

/// Surface geometry the mouse encoder needs to turn pixels into cells, in pixels.
public struct MouseGeometry: Sendable, Equatable {
    public var screenWidth: UInt32
    public var screenHeight: UInt32
    public var cellWidth: UInt32
    public var cellHeight: UInt32
    public var paddingTop: UInt32
    public var paddingRight: UInt32
    public var paddingBottom: UInt32
    public var paddingLeft: UInt32

    public init(
        screenWidth: UInt32, screenHeight: UInt32, cellWidth: UInt32, cellHeight: UInt32,
        paddingTop: UInt32 = 0, paddingRight: UInt32 = 0, paddingBottom: UInt32 = 0, paddingLeft: UInt32 = 0
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingTop = paddingTop
        self.paddingRight = paddingRight
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
    }
}

extension Terminal {
    /// Encodes a mouse event with the terminal's current tracking mode and format. Returns no bytes
    /// when mouse tracking is off, or the event is one the mode does not report (motion in normal
    /// mode, motion within the same cell, ...).
    public func encodeMouse(_ event: MouseEvent, geometry: MouseGeometry, anyButtonPressed: Bool) -> [UInt8] {
        let cell = GridPoint(
            x: Int((event.x - Double(geometry.paddingLeft)) / Double(max(1, geometry.cellWidth))),
            y: Int((event.y - Double(geometry.paddingTop)) / Double(max(1, geometry.cellHeight))))
        guard !(event.action == .motion && lastMouseCell.withLock({ $0 }) == cell) else { return [] }
        let bytes = encodeMouseUnchecked(event, geometry: geometry, anyButtonPressed: anyButtonPressed)
        if !bytes.isEmpty { lastMouseCell.withLock { $0 = cell } }
        return bytes
    }

    private func encodeMouseUnchecked(_ event: MouseEvent, geometry: MouseGeometry, anyButtonPressed: Bool) -> [UInt8] {
        withHandle { t in
            ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, t)
            var size = GhosttyMouseEncoderSize(
                size: MemoryLayout<GhosttyMouseEncoderSize>.size,
                screen_width: geometry.screenWidth, screen_height: geometry.screenHeight,
                cell_width: max(1, geometry.cellWidth), cell_height: max(1, geometry.cellHeight),
                padding_top: geometry.paddingTop, padding_bottom: geometry.paddingBottom,
                padding_right: geometry.paddingRight, padding_left: geometry.paddingLeft)
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
            var pressed = anyButtonPressed
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
            var trackLastCell = true
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell)

            let action: GhosttyMouseAction = switch event.action {
            case .press: GHOSTTY_MOUSE_ACTION_PRESS
            case .release: GHOSTTY_MOUSE_ACTION_RELEASE
            case .motion: GHOSTTY_MOUSE_ACTION_MOTION
            }
            ghostty_mouse_event_set_action(mouseEvent, action)
            if let button = event.button {
                ghostty_mouse_event_set_button(mouseEvent, button.ghostty)
            } else {
                ghostty_mouse_event_clear_button(mouseEvent)
            }
            ghostty_mouse_event_set_mods(mouseEvent, event.mods.rawValue)
            ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(event.x), y: Float(event.y)))

            var buffer = [CChar](repeating: 0, count: 64)
            var written = 0
            guard ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &buffer, buffer.count, &written) == GHOSTTY_SUCCESS
            else { return [] }
            return buffer.prefix(written).map { UInt8(bitPattern: $0) }
        }
    }

    /// Forgets the last reported cell (call when a drag ends or tracking changes) so the next
    /// motion is reported even in the same cell.
    public func resetMouseEncoder() {
        lastMouseCell.withLock { $0 = nil }
        withHandle { _ in ghostty_mouse_encoder_reset(mouseEncoder) }
    }
}

/// Ghostty's alternate scroll (DECSET 1007): on the alt screen with no mouse tracking, the wheel
/// sends cursor up/down keys so pagers and editors scroll.
public enum AlternateScroll {
    /// Whether wheel input should become arrow keys under `modes`.
    public static func applies(_ modes: TerminalModes) -> Bool {
        modes.altScreen && !modes.mouseTracking && modes.alternateScroll
    }
}
