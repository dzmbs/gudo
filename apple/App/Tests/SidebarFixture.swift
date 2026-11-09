import DesignSystem
import HostKit
import PaneLayout
@testable import App

/// The sidebar's hard cases, for captures on every platform.
@MainActor
enum SidebarFixture {
    /// Two projects, three Claude Codes and a Codex in one, a long name, a project folded away
    /// and an agent that needs the user: the sidebar's hard cases.
    static func arrangeProjects(_ model: WindowModel) async {
        model.isSidebarShown = true
        guard let workspace = model.workspace else { return }
        while workspace.session.tabs.count < 9 { model.newTab() }
        let tabs = workspace.session.tabs
        let rows: [(title: String, program: String, state: AgentState?)] = [
            ("Chat view timeline", "claude", .working),
            ("Release blockers A to D", "codex", .done),
            ("~/Downloads", "zsh", nil),
            ("Pricing page copy", "claude", .blocked),
            ("Refactor the authentication middleware and its session storage", "claude", .working),
            ("Onboarding tests", "claude", nil),
            ("Landing page", "zsh", nil),
            ("Deploy preview", "zsh", nil),
            ("Scratch", "zsh", nil),
        ]
        var fixture: [String: (program: String, state: AgentState?)] = [:]
        for (tab, row) in zip(tabs, rows) {
            workspace.apply(.rename(tab.id, row.title))
            for pane in tab.root.panes { fixture[pane.description] = (row.program, row.state) }
        }
        MockPaneStatus.fixture = fixture
        let refs = tabs.map { TabRef(hostId: model.groups.groups.first?.id ?? HostGroups.localId, tab: $0.id) }
        model.newProject(from: Array(refs[0..<3]), name: "Gudo", naming: false)
        model.newProject(from: Array(refs[3..<6]), name: "ascend", naming: false)
        model.newProject(from: Array(refs[6..<8]), name: "website", naming: false)
        if let website = model.groups.projects.first(where: { $0.name == "website" }) {
            model.groups.toggleCollapsed(project: website.id)
        }
        model.focus(refs[0])
    }

}
