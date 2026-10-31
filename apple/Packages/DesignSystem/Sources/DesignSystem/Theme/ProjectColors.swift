import SwiftUI

/// Project colours (Safari and Chrome tab groups): the theme's own ANSI hues, softened toward the
/// foreground like the state colours, so a project's dot sits in the chrome of any theme.
nonisolated public enum ProjectColor {
    public static let names = ["Blue", "Purple", "Cyan", "Green", "Yellow", "Red", "Orange", "Grey"]

    /// The ANSI slot and the hue it should have (monochrome themes fall back to the reference).
    private static let slots: [(index: Int, reference: String)] = [
        (4, "#81a2be"), (5, "#b294bb"), (6, "#8abeb7"), (2, "#b5bd68"), (3, "#f0c674"), (1, "#cc6666"),
    ]

    public static func color(_ index: Int, theme: TerminalTheme, chrome: ChromePalette) -> ThemeColor {
        let fg = chrome.foreground
        let surfaces = [chrome.background, chrome.background.blended(with: fg, ChromePalette.sidebarStrength)]
        func hue(_ slot: Int) -> ThemeColor {
            let (ansi, reference) = slots[slot]
            let ref = ThemeColor(hex: reference)!
            let raw = theme.ansiRGB(ansi)
            return raw.chroma < 12 || ChromePalette.hueDistance(raw.hue, ref.hue) > 60 ? ref : raw
        }
        let base: ThemeColor = switch ((index % names.count) + names.count) % names.count {
        case 6: hue(5).blended(with: hue(4), 0.5)
        case 7: chrome.background.blended(with: fg, 0.5)
        case let slot: hue(slot)
        }
        let mixed = fg.blended(with: base, 1 - ChromePalette.stateMix)
        return ChromePalette.legible(mixed, on: surfaces, toward: fg, minimum: ChromePalette.minimumGlyphContrast)
    }
}

public extension DS.Palette {
    /// Project colour `index` (`ProjectColor.names`).
    static func project(_ index: Int) -> ChromeStyle { ChromeStyle(.project(index)) }
}
