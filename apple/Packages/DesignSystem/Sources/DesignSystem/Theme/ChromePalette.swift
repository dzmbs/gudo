import SwiftUI

/// Every chrome colour, derived from the active terminal theme.
///
/// A theme gives four inputs: background, foreground, an accent and its 16 ANSI colours. Every
/// surface is the foreground laid over the background at a few fixed strengths, so a light theme
/// gets darker panels and a dark theme lighter ones with one rule; text is the foreground at four
/// strengths; state colours are the theme's own ANSI hues softened toward the foreground. The
/// result: Solarized chrome is Solarized, Dracula's is Dracula, and no grey from the system sits
/// on a tinted ground.
nonisolated public struct ChromePalette: Hashable, Sendable {
    /// The window's chrome scheme (`window-theme`), which is the theme's own unless the user
    /// forced the other one.
    public let scheme: ColorScheme
    public let terminal: ThemeColor
    /// The chrome's background: the theme's background, or a neutral one when the user forced the
    /// other scheme (a dark theme in a light window). The tab strip and toolbar band sit on it.
    public let background: ThemeColor
    /// The ink every surface, fill and text level is mixed from: the theme's foreground, pushed
    /// toward white or black only as far as text needs to stay readable (≥ 4.5:1, secondary text
    /// included).
    public let foreground: ThemeColor
    /// Focus, selection and the one primary action: the theme's hue, its chroma and lightness
    /// tamed (`refined`) so a raw ANSI blue never lands in the chrome.
    public let accent: ThemeColor
    /// The selected row in lists and the palette: the accent as a soft tint (`selectionLevel`)
    /// under normal text. `selection` is that tint composited on the raised surface, for
    /// contrast checks; `onSelection` is the text on it, ≥ 4.5:1.
    public let selection: ThemeColor
    public let onSelection: ThemeColor
    public let selectionLevel: Double
    /// A solid fill for the one primary action and the label on it, ≥ 4.5:1.
    public let prominent: ThemeColor
    public let onProminent: ThemeColor
    /// Labels and glyphs on a solid accent fill: the theme's own cursor text where it reads on
    /// the accent at 4.5:1, else the nearest ink that does (`label(on:)`).
    public let onAccent: ThemeColor
    /// The theme's `cursor-text`, the label it pairs with its accent.
    public let cursorText: ThemeColor?
    /// State hues: the theme's ANSI green, red, yellow, magenta and blue, mixed toward the
    /// foreground so they sit in the chrome, each ≥ 4.5:1 on every surface: they are words too
    /// ("Can't reach", an error under a form).
    public let done: ThemeColor
    public let error: ThemeColor
    public let attention: ThemeColor
    public let working: ThemeColor
    public let info: ThemeColor
    /// A tab that called for you, as a dot: the theme's own amber, unsoftened, moved only as far as
    /// it needs to stand off every row it sits on at 3:1.
    public let attentionMark: ThemeColor
    /// The secondary and tertiary text strengths: 60 % and 40 %, raised (up to a cap that keeps
    /// them below the level above) where a mid-tone ink would leave them unreadable, as on most
    /// light themes: secondary toward 4.5:1, tertiary toward 3:1.
    public let secondaryLevel: Double
    public let tertiaryLevel: Double
    /// How strongly a program's symbol draws in the style it inherits: `markStrength`, raised
    /// where the mark in secondary text (an unfocused pane header) would fall below 3:1.
    public let markOpacity: Double
    /// How a chip of a tab not selected dims (`DS.Opacity.inactive`), raised where its title
    /// would fall below 4.5:1 on the strip.
    public let inactiveOpacity: Double
    /// How the rows and chips of a host that is away dim (`DS.Opacity.away`), raised where their
    /// titles would fall below 4.5:1.
    public let awayOpacity: Double

    // MARK: Strengths

    /// Panels and surfaces: the foreground over the background at 5 / 10 / 15 %.
    public static let sidebarStrength = 0.05
    public static let raisedStrength = 0.10
    public static let overlayStrength = 0.15
    /// Text: main / secondary / tertiary / disabled.
    public static let textLevels = (primary: 0.90, secondary: 0.60, tertiary: 0.40, quaternary: 0.20)
    /// The most secondary and tertiary text are raised to for contrast.
    public static let levelCaps = (secondary: 0.78, tertiary: 0.62)
    /// A program's symbol dims the style it inherits, so it sits no heavier than the words beside it.
    public static let markStrength = 0.6
    /// Hover a third of selection, so a row under the pointer never reads as a second selection.
    public static let fillLevels = (hover: 0.04, selected: 0.12, pressed: 0.16)
    public static let lineLevels = (hairline: 0.10, separator: 0.15, border: 0.20)
    /// How far a state hue is mixed toward the foreground. At 50 % a dark theme's amber "needs
    /// you" is a cream barely apart from the text beside it (#F0C674 becomes #F8E3BA), so states
    /// keep two thirds of their hue: softened into the chrome, still a colour at a glance.
    public static let stateMix = 0.35
    /// The soft selection's accent strength (light / dark chrome): a tint, never a block of colour.
    public static let selectionLevels = (light: 0.14, dark: 0.24)
    /// The accent's OKLCH chroma ceiling and lightness band (light / dark chrome): saturated
    /// terminal blues (#0000FF, #2F5AF3) come down to a calm, still clearly blue tone.
    public static let accentChroma = 0.13
    public static let accentLightness = (light: 0.48...0.62, dark: 0.68...0.86)
    /// A signal over the surface under it: status chips, a glyph's disc, a drop target, the
    /// accent's dim fill (`accentDim`). One strength for every hue so chips read as one family.
    /// 12 % is the weakest tint that stands apart from its surface (1.2:1 on average); the signal
    /// on it moves only a little to keep 4.5:1 (`ThemeStressTests.containerStrength`).
    public static let containerLevel = 0.12
    /// The accent's focus halo outside a control's solid accent edge.
    public static let ringLevel = 0.25
    /// A scrollbar at rest; while scrolled or under the pointer it is the tertiary ink (≥ 3:1).
    public static let scrollbarLevel = 0.25
    /// A surface's inner edge (light / dark chrome).
    public static let edgeLevels = (light: 0.08, dark: 0.16)
    /// The line just outside a surface, in the scrim's darker ink (light / dark chrome).
    public static let outlineLevels = (light: 0.10, dark: 0.5)
    /// The light along a surface's top edge: white on light chrome, a bevel that shows only on a
    /// surface darker than its paper; the lighter ink on dark, added to what is under it.
    public static let topLightLevels = (light: 0.6, dark: 0.14)
    /// The dim behind a modal panel (light / dark chrome).
    public static let scrimLevels = (light: 0.10, dark: 0.28)
    /// The terminal's own background over a pane it covers: a saved screen, a pane being moved,
    /// one shielded while sketching. The pane still shows through.
    public static let veilLevel = 0.4
    /// The terminal's own background over a screen waiting for its host (saved, or its helper
    /// starting): marked, yet read at nearly full contrast.
    public static let waitingLevel = 0.12
    /// The bell's border: the theme's attention hue at half strength.
    public static let bellLevel = 0.5
    /// Minimum contrasts: text (WCAG AA), glyphs and the accent (WCAG non-text).
    public static let minimumTextContrast = 4.5
    public static let minimumGlyphContrast = 3.0

    // MARK: Surfaces (opaque)

    /// One surface with the terminal.
    public var base: ThemeColor { background }
    public var sidebar: ThemeColor { background.blended(with: foreground, Self.sidebarStrength) }
    /// Cards, popovers, the palette's fill under glass.
    public var raised: ThemeColor { background.blended(with: foreground, Self.raisedStrength) }
    /// Menus and anything on top of a raised surface.
    public var overlay: ThemeColor { background.blended(with: foreground, Self.overlayStrength) }
    /// The page under grouped lists and forms, and the rows on it. Dark: rows lift off the page
    /// (fg 10 % on the background). Light: the iOS convention, the page a step darker and rows
    /// on the background itself.
    public var groupedPage: ThemeColor { scheme == .light ? sidebar : background }
    public var groupedRow: ThemeColor { scheme == .light ? background : raised }

    /// Every opaque surface text and glyphs may sit on.
    public var surfaces: [ThemeColor] { [base, sidebar, raised, overlay, groupedPage, groupedRow] }

    /// The main text level composited over `surface` (what the eye sees).
    public func text(on surface: ThemeColor) -> ThemeColor { surface.blended(with: foreground, Self.textLevels.primary) }

    // MARK: Init

    /// `scheme` is the window's scheme when the user forced one (Light/Dark, or System differing
    /// from the theme); nil or the theme's own gives the theme's chrome.
    public init(theme: TerminalTheme, scheme requested: ColorScheme? = nil) {
        let cursorText = theme.cursorText.flatMap(ThemeColor.init(hex:))
        self.cursorText = cursorText
        let themeScheme: ColorScheme = theme.isLight ? .light : .dark
        let scheme = requested ?? themeScheme
        let themeBackground = theme.bgRGB, themeForeground = theme.fgRGB
        var background: ThemeColor, ink: ThemeColor
        if scheme == themeScheme {
            background = themeBackground
            ink = themeForeground
        } else if scheme == .light {
            // A dark theme in a light window: near-white with a whisper of the theme, its
            // background as the ink.
            background = ThemeColor.white.blended(with: themeBackground, 0.03)
            ink = themeBackground
        } else {
            // A light theme in a dark window: near-black tinted with the theme's paper (its ink is
            // often black itself, which would leave a flat black window).
            background = ThemeColor.black.blended(with: themeBackground, 0.12)
            ink = themeBackground
        }
        // A garish mid-tone background cannot carry readable text even in white: only then does
        // the chrome's background step away from the terminal's.
        let (chromeBackground, foreground) = Self.readable(ink: ink, background: background)
        background = chromeBackground
        self.scheme = scheme
        self.terminal = themeBackground
        self.background = background
        self.foreground = foreground

        let sidebar = background.blended(with: foreground, Self.sidebarStrength)
        let overlay = background.blended(with: foreground, Self.overlayStrength)

        let raised = background.blended(with: foreground, Self.raisedStrength)
        let refined = Self.refined(Self.accent(of: theme), scheme: scheme)
        // A glyph on the accent's own dim fill too, where hand-drawn controls sit (not on menus).
        let accent = Self.legible(
            Self.legible(refined, on: [background, sidebar, raised, overlay], minimum: Self.minimumGlyphContrast),
            on: [background, sidebar, raised], minimum: Self.minimumGlyphContrast, tints: [Self.containerLevel])
        self.accent = accent
        let (prominent, onProminent) = Self.prominent(accent: accent, background: background, foreground: foreground)
        self.prominent = prominent
        self.onProminent = onProminent
        self.onAccent = Self.label(on: accent, preferring: cursorText, background: background, foreground: foreground)
        let level = scheme == .light ? Self.selectionLevels.light : Self.selectionLevels.dark
        let selectionLevel = [background, sidebar, raised, overlay]
            .map { Self.selection(accent: accent, on: $0, text: foreground, level: level).0 }
            .min() ?? level
        let selection = raised.blended(with: accent, selectionLevel)
        self.selectionLevel = selectionLevel
        self.selection = selection
        self.onSelection = selection.blended(with: foreground, Self.textLevels.primary)

        let controlSurfaces = Self.controlStrengths.map { background.blended(with: foreground, $0) }
        let accentDims = [background, sidebar, raised].map { $0.blended(with: accent, Self.containerLevel) }
        let textSurfaces = controlSurfaces + [overlay] + accentDims
        secondaryLevel = Self.level(Self.textLevels.secondary, cap: Self.levelCaps.secondary, of: foreground, on: textSurfaces, minimum: Self.minimumTextContrast)
        tertiaryLevel = Self.level(Self.textLevels.tertiary, cap: Self.levelCaps.tertiary, of: foreground, on: textSurfaces, minimum: Self.minimumGlyphContrast)
        let markLevel = Self.level(Self.markStrength * secondaryLevel, cap: secondaryLevel, of: foreground, on: [background, sidebar], minimum: Self.minimumGlyphContrast)
        markOpacity = markLevel / secondaryLevel
        let primary = Self.textLevels.primary
        let hovered = background.blended(with: foreground, Self.fillLevels.hover)
        let rowSurfaces = [background, sidebar] + [background, sidebar].map { $0.blended(with: foreground, Self.fillLevels.selected) }
        inactiveOpacity = Self.level(
            primary * DS.Opacity.inactive, cap: Self.levelCaps.secondary, of: foreground, on: [background, hovered],
            minimum: Self.minimumTextContrast) / primary
        awayOpacity = Self.level(
            primary * DS.Opacity.away, cap: Self.levelCaps.secondary, of: foreground, on: rowSurfaces,
            minimum: Self.minimumTextContrast) / primary

        let stateSurfaces = [background, sidebar, raised, overlay]
        func state(_ signal: StateSignal) -> ThemeColor {
            Self.state(signal, of: theme, ink: foreground, on: stateSurfaces, tint: Self.containerLevel)
        }
        done = state(.done)
        error = state(.error)
        attention = state(.attention)
        working = state(.working)
        info = state(.info)
        attentionMark = Self.legible(Self.signalHue(.attention, of: theme), on: controlSurfaces, minimum: Self.minimumGlyphContrast)
    }

    public static let standard = ChromePalette(theme: .ghosttyDefault)

    // MARK: Derivation steps

    /// A state's ANSI slot and the hue it falls back to (Ghostty's default palette).
    enum StateSignal: CaseIterable {
        case done, error, attention, working, info

        var slot: (index: Int, reference: String) {
            switch self {
            case .done: (2, "#b5bd68")
            case .error: (1, "#cc6666")
            case .attention: (3, "#f0c674")
            case .working: (5, "#b294bb")
            case .info: (4, "#81a2be")
            }
        }
    }

    /// The theme's own colour for `signal`. A theme whose "green" is grey or not green (monochrome
    /// themes) keeps the meaning with the default hue.
    static func signalHue(_ signal: StateSignal, of theme: TerminalTheme) -> ThemeColor {
        let hue = theme.ansiRGB(signal.slot.index)
        let referenceHue = ThemeColor(hex: signal.slot.reference) ?? hue
        return hue.chroma < 12 || hueDistance(hue.hue, referenceHue.hue) > 60 ? referenceHue : hue
    }

    /// The theme's hue for `signal` softened toward the ink, then moved just far enough to read
    /// at 4.5:1 on every surface and, with a `tint`, on its own container over each.
    static func state(_ signal: StateSignal, of theme: TerminalTheme, ink: ThemeColor, on surfaces: [ThemeColor], tint: Double?) -> ThemeColor {
        let mixed = ink.blended(with: signalHue(signal, of: theme), 1 - stateMix)
        return legible(mixed, on: surfaces, minimum: minimumTextContrast, tints: tint.map { [$0] } ?? [])
    }

    /// The ink pushed toward white (dark chrome) or black (light chrome) until text at `level` (by
    /// default the strongest secondary text) reads at 4.5:1 on every surface mixed from it; if even
    /// white or black cannot, the background steps the other way until they do.
    static func readable(ink: ThemeColor, background: ThemeColor, level: Double = levelCaps.secondary) -> (background: ThemeColor, ink: ThemeColor) {
        let extreme: ThemeColor = background.contrast(with: .white) >= background.contrast(with: .black) ? .white : .black
        let opposite: ThemeColor = extreme == .white ? .black : .white
        func worst(_ ink: ThemeColor, _ background: ThemeColor) -> Double {
            (controlStrengths + [overlayStrength, (sidebarStrength + raisedStrength) / 2]).map { strength -> Double in
                let surface = background.blended(with: ink, strength)
                return surface.blended(with: ink, level).contrast(with: surface)
            }.min() ?? 0
        }
        var backgroundShift = 0.0
        while backgroundShift <= 1 {
            let candidateBackground = background.blended(with: opposite, backgroundShift)
            var inkShift = 0.0
            while inkShift <= 1 {
                let candidate = ink.blended(with: extreme, inkShift)
                if worst(candidate, candidateBackground) >= minimumTextContrast { return (candidateBackground, candidate) }
                inkShift += 0.02
            }
            backgroundShift += 0.05
        }
        return (opposite, extreme)
    }

    /// Every surface a hand-drawn control sits on (base, sidebar, raised) under each of its fills
    /// (rest, hover, selected, pressed), as one strength of the ink over the background. Menus
    /// (overlay) are the system's and carry no hand-drawn states.
    static let controlStrengths: [Double] = [0, sidebarStrength, raisedStrength].flatMap { surface in
        [0, fillLevels.hover, fillLevels.selected, fillLevels.pressed].map { fill in 1 - (1 - surface) * (1 - fill) }
    }

    /// The ink strength from `level` up to `cap` at which the ink reads at `minimum` on every
    /// surface (the cap when none does).
    static func level(_ level: Double, cap: Double, of ink: ThemeColor, on surfaces: [ThemeColor], minimum: Double) -> Double {
        var alpha = level
        while alpha < cap {
            if surfaces.allSatisfy({ $0.blended(with: ink, alpha).contrast(with: $0) >= minimum }) { return alpha }
            alpha += 0.02
        }
        return cap
    }

    /// The colour with its OKLab lightness moved away from the surfaces, hue kept and chroma
    /// eased only where sRGB runs out, just until it reaches `minimum` against every surface.
    /// `tints` are strengths at which the colour is also laid over each surface under itself (its
    /// container), where it must read as well.
    static func legible(_ color: ThemeColor, on surfaces: [ThemeColor], minimum: Double, tints: [Double] = []) -> ThemeColor {
        func readsOnEverySurface(_ candidate: ThemeColor) -> Bool {
            surfaces.allSatisfy { surface in
                ([surface] + tints.map { surface.blended(with: candidate, $0) }).allSatisfy { candidate.contrast(with: $0) >= minimum }
            }
        }
        guard !readsOnEverySurface(color) else { return color }
        let whiteContrast = surfaces.map { $0.contrast(with: .white) }.min() ?? 0
        let blackContrast = surfaces.map { $0.contrast(with: .black) }.min() ?? 0
        let extreme: ThemeColor = whiteContrast >= blackContrast ? .white : .black
        let lab = color.oklab, targetLightness = extreme.oklab.l
        var shift = 0.01
        while shift <= 1 {
            let lightness = lab.l + (targetLightness - lab.l) * shift
            let candidate = ThemeColor(oklabInGamut: (lightness, lab.a, lab.b))
            if readsOnEverySurface(candidate) { return candidate }
            shift += 0.01
        }
        return extreme
    }

    /// The cursor colour when it is a real colour distinct from the foreground; otherwise the
    /// bright blue, magenta or cyan farthest (CIEDE2000) from both background and foreground. Red,
    /// green and yellow are left out on purpose: they say failed, done and needs-you, and an
    /// accent must never read as a state.
    static func accent(of theme: TerminalTheme) -> ThemeColor {
        let background = theme.bgRGB, foreground = theme.fgRGB
        if let cursor = theme.cursorRGB, cursor.chroma >= 20, ThemeColor.deltaE2000(cursor, foreground) > 10,
           cursor.contrast(with: background) >= minimumGlyphContrast,
           !isStateHue(cursor, theme: theme)
        {
            return cursor
        }
        // Each hue slot is its bright colour, or its normal one where the bright is grey (Solarized's
        // bright blue is a grey; its blue is #268BD2).
        func slot(_ normal: Int) -> ThemeColor? {
            [normal + 8, normal].map(theme.ansiRGB).first { $0.chroma >= 10 }
        }
        func distance(_ color: ThemeColor) -> Double {
            ThemeColor.deltaE2000(color, background) + ThemeColor.deltaE2000(color, foreground)
        }
        // Blue first: the platform's selection colour, whenever it stands clear of both inks.
        if let blue = slot(4), !isStateHue(blue, theme: theme),
           ThemeColor.deltaE2000(blue, background) >= 20, ThemeColor.deltaE2000(blue, foreground) >= 10
        {
            return blue
        }
        let coloured = [4, 5, 6].compactMap(slot)
        let distinct = coloured.filter { !isStateHue($0, theme: theme) }
        let candidates = distinct.isEmpty ? coloured : distinct
        return candidates.max { distance($0) < distance($1) } ?? ThemeColor(hex: "#7aa6da")!
    }

    /// Whether a colour sits on the theme's red, green or yellow (within 25° of hue).
    static func isStateHue(_ color: ThemeColor, theme: TerminalTheme) -> Bool {
        [1, 2, 3, 9, 10, 11].map(theme.ansiRGB).contains { state in
            state.chroma >= 15 && hueDistance(state.hue, color.hue) < 25
        }
    }

    /// The accent with its chroma capped and its lightness kept in the scheme's band, hue intact.
    static func refined(_ color: ThemeColor, scheme: ColorScheme) -> ThemeColor {
        var (l, a, b) = color.oklab
        let chroma = (a * a + b * b).squareRoot()
        let band = scheme == .light ? accentLightness.light : accentLightness.dark
        guard chroma > accentChroma || !band.contains(l) else { return color }
        if chroma > accentChroma {
            a *= accentChroma / chroma
            b *= accentChroma / chroma
        }
        l = min(max(l, band.lowerBound), band.upperBound)
        return ThemeColor(oklab: (l, a, b))
    }

    /// The soft selection: the accent at `level` over `surface`, lowered until text reads on it at
    /// 4.5:1. Returns the level and the composited fill.
    static func selection(accent: ThemeColor, on surface: ThemeColor, text: ThemeColor, level: Double) -> (Double, ThemeColor) {
        var level = level
        while level > 0.04 {
            let fill = surface.blended(with: accent, level)
            if fill.blended(with: text, textLevels.primary).contrast(with: fill) >= minimumTextContrast { return (level, fill) }
            level -= 0.02
        }
        return (level, surface.blended(with: accent, level))
    }

    /// The label for a solid `fill`: `preferred` (the theme's cursor text) when it reads at 4.5:1,
    /// else the chrome's background or ink, else white or black (one of which always does).
    static func label(on fill: ThemeColor, preferring preferred: ThemeColor?, background: ThemeColor, foreground: ThemeColor) -> ThemeColor {
        let candidates = [preferred, background, foreground].compactMap { $0 }
        if let readable = candidates.first(where: { $0.contrast(with: fill) >= minimumTextContrast }) { return readable }
        return fill.contrast(with: .white) >= fill.contrast(with: .black) ? .white : .black
    }

    /// The label for a solid fill of any chrome colour (a swipe action's disc, a count badge).
    public func label(on fill: ThemeColor) -> ThemeColor {
        Self.label(on: fill, preferring: cursorText, background: background, foreground: foreground)
    }

    /// The colour behind a modal panel: the darker ink taken halfway to black, so it dims
    /// without greying a tinted theme.
    public var scrimColor: ThemeColor {
        let darker = background.luminance <= foreground.luminance ? background : foreground
        return darker.blended(with: .black, 0.5)
    }

    /// The lighter of the theme's background and foreground.
    var lighterInk: ThemeColor { background.luminance >= foreground.luminance ? background : foreground }

    /// A solid fill: the accent deepened toward the darker ink until the lighter ink reads on it
    /// at 4.5:1 (white-on-blue, the platform's prominent button, in both schemes).
    static func prominent(accent: ThemeColor, background: ThemeColor, foreground: ThemeColor) -> (fill: ThemeColor, text: ThemeColor) {
        let light = background.luminance >= foreground.luminance ? background : foreground
        let dark = background.luminance >= foreground.luminance ? foreground : background
        var mix = 0.0
        while mix <= 1 {
            let fill = accent.blended(with: dark, mix)
            if light.contrast(with: fill) >= minimumTextContrast { return (fill, light) }
            mix += 0.02
        }
        return (dark, light)
    }

    /// A selected row on `surface`, both states from the accent: emphasized (its window active)
    /// the solid prominent fill under its own label, unemphasized the soft accent tint under the
    /// main text. The text reads on the fill at 4.5:1 either way.
    func rowSelection(on surface: ThemeColor, emphasized: Bool) -> (fill: ThemeColor, text: ThemeColor) {
        if emphasized { return (prominent, onProminent) }
        let level = scheme == .light ? Self.selectionLevels.light : Self.selectionLevels.dark
        let (_, fill) = Self.selection(accent: accent, on: surface, text: foreground, level: level)
        return (fill, fill.blended(with: foreground, Self.textLevels.primary))
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return difference > 180 ? 360 - difference : difference
    }
}

// MARK: - Cache

@MainActor private var paletteCache: [TerminalTheme: [ColorScheme?: ChromePalette]] = [:]

public extension ChromePalette {
    /// The palette for `theme`, derived once: views that rebuild often (pane headers) skip the
    /// contrast search.
    @MainActor static func cached(theme: TerminalTheme, scheme: ColorScheme? = nil) -> ChromePalette {
        if let palette = paletteCache[theme]?[scheme] { return palette }
        let palette = ChromePalette(theme: theme, scheme: scheme)
        paletteCache[theme, default: [:]][scheme] = palette
        return palette
    }
}

// MARK: - Colours

nonisolated public extension ChromePalette {
    var baseColor: Color { base.color }
    var sidebarColor: Color { sidebar.color }
    var raisedColor: Color { raised.color }
    var overlayColor: Color { overlay.color }
    var groupedPageColor: Color { groupedPage.color }
    var groupedRowColor: Color { groupedRow.color }
    var terminalColor: Color { terminal.color }

    var text: Color { foreground.color.opacity(Self.textLevels.primary) }
    var textSecondary: Color { foreground.color.opacity(secondaryLevel) }
    var textTertiary: Color { foreground.color.opacity(tertiaryLevel) }
    var textQuaternary: Color { foreground.color.opacity(Self.textLevels.quaternary) }

    var hoverFill: Color { foreground.color.opacity(Self.fillLevels.hover) }
    var selectedFill: Color { foreground.color.opacity(Self.fillLevels.selected) }
    var pressedFill: Color { foreground.color.opacity(Self.fillLevels.pressed) }

    var hairline: Color { foreground.color.opacity(Self.lineLevels.hairline) }
    var separator: Color { foreground.color.opacity(Self.lineLevels.separator) }
    var border: Color { foreground.color.opacity(Self.lineLevels.border) }

    var accentColor: Color { accent.color }
    /// Translucent, so it tints glass and any surface alike.
    var selectionColor: Color { accent.color.opacity(selectionLevel) }
    var onSelectionColor: Color { text }
    var prominentColor: Color { prominent.color }
    var onProminentColor: Color { onProminent.color }
}

// MARK: - Environment

nonisolated public extension EnvironmentValues {
    /// The chrome derived from the active theme and window scheme. Set once per window or sheet
    /// root by `chromeTheme(_:windowTheme:)`; everything below reads it (or reads `DS.Palette`,
    /// whose colours resolve from it).
    @Entry var chrome: ChromePalette = .standard
}
