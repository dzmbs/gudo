#if os(macOS)
import DesignSystem
import HostKit
import XCTest
@testable import App

/// This Mac's helper starting (the app's launch, or again after it stopped) reads as starting,
/// never as a lost link with a last contact to count from.
@MainActor
final class ThisMacStartingTests: XCTestCase {
    private let since = Date(timeIntervalSinceReferenceDate: 0)

    func testAHelperStartingIsNotALostLink() {
        for status in [ConnectionStatus.reconnecting(attempt: 3, reason: "connection refused"), .connecting(.dialing), .connecting(.openingSession)] {
            XCTAssertEqual(ConnectionState(status, since: since, helperStarting: true), .starting, "\(status)")
        }
    }

    func testOtherStatesSayWhatTheyAre() {
        XCTAssertEqual(ConnectionState(.connected(rtt: nil), since: since, helperStarting: true), .connected)
        XCTAssertEqual(
            ConnectionState(.needsAttention(reason: "Removed"), since: since, helperStarting: true),
            .needsAttention(reason: "Removed", action: nil))
        XCTAssertEqual(
            ConnectionState(.reconnecting(attempt: 2, reason: "timed out"), since: since),
            .reconnecting(attempt: 2, since: since), "a host this launch reached reconnects")
    }

    func testThisLaunchNotHavingReachedTheHelperYetIsStarting() {
        XCTAssertTrue(LocalHelper.readsAsStarting(.starting, connectionCount: 4), "started again after it stopped")
        XCTAssertTrue(LocalHelper.readsAsStarting(.running, connectionCount: 0), "up, but this launch has not reached it yet")
        XCTAssertFalse(LocalHelper.readsAsStarting(.running, connectionCount: 1), "a link to a running helper dropped")
        XCTAssertFalse(LocalHelper.readsAsStarting(.failed("no"), connectionCount: 0))
        XCTAssertFalse(LocalHelper.readsAsStarting(.off, connectionCount: 0))
    }
}
#endif
