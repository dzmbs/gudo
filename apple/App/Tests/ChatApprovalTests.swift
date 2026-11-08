#if os(iOS)
import DesignSystem
import GudoCore
import HostKit
import PaneLayout
import SwiftUI
import UIKit
import XCTest
@testable import App

nonisolated private final class ChatApprovalFixtureClient: FakeWorkspaceClient, DaemonTimelineAPI, @unchecked Sendable {
    func timelineWatch(paneId: UInt64) async throws -> String { try TimelineFixtureJSON.snapshot(0..<12, before: nil) }
    func timelineUnwatch(paneId: UInt64) async throws {}
    func timelineItemsBefore(paneId: UInt64, before: UInt64, limit: UInt16) async throws -> String {
        try TimelineFixtureJSON.snapshot(0..<0, before: nil)
    }
    func timelineToolOutput(paneId: UInt64, handle: String, offset: UInt64, len: UInt32) async throws -> String {
        throw WorkspaceError.Unavailable(message: "No recorded output in this fixture")
    }
}

@MainActor
final class ChatApprovalTests: XCTestCase {
    func testSoloApprovalIsPinnedAboveComposerAndViewerKeepsTheExistingPolicyGate() async throws {
        let client = ChatApprovalFixtureClient()
        let connection = try fakeContext(client).daemon
        let workspace = Workspace(hostId: "h1", connection: connection, makeBackend: { _ in PanePresentationTests.Backend() })
        let backend = PanePresentationTests.Backend()
        let pane = try Pane(id: PaneId(7), backend: backend, appearance: .fromPreferences(), onExit: {})
        let suite = "chat-approval-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let state = PaneChatState(member: HostPane(hostId: "h1", pane: pane.id), defaultPresentation: .chat,
                                  agent: .claude, inputPresentation: pane.inputPresentation,
                                  preferences: preferences, pool: ChatModelPool(capacity: 1))
        state.draft = "Retained phone draft"
        let actor = Actor(principal: "aa", device: "01")
        connection.multiplayer.apply(.joined(info: JoinInfo(actor: actor, name: "Owner", roles: [.owner],
                                                            scope: .daemon, grantId: nil, expiresMs: nil)))
        XCTAssertEqual(SharedApproval(workspace: workspace, session: connection.multiplayer,
                                      pane: 7, placement: .chatComposer).answerers(risk: .any), "You answer")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ThemedRoot {
            PaneChatView(pane: pane, state: state, hub: connection.workspace,
                         approval: SharedApproval(workspace: workspace, session: connection.multiplayer,
                                                  pane: 7, placement: .chatComposer),
                         permitsSending: connection.multiplayer.isOwner) { _ in Color.clear }
        })
        window.isHidden = false
        defer {
            state.deactivate()
            window.isHidden = true
            window.rootViewController = nil
            workspace.close()
            connection.close()
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { state.controller != nil && state.model?.frame.rows.count == 12 }
        let controller = try XCTUnwrap(state.controller)
        try await Task.sleep(for: .milliseconds(100))
        let available = controller.collection.bounds.height
        client.send(.paneMeta(meta: metadata(summary: "Run the private fixture tests", request: 99)))
        try await wait { controller.collection.bounds.height < available - 60 }
        XCTAssertTrue(connection.multiplayer.others.isEmpty)
        XCTAssertEqual(state.draft, "Retained phone draft")
        try capture(window, name: "chat-approval-owner")
        let approval = SharedApproval(workspace: workspace, session: connection.multiplayer, pane: 7, placement: .chatComposer)
        PaneChatView(pane: pane, state: state, hub: connection.workspace, approval: approval,
                     permitsSending: true) { _ in Color.clear }.send()
        try await Task.sleep(for: .milliseconds(30))
        guard state.composer.phase == .idle else { XCTFail("A blocked composer must use signed decisions, not prompt input"); return }
        let allow = DecisionOption(id: 0, label: "Allow once")
        approval.answer(request: 98, option: allow)
        approval.answer(request: 99, option: DecisionOption(id: 0, label: "Different option"))
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("decide ") })
        approval.answer(request: 99, option: allow)
        XCTAssertEqual(client.calls.filter { $0.hasPrefix("decide ") }, ["decide 99 0"])
        connection.multiplayer.apply(.decided(decided: Decided(paneId: 7, requestId: 99, optionId: 0,
                                      decidedBy: actor, atMs: UInt64(Date.now.timeIntervalSince1970 * 1_000))))
        try await wait { abs(controller.collection.bounds.height - available) < 1 }
        approval.answer(request: 99, option: allow)
        XCTAssertEqual(client.calls.filter { $0.hasPrefix("decide ") }, ["decide 99 0"])
        client.send(.paneMeta(meta: metadata(summary: "", request: 100)))
        try await wait { abs(controller.collection.bounds.height - available) < 1 }
        XCTAssertTrue(approval.hasBlockedRequest, "An unstructured question still blocks native prompt input")
        client.send(.paneMeta(meta: metadata(summary: "Another pane's request", request: 888, pane: 8)))
        try await wait { connection.meta[PaneId(8)] != nil }
        XCTAssertEqual(controller.collection.bounds.height, available, accuracy: 1)
        connection.multiplayer.apply(.joined(info: JoinInfo(actor: actor, name: "Viewer", roles: [.viewer],
                                                            scope: .daemon, grantId: "fixture", expiresMs: nil)))
        client.send(.paneMeta(meta: metadata(summary: "Run the private fixture tests", request: 101)))
        try await wait { controller.collection.bounds.height < available - 60 }
        XCTAssertNotNil(connection.multiplayer.approvalBlock(requestId: 101, risk: .any))
        try capture(window, name: "chat-approval-viewer")
        approval.answer(request: 101, option: allow)
        XCTAssertEqual(client.calls.filter { $0.hasPrefix("decide ") }, ["decide 99 0"])
        XCTAssertEqual(state.draft, "Retained phone draft")
        assertHeldPolicies(connection, approval: approval, client: client, actor: actor)
        XCTAssertEqual(backend.state.withLock { $0.resizes }, 0)
        XCTAssertEqual(backend.state.withLock { $0.claims }, 0)
        XCTAssertTrue(backend.state.withLock { $0.input.isEmpty })
    }

    private func assertHeldPolicies(_ connection: DaemonConnection, approval: SharedApproval,
                                    client: ChatApprovalFixtureClient, actor: Actor) {
        let session = connection.multiplayer
        session.apply(.joined(info: JoinInfo(actor: actor, name: "Approver", roles: [.approver],
                                             scope: .daemon, grantId: "fixture", expiresMs: nil)))
        session.apply(.approvalPolicy(sessionId: 1, policy: ApprovalPolicy(mode: .ownerOnly, maxRisk: .any)))
        approval.answer(request: 101, option: DecisionOption(id: 0, label: "Allow once"))
        session.apply(.approvalPolicy(sessionId: 1, policy: ApprovalPolicy(mode: .twoPerson, maxRisk: .any)))
        session.apply(.approvalStatus(status: ApprovalStatus(paneId: 7, requestId: 101, risk: .any,
                      mode: .twoPerson, approvals: [ApprovalVote(actor: actor, name: "Approver", atMs: 1)],
                      needed: 2, claimedBy: nil)))
        XCTAssertTrue(session.approvedAlready(requestId: 101))
        approval.answer(request: 101, option: DecisionOption(id: 0, label: "Allow once"))
        session.apply(.approvalPolicy(sessionId: 1, policy: ApprovalPolicy(mode: .claim, maxRisk: .any)))
        session.apply(.approvalStatus(status: ApprovalStatus(paneId: 7, requestId: 101, risk: .any,
                      mode: .claim, approvals: [], needed: 1,
                      claimedBy: ApprovalVote(actor: Actor(principal: "bb", device: "02"), name: "Reviewer", atMs: 2))))
        XCTAssertNotNil(session.approvalBlock(requestId: 101, risk: .any))
        approval.answer(request: 101, option: DecisionOption(id: 0, label: "Allow once"))
        XCTAssertEqual(client.calls.filter { $0.hasPrefix("decide ") }, ["decide 99 0"])
    }

    private func metadata(summary: String, request: UInt64, pane: UInt64 = 7) -> PaneMeta {
        PaneMeta(paneId: pane, title: "Private fixture", cwd: "/private/fixture", exit: nil,
                 agent: AgentStatus(kind: "claude", state: .blocked(requestId: request, summary: summary,
                       options: [DecisionOption(id: 0, label: "Allow once"), DecisionOption(id: 2, label: "Deny")])),
                 size: PaneSize(cols: 80, rows: 24), sizePolicy: .smallest, sizedBy: nil)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private func capture(_ window: UIWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent(name + ".png"))
    }
}
#endif
