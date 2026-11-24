#if os(iOS)
import DesignSystem
import GudoCore
import HostKit
import Observation
import PaneLayout
import SwiftUI
import UIKit
import XCTest
@testable import App

/// The composer in a real Chat pane: queueing while the agent works and sending when its turn
/// ends, sending now instead, and `@` and `/` suggestions from the host and the session.
@MainActor
final class ChatComposerFlowTests: XCTestCase {
    @MainActor @Observable final class Agent { var working: Bool; init(working: Bool) { self.working = working } }

    @MainActor private struct Fixture {
        let pane: Pane
        let state: PaneChatState
        let hub: DaemonWorkspace
        let client: TimelineFixtureClient
        let agent: Agent
        let window: UIWindow
        let preferences: UserDefaults
        let suite: String

        func view() -> PaneChatView<Color> {
            PaneChatView(pane: pane, state: state, hub: hub, permitsSending: true, working: agent.working) { _ in Color.clear }
        }

        func tearDown() {
            state.deactivate()
            window.isHidden = true
            window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: ChatPreferences.Key.sendWhileWorking)
        }
    }

    @MainActor private struct Harness: View {
        let pane: Pane
        let state: PaneChatState
        let hub: DaemonWorkspace
        @Bindable var agent: Agent

        var body: some View {
            NavigationStack {
                PaneChatView(pane: pane, state: state, hub: hub, permitsSending: true, working: agent.working) { _ in Color.clear }
                    .navigationTitle("Review the change").navigationBarTitleDisplayMode(.inline)
                    .chromeBarBackground(.base)
                    .chromeBackground(DS.Palette.base)
            }
        }
    }

    func testSendWhileWorkingQueuesAndTheQueueDrainsWhenTheTurnEnds() async throws {
        let fixture = try makeFixture(working: true)
        defer { fixture.tearDown() }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.isEmpty == false }
        fixture.state.draft = "Then run the tests"
        fixture.view().send()
        XCTAssertEqual(fixture.state.queue.messages.map(\.text), ["Then run the tests"])
        XCTAssertEqual(fixture.state.draft, "")
        fixture.state.draft = "And update the docs"
        fixture.view().send()
        XCTAssertEqual(fixture.state.queue.messages.count, 2)
        XCTAssertTrue(fixture.client.calls.filter { $0.hasPrefix("send ") }.isEmpty, "nothing goes while the agent works")
        try await Task.sleep(for: .milliseconds(300))
        try capture(fixture.window, name: "queued")

        fixture.agent.working = false
        try await wait { fixture.client.calls.contains("send 7 Then run the tests") }
        XCTAssertEqual(fixture.state.queue.messages.map(\.text), ["And update the docs"], "one message per finished turn")
        try await wait { fixture.state.composer.phase == .finished }
        fixture.agent.working = true
        try await Task.sleep(for: .milliseconds(30))
        fixture.agent.working = false
        try await wait { fixture.client.calls.contains("send 7 And update the docs") }
        XCTAssertTrue(fixture.state.queue.messages.isEmpty)
    }

    func testTheAlternateSendGoesNowAndTheSettingCanMakeThatTheDefault() async throws {
        let fixture = try makeFixture(working: true)
        defer { fixture.tearDown() }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.isEmpty == false }
        fixture.state.draft = "Stop and look at the parser"
        fixture.view().submit(alternate: true)
        try await wait { fixture.client.calls.contains("send 7 Stop and look at the parser") }
        XCTAssertTrue(fixture.state.queue.messages.isEmpty)
        try await wait { fixture.state.composer.confirmedText != nil && fixture.state.draft.isEmpty }

        UserDefaults.standard.set(ChatPreferences.SendWhileWorking.steer.rawValue, forKey: ChatPreferences.Key.sendWhileWorking)
        try await Task.sleep(for: .milliseconds(30))
        fixture.state.draft = "Also the lexer"
        fixture.view().submit(alternate: true)
        XCTAssertEqual(fixture.state.queue.messages.map(\.text), ["Also the lexer"], "with steering the default, the other way queues")
    }

    func testAQueuedMessageCanGoBackToTheFieldGoNowOrBeRemoved() async throws {
        let fixture = try makeFixture(working: true)
        defer { fixture.tearDown() }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.isEmpty == false }
        for text in ["first", "second", "third"] {
            fixture.state.draft = text
            fixture.view().send()
        }
        XCTAssertEqual(fixture.state.queue.messages.count, 3)
        XCTAssertNotNil(fixture.state.queue.take(fixture.state.queue.messages[2].id))
        let first = fixture.state.queue.messages[0]
        fixture.state.queue.take(first.id).map { fixture.state.draft = $0.text }
        XCTAssertEqual(fixture.state.draft, "first")
        XCTAssertEqual(fixture.state.queue.messages.map(\.text), ["second"])
    }

    func testTypingAtOffersTheHostsFilesAndSlashTheSessionsCommands() async throws {
        let fixture = try makeFixture(working: false, commands: [["name": "review", "description": "Review the diff", "source": "Built-in"]])
        fixture.client.searchablePaths = ["src/app.ts", "src/apple.ts", "README.md"]
        defer { fixture.tearDown() }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.isEmpty == false }
        fixture.state.draft = "Look at @app"
        try await wait { fixture.state.autocomplete.suggestions.map(\.title) == ["src/app.ts", "src/apple.ts"] }
        XCTAssertEqual(fixture.client.calls.filter { $0.hasPrefix("files ") }.last, "files 7 app")
        try await Task.sleep(for: .milliseconds(300))
        try capture(fixture.window, name: "autocomplete-files")
        fixture.state.draft = "/rev"
        try await wait { fixture.state.autocomplete.suggestions.map(\.title) == ["/review"] }
        XCTAssertEqual(fixture.state.autocomplete.trigger?.kind, .command)
        try await Task.sleep(for: .milliseconds(300))
        try capture(fixture.window, name: "autocomplete-commands")
    }

    // MARK: Fixture

    private func makeFixture(working: Bool, commands: [[String: Any]] = []) throws -> Fixture {
        let suite = "chat-composer-flow-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let backend = PanePresentationTests.Backend()
        let pane = try Pane(id: PaneId(7), backend: backend, appearance: .fromPreferences(), onExit: {})
        let state = PaneChatState(member: HostPane(hostId: "fixture", pane: pane.id), defaultPresentation: .chat,
                                  agent: .claude, inputPresentation: pane.inputPresentation,
                                  preferences: preferences, pool: ChatModelPool(capacity: 1), dictation: .init())
        state.prepareInitialPresentation { pane.prepareToParkTerminal() }
        let snapshot = try TimelineFixtureJSON.json([
            "capabilities": 447, "cursor": ["epoch": 1, "sequence": 0], "before": NSNull(),
            "items": [TimelineFixtureJSON.item(1), TimelineFixtureJSON.item(2)],
            "session": ["agent": "Claude", "native_session": "fixture", "title": "Review the change",
                        "model": "claude-opus-4-5-20251101", "permission_mode": "default", "commands": commands],
        ])
        let client = TimelineFixtureClient(snapshot: snapshot, nativeMessageReceipts: true)
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: { client })
        let agent = Agent(working: working)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ThemedRoot {
            Harness(pane: pane, state: state, hub: hub, agent: agent)
        })
        window.makeKeyAndVisible()
        return Fixture(pane: pane, state: state, hub: hub, client: client, agent: agent, window: window,
                       preferences: preferences, suite: suite)
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<3_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("The composer did not reach its expected state", file: file, line: line)
        throw CancellationError()
    }

    private func capture(_ window: UIWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let mode = window.traitCollection.userInterfaceStyle == .light ? "light" : "dark"
        try image.pngData()?.write(to: root.appendingPathComponent("iphone-composer-\(name)-\(mode).png"))
    }
}
#endif
