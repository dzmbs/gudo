import SwiftUI

nonisolated public extension TerminalTheme {
    /// The fill under code in Chat: the theme's background lifted by its own ink at the sidebar
    /// strength, so a code block reads as a surface in the theme's scheme whatever the chrome is.
    var codeSurfaceRGB: ThemeColor { bgRGB.blended(with: fgRGB, ChromePalette.sidebarStrength) }

    var codeSurface: Color { codeSurfaceRGB.color }

    /// Code uses the theme's ANSI hues, lifted to readable text contrast on its terminal surface
    /// and on the code surface. Increase Contrast targets 7:1, or the best physically possible
    /// contrast on those surfaces. This does not change terminal rendering or the user's palette/settings.
    func syntaxANSI(_ index: Int, increasedContrast: Bool = false) -> ThemeColor {
        ChromePalette.legible(ansiRGB(index), on: [bgRGB, codeSurfaceRGB], minimum: increasedContrast ? 7 : 4.5)
    }
}
