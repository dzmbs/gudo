import SwiftUI

/// Project colours: the theme's own ANSI hues, barely softened toward the foreground (less than
/// the state colours: a project's colour is how it is told apart, so hues stay distinct), kept
/// legible on the sidebar.
nonisolated public enum ProjectColor {
    public static let names = ["Blue", "Purple", "Cyan", "Green", "Yellow", "Red", "Orange", "Grey"]

    /// The ANSI slot and the hue it should have (monochrome themes fall back to the reference).
    private static let slots: [(index: Int, reference: String)] = [
        (4, "#81a2be"), (5, "#b294bb"), (6, "#8abeb7"), (2, "#b5bd68"), (3, "#f0c674"), (1, "#cc6666"),
    ]

    /// How far a hue moves toward the foreground.
    static let mix = 0.12

    public static func color(_ index: Int, theme: TerminalTheme, chrome: ChromePalette) -> ThemeColor {
        let foreground = chrome.foreground
        let surfaces = [chrome.background, chrome.background.blended(with: foreground, ChromePalette.sidebarStrength)]
        func hue(_ slot: Int) -> ThemeColor {
            let (ansi, reference) = slots[slot]
            let referenceHue = ThemeColor(hex: reference)!
            let themeHue = theme.ansiRGB(ansi)
            return themeHue.chroma < 12 || ChromePalette.hueDistance(themeHue.hue, referenceHue.hue) > 60 ? referenceHue : themeHue
        }
        let base: ThemeColor = switch ((index % names.count) + names.count) % names.count {
        case 6: hue(5).blended(with: hue(4), 0.5)
        case 7: chrome.background.blended(with: foreground, 0.5)
        case let slot: hue(slot)
        }
        let mixed = foreground.blended(with: base, 1 - mix)
        return ChromePalette.legible(mixed, on: surfaces, minimum: ChromePalette.minimumGlyphContrast)
    }
}

public extension DS.Palette {
    /// Project colour `index` (`ProjectColor.names`).
    static func project(_ index: Int) -> ChromeStyle { ChromeStyle(.project(index)) }
}
