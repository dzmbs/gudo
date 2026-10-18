/// Ghostty's `macos-option-as-alt`: which Option keys act as Meta/Alt (ESC prefix, kitty alt bit)
/// instead of typing the layout's special characters (é, ∂, …).
public enum OptionAsMeta: String, Sendable, CaseIterable, Codable {
    case none, left, right, both

    /// Whether Option should be Meta given which Option keys are held.
    public func applies(leftHeld: Bool, rightHeld: Bool) -> Bool {
        switch self {
        case .none: false
        case .left: leftHeld
        case .right: rightHeld
        case .both: leftHeld || rightHeld
        }
    }

    /// The key event for a key pressed with Option acting as Meta: the text is what the key
    /// types without Option (Shift kept), and Alt stays a modifier, so the encoder adds the ESC
    /// prefix (or the kitty alt bit).
    public func metaEvent(
        key: PhysicalKey, action: KeyEvent.Action, mods: KeyModifiers, textWithoutOption: String, unshiftedCodepoint: UInt32
    ) -> KeyEvent {
        let shifted = mods.contains(.shift)
        let text = textWithoutOption
        let consumed: KeyModifiers = shifted && !text.isEmpty && text != text.lowercased() ? .shift : []
        return KeyEvent(key: key, action: action, mods: mods, consumedMods: consumed, text: text, unshiftedCodepoint: unshiftedCodepoint)
    }
}
