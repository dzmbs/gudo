import DesignSystem
import HostKit
import PaneLayout
import XCTest
@testable import App

/// A bell or an agent that needs the user, in a tab out of sight, marks the tab until it is
/// shown; each new call plays the attention beat once.
@MainActor
final class TabAttentionTests: XCTestCase {
    private let first = TabRef(hostId: "local", tab: TabId(1))
    private let second = TabRef(hostId: "local", tab: TabId(2))

    func testARaisedTabWaitsUntilShown() {
        var attention = TabAttention()
        XCTAssertTrue(attention.isEmpty)
        attention.raise(first)
        XCTAssertTrue(attention.contains(first))
        XCTAssertFalse(attention.contains(second))
        attention.shown(first)
        XCTAssertFalse(attention.contains(first))
        XCTAssertTrue(attention.isEmpty)
    }

    func testEachCallIsOneBeatAndShowingItPlaysNone() {
        var attention = TabAttention()
        attention.raise(first)
        attention.raise(first)
        XCTAssertEqual(attention.beat(of: first), 2)
        attention.shown(first)
        XCTAssertEqual(attention.beat(of: first), 2, "clearing never changes the beat, so it plays nothing")
        XCTAssertEqual(attention.beat(of: second), 0)
    }

    func testOnlyATabTurningToNeedYouCalls() {
        let before: [TabRef: AgentState] = [first: .working, second: .blocked]
        let after: [TabRef: AgentState] = [first: .blocked, second: .blocked]
        XCTAssertEqual(TabAttention.newlyBlocked(from: before, to: after), [first])
        XCTAssertEqual(TabAttention.newlyBlocked(from: [:], to: [first: .blocked]), [first])
        XCTAssertEqual(TabAttention.newlyBlocked(from: [first: .blocked], to: [first: .done]), [])
    }

    func testABellInATabOutOfSightMarksItUntilItIsShown() async throws {
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        let backgroundPane = try XCTUnwrap(workspace.focusedPane)
        let background = try XCTUnwrap(model.currentTab)
        model.newTab()
        let shown = try XCTUnwrap(model.currentTab)
        XCTAssertNotEqual(shown, background)

        let pane = try await made(backgroundPane, in: workspace)
        pane.onBell?()
        XCTAssertTrue(model.attention.contains(background), "a bell out of sight marks its tab")

        let shownPane = try await made(try XCTUnwrap(workspace.focusedPane), in: workspace)
        shownPane.onBell?()
        XCTAssertFalse(model.attention.contains(shown), "a bell in the tab on screen is already seen")

        model.focus(background)
        XCTAssertFalse(model.attention.contains(background), "showing the tab clears it")
    }

    func testAnAgentThatTurnsToNeedYouOutOfSightMarksItsTab() async throws {
        let model = WindowModel(app: .shared)
        model.start()
        defer {
            model.close()
            MockPaneStatus.fixture = nil
        }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        let backgroundPane = try XCTUnwrap(workspace.focusedPane)
        let background = try XCTUnwrap(model.currentTab)
        model.newTab()
        MockPaneStatus.fixture = [backgroundPane.description: ("claude", .working)]
        model.noteAgentStates()
        XCTAssertTrue(model.attention.isEmpty)
        MockPaneStatus.fixture = [backgroundPane.description: ("claude", .blocked)]
        model.noteAgentStates()
        XCTAssertTrue(model.attention.contains(background))
    }

    private func made(_ id: PaneId, in workspace: Workspace) async throws -> Pane {
        for _ in 0..<100 where workspace.pane(id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        return try XCTUnwrap(workspace.pane(id))
    }
}
