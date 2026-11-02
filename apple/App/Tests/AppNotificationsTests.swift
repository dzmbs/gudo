import NotifyKit
import UnnamedCore
import UserNotifications
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

    // MARK: Permission

    private final class FakeAuthorizer: NotificationAuthorizing, @unchecked Sendable {
        var current: UNAuthorizationStatus = .notDetermined
        var requests = 0
        func status() async -> UNAuthorizationStatus { current }
        func request() async -> Bool {
            requests += 1
            current = .authorized
            return true
        }
    }

    /// Permission is asked right after pairing, once; a note firing while the app is away
    /// never asks (it would come out of nowhere), it just is not posted.
    func testPermissionIsAskedAfterPairingNeverWhenANoteFires() async {
        let notifications = AppNotifications.shared
        let saved = (notifications.authorizer, notifications.appIsActive)
        defer { (notifications.authorizer, notifications.appIsActive) = saved }
        let authorizer = FakeAuthorizer()
        notifications.authorizer = authorizer
        notifications.appIsActive = false

        let note = AttentionNote(hostId: "h", hostName: "studio", itemId: 1, paneId: 2, kind: .done, title: "", body: "", agent: "Claude Code")
        await notifications.post(note)
        XCTAssertEqual(authorizer.requests, 0, "a note while away does not ask")

        await notifications.askAfterPairing(allowed: false)
        XCTAssertEqual(authorizer.requests, 0, "-notificationPrompt NO")
        await notifications.askAfterPairing(allowed: true)
        XCTAssertEqual(authorizer.requests, 1, "asked after the first pairing")
        await notifications.askAfterPairing(allowed: true)
        XCTAssertEqual(authorizer.requests, 1, "asked once")
    }
}
