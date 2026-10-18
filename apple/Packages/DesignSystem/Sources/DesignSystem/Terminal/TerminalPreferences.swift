import Foundation

/// User-facing terminal settings, named after the Ghostty config keys they mirror so a Ghostty
/// user can find them (the settings screen shows the key under each control). Stored in
/// `UserDefaults` under `Key`; the renderer reads them through the app.
nonisolated public enum TerminalPreferences {
    public enum Key {
        public static let theme = "theme"
        public static let fontSize = "font-size"
        public static let cursorStyle = "cursor-style"
        public static let cursorBlink = "cursor-style-blink"
        public static let optionAsAlt = "macos-option-as-alt"
        public static let unfocusedSplitOpacity = "unfocused-split-opacity"
        public static let resizeOverlay = "resize-overlay"
        public static let windowTheme = "window-theme"
        public static let copyOnSelect = "copy-on-select"
        public static let bellFeatures = "bell-features"
        public static let keyBarWithHardwareKeyboard = "key-bar-with-hardware-keyboard"
        public static let paneStyle = "pane-style"
    }

    /// Ghostty defaults (src/config/Config.zig).
    public enum Default {
        public static let theme = TerminalTheme.ghosttyDefault.name
        public static let fontSize: Double = 13
        public static let unfocusedSplitOpacity: Double = 0.7
        public static let fontFamily = "JetBrains Mono"
    }

    public enum CursorStyle: String, CaseIterable, Identifiable, Sendable {
        case block, bar, underline, blockHollow = "block_hollow"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .block: "Block"
            case .bar: "Bar"
            case .underline: "Underline"
            case .blockHollow: "Hollow Block"
            }
        }
    }

    public enum OptionAsAlt: String, CaseIterable, Identifiable, Sendable {
        case off = "false", both = "true", left, right
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .off: "Off"
            case .both: "Both Keys"
            case .left: "Left Key"
            case .right: "Right Key"
            }
        }
    }

    /// Ghostty `window-theme`; `system` is the default here (Ghostty's is `auto`).
    public enum WindowTheme: String, CaseIterable, Identifiable, Sendable {
        case system, auto, light, dark
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: "System"
            case .auto: "Match Terminal"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    public enum ResizeOverlay: String, CaseIterable, Identifiable, Sendable {
        case afterFirst = "after-first", always, never
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .afterFirst: "After First Resize"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    /// rounded panes with gaps.
    public enum PaneStyle: String, CaseIterable, Identifiable, Sendable {
        case compact, comfortable
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .compact: "Compact"
            case .comfortable: "Comfortable"
            }
        }
    }
}
