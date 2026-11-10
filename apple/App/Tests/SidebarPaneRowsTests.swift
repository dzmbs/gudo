import HostKit
import PaneLayout
import XCTest
@testable import App

/// A tab opened into its panes lists them as rows of the list itself, so they slide in and out
/// as a project's rows do instead of growing one row.
@MainActor
final class SidebarPaneRowsTests: XCTestCase {
    func testAnOpenedTabListsEachPaneRightAfterItsRow() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        let model = WindowModel(app: .shared)
        model.start()
        defer {
            MockPaneStatus.fixture = nil
            model.close()
        }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        await SidebarFixture.arrangeProjects(model)
        let opened = try XCTUnwrap(model.expandedTabs.first)
        let panes = try XCTUnwrap(model.groups.group(opened.hostId)?.tabs.first { $0.id == opened.tab }?.root.panes)
        XCTAssertEqual(panes.count, 2)

        let items = model.sidebarItems(drop: nil, projectMove: nil, opensPanes: true).items
        let rowIndex = try XCTUnwrap(items.firstIndex { if case .row(opened, _) = $0 { true } else { false } })
        let following = items[(rowIndex + 1)...].prefix(panes.count).compactMap { item -> PaneId? in
            if case .pane(opened, let pane, _) = item { pane } else { nil }
        }
        XCTAssertEqual(following, panes)

        let grouped = model.sidebarItems(drop: nil, projectMove: nil, opensPanes: false).items
        XCTAssertFalse(grouped.contains { if case .pane = $0 { true } else { false } })

        model.expandedTabs.remove(opened)
        let closed = model.sidebarItems(drop: nil, projectMove: nil, opensPanes: true).items
        XCTAssertFalse(closed.contains { if case .pane = $0 { true } else { false } })
    }
}
