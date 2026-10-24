#if os(macOS)
import XCTest
@testable import App

/// The Mac Settings window's sidebar and the pages pushed over a pane.
@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testChoosingAnotherPaneStartsItAtItsRoot() {
        let navigation = SettingsNavigation()
        navigation.path = [.theme]
        navigation.pane = .terminal
        XCTAssertEqual(navigation.pane, .terminal)
        XCTAssertTrue(navigation.path.isEmpty)
    }

    func testChoosingTheSamePaneKeepsThePage() {
        let navigation = SettingsNavigation(pane: .about, path: [.acknowledgements])
        navigation.pane = .about
        XCTAssertEqual(navigation.path, [.acknowledgements])
    }
}
#endif
