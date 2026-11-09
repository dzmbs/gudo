import Testing
@testable import DesignSystem

struct SyntaxPaletteTests {
    @Test(arguments: [TerminalTheme.ghosttyDefault] + ThemeCatalog.all)
    func syntaxSlotsRemainReadableWithoutChangingThePalette(theme: TerminalTheme) {
        let original = theme
        for slot in [1, 2, 3, 4, 5, 6, 8] {
            let normal = theme.syntaxANSI(slot)
            let increased = theme.syntaxANSI(slot, increasedContrast: true)
            #expect(normal.contrast(with: theme.bgRGB) >= 4.5, "\(theme.name), slot \(slot)")
            // A few mid-luminance backgrounds cannot reach 7:1 with any foreground.
            let possible = max(ThemeColor.black.contrast(with: theme.bgRGB), ThemeColor.white.contrast(with: theme.bgRGB))
            #expect(increased.contrast(with: theme.bgRGB) >= min(7, possible) - 1e-9, "\(theme.name), slot \(slot)")
            if theme.ansiRGB(slot).contrast(with: theme.bgRGB) >= 4.5 {
                #expect(normal == theme.ansiRGB(slot))
            }
        }
        #expect(theme == original)
    }
}
