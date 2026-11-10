#if os(iOS)
import GudoCore
import HostKit
import PaneLayout
import UIKit
import XCTest
@testable import App

@MainActor
final class PaneChatStateTests: XCTestCase {
    private var suite = ""
    private var preferences: UserDefaults?

    override func setUp() async throws {
        suite = "chat-presentation-test-" + UUID().uuidString
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws { preferences?.removePersistentDomain(forName: suite) }

    private func state(host: String = "first", pane: UInt64 = 7, initial: PanePresentation = .chat) throws -> PaneChatState {
        PaneChatState(member: HostPane(hostId: host, pane: PaneId(pane)),
                      defaultPresentation: initial, agent: .claude,
                      preferences: try XCTUnwrap(preferences), pool: ChatModelPool())
    }

    func testWorkspaceUsesOnlyThisPanesTrackedAgentBeforeItsFirstLayout() async throws {
        let client = TimelineFixtureClient(snapshot: try TimelineFixtureJSON.snapshot(0..<1))
        let host = "chat-metadata-test-" + UUID().uuidString
        let connection = DaemonConnection(hostId: host, ticket: "placeholder") { _, listener in
            client.state.withLock { $0.events = listener }
            return client
        }
        try connection.connect()
        let backend = PanePresentationTests.Backend()
        let workspace = Workspace(hostId: host, connection: connection, makeBackend: { _ in backend })
        defer { workspace.close() }
        let pane = try Pane(id: PaneId(7), backend: backend, onExit: {})
        for id: UInt64 in [8, 7] {
            client.send(.paneMeta(meta: PaneMeta(
                paneId: id, title: "private fixture", cwd: "/private/fixture", exit: nil,
                agent: AgentStatus(kind: "claude", state: .idle), size: PaneSize(cols: 80, rows: 24),
                sizePolicy: .lastActive, sizedBy: nil)))
            for _ in 0..<100 where connection.meta[PaneId(id)] == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(connection.meta[PaneId(id)])
            workspace.updateChatState(of: pane)
            if id == 8 { XCTAssertNil(pane.chat) }
        }
        XCTAssertEqual(pane.chat?.agent, .claude)
        let preferred: PanePresentation = UIDevice.current.userInterfaceIdiom == .phone ? .chat : .terminal
        XCTAssertEqual(pane.chat?.presentation, preferred)
        XCTAssertEqual(backend.isSizeDeferred, preferred == .chat)
        XCTAssertEqual(backend.state.withLock { $0.claims }, 0)
        XCTAssertEqual(backend.state.withLock { $0.resizes }, 0)
    }

    func testAHelperWithoutAgentTimelinesKeepsTerminalAndSaysWhy() async throws {
        let client = FakeWorkspaceClient()
        let host = "chat-old-helper-test-" + UUID().uuidString
        let connection = DaemonConnection(hostId: host, ticket: "placeholder") { _, listener in
            client.state.withLock { $0.events = listener }
            return client
        }
        try connection.connect()
        let backend = PanePresentationTests.Backend()
        let workspace = Workspace(hostId: host, connection: connection, makeBackend: { _ in backend })
        defer { workspace.close() }
        let pane = try Pane(id: PaneId(7), backend: backend, onExit: {})
        client.send(.paneMeta(meta: PaneMeta(
            paneId: 7, title: "private fixture", cwd: "/private/fixture", exit: nil,
            agent: AgentStatus(kind: "claude", state: .idle), size: PaneSize(cols: 80, rows: 24),
            sizePolicy: .lastActive, sizedBy: nil)))
        for _ in 0..<100 where connection.meta[PaneId(7)] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        workspace.updateChatState(of: pane)
        let chat = try XCTUnwrap(pane.chat)
        XCTAssertEqual(chat.presentation, .terminal)
        XCTAssertFalse(chat.show(.chat, terminal: pane))
        XCTAssertEqual(chat.presentation, .terminal)
        XCTAssertEqual(chat.error, "Update the helper to use Chat.")
    }

    func testInputCallbacksReadOnlyTheAdmittedPresentation() throws {
        let input = PaneInputPresentation()
        let first = PaneChatState(member: HostPane(hostId: "first", pane: PaneId(7)), defaultPresentation: .chat,
                                  inputPresentation: input, preferences: try XCTUnwrap(preferences))
        XCTAssertFalse(input.allowsTerminalInput)
        XCTAssertFalse(first.select(.terminal, preparing: { false }))
        XCTAssertFalse(input.allowsTerminalInput)
        XCTAssertTrue(first.select(.terminal, preparing: { true }))
        XCTAssertTrue(input.allowsTerminalInput)
    }

    func testAgentExitRetainsItsDraftAndRestoresThePreferenceForTheNextAgent() throws {
        let first = try state(initial: .terminal)
        first.draft = "Unsent draft"
        XCTAssertTrue(first.select(.chat, preparing: { true }))
        let hub = DaemonWorkspace(hostId: "first", events: WorkspaceEventHub(), resolve: { nil })
        first.activate(in: hub)
        XCTAssertNotNil(first.model)
        first.updateAgent(nil)
        XCTAssertNil(first.model)
        XCTAssertEqual(first.presentation, .terminal)
        XCTAssertEqual(first.draft, "Unsent draft")
        first.updateAgent(.codex)
        XCTAssertEqual(first.presentation, .chat)
        XCTAssertEqual(first.draft, "Unsent draft")
    }

    func testAbsentAgentsCannotAcquireATimelineModel() throws {
        let first = try state()
        first.updateAgent(nil)
        first.activate(in: DaemonWorkspace(hostId: "first", events: WorkspaceEventHub(), resolve: { nil }))
        XCTAssertNil(first.agent)
        XCTAssertNil(first.model)
    }

    func testARecognizedKindDoesNotInventAdapterFeatures() throws {
        let first = try state()
        first.updateAgent(.other)
        first.activate(in: DaemonWorkspace(hostId: "first", events: WorkspaceEventHub(), resolve: { nil }))
        XCTAssertNotNil(first.agent)
        XCTAssertNotNil(first.model)
        XCTAssertEqual(first.capabilities, [])
        first.deactivate()
    }

    func testDraftSurvivesRenderModelEviction() throws {
        let pool = ChatModelPool(capacity: 1)
        let preferences = try XCTUnwrap(preferences)
        let first = PaneChatState(member: HostPane(hostId: "first", pane: PaneId(7)), defaultPresentation: .chat,
                                  agent: .claude, preferences: preferences, pool: pool)
        let second = PaneChatState(member: HostPane(hostId: "first", pane: PaneId(8)), defaultPresentation: .chat,
                                   agent: .claude, preferences: preferences, pool: pool)
        let hub = DaemonWorkspace(hostId: "first", events: WorkspaceEventHub(), resolve: { nil })
        first.draft = "Keep this draft"
        first.activate(in: hub)
        let old = try XCTUnwrap(first.model)
        first.deactivate()
        second.activate(in: hub)
        second.deactivate()
        first.activate(in: hub)
        XCTAssertFalse(first.model === old)
        XCTAssertEqual(first.draft, "Keep this draft")
        first.deactivate()
    }

    func testChoiceIsRememberedOnlyForItsHostAndPane() throws {
        let first = try state()
        XCTAssertTrue(first.select(.terminal, preparing: { true }))
        XCTAssertEqual(try state().presentation, .terminal)
        XCTAssertEqual(try state(host: "second").presentation, .chat)
        XCTAssertEqual(try state(pane: 8).presentation, .chat)
    }

    func testMissingCommandNoticeClearsOnlyAfterAnAdmittedSelectionOrAgentChange() throws {
        let first = try state()
        let backend = PanePresentationTests.Backend()
        let pane = try Pane(id: PaneId(7), backend: backend, onExit: {})
        defer { pane.detach() }
        XCTAssertTrue(first.showTerminal(commandMark: 99, terminal: pane))
        XCTAssertEqual(first.presentation, .terminal)
        XCTAssertEqual(first.terminalNotice, .unavailableCommand(99))
        XCTAssertFalse(first.select(.chat, preparing: { false }))
        XCTAssertEqual(first.terminalNotice, .unavailableCommand(99))
        XCTAssertTrue(first.select(.chat, preparing: { true }))
        XCTAssertNil(first.terminalNotice)
        XCTAssertTrue(first.showTerminal(commandMark: 99, terminal: pane))
        first.updateAgent(.codex)
        XCTAssertNil(first.terminalNotice)
        XCTAssertEqual(backend.state.withLock { $0.resizes }, 0)
        XCTAssertEqual(backend.state.withLock { $0.claims }, 0)
        XCTAssertTrue(backend.state.withLock { $0.input.isEmpty })
    }

    func testACompositionVetoDoesNotChangeOrPersistTheChoice() throws {
        let first = try state(initial: .terminal)
        XCTAssertFalse(first.select(.chat, preparing: { false }))
        XCTAssertEqual(first.presentation, .terminal)
        XCTAssertEqual(try state().presentation, .chat)
    }

    func testInitialParkingVetoKeepsTerminalWithoutChangingTheSavedDefault() throws {
        let first = try state()
        var preparations = 0
        first.prepareInitialPresentation {
            preparations += 1
            return false
        }
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(first.presentation, .terminal)
        XCTAssertEqual(try state().presentation, .chat)
    }

    func testTransientFallbackDoesNotOverwriteAnExplicitPreference() throws {
        let first = try state(initial: .terminal)
        XCTAssertTrue(first.select(.chat, preparing: { true }))
        XCTAssertTrue(first.select(.terminal, persistence: .transient, preparing: { true }))
        XCTAssertEqual(first.presentation, .terminal)
        XCTAssertEqual(try state(initial: .terminal).presentation, .chat)
    }

    func testClosingThePaneForgetsItsUnreachableRenderModel() throws {
        let pool = ChatModelPool(capacity: 1)
        var state: PaneChatState? = PaneChatState(
            member: HostPane(hostId: "first", pane: PaneId(7)), defaultPresentation: .chat,
            agent: .claude, preferences: try XCTUnwrap(preferences), pool: pool)
        let hub = DaemonWorkspace(hostId: "first", events: WorkspaceEventHub(), resolve: { nil })
        state?.activate(in: hub)
        weak let model = state?.model
        XCTAssertNotNil(model)
        state = nil
        XCTAssertNil(model)
    }

    func testDeactivationReleasesItsLeaseAndReactivationReusesTheWarmModel() throws {
        let first = try state()
        let hub = DaemonWorkspace(hostId: "first", events: WorkspaceEventHub(), resolve: { nil })
        first.activate(in: hub)
        let model = try XCTUnwrap(first.model)
        first.deactivate()
        XCTAssertNil(first.model)
        first.activate(in: hub)
        XCTAssertTrue(first.model === model)
        first.deactivate()
    }
}
#endif
