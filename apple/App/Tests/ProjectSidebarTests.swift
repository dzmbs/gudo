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
        XCTAssertTrue(made.name.hasPrefix("Project"), made.name)
        // Its rows lead ⌘-numbers in project order.
        XCTAssertEqual(Array(model.groups.tabs.prefix(5)), model.projects.flatMap(\.tabs).prefix(5).map { $0 })
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
