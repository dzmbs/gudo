import Foundation
import SwiftUI

/// A terminal color theme in Ghostty's theme-file vocabulary (`background`, `foreground`,
/// `cursor-color`, `cursor-text`, `selection-*`, `palette = 0..15`).
nonisolated public struct TerminalTheme: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var bg: String
    public var fg: String
    public var cursor: String?
    public var cursorText: String?
    public var selBg: String?
    public var selFg: String?
    /// The 16 ANSI colors as `#rrggbb`.
    public var palette: [String]

    public var id: String { name }

    public nonisolated init(
        name: String, bg: String, fg: String, cursor: String? = nil, cursorText: String? = nil,
        selBg: String? = nil, selFg: String? = nil, palette: [String]
    ) {
        self.name = name
        self.bg = bg
        self.fg = fg
        self.cursor = cursor
        self.cursorText = cursorText
        self.selBg = selBg
        self.selFg = selFg
        self.palette = palette
    }

    /// Ghostty's built-in default: background #282C34, foreground #FFFFFF and the palette in
    /// src/terminal/color.zig `Name.default` (the Tomorrow Night family).
    public nonisolated static let ghosttyDefault = TerminalTheme(
        name: "Ghostty Default", bg: "#282c34", fg: "#ffffff",
        palette: [
            "#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
            "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
        ])

    public var background: Color { Color(hex: bg) }
    public var foreground: Color { Color(hex: fg) }
    public var cursorColor: Color { cursor.map(Color.init(hex:)) ?? foreground }
    public func ansi(_ index: Int) -> Color { Color(hex: palette[index]) }

    /// Relative luminance of the background, for Ghostty's `window-theme = auto`.
    public nonisolated var isLight: Bool {
        let digits = bg.dropFirst()
        guard let value = UInt32(digits, radix: 16) else { return false }
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0) > 0.5
    }

    /// Ghostty's default `split-divider-color`: the background darkened by 40 % (dark backgrounds)
    /// or 8 % (light) in HSB brightness (Ghostty.Config.swift `splitDividerColor`).
    public var splitDivider: Color { scaled(isLight ? 0.92 : 0.6) }

    /// The sidebar: the terminal background a step darker (dark themes) or lighter-grey (light),
    public var sidebarBackground: Color { scaled(isLight ? 0.955 : 0.82) }

    /// The window chrome's light/dark, from the terminal background (Ghostty `window-theme = auto`).
    public nonisolated var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// The background with its HSB brightness scaled (all channels scaled: hue and saturation kept).
    public func scaled(_ factor: Double) -> Color {
        let digits = bg.dropFirst()
        let value = UInt32(digits, radix: 16) ?? 0
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        return Color(.sRGB, red: r * factor, green: g * factor, blue: b * factor)
    }
}

/// The themes Ghostty bundles (iTerm2-Color-Schemes, MIT), converted to one JSON file by
/// docs/DESIGN.md "Themes".
nonisolated public enum ThemeCatalog {
    public nonisolated static let all: [TerminalTheme] = {
        guard let url = Bundle.module.url(forResource: "ghostty-themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let themes = try? JSONDecoder().decode([TerminalTheme].self, from: data)
        else { return [] }
        return themes
    }()

    public nonisolated static func theme(named name: String) -> TerminalTheme {
        all.first { $0.name == name } ?? .ghosttyDefault
    }
}

// MARK: - Environment

public extension EnvironmentValues {
    /// The active terminal theme; chrome that touches the terminal (padding, dividers, dimming,
    /// the compact top bar) paints with its background so the terminal edge never shows a seam.
    @Entry var terminalTheme: TerminalTheme = .ghosttyDefault
}
