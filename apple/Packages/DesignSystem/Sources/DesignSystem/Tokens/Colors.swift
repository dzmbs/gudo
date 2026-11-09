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
    /// theme) when it is drawn: `DS.Palette.done` is Solarized's green under Solarized and
    /// Dracula's under Dracula. Chrome is otherwise monochrome: hue is for state, the accent for
    /// focus, selection and the one primary action.
    nonisolated enum Palette {
        /// The theme's cursor colour when that is a real colour, else its bright blue (or the
        /// bright magenta or cyan farthest from background and foreground).
        public static let accent = ChromeStyle(.accent)
        /// The accent as a soft tint under normal text (`onSelection`, ≥ 4.5:1).
        public static let selection = ChromeStyle(.selection)
        public static let onSelection = ChromeStyle(.onSelection)
        /// The accent deepened until `onProminent` reads on it at 4.5:1.
        public static let prominent = ChromeStyle(.prominent)
        public static let onProminent = ChromeStyle(.onProminent)

        /// Your turn: an agent waiting for input, a slow or reconnecting link (the theme's
        /// yellow). Amber, not red: red means broken.
        public static let attention = ChromeStyle(.attention)
        /// The theme's magenta. In rows a working agent is a neutral spinner.
        public static let working = ChromeStyle(.working)
        public static let blocked = attention
        /// Done, git added, connected (the theme's green).
        public static let done = ChromeStyle(.done)
        /// Failed, git deleted, unreachable (the theme's red).
        public static let error = ChromeStyle(.error)
        public static let info = ChromeStyle(.info)

        public static let bell = Color(red: 1, green: 0.8, blue: 0).opacity(0.5)

        /// Text: the theme's foreground at 90 / 60 / 40 / 20 %. Window and sheet roots set the
        /// first three as the hierarchical styles, so `.primary`, `.secondary` and `.tertiary`
        /// resolve to them as well.
        public static let text = ChromeStyle(.text)
        public static let textSecondary = ChromeStyle(.textSecondary)
        public static let textTertiary = ChromeStyle(.textTertiary)
        public static let textQuaternary = ChromeStyle(.textQuaternary)

        /// Row hover / selected / pressed fills: the foreground at 5 / 10 / 15 %.
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
        case accent, selection, onSelection, prominent, onProminent
        case done, error, attention, working, info
        case text, textSecondary, textTertiary, textQuaternary
        case hoverFill, selectedFill, pressedFill
        case hairline, separator, border
        case base, sidebar, raised, overlay, groupedPage, groupedRow, terminal
        case ink
        case ansi(Int)
        case project(Int)
    }

    public let token: Token

    public init(_ token: Token) {
        self.token = token
    }

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let token = environment.colorSchemeContrast == .increased ? token.increasedContrast : token
        if case .ansi(let index) = token { return environment.terminalTheme.ansiRGB(index).color.resolve(in: environment) }
        if case .project(let index) = token {
            return ProjectColor.color(index, theme: environment.terminalTheme, chrome: environment.chrome).color.resolve(in: environment)
        }
        return environment.chrome.color(token).resolve(in: environment)
    }
}

nonisolated public extension ChromeStyle.Token {
    /// The token drawn under Increase Contrast: secondary text as main text, tertiary as
    /// secondary, hairlines and separators as borders.
    var increasedContrast: Self {
        switch self {
        case .textSecondary: .text
        case .textTertiary: .textSecondary
        case .hairline, .separator: .border
        default: self
        }
    }
}

nonisolated public extension ChromePalette {
    func color(_ token: ChromeStyle.Token) -> Color {
        switch token {
        case .accent: accentColor
        case .selection: selectionColor
        case .onSelection: onSelectionColor
        case .prominent: prominentColor
        case .onProminent: onProminentColor
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
        case .ansi, .project: foreground.color
        }
    }
}
