import PaneLayout
import XCTest
@testable import App

/// File ▸ Close Tab (⌥⌘W) closes the tab on screen, whatever it holds.
@MainActor
final class CloseTabTests: XCTestCase {
    func testCloseTabClosesTheTerminalTabOnScreen() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        let opened = try XCTUnwrap(workspace.session.tabs.first { !before.contains($0.id) })
        XCTAssertEqual(model.currentTab?.tab, opened.id)

        model.closeCurrentTab()
        XCTAssertFalse(workspace.session.tabs.contains { $0.id == opened.id }, "the tab on screen closed")
        XCTAssertEqual(Set(workspace.session.tabs.map(\.id)), before)
    }

    func testCloseTabClosesAMixedTab() throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        let id = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        model.activeMixedTab = id
        XCTAssertEqual(model.currentTab, WindowModel.mixedRef(id))
        model.closeCurrentTab()
        XCTAssertNil(model.composites.tab(id))
    }
}
