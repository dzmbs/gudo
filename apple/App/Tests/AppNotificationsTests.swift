import UnnamedCore
import XCTest
@testable import App

/// An approval's attention item and the agent state carrying its options come on separate
/// streams: the notification waits for the options, so it keeps Approve / Deny.
@MainActor
final class AppNotificationsTests: XCTestCase {
    private final class Box {
        var agent: AgentStatus? = AgentStatus(kind: "claude", state: .running)
    }

    private static let blocked = AgentStatus(kind: "claude", state: .blocked(
        requestId: 7, summary: "rm -rf build",
        options: [DecisionOption(id: 1, label: "Yes"), DecisionOption(id: 2, label: "No")]))

    func testAnApprovalWaitsForItsOptions() async {
        let box = Box()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            box.agent = Self.blocked
        }
        let start = ContinuousClock.now
        await AppNotifications.settle { AppNotifications.blockedOptions(box.agent, request: 7) != nil }
        XCTAssertEqual(AppNotifications.blockedOptions(box.agent, request: 7)?.map(\.label), ["Yes", "No"])
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "it goes as soon as the options are there")
    }

    func testOptionsOfAnotherRequestDoNotCount() async {
        XCTAssertNil(AppNotifications.blockedOptions(Self.blocked, request: 8))
        let start = ContinuousClock.now
        await AppNotifications.settle(limit: .milliseconds(200)) { false }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(200), "gives up after the limit")
    }
}
