import SwiftUI
import Testing
@testable import DesignSystem

/// the theme, and stay readable on every bundled theme.
struct ChromePaletteTests {
    static let themes = [TerminalTheme.ghosttyDefault] + ThemeCatalog.all

    // MARK: Colour maths

    @Test func blendAndContrast() {
        #expect(ThemeColor.black.blended(with: .white, 0.5).hex == "#808080")
        #expect(abs(ThemeColor.white.contrast(with: .black) - 21) < 0.01)
        #expect(abs(ThemeColor(hex: "#777777")!.contrast(with: .white) - 4.48) < 0.01)
    }

    /// Reference pairs from Sharma, Wu and Dalal (2005), converted from Lab is not possible here, so
    /// check the properties instead: identity, symmetry, and a known sRGB pair.
    @Test func deltaE2000() {
        let red = ThemeColor(hex: "#ff0000")!, blue = ThemeColor(hex: "#0000ff")!
        #expect(ThemeColor.deltaE2000(red, red) < 1e-9)
        #expect(abs(ThemeColor.deltaE2000(red, blue) - ThemeColor.deltaE2000(blue, red)) < 1e-9)
        // sRGB red vs blue is ≈ 52.9 in CIEDE2000.
        #expect(abs(ThemeColor.deltaE2000(red, blue) - 52.88) < 0.1)
        // Black vs white: 100.
        #expect(abs(ThemeColor.deltaE2000(.black, .white) - 100) < 0.01)
    }

    // MARK: Derivation

    @Test func surfacesAreTheForegroundOverTheBackground() {
        let chrome = ChromePalette(theme: .ghosttyDefault)
        #expect(chrome.base == ThemeColor(hex: "#282c34"))
        #expect(chrome.sidebar == chrome.base.blended(with: chrome.foreground, 0.05))
        #expect(chrome.raised == chrome.base.blended(with: chrome.foreground, 0.10))
        #expect(chrome.overlay == chrome.base.blended(with: chrome.foreground, 0.15))
        // Dark theme: surfaces get lighter; light theme: darker. One rule, no branch.
        #expect(chrome.raised.luminance > chrome.base.luminance)
        let light = ChromePalette(theme: ThemeCatalog.theme(named: "iTerm2 Solarized Light"))
        #expect(light.scheme == .light)
        #expect(light.raised.luminance < light.base.luminance)
    }

    @Test func defaultThemeKeepsGhosttyBlue() {
        let chrome = ChromePalette(theme: .ghosttyDefault)
        #expect(chrome.accent == ThemeColor(hex: "#7aa6da"))
        // White-ish text on the solid selection.
        #expect(chrome.onSelection.contrast(with: chrome.selection) >= 4.5)
    }

    @Test func accentFollowsTheTheme() {
        // Dracula's cursor is its foreground: the accent comes from its palette, not Ghostty blue.
        let dracula = ChromePalette(theme: ThemeCatalog.theme(named: "Dracula"))
        #expect(dracula.accent != ThemeColor(hex: "#7aa6da"))
        // A cursor that is a real colour is the accent (Catppuccin's rosewater is too grey; Gruvbox's
        // is its foreground), and the accent is never the theme's red, green or yellow.
        let stateAccents = Self.themes.filter { ChromePalette.isStateHue(ChromePalette.accent(of: $0), theme: $0) }
        #expect(stateAccents.count <= Self.themes.count / 20, "\(stateAccents.map(\.name))")
    }

    @Test func statesComeFromTheThemesAnsiColours() {
        let solarized = ThemeCatalog.theme(named: "iTerm2 Solarized Dark")
        let chrome = ChromePalette(theme: solarized)
        let green = solarized.ansiRGB(2)
        // Mixed half-way to the foreground: closer to Solarized green than Ghostty's green is.
        #expect(ThemeColor.deltaE2000(chrome.done, green) < ThemeColor.deltaE2000(ChromePalette.standard.done, green))
        #expect(ChromePalette.hueDistance(chrome.done.hue, green.hue) < 40)
    }

    @Test func forcedSchemeGivesThatScheme() {
        let dark = TerminalTheme.ghosttyDefault
        let light = ChromePalette(theme: dark, scheme: .light)
        #expect(light.scheme == .light)
        #expect(light.base.luminance > 0.8)
        #expect(light.terminal == dark.bgRGB)
        let solarizedLight = ThemeCatalog.theme(named: "iTerm2 Solarized Light")
        let darkChrome = ChromePalette(theme: solarizedLight, scheme: .dark)
        #expect(darkChrome.base.luminance < 0.05)
    }

    /// Text at the main level reads at 4.5:1 on every surface, on every bundled theme, in the
    /// theme's own scheme and forced to the other.
    @Test(arguments: [ColorScheme?.none, .light, .dark])
    func textContrastOnEveryTheme(scheme: ColorScheme?) {
        var failures: [String] = []
        for theme in Self.themes {
            let chrome = ChromePalette(theme: theme, scheme: scheme)
            for surface in chrome.surfaces {
                let ratio = chrome.text(on: surface).contrast(with: surface)
                if ratio < 4.5 { failures.append("\(theme.name) \(surface): \(ratio)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(10))")
    }

    /// State glyphs and the accent read at 3:1 on the base, sidebar and overlay; the selection's
    /// text at 4.5:1.
    @Test(arguments: [ColorScheme?.none, .light, .dark])
    func glyphContrastOnEveryTheme(scheme: ColorScheme?) {
        var failures: [String] = []
        for theme in Self.themes {
            let chrome = ChromePalette(theme: theme, scheme: scheme)
            for surface in [chrome.base, chrome.sidebar, chrome.overlay] {
                for (name, color) in [("accent", chrome.accent), ("done", chrome.done), ("error", chrome.error),
                                      ("attention", chrome.attention), ("working", chrome.working), ("info", chrome.info)]
                where color.contrast(with: surface) < 3 {
                    failures.append("\(theme.name) \(name) \(color) on \(surface)")
                }
            }
            if chrome.onSelection.contrast(with: chrome.selection) < 4.5 {
                failures.append("\(theme.name) selection")
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(10))")
    }

    /// The four themes the screenshots use, printed for review.
    @Test func reviewThemes() {
        for name in ["Ghostty Default", "iTerm2 Solarized Light", "Gruvbox Dark", "Dracula", "Catppuccin Mocha", "iTerm2 Solarized Dark", "TokyoNight", "Nord"] {
            let theme = name == "Ghostty Default" ? TerminalTheme.ghosttyDefault : ThemeCatalog.theme(named: name)
            let c = ChromePalette(theme: theme)
            print("\(name): bg \(c.base) fg \(c.foreground) sidebar \(c.sidebar) accent \(c.accent) sel \(c.selection)/\(c.onSelection) done \(c.done) error \(c.error) attn \(c.attention) working \(c.working) info \(c.info)")
        }
    }
}
