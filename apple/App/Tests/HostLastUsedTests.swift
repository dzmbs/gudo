import XCTest
@testable import App

/// A host's "Last used" counts on while it is on screen.
@MainActor
final class HostLastUsedTests: XCTestCase {
    func testLastUsedFollowsTheClock() {
        let seen = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let soon = HostsView.lastUsed(seen, now: seen + 33)
        let later = HostsView.lastUsed(seen, now: seen + 3 * 60)
        XCTAssertTrue(soon.hasPrefix("Last used "))
        XCTAssertNotEqual(soon, later, "the text moves on with the clock")
        XCTAssertTrue(later.contains("3"), later)
        XCTAssertEqual(HostsView.lastUsed(.distantPast, now: seen), "Not connected")
    }
}
