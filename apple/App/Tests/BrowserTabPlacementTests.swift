#if os(macOS)
import HostKit
import PaneLayout
import XCTest
@testable import App

/// A browser opens as a tab of its own, in the project of the tab it was opened from, and
/// leaves that tab's panes as they were. Open Browser Beside is in `SplitWebLeavesTests`.
@MainActor
final class BrowserTabPlacementTests: XCTestCase {
    private var model: WindowModel!
    private var workspace: Workspace!
    private var terminal: TabRef!
    private var projectId: String?

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        model = WindowModel(app: .shared)
        model.start()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        workspace = try XCTUnwrap(model.workspace)
        // A tab of its own: the local workspace is shared by every test in the process.
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        let opened = try XCTUnwrap(workspace.session.tabs.first { !before.contains($0.id) })
        terminal = TabRef(hostId: workspace.groupId, tab: opened.id)
        for _ in 0..<20 where workspace.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        model.focus(terminal)
    }

    override func tearDown() async throws {
        guard let model else { return }
        if let projectId { model.ungroupProject(projectId) }
        for tab in model.composites.tabs { model.closeMixedTab(tab.id) }
        if let terminal { workspace?.apply(.closeTab(terminal.tab)) }
        model.close()
    }

    private var terminalPanes: [PaneId] {
        workspace.session.tabs.first { $0.id == terminal.tab }?.root.panes ?? []
    }

    func testNewBrowserTabJoinsTheProjectAndAddsNoPane() throws {
        model.newProject(from: [terminal], name: "Browser Tab Placement", naming: false)
        let project = try XCTUnwrap(model.groups.project(of: terminal))
        projectId = project.id
        let panesBefore = terminalPanes
        XCTAssertEqual(panesBefore.count, 1)

        WorkspaceAction.newBrowserTab.perform(on: workspace, window: model)

        let browserTab = try XCTUnwrap(model.activeMixed, "the browser tab comes forward")
        XCTAssertTrue(browserTab.isBrowserOnly, "a tab of its own")
        XCTAssertEqual(browserTab.leaves.count, 1)
        XCTAssertEqual(model.composites.tabs.count, 1, "the terminal's tab is not made a split")
        XCTAssertEqual(terminalPanes, panesBefore, "no pane opens in the terminal's tab")
        let browserRef = WindowModel.mixedRef(browserTab.id)
        XCTAssertEqual(model.groups.project(project.id)?.tabs, [terminal, browserRef], "right after the tab it came from, in its project")
    }

    func testNewBrowserTabOutsideAProjectStaysLoose() throws {
        WorkspaceAction.newBrowserTab.perform(on: workspace, window: model)
        let browserTab = try XCTUnwrap(model.activeMixed)
        XCTAssertTrue(browserTab.isBrowserOnly)
        XCTAssertNil(model.groups.project(of: WindowModel.mixedRef(browserTab.id)))
    }
}
#endif
