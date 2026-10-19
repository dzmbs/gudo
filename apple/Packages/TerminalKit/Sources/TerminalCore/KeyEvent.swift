import GhosttyVt

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

    private init(_ raw: GhosttyKey) {
        self.raw = raw
    }

    public static let unidentified = Self(GHOSTTY_KEY_UNIDENTIFIED)
    public static let enter = Self(GHOSTTY_KEY_ENTER)
    public static let tab = Self(GHOSTTY_KEY_TAB)
    public static let backspace = Self(GHOSTTY_KEY_BACKSPACE)
    public static let escape = Self(GHOSTTY_KEY_ESCAPE)
    public static let arrowUp = Self(GHOSTTY_KEY_ARROW_UP)
    public static let arrowDown = Self(GHOSTTY_KEY_ARROW_DOWN)
    public static let arrowLeft = Self(GHOSTTY_KEY_ARROW_LEFT)
    public static let arrowRight = Self(GHOSTTY_KEY_ARROW_RIGHT)
    public static let space = Self(GHOSTTY_KEY_SPACE)

    /// The key that types `character` on a US ANSI layout, and whether that needs Shift. Text that
    /// arrives without a physical key (software keyboard, key bar) is mapped through this so that
    /// modifiers encode exactly like the same chord on a hardware keyboard.
    public static func usLayout(_ character: Character) -> (key: PhysicalKey, shift: Bool, unshifted: Character)? {
        guard let entry = usLayoutTable[character], let key = byHIDUsage[entry.usage] else { return nil }
        return (Self(key), entry.shift, entry.unshifted)
    }

    /// The printable keys of a US ANSI keyboard, by the character they type.
    private static let usLayoutTable: [Character: (usage: UInt32, shift: Bool, unshifted: Character)] = {
        var table: [Character: (usage: UInt32, shift: Bool, unshifted: Character)] = [" ": (0x2C, false, " ")]
        let rows: [(usage: UInt32, plain: String, shifted: String)] = [
            (0x04, "abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
            (0x1E, "1234567890", "!@#$%^&*()"),
            (0x2D, "-=[]\\", "_+{}|"),
            (0x33, ";'`,./", ":\"~<>?"),
        ]
        for row in rows {
            for (offset, (plain, shifted)) in zip(row.plain, row.shifted).enumerated() {
                let usage = row.usage + UInt32(offset)
                table[plain] = (usage, false, plain)
                table[shifted] = (usage, true, plain)
            }
        }
        return table
    }()

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

    /// A press of a key that produces no text (arrows, Esc, Enter, ...).
    public static func press(_ key: PhysicalKey, mods: KeyModifiers = []) -> KeyEvent {
        KeyEvent(key: key, action: .press, mods: mods, text: "", unshiftedCodepoint: 0)
    }

    /// A press that types `text` with `mods` held, for input that has no physical key (software
    /// keyboard, key bar). A single character maps to its US-layout key, so chords encode like
    /// their hardware equivalents (Ctrl+c → 0x03, kitty CSI u). Anything else (IME commits, emoji,
    /// swipe-typed words) is sent as text on an unidentified key.
    public static func typing(_ text: String, mods: KeyModifiers = []) -> KeyEvent {
        guard text.count == 1, let character = text.first, let (key, shift, unshifted) = PhysicalKey.usLayout(character) else {
            return KeyEvent(key: .unidentified, action: .press, mods: mods, text: text, unshiftedCodepoint: 0)
        }
        let mods = shift ? mods.union(.shift) : mods
        // As from a hardware keyboard: Ctrl chords carry no text (the encoder derives the control
        // byte from the key), and Shift is consumed by the character it produced.
        let carriesText = !mods.contains(.control)
        return KeyEvent(
            key: key, action: .press, mods: mods,
            consumedMods: carriesText && shift ? .shift : [],
            text: carriesText ? text : "",
            unshiftedCodepoint: unshifted.unicodeScalars.first!.value)
    }
}
