import DesignSystem
import Foundation
import TerminalCore
import TerminalRenderer

extension TerminalAppearance {
    /// The renderer's appearance from the user's settings (Ghostty names and defaults, see
    /// `TerminalPreferences`), plus `window-padding-balance` so the grid never hugs a pane edge.
    static func fromPreferences(_ defaults: UserDefaults = .standard) -> TerminalAppearance {
        typealias Key = TerminalPreferences.Key
        let theme = ThemeCatalog.theme(named: defaults.string(forKey: Key.theme) ?? TerminalPreferences.Default.theme)
        var appearance = TerminalAppearance()
        if let size = defaults.object(forKey: Key.fontSize) as? Double { appearance.fontSize = size }
        appearance.paddingBalance = true
        if let opacity = defaults.object(forKey: Key.unfocusedSplitOpacity) as? Double { appearance.unfocusedSplitOpacity = opacity }
        if let blink = defaults.object(forKey: Key.cursorBlink) as? Bool { appearance.cursorBlink = blink }
        switch TerminalPreferences.CursorStyle(rawValue: defaults.string(forKey: Key.cursorStyle) ?? "") {
        case .bar: appearance.cursorStyle = .bar
        case .underline: appearance.cursorStyle = .underline
        case .blockHollow: appearance.cursorStyle = .blockHollow
        case .block, nil: appearance.cursorStyle = .block
        }
        // The default theme is the renderer's own default; anything else replaces the colors.
        guard theme != .ghosttyDefault else { return appearance }
        appearance.background = RGB(hex: theme.bg)
        appearance.foreground = RGB(hex: theme.fg)
        appearance.cursorColor = theme.cursor.map(RGB.init(hex:))
        appearance.selectionBackground = theme.selBg.map(RGB.init(hex:))
        appearance.selectionForeground = theme.selFg.map(RGB.init(hex:))
        appearance.palette = RGB.palette(ansi: theme.palette.map(RGB.init(hex:)))
        return appearance
    }
}

extension RGB {
    init(hex: String) {
        let value = UInt32(hex.dropFirst(hex.hasPrefix("#") ? 1 : 0), radix: 16) ?? 0
        self.init(r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }

    /// A theme's 16 colors followed by xterm's 6×6×6 cube and gray ramp, as Ghostty builds the
    /// rest of the 256-color palette (src/terminal/color.zig).
    static func palette(ansi: [RGB]) -> [RGB] {
        var result = ansi
        let level: (Int) -> UInt8 = { $0 == 0 ? 0 : UInt8($0 * 40 + 55) }
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 { result.append(RGB(r: level(r), g: level(g), b: level(b))) } } }
        for i in 0..<24 {
            let gray = UInt8(8 + i * 10)
            result.append(RGB(r: gray, g: gray, b: gray))
        }
        return result
    }
}
