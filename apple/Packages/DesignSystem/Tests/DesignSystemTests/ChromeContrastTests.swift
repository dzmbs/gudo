import SwiftUI
import Testing
@testable import DesignSystem

/// Every text-bearing chrome colour against every surface it is drawn on, on every bundled theme,
/// in the theme's own scheme and forced to the other (WCAG 2 contrast).
struct ChromeContrastTests {
    static let themes = [TerminalTheme.ghosttyDefault] + ThemeCatalog.all
    static let schemes: [ColorScheme?] = [nil, .light, .dark]

    /// The surfaces text sits on, with the selected-row fill composited where rows are listed.
    static func textSurfaces(of chrome: ChromePalette) -> [(name: String, color: ThemeColor)] {
        let selected = ChromePalette.fillLevels.selected
        return [
            ("base", chrome.base), ("sidebar", chrome.sidebar), ("raised", chrome.raised),
            ("overlay", chrome.overlay), ("groupedPage", chrome.groupedPage), ("groupedRow", chrome.groupedRow),
            ("selected on base", chrome.base.blended(with: chrome.foreground, selected)),
            ("selected on sidebar", chrome.sidebar.blended(with: chrome.foreground, selected)),
        ]
    }

    static func states(of chrome: ChromePalette) -> [(name: String, color: ThemeColor)] {
        [("done", chrome.done), ("error", chrome.error), ("attention", chrome.attention),
         ("working", chrome.working), ("info", chrome.info)]
    }

    /// Failures grouped by token pair, each listing the themes that fail it.
    static func failures(
        scheme: ColorScheme?, minimum: Double,
        _ pairs: (ChromePalette) -> [(pair: String, color: ThemeColor, surface: ThemeColor)]
    ) -> [String: [String]] {
        var failures: [String: [String]] = [:]
        for theme in themes {
            let chrome = ChromePalette(theme: theme, scheme: scheme)
            for (pair, color, surface) in pairs(chrome) where color.contrast(with: surface) < minimum {
                failures[pair, default: []].append("\(theme.name) \(color) on \(surface)")
            }
        }
        return failures
    }

    static func summary(_ failures: [String: [String]]) -> String {
        failures.keys.sorted().map { pair in "\(pair): \(failures[pair]?.count ?? 0) themes, e.g. \(failures[pair]?.prefix(3) ?? [])" }
            .joined(separator: "\n")
    }

    @Test(arguments: schemes)
    func primaryAndSecondaryTextReadAt4_5OnEverySurface(scheme: ColorScheme?) {
        let failures = Self.failures(scheme: scheme, minimum: ChromePalette.minimumTextContrast) { chrome in
            Self.textSurfaces(of: chrome).flatMap { surface in
                [("text on \(surface.name)", surface.color.blended(with: chrome.foreground, ChromePalette.textLevels.primary), surface.color),
                 ("textSecondary on \(surface.name)", surface.color.blended(with: chrome.foreground, chrome.secondaryLevel), surface.color)]
            }
        }
        #expect(failures.isEmpty, "\(Self.summary(failures))")
    }

    /// Tertiary is the third step of meta text (tab numbers, paths, timestamps). Held to 4.5:1 on
    /// menus it would reach the secondary level on most dark themes and the hierarchy would be
    /// gone, so it is held to the large-text and graphics minimum instead.
    @Test(arguments: schemes)
    func tertiaryTextReadsAt3To1SoItStaysAStepBelowSecondary(scheme: ColorScheme?) {
        let failures = Self.failures(scheme: scheme, minimum: ChromePalette.minimumGlyphContrast) { chrome in
            Self.textSurfaces(of: chrome).map { surface in
                ("textTertiary on \(surface.name)", surface.color.blended(with: chrome.foreground, chrome.tertiaryLevel), surface.color)
            }
        }
        #expect(failures.isEmpty, "\(Self.summary(failures))")
        let collapsed = Self.themes.filter { theme in
            let chrome = ChromePalette(theme: theme, scheme: scheme)
            return chrome.tertiaryLevel >= chrome.secondaryLevel
        }
        #expect(collapsed.isEmpty, "\(collapsed.map(\.name))")
    }

    /// States are words as well as glyphs ("Can't reach", "Reconnecting", an error under a form).
    @Test(arguments: schemes)
    func stateColoursReadAsTextAt4_5OnEverySurface(scheme: ColorScheme?) {
        let failures = Self.failures(scheme: scheme, minimum: ChromePalette.minimumTextContrast) { chrome in
            Self.textSurfaces(of: chrome).prefix(6).flatMap { surface in
                Self.states(of: chrome).map { state in ("\(state.name) on \(surface.name)", state.color, surface.color) }
            }
        }
        #expect(failures.isEmpty, "\(Self.summary(failures))")
    }

    /// A colour brought up to contrast keeps its hue: amber stays amber on paper, never a brown
    /// drifting toward the ink.
    @Test(arguments: [["#f7f7f7", "#dcdbdb"], ["#282c34", "#4a4e55"]])
    func legibleKeepsTheHue(surfaceHexes: [String]) throws {
        let surfaces = try surfaceHexes.map { try #require(ThemeColor(hex: $0)) }
        for hex in ["#f0c674", "#b5bd68", "#cc6666", "#b294bb", "#81a2be", "#0000ff", "#00ff00"] {
            let color = try #require(ThemeColor(hex: hex))
            let legible = ChromePalette.legible(color, on: surfaces, minimum: ChromePalette.minimumTextContrast)
            #expect(surfaces.allSatisfy { legible.contrast(with: $0) >= ChromePalette.minimumTextContrast }, "\(hex) → \(legible)")
            func oklabHue(_ color: ThemeColor) -> Double { atan2(color.oklab.b, color.oklab.a) * 180 / .pi }
            #expect(ChromePalette.hueDistance(oklabHue(legible), oklabHue(color)) < 1, "\(hex) → \(legible)")
        }
    }

    @Test(arguments: schemes)
    func selectionAndProminentLabelsReadAt4_5(scheme: ColorScheme?) {
        let failures = Self.failures(scheme: scheme, minimum: ChromePalette.minimumTextContrast) { chrome in
            [("onSelection on selection", chrome.onSelection, chrome.selection),
             ("onProminent on prominent", chrome.onProminent, chrome.prominent)]
        }
        #expect(failures.isEmpty, "\(Self.summary(failures))")
    }

    /// A program's symbol dims the style it inherits; the dimmed glyph still reads as a graphic
    /// (WCAG 1.4.11): in main text on every surface (the palette, menus), in secondary text on
    /// the bands that carry an unfocused or inactive one (pane headers, tab strips, the sidebar).
    @Test(arguments: schemes)
    func mutedProgramMarksReadAt3To1(scheme: ColorScheme?) {
        let failures = Self.failures(scheme: scheme, minimum: ChromePalette.minimumGlyphContrast) { chrome in
            let inText = Self.textSurfaces(of: chrome).prefix(4).map { surface in
                ("mark in text on \(surface.name)", ChromePalette.textLevels.primary, surface.color)
            }
            let inSecondaryText = Self.textSurfaces(of: chrome).prefix(2).map { surface in
                ("mark in textSecondary on \(surface.name)", chrome.secondaryLevel, surface.color)
            }
            return (inText + inSecondaryText).map { pair, level, surface in
                (pair, surface.blended(with: chrome.foreground, level * chrome.markOpacity), surface)
            }
        }
        #expect(failures.isEmpty, "\(Self.summary(failures))")
    }
}
