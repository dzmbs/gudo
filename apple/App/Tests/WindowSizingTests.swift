import GudoCore
import XCTest
@testable import App

@MainActor
final class WindowSizingTests: XCTestCase {
    func testVisibilityAndActivityRemainSeparate() throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let model = WindowModel(app: .shared)
        defer { model.close() }
        XCTAssertTrue(model.isOnScreen)
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.sizingActivity = .active
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.isOnScreen = false
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.isOnScreen = true
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.destination = .inbox
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.destination = .terminal
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.close()
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
    }
}
