import HostKit
import NotifyKit
import GudoCore
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

    /// An agent asking to type into the user's pane: the note says what it wants and exactly
    /// what it would type, and Approve on it allows once, never "for this pane".
    func testADriveRequestNoteShowsTheActionAndAllowsOnce() {
        let drive = DriveRequestInfo(id: 41, paneId: 3, target: 2, title: "Claude wants to type into ~/api · zsh",
                                     action: "Type “npm test”, then Return")
        let item = AttentionItem(
            id: 9, atMs: 0, paneId: 3, sessionId: nil, kind: .agentBlocked(agent: "claude", requestId: 41),
            title: drive.title, body: drive.action, seen: false, whileViewed: false)
        let blocked = AgentStatus(kind: "claude", state: .blocked(
            requestId: 41, summary: "\(drive.title): \(drive.action)",
            options: [DecisionOption(id: 0, label: "Allow once"),
                      DecisionOption(id: 1, label: "Allow for this pane until it closes"),
                      DecisionOption(id: 2, label: "Deny")]))
        let note = AppNotifications.note(for: item, hostId: "h", hostName: "studio", agentState: blocked, drive: drive)
        XCTAssertEqual(note.title, "Claude wants to type into ~/api · zsh")
        XCTAssertEqual(note.body, "Type “npm test”, then Return")
        guard case .approval(let request, let approve, let deny) = note.kind else {
            return XCTFail("not an approval: \(note.kind)")
        }
        XCTAssertEqual(request, 41)
        XCTAssertEqual(approve?.id, 0)
        XCTAssertEqual(approve?.label, "Allow once")
        XCTAssertEqual(deny?.id, 2)
    }

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

    /// A finished turn is titled with the agent's product name, carries the daemon's agent name
    /// for the per-agent choices, and says the first line of the last message.
    func testAFinishedTurnNamesTheAgentAndSummarizes() {
        let item = AttentionItem(
            id: 5, atMs: 0, paneId: 3, sessionId: nil, kind: .agentDone(agent: "codex"),
            title: "codex finished", body: "Published the crate.\n\nDetails follow.", seen: false, whileViewed: false)
        var note = AppNotifications.note(for: item, hostId: "h", hostName: "studio", agentState: nil, drive: nil)
        note.place = AppNotifications.place(tabTitle: nil, directory: "file://studio/Users/me/src/api")
        XCTAssertEqual(note.agentId, "codex")
        let content = LocalNotifications.content(for: note)
        XCTAssertEqual(content.title, "Codex finished")
        XCTAssertEqual(content.subtitle, "api · studio")
        XCTAssertEqual(content.body, "Published the crate.")
        XCTAssertEqual(AppNotifications.place(tabTitle: " Release ", directory: "/x/y"), "Release")
        XCTAssertNil(AppNotifications.place(tabTitle: "", directory: "/"))
    }

    func testAgentChoicesBecomePushRules() {
        var prefs = NotificationPrefs()
        prefs.agents["codex"] = AgentNotificationPrefs(needsYou: true, finished: false)
        prefs.agents[NotificationPrefs.otherAgents] = AgentNotificationPrefs(needsYou: false, finished: false)
        XCTAssertEqual(AppNotifications.agentRules(prefs), [
            PushAgentRule(agent: "*", needsYou: false, finished: false),
            PushAgentRule(agent: "codex", needsYou: true, finished: false),
        ])
        XCTAssertEqual(AgentNotificationChoice(prefs.agent("claude")), .off, "the other agents' choice")
        XCTAssertEqual(AgentNotificationChoice(prefs.agent("codex")), .needsYou)
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
