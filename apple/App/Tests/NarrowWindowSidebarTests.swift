import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// A window too narrow for the sidebar and the terminal hides the sidebar, and shows it again once
/// it is wide enough, unless the user chose meanwhile.
@MainActor
final class NarrowWindowSidebarTests: XCTestCase {
    func testNarrowingHidesTheSidebarAndWideningBringsItBack() {
        var fit = SidebarWidthFit()
        XCTAssertNil(fit.widthChanged(to: 1200, isShown: true))
        XCTAssertEqual(fit.widthChanged(to: SidebarWidthFit.hideBelow - 1, isShown: true), false)
        XCTAssertNil(fit.widthChanged(to: SidebarWidthFit.hideBelow + 1, isShown: false), "no flicker at the edge")
        XCTAssertEqual(fit.widthChanged(to: SidebarWidthFit.showFrom, isShown: false), true)
    }

    func testASidebarTheUserHidStaysHiddenWhenTheWindowWidens() {
        var fit = SidebarWidthFit()
        XCTAssertNil(fit.widthChanged(to: 700, isShown: false))
        XCTAssertNil(fit.widthChanged(to: 1400, isShown: false))
    }

    func testTheUsersChoiceWhileNarrowWins() {
        var fit = SidebarWidthFit()
        XCTAssertEqual(fit.widthChanged(to: 700, isShown: true), false)
        fit.userChose()
        XCTAssertNil(fit.widthChanged(to: 1400, isShown: false), "hidden by hand now")

        var shownByHand = SidebarWidthFit()
        XCTAssertEqual(shownByHand.widthChanged(to: 700, isShown: true), false)
        shownByHand.userChose()
        XCTAssertNil(shownByHand.widthChanged(to: 720, isShown: true), "shown by hand in a narrow window stays")
    }

    /// Where the sidebar would squeeze the panes past their smallest, it goes, whatever the
    /// user chose while narrow; it comes back once they fit again.
    func testTheSidebarGivesWayBeforeAnyPaneIsSqueezed() {
        var fit = SidebarWidthFit()
        XCTAssertEqual(fit.widthChanged(to: 700, isShown: true, room: 600), false)
        fit.userChose()
        XCTAssertNil(fit.widthChanged(to: 680, isShown: true, room: 600), "shown by hand, and the panes fit")
        XCTAssertEqual(fit.widthChanged(to: 580, isShown: true, room: 600), false, "the panes no longer fit")
        XCTAssertNil(fit.widthChanged(to: 900, isShown: false, room: 1000), "still too narrow for both")
        XCTAssertEqual(fit.widthChanged(to: 1100, isShown: false, room: 1000), true)
    }

    func testThePanesSmallestWidthFollowsTheirSplits() {
        let pane: CGFloat = 100, gap: CGFloat = 1
        XCTAssertEqual(Node.leaf(PaneId(1)).minimumWidth(pane: pane, gap: gap), 100)
        let beside = Node.split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(1)), second: .leaf(PaneId(2)))
        XCTAssertEqual(beside.minimumWidth(pane: pane, gap: gap), 201)
        let stacked = Node.split(axis: .vertical, ratio: 0.5, first: beside, second: .leaf(PaneId(3)))
        XCTAssertEqual(stacked.minimumWidth(pane: pane, gap: gap), 201)
    }

    #if os(macOS)
    /// A narrow window with the sidebar shown keeps every pane on screen, side by side within
    /// the detail column.
    func testEveryPaneStaysInViewBesideTheSidebarInANarrowWindow() async throws {
        let wasShown = TabPlacement.sidebarShown
        defer { TabPlacement.sidebarShown = wasShown }
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 1200, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        // A content view controller sizes the window to its view: the size goes after it.
        window.setContentSize(NSSize(width: 1200, height: 600))
        window.orderFrontRegardless()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        let first = try XCTUnwrap(workspace.focusedPane)
        for _ in 0..<50 where !workspace.hasRoomToSplit(first, .horizontal) { try await Task.sleep(for: .milliseconds(100)) }
        workspace.split(.horizontal)
        let panes = try XCTUnwrap(workspace.session.activeTab?.root.panes)
        XCTAssertEqual(panes.count, 2)
        // The mock host outlives the test: its tab goes back to one pane.
        defer { if let added = panes.last { workspace.apply(.close(added)) } }

        window.setContentSize(NSSize(width: 640, height: 600))
        try await Task.sleep(for: .milliseconds(200))
        model.isSidebarShown = true
        try await Task.sleep(for: .seconds(1.5))
        let content = try XCTUnwrap(window.contentView).bounds
        XCTAssertEqual(content.width, 640)
        XCTAssertTrue(model.isSidebarShown)
        var frames: [CGRect] = []
        for pane in panes {
            let view = try XCTUnwrap(workspace.pane(pane)?.view)
            XCTAssertNotNil(view.window, "pane \(pane) is not on screen")
            frames.append(view.convert(view.bounds, to: nil))
        }
        for frame in frames {
            let shown = frame.intersection(content)
            XCTAssertGreaterThan(shown.width, frame.width - 1, "a pane runs past the window: \(frame) in \(content)")
            XCTAssertGreaterThan(frame.width, 100)
            XCTAssertGreaterThanOrEqual(frame.minX, SidebarWidth.range.lowerBound - 1, "a pane under the sidebar: \(frame)")
        }

        // Too narrow for the sidebar beside the panes at their smallest: the sidebar goes.
        let minimum = workspace.minimumPanesWidth
        XCTAssertGreaterThan(minimum, 0)
        window.setContentSize(NSSize(width: (minimum + SidebarWidth.range.lowerBound - 1).rounded(.down), height: 600))
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(model.isSidebarShown, "the panes would be squeezed past their smallest")
        let narrow = try XCTUnwrap(window.contentView).bounds
        for pane in panes {
            let view = try XCTUnwrap(workspace.pane(pane)?.view)
            let frame = view.convert(view.bounds, to: nil)
            XCTAssertGreaterThan(frame.intersection(narrow).width, frame.width - 1, "a pane runs past the window: \(frame) in \(narrow)")
        }
    }
    #endif
}
