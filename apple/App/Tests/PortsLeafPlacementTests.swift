#if os(macOS)
import PaneLayout
import XCTest
@testable import App

/// A page opened from a Ports leaf goes beside that leaf, whichever leaf had the focus; one
/// opened from elsewhere (the offer, a pane's link) goes beside the focused leaf.
@MainActor
final class PortsLeafPlacementTests: XCTestCase {
    private var model: WindowModel!
    private var openedTab: (workspace: Workspace, tab: TabId)?

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        model = WindowModel(app: .shared)
        model.start()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        // A tab of its own: the local workspace is shared by every test in the process.
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        openedTab = workspace.session.tabs.first { !before.contains($0.id) }.map { (workspace, $0.id) }
        for _ in 0..<20 where workspace.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
    }

    override func tearDown() async throws {
        guard let model else { return }
        for tab in model.composites.tabs { model.closeMixedTab(tab.id) }
        if let openedTab { openedTab.workspace.apply(.closeTab(openedTab.tab)) }
        model.close()
    }

    func testAPageFromPortsOpensBesideThePortsLeaf() throws {
        let ports = model.openToolLeaf(.ports)
        var tab = try XCTUnwrap(model.activeMixed)
        let portsLeaf = try XCTUnwrap(tab.leaf(forTool: ports.id))
        let terminal = try XCTUnwrap(tab.leaves.first { $0 != portsLeaf })
        // The terminal has the focus, as after typing in it.
        model.focusLeaf(terminal, inMixedTab: tab.id)

        model.openPage(URL(string: "http://localhost:5173")!, hostId: nil, besideTool: ports.id)
        tab = try XCTUnwrap(model.activeMixed)
        let page = try XCTUnwrap(tab.leaves.first { tab.browsers[$0] != nil })
        XCTAssertEqual(tab.leaves, [terminal, portsLeaf, page], "right of Ports, not between the terminal and Ports")

        // From elsewhere: beside the focused leaf.
        model.focusLeaf(terminal, inMixedTab: tab.id)
        model.openPage(URL(string: "http://localhost:3000")!, hostId: nil)
        tab = try XCTUnwrap(model.activeMixed)
        XCTAssertEqual(tab.leaves.count, 4)
        XCTAssertNotNil(tab.browsers[tab.leaves[1]], "the second page beside the terminal")
    }
}
#endif
