#if os(macOS)
import HostKit
import PaneLayout
import XCTest
@testable import App

/// Pages agents and hosts open beside a pane: the tab they land in keeps its place (its project
/// and position, its host section), and the user's tab, focus and sheet stay as they were.
@MainActor
final class AgentBrowserPlacementTests: XCTestCase {
    private var model: WindowModel!
    private var workspace: Workspace!
    private var opened: [TabRef] = []
    private var projectId: String?

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        model = WindowModel(app: .shared)
        model.start()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        workspace = try XCTUnwrap(model.workspace)
    }

    override func tearDown() async throws {
        guard let model else { return }
        if let projectId { model.ungroupProject(projectId) }
        for tab in model.composites.tabs { model.closeMixedTab(tab.id) }
        for ref in opened { workspace?.apply(.closeTab(ref.tab)) }
        model.close()
    }

    /// A tab of its own: the local workspace is shared by every test in the process.
    private func newTab() async throws -> TabRef {
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        let tab = try XCTUnwrap(workspace.session.tabs.first { !before.contains($0.id) })
        for _ in 0..<20 where workspace.session.tabs.first(where: { $0.id == tab.id })?.root.panes.isEmpty != false {
            try await Task.sleep(for: .milliseconds(100))
        }
        let ref = TabRef(hostId: workspace.groupId, tab: tab.id)
        opened.append(ref)
        return ref
    }

    private func pane(of ref: TabRef) throws -> HostPane {
        let tab = try XCTUnwrap(workspace.session.tabs.first { $0.id == ref.tab })
        return HostPane(hostId: ref.hostId, pane: try XCTUnwrap(tab.root.panes.first))
    }

    private func project(_ refs: [TabRef]) throws -> Project {
        model.newProject(from: refs, name: "Agent Browser Placement", naming: false)
        let project = try XCTUnwrap(model.groups.project(of: refs[0]))
        projectId = project.id
        return project
    }

    private var hostRows: [TabRef] {
        model.groups.sections.first { $0.container == .host(workspace.groupId) }?.rows ?? []
    }

    func testAnAgentsPageBesideABackgroundTabKeepsTheTabInItsProjectAndTheUsersTab() async throws {
        let first = try await newTab()
        let agentTab = try await newTab()
        let userTab = try await newTab()
        let project = try project([first, agentTab, userTab])
        model.focus(userTab)
        let userPane = workspace.focusedPane
        let agent = try pane(of: agentTab)

        let page = model.openBrowser(URL(string: "about:blank")!, beside: agent)

        XCTAssertEqual(model.currentTab, userTab, "the user's tab stays on screen")
        XCTAssertEqual(workspace.focusedPane, userPane, "the user's pane keeps the keyboard")
        let mixed = try XCTUnwrap(model.composites.tab(containingBrowser: page.id))
        let mixedRef = WindowModel.mixedRef(mixed.id)
        XCTAssertEqual(mixed.focusedMember, agent, "the agent's tab keeps its focused pane")
        XCTAssertEqual(model.groups.project(project.id)?.tabs, [first, mixedRef, userTab], "in the agent tab's place in its project")
        XCTAssertTrue(model.changedTabs.contains(mixedRef), "its row marks the change")
        XCTAssertFalse(model.groups.sections.first { $0.container == .window }?.rows.contains(mixedRef) ?? false, "never under Mixed")
    }

    func testAHostsPageBesideABackgroundTabLeavesTheUsersTabAlone() async throws {
        let agentTab = try await newTab()
        let userTab = try await newTab()
        model.focus(userTab)
        let agent = try pane(of: agentTab)

        model.openFromHost(URL(string: "https://example.com/")!, hostId: agent.hostId, pane: agent.pane.rawValue)

        XCTAssertEqual(model.currentTab, userTab)
        XCTAssertNil(model.sheet)
        let mixed = try XCTUnwrap(model.composites.tab(containing: agent))
        XCTAssertEqual(mixed.focusedMember, agent)
    }

    func testAnAgentsPageBesideTheTabTheUserIsOnKeepsTheirKeyboard() async throws {
        let before = try await newTab()
        let agentTab = try await newTab()
        let after = try await newTab()
        model.focus(agentTab)
        let agent = try pane(of: agentTab)
        let index = try XCTUnwrap(hostRows.firstIndex(of: agentTab))

        let page = model.openBrowser(URL(string: "about:blank")!, beside: agent)

        let mixed = try XCTUnwrap(model.composites.tab(containingBrowser: page.id))
        let mixedRef = WindowModel.mixedRef(mixed.id)
        XCTAssertEqual(model.currentTab, mixedRef, "the user's view stays on the tab, now with the page")
        XCTAssertEqual(model.activeMixed?.focusedMember, agent, "the terminal keeps the keyboard")
        XCTAssertFalse(model.changedTabs.contains(mixedRef), "the user sees it change")
        XCTAssertEqual(hostRows.firstIndex(of: mixedRef), index, "listed where the tab was, under its host")
        XCTAssertTrue(hostRows.contains(before) && hostRows.contains(after))
        XCTAssertFalse(model.groups.sections.first { $0.container == .window }?.rows.contains(mixedRef) ?? false, "never under Mixed")
    }

    func testAnAgentsPageForAPaneInNoTabLeavesTheUsersTabAlone() async throws {
        let userTab = try await newTab()
        model.focus(userTab)

        model.openBrowser(URL(string: "about:blank")!, beside: HostPane(hostId: workspace.groupId, pane: PaneId(999_999)))

        XCTAssertEqual(model.currentTab, userTab)
    }

    func testAToolBesideATabInAProjectKeepsItsPlace() async throws {
        let first = try await newTab()
        let toolTab = try await newTab()
        let last = try await newTab()
        let project = try project([first, toolTab, last])
        model.focus(toolTab)

        model.openToolLeaf(.files)

        let mixed = try XCTUnwrap(model.activeMixed)
        XCTAssertEqual(model.groups.project(project.id)?.tabs, [first, WindowModel.mixedRef(mixed.id), last])
    }
}
#endif
