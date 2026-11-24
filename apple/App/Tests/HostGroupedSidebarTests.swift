import HostKit
import PaneLayout
import XCTest
@testable import App

/// With more than one host the sidebar groups everything by host: each host's header, then its
/// tabs and its part of each project a level in. With one host the list stays flat.
@MainActor
final class HostGroupedSidebarTests: XCTestCase {
    private var model: WindowModel!
    private let fixtureHosts = ["fixture-studio", "fixture-hetzner", "fixture-box"]

    override func setUp() async throws {
        model = WindowModel(app: .shared)
        model.start()
    }

    override func tearDown() async throws {
        for project in model.projects { model.ungroupProject(project.id) }
        model.close()
        for id in fixtureHosts { AppModel.shared.hosts.disconnect(id) }
    }

    private var items: [SidebarItem] { model.sidebarItems(drop: nil, projectMove: nil).items }

    private var rows: [TabRef] {
        items.compactMap { if case .row(let ref, _) = $0 { ref } else { nil } }
    }

    private func ref(_ host: String, _ title: String) throws -> TabRef {
        let group = try XCTUnwrap(model.groups.group(host))
        return group.ref(try XCTUnwrap(group.tabs.first { $0.title == title }).id)
    }

    // MARK: One host

    func testOneHostKeepsTheFlatList() throws {
        XCTAssertEqual(model.groups.groups.count, 1, "the mock window starts on one host")
        while model.groups.tabs.count < 3 { model.newTab() }
        let tabs = model.groups.tabs
        model.newProject(from: Array(tabs.prefix(2)), name: "solo", naming: false)
        let project = try XCTUnwrap(model.projects.first { $0.name == "solo" })
        let host = try XCTUnwrap(model.groups.groups.first)

        XCTAssertFalse(model.groups.groupsByHost)
        XCTAssertEqual(model.groups.places(of: project.id), [ProjectPlace(project.id)])
        let ids = items.map(\.id)
        let header = try XCTUnwrap(ids.firstIndex(of: "project/\(project.id)"))
        let hostHeader = try XCTUnwrap(ids.firstIndex(of: "host/\(host.id)"))
        XCTAssertLessThan(header, hostHeader, "projects lead, as they always have")
        XCTAssertFalse(ids.contains { $0.hasPrefix("project/\(host.id)/") }, "no project is drawn per host")
        XCTAssertEqual(model.groups.sections.first?.container, .project(project.id))
    }

    // MARK: Several hosts

    func testEachHostHeadsItsOwnTabsAndProjects() throws {
        DesignFixtures.projects(model)
        XCTAssertTrue(model.groups.groupsByHost)
        let hosts = items.compactMap { if case .hostHeader(let id) = $0 { id } else { nil } }
        XCTAssertEqual(hosts, model.groups.groups.map(\.id))
        XCTAssertEqual(hosts.suffix(3), ["fixture-box", "fixture-hetzner", "fixture-studio"], "the rest by name")
        #if os(macOS)
        XCTAssertEqual(hosts.first, HostGroups.localId, "This Mac first")
        #endif

        // Every line after a host's header is that host's, until the next header.
        var current: String?
        for item in items {
            if case .hostHeader(let id) = item {
                current = id
            } else if let current {
                XCTAssertEqual(item.hostSection, current, item.id)
                XCTAssertTrue(item.isUnderHost)
            }
        }
        XCTAssertNotNil(current)

        // A host's own tabs come first, then its part of each project.
        let logs = try ref("fixture-studio", "logs")
        let app = try XCTUnwrap(model.projects.first { $0.name == "acme-app" })
        let ids = items.map(\.id)
        let studio = try XCTUnwrap(ids.firstIndex(of: "host/fixture-studio"))
        let logsRow = try XCTUnwrap(ids.firstIndex(of: "tab/\(logs)"))
        let appOnStudio = try XCTUnwrap(ids.firstIndex(of: SidebarItem.projectHeader(ProjectPlace(app.id, on: "fixture-studio")).id))
        XCTAssertLessThan(studio, logsRow)
        XCTAssertLessThan(logsRow, appOnStudio)

        // ⌘-numbers and the next and previous tab walk the rows as drawn.
        XCTAssertEqual(model.groups.tabs, rows)
        XCTAssertEqual(model.groups.tab(forShortcut: 1), rows.first)
        XCTAssertEqual(model.groups.tab(after: rows[0], offset: 1), rows[1])
    }

    /// A project with tabs on two hosts (the same folder on each) is two groups, one under each
    /// host, each folding on its own.
    func testAProjectOnTwoHostsIsTwoGroups() throws {
        DesignFixtures.projects(model)
        let app = try XCTUnwrap(model.projects.first { $0.name == "acme-app" })
        let onStudio = ProjectPlace(app.id, on: "fixture-studio"), onHetzner = ProjectPlace(app.id, on: "fixture-hetzner")
        XCTAssertEqual(model.groups.places(of: app.id), [onHetzner, onStudio])
        XCTAssertTrue(items.contains(.projectHeader(onStudio)))
        XCTAssertTrue(items.contains(.projectHeader(onHetzner)))
        XCTAssertFalse(items.contains(.projectHeader(ProjectPlace(app.id))))
        XCTAssertEqual(model.groups.rows(of: onStudio), [try ref("fixture-studio", "api-server"), try ref("fixture-studio", "claude")])
        XCTAssertEqual(model.groups.rows(of: onHetzner), [try ref("fixture-hetzner", "web")])

        model.groups.toggleCollapsed(onStudio)
        XCTAssertFalse(rows.contains(try ref("fixture-studio", "claude")))
        XCTAssertTrue(rows.contains(try ref("fixture-hetzner", "web")), "the other host's part stays open")
        XCTAssertTrue(model.groups.projectsState.collapsed.contains(onStudio.foldKey), "kept with the window")

        // Showing a folded row (closing the tab before it) opens its part only.
        model.groups.showRow(try ref("fixture-studio", "claude"))
        XCTAssertTrue(rows.contains(try ref("fixture-studio", "claude")))
        XCTAssertFalse(model.groups.isCollapsed(onStudio))

        // Under one host, Ungroup and Close All Tabs act on that host's part.
        model.ungroup(onHetzner)
        XCTAssertEqual(model.groups.project(app.id)?.tabs, model.groups.rows(of: onStudio))
        XCTAssertFalse(items.contains(.projectHeader(onHetzner)))
    }

    /// A project's + under a host opens on that host and joins that host's part.
    func testNewTerminalInAProjectUnderAHostOpensOnThatHost() throws {
        DesignFixtures.projects(model)
        let app = try XCTUnwrap(model.projects.first { $0.name == "acme-app" })
        model.focus(try ref("fixture-studio", "claude"))
        model.newTab(inProject: app.id, on: "fixture-hetzner")
        let joined = try XCTUnwrap(model.joinedTab)
        XCTAssertEqual(joined.hostId, "fixture-hetzner")
        XCTAssertEqual(model.groups.rows(of: ProjectPlace(app.id, on: "fixture-hetzner")), [try ref("fixture-hetzner", "web"), joined])
    }

    func testFoldingAHostHidesAllItsLinesAndIsRemembered() throws {
        DesignFixtures.projects(model)
        model.groups.toggleCollapsed("fixture-studio")
        let studio = items.filter { $0.hostSection == "fixture-studio" }
        XCTAssertEqual(studio, [.hostHeader("fixture-studio")])
        XCTAssertFalse(model.groups.isRowShown(try ref("fixture-studio", "claude")), "its projects' rows fold with it")
        XCTAssertTrue(model.groups.isRowShown(try ref("fixture-hetzner", "web")))

        let restored = WindowModel(app: .shared)
        restored.start()
        defer { restored.close() }
        restored.restore(openHosts: fixtureHosts, collapsed: ["fixture-studio", HostGroups.localId], focus: nil)
        XCTAssertTrue(restored.groups.collapsed.contains("fixture-studio"))
        #if os(macOS)
        XCTAssertTrue(restored.groups.collapsed.contains(HostGroups.localId), "This Mac's fold is kept too")
        #endif
    }

    /// A host that is down keeps its section and its last known projects, dimmed, its state
    /// in words beside its name.
    func testAnOfflineHostKeepsItsSectionWithWords() throws {
        DesignFixtures.projects(model)
        let before = items.filter { $0.hostSection == "fixture-hetzner" }
        let connection = try XCTUnwrap(model.app.hosts.connection("fixture-hetzner") as? PreviewConnection)
        connection.status = .offline(reason: "no route")
        let group = try XCTUnwrap(model.groups.group("fixture-hetzner"))
        XCTAssertFalse(group.showsAsLive)
        XCTAssertEqual(group.awayWords, "Offline")
        XCTAssertEqual(items.filter { $0.hostSection == "fixture-hetzner" }, before, "nothing vanishes")
        connection.status = .reconnecting(attempt: 2, reason: "lost")
        XCTAssertEqual(model.groups.group("fixture-hetzner")?.awayWords, "Reconnecting…")
        connection.status = .connected(rtt: nil)
        XCTAssertNil(model.groups.group("fixture-hetzner")?.awayWords)
    }

    /// The drop a project's header takes from another host's tab joins the project under that
    /// tab's own host; what the drag shows is what the drop leaves.
    func testDroppingAnotherHostsTabOnAProjectJoinsItUnderItsOwnHost() throws {
        DesignFixtures.projects(model)
        let infra = try XCTUnwrap(model.projects.first { $0.name == "infra" })
        let logs = try ref("fixture-studio", "logs")
        let drop = SidebarDrop.insert(logs, into: .hostProject(host: "fixture-studio", project: infra.id), at: 0)
        let preview = model.sidebarItems(drop: drop, projectMove: nil).items.map(\.id)
        model.commit(drop)
        XCTAssertEqual(items.map(\.id), preview)
        XCTAssertEqual(model.groups.rows(of: ProjectPlace(infra.id, on: "fixture-studio")), [logs])
    }

    func testProjectHeadersSayWhichHostTheyAreOn() {
        XCTAssertEqual(ProjectHeaderLabel.spoken("acme-app", host: "studio", tabs: 2), "acme-app, on studio, project, 2 tabs")
        XCTAssertEqual(ProjectHeaderLabel.spoken("acme-app", host: nil, tabs: 1), "acme-app, project, 1 tab")
    }
}
