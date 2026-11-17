#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import App

/// An Objective-C exception raised by a click fails the test that made it, and a menu asked to
/// open from a view in no window stays shut instead of raising.
@MainActor
final class ExceptionTrapTests: XCTestCase {
    /// What AppKit catches it reports, and a report fails the test; an exception nothing catches
    /// fails the test in XCTest itself.
    func testAnExceptionAppKitReportsFailsTheTest() async throws {
        let driver = try await WindowDriver.start(width: 900)
        defer { driver.close() }
        ExceptionTrap.clear()
        let exception = NSException(name: .internalInconsistencyException, reason: "raised under a test click", userInfo: nil)
        XCTExpectFailure("the trap fails the test") {
            NSApp.reportException(exception)
        }
        XCTAssertEqual(ExceptionTrap.reported.map(\.reason), ["raised under a test click"])
    }

    func testAMenuForAViewInNoWindowStaysShut() async throws {
        let driver = try await WindowDriver.start(width: 900)
        defer { driver.close() }
        ExceptionTrap.clear()
        let menu = NSMenu()
        menu.addItem(withTitle: "Command", action: nil, keyEquivalent: "")
        let detached = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertFalse(menu.popUpIfShown(at: .zero, in: detached))
        await driver.pump(0.3)
        XCTAssertEqual(driver.menus.titles, [], "no menu opened")
        XCTAssertEqual(ExceptionTrap.reported, [])
    }
}
#endif
