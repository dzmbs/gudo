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
        /// Labels and glyphs on a solid accent: the theme's cursor text where it reads (4.5:1).
        public static let onAccent = ChromeStyle(.onAccent)
        /// The accent at the container strength: a pressed accent control, a lit toggle, a drop target.
        public static let accentDim = ChromeStyle(.accentDim)
        /// The accent's soft focus halo, outside a solid accent edge.
        public static let accentRing = ChromeStyle(.accentRing)

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

        /// Signals over the surface under them, at one strength (`ChromePalette.containerLevel`):
        /// status chips, a glyph's disc. The signal itself reads on its container at 4.5:1.
        public static let doneContainer = ChromeStyle(.container(.done))
        public static let errorContainer = ChromeStyle(.container(.error))
        public static let attentionContainer = ChromeStyle(.container(.attention))
        public static let workingContainer = ChromeStyle(.container(.working))
        public static let infoContainer = ChromeStyle(.container(.info))
        /// Any signal's container, for a colour chosen at run time (a project's, a state's).
        public static func container(_ style: ChromeStyle) -> ChromeStyle { ChromeStyle(.container(style.token)) }
        /// The label on a solid fill of `style`: the theme's cursor text, background or ink, the
        /// first that reads at 4.5:1.
        public static func on(_ style: ChromeStyle) -> ChromeStyle { ChromeStyle(.on(style.token)) }

        /// The bell's border: the theme's attention hue at half strength.
        public static let bell = ChromeStyle(.bell)
        /// A scrollbar at rest, and while scrolling or under the pointer (≥ 3:1).
        public static let scrollbar = ChromeStyle(.scrollbar)
        public static let scrollbarActive = ChromeStyle(.scrollbarActive)
        /// The light edge on floating glass and lifted panes.
        public static let edge = ChromeStyle(.edge)
        /// The dim behind a modal panel (the palette).
        public static let scrim = ChromeStyle(.scrim)
        /// The terminal's background laid over a pane it covers (a saved screen, a pane being moved).
        public static let veil = ChromeStyle(.veil)

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
        case onAccent, accentDim, accentRing
        case bell, scrollbar, scrollbarActive, edge, scrim, veil
        indirect case container(Token)
        indirect case on(Token)
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
        return environment.chrome.layer(token, theme: environment.terminalTheme).swiftUIColor.resolve(in: environment)
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
        case .scrollbar: .scrollbarActive
        default: self
        }
    }
}

/// A token as drawn: a colour and how strongly it lays over whatever is under it.
nonisolated public struct ChromeLayer: Hashable, Sendable {
    public let color: ThemeColor
    public let alpha: Double

    public init(_ color: ThemeColor, _ alpha: Double = 1) {
        self.color = color
        self.alpha = alpha
    }

    public func composited(over surface: ThemeColor) -> ThemeColor { surface.blended(with: color, alpha) }

    public var swiftUIColor: Color { alpha >= 1 ? color.color : color.color.opacity(alpha) }
}

nonisolated public extension ChromePalette {
    func color(_ token: ChromeStyle.Token) -> Color { layer(token).swiftUIColor }

    /// The token as drawn; `theme` resolves the ANSI and project colours (the foreground without it).
    func layer(_ token: ChromeStyle.Token, theme: TerminalTheme? = nil) -> ChromeLayer {
        switch token {
        case .onAccent: ChromeLayer(onAccent)
        case .accentDim: ChromeLayer(accent, Self.containerLevel)
        case .accentRing: ChromeLayer(accent, Self.ringLevel)
        case .bell: ChromeLayer(attention, Self.bellLevel)
        case .scrollbar: ChromeLayer(foreground, Self.scrollbarLevel)
        case .scrollbarActive: ChromeLayer(foreground, tertiaryLevel)
        case .edge: ChromeLayer(foreground, scheme == .dark ? Self.edgeLevels.dark : Self.edgeLevels.light)
        case .scrim: ChromeLayer(scrimColor, scheme == .dark ? Self.scrimLevels.dark : Self.scrimLevels.light)
        case .veil: ChromeLayer(terminal, Self.veilLevel)
        case .container(let signal): ChromeLayer(layer(signal, theme: theme).color, Self.containerLevel)
        case .on(let fill): ChromeLayer(label(on: layer(fill, theme: theme).composited(over: base)))
        case .accent: ChromeLayer(accent)
        case .selection: ChromeLayer(accent, selectionLevel)
        case .onSelection: ChromeLayer(foreground, Self.textLevels.primary)
        case .prominent: ChromeLayer(prominent)
        case .onProminent: ChromeLayer(onProminent)
        case .done: ChromeLayer(done)
        case .error: ChromeLayer(error)
        case .attention: ChromeLayer(attention)
        case .working: ChromeLayer(working)
        case .info: ChromeLayer(info)
        case .text: ChromeLayer(foreground, Self.textLevels.primary)
        case .textSecondary: ChromeLayer(foreground, secondaryLevel)
        case .textTertiary: ChromeLayer(foreground, tertiaryLevel)
        case .textQuaternary: ChromeLayer(foreground, Self.textLevels.quaternary)
        case .hoverFill: ChromeLayer(foreground, Self.fillLevels.hover)
        case .selectedFill: ChromeLayer(foreground, Self.fillLevels.selected)
        case .pressedFill: ChromeLayer(foreground, Self.fillLevels.pressed)
        case .hairline: ChromeLayer(foreground, Self.lineLevels.hairline)
        case .separator: ChromeLayer(foreground, Self.lineLevels.separator)
        case .border: ChromeLayer(foreground, Self.lineLevels.border)
        case .base: ChromeLayer(base)
        case .sidebar: ChromeLayer(sidebar)
        case .raised: ChromeLayer(raised)
        case .overlay: ChromeLayer(overlay)
        case .groupedPage: ChromeLayer(groupedPage)
        case .groupedRow: ChromeLayer(groupedRow)
        case .terminal: ChromeLayer(terminal)
        case .ansi(let index): ChromeLayer(theme?.ansiRGB(index) ?? foreground)
        case .project(let index): ChromeLayer(theme.map { ProjectColor.color(index, theme: $0, chrome: self) } ?? foreground)
        case .ink: ChromeLayer(foreground)
        }
    }
}
