extension KeyEvent {
    /// Ghostty's macOS defaults, sent as legacy bytes whatever keyboard protocol is active:
    /// ⌥←/⌥→ move by word, ⌘←/⌘→ go to the line's start/end, ⌘⌫ deletes to the start.
    /// Nil for any other key; empty for the release of one of these.
    public var lineEditingBytes: [UInt8]? {
        let bytes: [UInt8]? = switch (key, mods.subtracting(.capsLock)) {
        case (.arrowLeft, .alt): [0x1B, 0x62]
        case (.arrowRight, .alt): [0x1B, 0x66]
        case (.arrowLeft, .super): [0x01]
        case (.arrowRight, .super): [0x05]
        case (.backspace, .super): [0x15]
        default: nil
        }
        guard let bytes else { return nil }
        return action == .release ? [] : bytes
    }
}
