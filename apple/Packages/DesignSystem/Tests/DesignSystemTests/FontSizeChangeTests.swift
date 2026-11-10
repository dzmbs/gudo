import DesignSystem
import Testing

struct FontSizeChangeTests {
    @Test func increaseAndDecreaseStepOnePoint() {
        #expect(TerminalPreferences.FontSizeChange.increase.applied(to: 13) == 14)
        #expect(TerminalPreferences.FontSizeChange.decrease.applied(to: 13) == 12)
    }

    @Test func sizesStayWithinTheSettingsRange() {
        let range = TerminalPreferences.fontSizeRange
        #expect(TerminalPreferences.FontSizeChange.increase.applied(to: range.upperBound) == range.upperBound)
        #expect(TerminalPreferences.FontSizeChange.decrease.applied(to: range.lowerBound) == range.lowerBound)
    }

    @Test func aPinchedFractionalSizeStepsToWholePoints() {
        #expect(TerminalPreferences.FontSizeChange.increase.applied(to: 14.6) == 16)
    }

    @Test func resetLeavesNoSizeOfItsOwn() {
        #expect(TerminalPreferences.FontSizeChange.reset.applied(to: 20) == nil)
    }
}
