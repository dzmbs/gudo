import SwiftUI
import Testing
@testable import DesignSystem

/// Under Increase Contrast, secondary text reads as main text and lines get stronger.
@MainActor
struct IncreasedContrastTests {
    @Test func secondaryTextAndLinesStepUp() {
        #expect(ChromeStyle.Token.textSecondary.increasedContrast == .text)
        #expect(ChromeStyle.Token.textTertiary.increasedContrast == .textSecondary)
        #expect(ChromeStyle.Token.hairline.increasedContrast == .border)
        #expect(ChromeStyle.Token.separator.increasedContrast == .border)
        #expect(ChromeStyle.Token.accent.increasedContrast == .accent)
        #expect(ChromeStyle.Token.text.increasedContrast == .text)
    }

    @Test func stylesResolveToTheStrongerTokenOnlyUnderIncreasedContrast() {
        var environment = EnvironmentValues()
        environment.chrome = ChromePalette(theme: .ghosttyDefault)
        let secondary = DS.Palette.textSecondary.resolve(in: environment)
        #expect(secondary != DS.Palette.text.resolve(in: environment))
        environment._colorSchemeContrast = .increased
        #expect(DS.Palette.textSecondary.resolve(in: environment) == DS.Palette.text.resolve(in: environment))
        #expect(DS.Palette.hairline.resolve(in: environment) == DS.Palette.border.resolve(in: environment))
    }
}
