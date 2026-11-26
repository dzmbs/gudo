import Testing
@testable import DesignSystem

/// An approval card's action counts as shown only once every line of it has been on screen.
@Suite struct ActionRevealTests {
    @Test func anActionThatFitsTheCardIsShownAtOnce() {
        var reveal = ActionReveal()
        #expect(!reveal.hasShownAll, "nothing is shown before it is measured")
        reveal.measured(collapsed: 32)
        #expect(!reveal.hasShownAll)
        reveal.measured(full: 32)
        #expect(reveal.hasShownAll)
        #expect(!reveal.isCut)
    }

    @Test func aCutActionIsShownOnlyOnceOpenedAndReadToItsEnd() {
        var reveal = ActionReveal()
        reveal.measured(collapsed: 32)
        reveal.measured(full: 400)
        #expect(reveal.isCut)
        #expect(!reveal.hasShownAll)
        reveal.reachedEnd()
        #expect(!reveal.hasShownAll, "the end of a closed action was never on screen")
        reveal.open()
        #expect(!reveal.hasShownAll, "opened, it still scrolls past its first lines")
        reveal.reachedEnd()
        #expect(reveal.hasShownAll)
    }

    @Test func onceShownALaterLayoutDoesNotTakeItBack() {
        var reveal = ActionReveal()
        reveal.measured(collapsed: 32)
        reveal.measured(full: 32)
        reveal.measured(full: 48)
        #expect(reveal.hasShownAll)
    }

    @Test func anEmptyActionIsShown() {
        var reveal = ActionReveal()
        reveal.measured(full: 0)
        reveal.measured(collapsed: 0)
        #expect(reveal.hasShownAll)
    }
}
