import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public extension Color {
    /// `#RRGGBB` or `RRGGBB`; anything else is magenta so a typo is impossible to miss.
    nonisolated init(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = Color(red: 1, green: 0, blue: 1)
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// A color that follows the light/dark appearance of whatever draws it.
    nonisolated init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
        #endif
    }
}

public extension DS {
    /// Chrome colours. Every one resolves from the window's `ChromePalette` (the active terminal
    /// under Solarized and Dracula's under Dracula. Chrome is otherwise monochrome: hue is for
    /// is for state").
    nonisolated enum Palette {
        /// The theme's accent: its cursor colour when that is a real colour, else its bright blue
        /// (or the bright magenta or cyan farthest from background and foreground). Ghostty's
        /// default theme gives #7AA6DA. Focus, selection and the single primary action only.
        public static let accent = ChromeStyle(.accent)
        /// A solid selection (the palette's selected row): the accent deepened until
        /// `onSelection` text reads on it at 4.5:1.
        public static let selection = ChromeStyle(.selection)
        public static let onSelection = ChromeStyle(.onSelection)

        /// Your turn: an agent waiting for input, a slow or reconnecting link (the theme's
        public static let attention = ChromeStyle(.attention)
        /// Agent working (the theme's magenta). In rows a working agent is a neutral spinner.
        public static let working = ChromeStyle(.working)
        /// Agent blocked / needs you.
        public static let blocked = attention
        /// Done, git added, connected (the theme's green).
        public static let done = ChromeStyle(.done)
        /// Failed, git deleted, unreachable (the theme's red).
        public static let error = ChromeStyle(.error)
        /// Informational (the theme's blue).
        public static let info = ChromeStyle(.info)

        /// Ghostty's bell border: #FFCC00 at 50 %.
        public static let bell = Color(red: 1, green: 0.8, blue: 0).opacity(0.5)

        /// Text: the theme's foreground at 90 / 60 / 40 / 20 %. Window and sheet roots set the
        /// first three as the hierarchical styles, so `.primary`, `.secondary` and `.tertiary`
        /// resolve to them as well.
        public static let text = ChromeStyle(.text)
        public static let textSecondary = ChromeStyle(.textSecondary)
        public static let textTertiary = ChromeStyle(.textTertiary)
        public static let textQuaternary = ChromeStyle(.textQuaternary)

        /// control-hover 5 %).
        public static let hoverFill = ChromeStyle(.hoverFill)
        public static let selectedFill = ChromeStyle(.selectedFill)
        public static let pressedFill = ChromeStyle(.pressedFill)

        /// Lines: the foreground at 10 / 15 / 20 %.
        public static let hairline = ChromeStyle(.hairline)
        public static let separator = ChromeStyle(.separator)
        public static let border = ChromeStyle(.border)

        /// Opaque surfaces: the window base (the terminal's background), the sidebar (fg 5 %),
        /// cards and popovers (10 %), menus (15 %), grouped lists' page and rows, and the
        /// terminal grid itself.
        public static let base = ChromeStyle(.base)
        public static let sidebar = ChromeStyle(.sidebar)
        public static let raised = ChromeStyle(.raised)
        public static let overlay = ChromeStyle(.overlay)
        public static let groupedPage = ChromeStyle(.groupedPage)
        public static let groupedRow = ChromeStyle(.groupedRow)
        public static let terminal = ChromeStyle(.terminal)
        /// The foreground at full strength, for a one-off opacity (prefer the named levels).
        public static let ink = ChromeStyle(.ink)
        /// The theme's ANSI colour `index` (0…15), as the terminal draws it.
        public static func ansi(_ index: Int) -> ChromeStyle { ChromeStyle(.ansi(index)) }
    }
}

/// A chrome colour by name, resolved from the environment's `ChromePalette` when drawn. Usable
/// wherever a `ShapeStyle` is (`foregroundStyle`, `fill`, `background`, `tint`, `opacity`), with
/// no `@Environment` at the call site.
nonisolated public struct ChromeStyle: ShapeStyle, Hashable, Sendable {
    public enum Token: Hashable, Sendable {
        case accent, selection, onSelection
        case done, error, attention, working, info
        case text, textSecondary, textTertiary, textQuaternary
        case hoverFill, selectedFill, pressedFill
        case hairline, separator, border
        case base, sidebar, raised, overlay, groupedPage, groupedRow, terminal
        /// The ink itself (the foreground at full strength), for one-off opacities.
        case ink
        /// One of the theme's 16 ANSI colours as the terminal draws it (presence hues, previews).
        case ansi(Int)
    }

    public let token: Token

    public init(_ token: Token) {
        self.token = token
    }

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        if case .ansi(let index) = token { return environment.terminalTheme.ansiRGB(index).color.resolve(in: environment) }
        return environment.chrome.color(token).resolve(in: environment)
    }
}

nonisolated public extension ChromePalette {
    /// The colour for a token.
    func color(_ token: ChromeStyle.Token) -> Color {
        switch token {
        case .accent: accentColor
        case .selection: selectionColor
        case .onSelection: onSelectionColor
        case .done: done.color
        case .error: error.color
        case .attention: attention.color
        case .working: working.color
        case .info: info.color
        case .text: text
        case .textSecondary: textSecondary
        case .textTertiary: textTertiary
        case .textQuaternary: textQuaternary
        case .hoverFill: hoverFill
        case .selectedFill: selectedFill
        case .pressedFill: pressedFill
        case .hairline: hairline
        case .separator: separator
        case .border: border
        case .base: baseColor
        case .sidebar: sidebarColor
        case .raised: raisedColor
        case .overlay: overlayColor
        case .groupedPage: groupedPageColor
        case .groupedRow: groupedRowColor
        case .terminal: terminalColor
        case .ink: foreground.color
        case .ansi: foreground.color
        }
    }
}
