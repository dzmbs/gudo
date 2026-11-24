import HostKit
import PaneLayout
import XCTest
@testable import App

@MainActor
final class StickyProjectHeaderTests: XCTestCase {
    private func geometry(_ entries: [(SidebarItem, CGRect?)]) -> SidebarGeometry {
        let geometry = SidebarGeometry()
        for (item, frame) in entries {
            geometry.items[item.id] = item
            geometry.order.append(item.id)
            geometry.frames[item.id] = frame
        }
        return geometry
    }

    private func row(_ tab: Int, in project: String) -> SidebarItem {
        .row(TabRef(hostId: "local", tab: TabId(UInt64(tab))), .project(project))
    }

    func testAProjectScrolledUnderTheTopPinsItsHeader() throws {
        let list = geometry([
            (.projectHeader(ProjectPlace("a")), CGRect(x: 0, y: 10, width: 260, height: 46)),
            (row(1, in: "a"), CGRect(x: 0, y: 56, width: 260, height: 40)),
            (row(2, in: "a"), CGRect(x: 0, y: 96, width: 260, height: 40)),
            (.projectHeader(ProjectPlace("b")), CGRect(x: 0, y: 300, width: 260, height: 46)),
        ])
        let pinned = try XCTUnwrap(StickyProjectHeader.pinned(in: list, top: 52, height: 46))
        XCTAssertEqual(pinned.project, ProjectPlace("a"))
        XCTAssertEqual(pinned.offset, 0)
    }

    func testTheEndOfItsRowsPushesItUp() throws {
        let list = geometry([
            (.projectHeader(ProjectPlace("a")), CGRect(x: 0, y: -60, width: 260, height: 46)),
            (row(1, in: "a"), CGRect(x: 0, y: -14, width: 260, height: 40)),
            (row(2, in: "a"), CGRect(x: 0, y: 26, width: 260, height: 40)),
            (.projectHeader(ProjectPlace("b")), CGRect(x: 0, y: 66, width: 260, height: 46)),
        ])
        let pinned = try XCTUnwrap(StickyProjectHeader.pinned(in: list, top: 52, height: 46))
        XCTAssertEqual(pinned.project, ProjectPlace("a"))
        XCTAssertEqual(pinned.offset, -32)
    }

    /// The list lets go of a header scrolled far away, and of rows it has not laid out yet.
    func testItStaysPinnedOnceTheListLetsGoOfItsHeader() throws {
        let list = geometry([
            (.projectHeader(ProjectPlace("a")), nil),
            (row(1, in: "a"), nil),
            (row(2, in: "a"), CGRect(x: 0, y: 30, width: 260, height: 40)),
            (row(3, in: "a"), CGRect(x: 0, y: 70, width: 260, height: 40)),
            (row(4, in: "a"), nil),
        ])
        let pinned = try XCTUnwrap(StickyProjectHeader.pinned(in: list, top: 52, height: 46))
        XCTAssertEqual(pinned.project, ProjectPlace("a"))
        XCTAssertEqual(pinned.offset, 0, "rows still to come keep it at the edge")

        let crossing = geometry([
            (.projectHeader(ProjectPlace("a")), nil),
            (row(1, in: "a"), nil),
            (row(2, in: "a"), CGRect(x: 0, y: 60, width: 260, height: 40)),
        ])
        XCTAssertEqual(StickyProjectHeader.pinned(in: crossing, top: 52, height: 46)?.project, ProjectPlace("a"), "the row under the edge is let go of too")
    }

    func testNothingPinsWhileTheHeaderIsInViewOrItsRowsAreGone() {
        let inView = geometry([
            (.projectHeader(ProjectPlace("a")), CGRect(x: 0, y: 60, width: 260, height: 46)),
            (row(1, in: "a"), CGRect(x: 0, y: 106, width: 260, height: 40)),
        ])
        XCTAssertNil(StickyProjectHeader.pinned(in: inView, top: 52, height: 46))
        let scrolledAway = geometry([
            (.projectHeader(ProjectPlace("a")), CGRect(x: 0, y: -200, width: 260, height: 46)),
            (row(1, in: "a"), CGRect(x: 0, y: -154, width: 260, height: 40)),
        ])
        XCTAssertNil(StickyProjectHeader.pinned(in: scrolledAway, top: 52, height: 46))
    }

    // MARK: Grouped by host

    private func hostRow(_ tab: Int, on host: String, in project: String? = nil) -> SidebarItem {
        let ref = TabRef(hostId: host, tab: TabId(UInt64(tab)))
        return .row(ref, project.map { .hostProject(host: host, project: $0) } ?? .host(host))
    }

    /// Two hosts, each with a loose tab and a project of two tabs: frames 40 high from y 0.
    private func twoHosts(scrolledBy offset: CGFloat) -> SidebarGeometry {
        let entries: [SidebarItem] = [
            .hostHeader("a"), hostRow(1, on: "a"), .projectHeader(ProjectPlace("p", on: "a")), hostRow(2, on: "a", in: "p"),
            hostRow(3, on: "a", in: "p"),
            .hostHeader("b"), hostRow(1, on: "b"), .projectHeader(ProjectPlace("p", on: "b")), hostRow(2, on: "b", in: "p"),
            hostRow(3, on: "b", in: "p"),
        ]
        let list = geometry(entries.enumerated().map { ($1, CGRect(x: 0, y: CGFloat($0) * 40 - offset, width: 260, height: 40)) })
        list.pinsHosts = true
        return list
    }

    func testAHostsHeaderPinsOverItsSectionAndItsProjectUnderIt() throws {
        // The edge at the top of a's project's first row.
        let list = twoHosts(scrolledBy: 120)
        let host = try XCTUnwrap(StickyProjectHeader.pinnedHost(in: list, top: 0, height: 40))
        XCTAssertEqual(host.host, "a")
        XCTAssertEqual(host.offset, 0)
        let project = try XCTUnwrap(StickyProjectHeader.pinned(in: list, top: 40, height: 40))
        XCTAssertEqual(project.project, ProjectPlace("p", on: "a"), "the same project on another host is another group")
        XCTAssertEqual(project.offset, 0)
    }

    func testTheEndOfAHostsSectionPushesItsHeadersUpInTurn() throws {
        // a's section ends 50 under the edge: its project's header slides under the host's.
        let list = twoHosts(scrolledBy: 150)
        let host = try XCTUnwrap(StickyProjectHeader.pinnedHost(in: list, top: 0, height: 40))
        XCTAssertEqual(host.host, "a")
        XCTAssertEqual(host.offset, 0)
        let project = try XCTUnwrap(StickyProjectHeader.pinned(in: list, top: 40, height: 40))
        XCTAssertEqual(project.project, ProjectPlace("p", on: "a"))
        XCTAssertEqual(project.offset, -30)

        // Then b's header pushes a's up, the project's already gone under it.
        let pushed = twoHosts(scrolledBy: 165)
        let pushedHost = try XCTUnwrap(StickyProjectHeader.pinnedHost(in: pushed, top: 0, height: 40))
        XCTAssertEqual(pushedHost.host, "a")
        XCTAssertEqual(pushedHost.offset, -5)
        XCTAssertNil(StickyProjectHeader.pinned(in: pushed, top: 35, height: 40))

        // Past the boundary, b takes over.
        let next = twoHosts(scrolledBy: 210)
        XCTAssertEqual(StickyProjectHeader.pinnedHost(in: next, top: 0, height: 40)?.host, "b")
        XCTAssertNil(StickyProjectHeader.pinned(in: next, top: 40, height: 40), "b's own tab is under its header, no project yet")
    }
}
