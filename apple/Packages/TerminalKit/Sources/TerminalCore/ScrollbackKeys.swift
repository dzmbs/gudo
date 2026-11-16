/// Where a viewport key moves the scrollback.
public enum ScrollbackMove: Sendable, Equatable {
    case pageUp, pageDown, top, bottom
}

extension KeyEvent {
    /// Ghostty's macOS viewport keys: ⌘Page Up/Down page through the scrollback, ⌘Home/End go
    /// to its top and bottom. Nil for any other key, and for their release.
    public var scrollbackMove: ScrollbackMove? {
        guard action != .release, mods.subtracting(.capsLock) == .super else { return nil }
        return switch key {
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .home: .top
        case .end: .bottom
        default: nil
        }
    }
}
