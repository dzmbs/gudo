import Testing
@testable import DesignSystem

struct SyntaxPaletteTests {
    @Test(arguments: [TerminalTheme.ghosttyDefault] + ThemeCatalog.all)
    func syntaxSlotsReadOnTheTerminalAndCodeSurfacesWithoutChangingThePalette(theme: TerminalTheme) {
        let original = theme
        for slot in [1, 2, 3, 4, 5, 6, 8] {
            let normal = theme.syntaxANSI(slot)
            let increased = theme.syntaxANSI(slot, increasedContrast: true)
            for surface in [theme.bgRGB, theme.codeSurfaceRGB] {
                #expect(normal.contrast(with: surface) >= 4.5, "\(theme.name), slot \(slot)")
                // A few mid-luminance backgrounds cannot reach 7:1 with any foreground.
                let possible = min(
                    max(ThemeColor.black.contrast(with: theme.bgRGB), ThemeColor.white.contrast(with: theme.bgRGB)),
                    max(ThemeColor.black.contrast(with: theme.codeSurfaceRGB), ThemeColor.white.contrast(with: theme.codeSurfaceRGB)))
                #expect(increased.contrast(with: surface) >= min(7, possible) - 1e-9, "\(theme.name), slot \(slot)")
            }
            if theme.ansiRGB(slot).contrast(with: theme.bgRGB) >= 4.5, theme.ansiRGB(slot).contrast(with: theme.codeSurfaceRGB) >= 4.5 {
                #expect(normal == theme.ansiRGB(slot))
            }
        }
        #expect(theme == original)
    }
}
