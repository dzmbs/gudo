import XCTest
@testable import App

/// A window too narrow for the sidebar and the terminal hides the sidebar, and shows it again once
/// it is wide enough, unless the user chose meanwhile.
@MainActor
final class NarrowWindowSidebarTests: XCTestCase {
    func testNarrowingHidesTheSidebarAndWideningBringsItBack() {
        var fit = SidebarWidthFit()
        XCTAssertNil(fit.widthChanged(to: 1200, isShown: true))
        XCTAssertEqual(fit.widthChanged(to: SidebarWidthFit.hideBelow - 1, isShown: true), false)
        XCTAssertNil(fit.widthChanged(to: SidebarWidthFit.hideBelow + 1, isShown: false), "no flicker at the edge")
        XCTAssertEqual(fit.widthChanged(to: SidebarWidthFit.showFrom, isShown: false), true)
    }

    func testASidebarTheUserHidStaysHiddenWhenTheWindowWidens() {
        var fit = SidebarWidthFit()
        XCTAssertNil(fit.widthChanged(to: 700, isShown: false))
        XCTAssertNil(fit.widthChanged(to: 1400, isShown: false))
    }

    func testTheUsersChoiceWhileNarrowWins() {
        var fit = SidebarWidthFit()
        XCTAssertEqual(fit.widthChanged(to: 700, isShown: true), false)
        fit.userChose()
        XCTAssertNil(fit.widthChanged(to: 1400, isShown: false), "hidden by hand now")

        var shownByHand = SidebarWidthFit()
        XCTAssertEqual(shownByHand.widthChanged(to: 700, isShown: true), false)
        shownByHand.userChose()
        XCTAssertNil(shownByHand.widthChanged(to: 720, isShown: true), "shown by hand in a narrow window stays")
    }
}
