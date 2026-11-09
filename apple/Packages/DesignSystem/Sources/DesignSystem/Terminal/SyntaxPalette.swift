import SwiftUI

nonisolated public extension TerminalTheme {
    /// Code uses the theme's ANSI hues, lifted to readable text contrast on its terminal surface.
    /// Increase Contrast targets 7:1, or the best physically possible contrast on that surface.
    /// This does not change terminal rendering or the user's palette/settings.
    func syntaxANSI(_ index: Int, increasedContrast: Bool = false) -> ThemeColor {
        ChromePalette.legible(ansiRGB(index), on: [bgRGB], minimum: increasedContrast ? 7 : 4.5)
    }
}
