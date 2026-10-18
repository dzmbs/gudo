import CGhosttyVt

/// A physical key, identified layout-independently (W3C `code`), as libghostty-vt expects.
public struct PhysicalKey: Hashable, Sendable {
    let raw: GhosttyKey

    private static let byMacKeyCode: [UInt16: GhosttyKey] = Dictionary(
        keyCodeTable.filter { $0.mac != 0xFFFF }.map { ($0.mac, $0.key) },
        uniquingKeysWith: { first, _ in first }
    )
    private static let byHIDUsage: [UInt32: GhosttyKey] = Dictionary(
        keyCodeTable.map { ($0.usb & 0xFFFF, $0.key) },
        uniquingKeysWith: { first, _ in first }
    )

    /// From an AppKit `NSEvent.keyCode` (macOS virtual keycode).
    public init?(macKeyCode: UInt16) {
        guard let key = Self.byMacKeyCode[macKeyCode] else { return nil }
        raw = key
    }

    /// From a UIKit `UIKey.keyCode` (USB HID usage on the keyboard page 0x07).
    public init?(hidUsage: UInt32) {
        guard let key = Self.byHIDUsage[hidUsage & 0xFFFF] else { return nil }
        raw = key
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.raw.rawValue == rhs.raw.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(raw.rawValue) }
}

/// Modifier bits, identical to `GHOSTTY_MODS_*`.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = Self(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    public static let control = Self(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    public static let alt = Self(rawValue: UInt16(GHOSTTY_MODS_ALT))
    public static let `super` = Self(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    public static let capsLock = Self(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
}

public struct KeyEvent: Sendable {
    public enum Action: Sendable {
        case press, `repeat`, release

        var ghostty: GhosttyKeyAction {
            switch self {
            case .press: GHOSTTY_KEY_ACTION_PRESS
            case .repeat: GHOSTTY_KEY_ACTION_REPEAT
            case .release: GHOSTTY_KEY_ACTION_RELEASE
            }
        }
    }

    public var key: PhysicalKey
    public var action: Action
    public var mods: KeyModifiers
    /// Modifiers the layout already applied to `text` (e.g. shift for "A"); excluded from encoding.
    public var consumedMods: KeyModifiers
    /// Text the key produces in the current layout, without control transformations. Empty for
    /// keys that produce no text (arrows, function keys) or produce C0 controls.
    public var text: String
    /// The codepoint the key produces with no modifiers (for kitty keyboard alternate keys).
    public var unshiftedCodepoint: UInt32

    public init(
        key: PhysicalKey,
        action: Action,
        mods: KeyModifiers,
        consumedMods: KeyModifiers = [],
        text: String,
        unshiftedCodepoint: UInt32
    ) {
        self.key = key
        self.action = action
        self.mods = mods
        self.consumedMods = consumedMods
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
    }
}
