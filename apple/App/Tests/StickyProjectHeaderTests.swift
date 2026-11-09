import HostKit
import PaneLayout
import XCTest
@testable import App

@MainActor
final class StickyProjectHeaderTests: XCTestCase {
    private func geometry(_ entries: [(SidebarItem, CGRect)]) -> SidebarGeometry {
        let geometry = SidebarGeometry()
        for (item, frame) in entries {
            geometry.items[item.id] = item
            geometry.frames[item.id] = frame
        }
        return geometry
    }

    private func row(_ tab: Int, in project: String) -> SidebarItem {
        .row(TabRef(hostId: "local", tab: TabId(UInt64(tab))), .project(project))
    }

    func testAProjectScrolledUnderTheTopPinsItsHeader() throws {
        let list = geometry([
            (.projectHeader("a"), CGRect(x: 0, y: 10, width: 260, height: 46)),
            (row(1, in: "a"), CGRect(x: 0, y: 56, width: 260, height: 40)),
            (row(2, in: "a"), CGRect(x: 0, y: 96, width: 260, height: 40)),
            (.projectHeader("b"), CGRect(x: 0, y: 300, width: 260, height: 46)),
        ])
        let pinned = try XCTUnwrap(StickyProjectHeader.pinned(in: list, top: 52, height: 46))
        XCTAssertEqual(pinned.project, "a")
        XCTAssertEqual(pinned.offset, 0)
    }

    func testTheNextHeaderPushesItUp() throws {
        let list = geometry([
            (.projectHeader("a"), CGRect(x: 0, y: -100, width: 260, height: 46)),
            (row(1, in: "a"), CGRect(x: 0, y: -54, width: 260, height: 40)),
            (row(2, in: "a"), CGRect(x: 0, y: 70, width: 260, height: 40)),
            (.projectHeader("b"), CGRect(x: 0, y: 80, width: 260, height: 46)),
        ])
        let pinned = try XCTUnwrap(StickyProjectHeader.pinned(in: list, top: 52, height: 46))
        XCTAssertEqual(pinned.project, "a")
        XCTAssertEqual(pinned.offset, -18)
    }

    func testNothingPinsWhileTheHeaderIsInViewOrItsRowsAreGone() {
        let inView = geometry([
            (.projectHeader("a"), CGRect(x: 0, y: 60, width: 260, height: 46)),
            (row(1, in: "a"), CGRect(x: 0, y: 106, width: 260, height: 40)),
        ])
        XCTAssertNil(StickyProjectHeader.pinned(in: inView, top: 52, height: 46))
        let scrolledAway = geometry([
            (.projectHeader("a"), CGRect(x: 0, y: -200, width: 260, height: 46)),
            (row(1, in: "a"), CGRect(x: 0, y: -154, width: 260, height: 40)),
        ])
        XCTAssertNil(StickyProjectHeader.pinned(in: scrolledAway, top: 52, height: 46))
    }
}
