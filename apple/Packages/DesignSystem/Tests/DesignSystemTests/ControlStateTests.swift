import Testing
@testable import DesignSystem

/// Hand-drawn controls: the fill each state lays under them and the ink a disabled one keeps.
@Suite struct ControlStateTests {
    private let levels = ChromePalette.fillLevels

    @Test func restDrawsNothingAndEachStateHasItsFill() {
        #expect(ControlState().fillLevel == 0)
        #expect(ControlState(isHovered: true).fillLevel == levels.hover)
        #expect(ControlState(isSelected: true).fillLevel == levels.selected)
        #expect(ControlState(isHovered: true, isPressed: true).fillLevel == levels.pressed)
    }

    @Test func aPressShowsOnASelectedControlAndHoverDoesNot() {
        #expect(ControlState(isPressed: true, isSelected: true).fillLevel == levels.pressed)
        #expect(ControlState(isHovered: true, isSelected: true).fillLevel == levels.selected)
    }

    @Test func aDisabledControlIgnoresThePointerAndKeepsItsSelection() {
        #expect(ControlState(isHovered: true, isPressed: true, isEnabled: false).fillLevel == 0)
        #expect(ControlState(isHovered: true, isSelected: true, isEnabled: false).fillLevel == levels.selected)
    }

    @Test func disabledInkStepsDownOnceAndNeverPastTertiary() {
        #expect(DS.Palette.text.disabled == DS.Palette.textSecondary)
        #expect(DS.Palette.textSecondary.disabled == DS.Palette.textTertiary)
        #expect(DS.Palette.textTertiary.disabled == DS.Palette.textTertiary)
        #expect(DS.Palette.textQuaternary.disabled == DS.Palette.textTertiary)
        #expect(DS.Palette.accent.disabled == DS.Palette.textSecondary)
        #expect(DS.Palette.error.disabled == DS.Palette.textSecondary)
    }
}
