import HostKit
import PaneLayout
import XCTest
@testable import App

/// The sidebar's list while a tab is dragged is the list the drop leaves: rows keep their ids
/// and nothing moves a second time when the stores take the change.
@MainActor
final class ProjectSidebarTests: XCTestCase {
    private var model: WindowModel!

    override func setUp() async throws {
        model = WindowModel(app: .shared)
        model.start()
        DesignFixtures.projects(model)
        XCTAssertEqual(model.projects.map(\.name), ["acme-app", "infra"])
    }

    override func tearDown() async throws {
        model.close()
        for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) }
    }

    private func ids(_ drop: SidebarDrop? = nil) -> [String] {
        model.sidebarItems(drop: drop, projectMove: nil).items.map(\.id)
    }

    func testEveryDropShowsWhatItLeaves() throws {
        let app = try XCTUnwrap(model.projects.first)
        let infra = try XCTUnwrap(model.projects.last)
        let logs = try XCTUnwrap(model.groups.sections.first { $0.container == .host("fixture-studio") }?.rows.first)
        let drops: [SidebarDrop] = [
            .insert(app.tabs[2], into: .project(app.id), at: 0),
            .insert(logs, into: .project(infra.id), at: 1),
            .insert(infra.tabs[0], into: .project(app.id), at: 3),
            .insert(app.tabs[0], into: .host(app.tabs[0].hostId), at: 0),
        ]
        for drop in drops {
            let preview = ids(drop)
            model.commit(drop)
            XCTAssertEqual(ids(), preview, "\(drop)")
        }
    }

    func testGroupingTwoLooseTabsMakesAProjectNamedForThem() throws {
        let loose = model.groups.sections.first { $0.container == .host("fixture-hetzner") }?.rows ?? []
        let target = try XCTUnwrap(model.groups.sections.first { $0.container == .host("fixture-studio") }?.rows.first)
        let dragged = try XCTUnwrap(loose.first)
        // A group drop only lights the target while hovering: the rows stay put.
        XCTAssertEqual(ids(.group(dragged, onto: target)), ids())
        model.commit(.group(dragged, onto: target))
        let made = try XCTUnwrap(model.projects.first { $0.tabs == [target, dragged] })
        XCTAssertEqual(made.name, "New Project")
        // Its name opens for typing at once.
        XCTAssertEqual(model.namingProject, made.id)
        // Its rows lead ⌘-numbers in project order.
        XCTAssertEqual(Array(model.groups.tabs.prefix(5)), model.projects.flatMap(\.tabs).prefix(5).map { $0 })
    }

    /// ⌘T from a project's tab adds to that project, beside it, and shows it; ⌘T anywhere else,
    /// or a host's +, makes a loose tab and never a project.
    func testNewTerminalJoinsAProjectOnlyWhenMadeFromIt() throws {
        let app = try XCTUnwrap(model.projects.first { $0.name == "acme-app" })
        let host = app.tabs[0].hostId
        model.focus(app.tabs[0])
        model.newTab()
        let joined = try XCTUnwrap(model.joinedTab)
        XCTAssertEqual(model.groups.project(app.id)?.tabs, [app.tabs[0], joined] + app.tabs.dropFirst())
        XCTAssertEqual(joined.hostId, host)

        let projects = model.projects.map(\.id)
        model.newTab(onGroup: host)
        let loose = try XCTUnwrap(model.currentTab)
        XCTAssertNil(model.groups.project(of: loose))
        model.newTab()
        XCTAssertNil(model.groups.project(of: try XCTUnwrap(model.currentTab)))
        XCTAssertEqual(model.projects.map(\.id), projects)
        XCTAssertEqual(model.groups.project(app.id)?.tabs.count, app.tabs.count + 1)
    }

    /// New Project: an empty project named in place, a line inviting tabs, never a duplicate name.
    func testNewProjectStartsEmptyAndNamedInPlace() throws {
        model.newEmptyProject()
        let made = try XCTUnwrap(model.projects.last)
        XCTAssertEqual(made.name, "New Project")
        XCTAssertEqual(made.tabs, [])
        XCTAssertEqual(model.namingProject, made.id)
        XCTAssertTrue(ids().contains(SidebarItem.projectEmpty(made.id).id))
        model.newEmptyProject()
        XCTAssertEqual(model.projects.last?.name, "New Project 2")
        model.renameProject(made.id, to: "infra")
        XCTAssertEqual(model.groups.project(made.id)?.name, "infra 2")
    }

    /// The drop says what it will do.
    func testTheDropSaysWhatItWillDo() throws {
        let app = try XCTUnwrap(model.projects.first { $0.name == "acme-app" })
        let loose = model.groups.sections.first { $0.container == .host("fixture-hetzner") }?.rows ?? []
        let logs = try XCTUnwrap(model.groups.sections.first { $0.container == .host("fixture-studio") }?.rows.first)
        XCTAssertEqual(model.groupLabel(logs, onto: app.tabs[1]), "Add to acme-app")
        XCTAssertEqual(model.groupLabel(logs, onto: try XCTUnwrap(loose.first)), "Group")
    }

    /// The iPhone switcher: projects first, as in the sidebar, then each host's other tabs;
    /// every tab once, in ⌘-number order.
    func testSwitcherListsProjectsThenHostsWithEveryTabOnce() throws {
        let sections = model.switcherSections
        let projectIds = model.projects.map(\.id)
        XCTAssertEqual(sections.prefix(projectIds.count).map(\.kind), projectIds.map { .project($0) })
        XCTAssertEqual(sections.dropFirst(projectIds.count).map(\.kind), model.groups.groups.map { .host($0.id) })
        let listed = sections.flatMap(\.tabs)
        XCTAssertEqual(listed, model.groups.tabs)
        XCTAssertEqual(Set(listed).count, listed.count)

        let sidebarOrder = ids().compactMap { id in id.hasPrefix("project/") || id.hasPrefix("host/") ? id : nil }
        let switcherOrder = sections.map { section -> String in
            switch section.kind {
            case .project(let id): SidebarItem.projectHeader(id).id
            case .host(let id): SidebarItem.hostHeader(id).id
            case .window: "window"
            }
        }
        XCTAssertEqual(switcherOrder, sidebarOrder)

        let app = try XCTUnwrap(model.projects.first { $0.name == "acme-app" })
        XCTAssertEqual(model.switcherSubtitle(of: app), "2 hosts · 3 tabs")
        model.newEmptyProject()
        XCTAssertEqual(model.switcherSubtitle(of: try XCTUnwrap(model.projects.last)), "No tabs")
    }

    /// The tab overview closes once a tab is shown or made, and stays while tabs are closed or
    /// moved under it.
    func testShowingATabClosesTheTabOverview() throws {
        let app = try XCTUnwrap(model.projects.first)
        let infra = try XCTUnwrap(model.projects.last)
        model.sheet = .tabs
        model.move(app.tabs[0], toProject: infra.id)
        model.closeTab(app.tabs[1], undoable: false)
        XCTAssertEqual(model.sheet, .tabs)
        model.focus(app.tabs[2])
        XCTAssertNil(model.sheet)

        model.sheet = .tabs
        model.newTab(onGroup: app.tabs[2].hostId)
        XCTAssertNil(model.sheet)

        model.sheet = .settings
        model.focus(app.tabs[0])
        XCTAssertEqual(model.sheet, .settings, "only the overview closes")
    }

    func testMoveTabKeysStayWithinTheSection() throws {
        let app = try XCTUnwrap(model.projects.first)
        model.focus(app.tabs[0])
        model.moveCurrentTab(by: 1)
        XCTAssertEqual(model.projects.first?.tabs[1], app.tabs[0])
        model.moveCurrentTab(by: 5)
        XCTAssertEqual(model.projects.first?.tabs[1], app.tabs[0], "past the end: stays")
    }
}
