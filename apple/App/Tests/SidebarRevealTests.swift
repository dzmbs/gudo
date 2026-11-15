import HostKit
import PaneLayout
import SwiftUI
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import App

/// The sidebar keeps the active tab's row in view: it scrolls only when the row is off screen,
/// and then by the least travel.
@MainActor
final class SidebarRevealTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]
    private let visible: ClosedRange<CGFloat> = 40...400

    private func row(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 260, height: 30) }

    func testARowInViewStays() {
        let frames = ["b": row(100), "c": row(130), "d": row(160)]
        XCTAssertEqual(SidebarReveal.move(to: "c", in: order, frames: frames, visible: visible), .none)
    }

    func testARowCutAtEitherEdgeComesIn() {
        let frames = ["a": row(20), "b": row(50), "e": row(380)]
        XCTAssertEqual(SidebarReveal.move(to: "a", in: order, frames: frames, visible: visible), .up)
        XCTAssertEqual(SidebarReveal.move(to: "e", in: order, frames: frames, visible: visible), .down)
    }

    func testARowTheListHasNotLaidOutGoesTheWayItLies() {
        let frames = ["b": row(100), "c": row(130)]
        XCTAssertEqual(SidebarReveal.move(to: "a", in: order, frames: frames, visible: visible), .up)
        XCTAssertEqual(SidebarReveal.move(to: "e", in: order, frames: frames, visible: visible), .down)
        XCTAssertEqual(SidebarReveal.move(to: "zz", in: order, frames: frames, visible: visible), .none, "not in the list")
    }

    func testARowBetweenShownRowsNeedsNoScroll() {
        let frames = ["b": row(100), "d": row(160)]
        XCTAssertEqual(SidebarReveal.move(to: "c", in: order, frames: frames, visible: visible), .none)
    }

    func testARowUnderThePinnedHeaderIsNotInView() {
        let frames = ["b": row(50), "c": row(80)]
        XCTAssertEqual(SidebarReveal.move(to: "b", in: order, frames: frames, visible: 40 + 46...400), .up)
    }

    func testGoingUpLandsTheRowJustUnderWhatCoversTheTop() {
        XCTAssertEqual(SidebarReveal.anchor(for: .down, covered: 46, viewport: 500, rowHeight: 30), .bottom)
        XCTAssertNil(SidebarReveal.anchor(for: .none, covered: 46, viewport: 500, rowHeight: 30))
        let up = try? XCTUnwrap(SidebarReveal.anchor(for: .up, covered: 47, viewport: 500, rowHeight: 30))
        XCTAssertEqual(up?.y ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(SidebarReveal.anchor(for: .up, covered: 0, viewport: 500, rowHeight: 30), .top)
    }

    #if os(macOS)
    /// ⌘T or ⌘9 on a tab below the fold scrolls the list to it; a tab already in view moves nothing.
    func testTheListScrollsToAnActiveTabBelowTheFold() async throws {
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        while workspace.session.tabs.count < 24 { workspace.apply(.newTab) }
        let first = try XCTUnwrap(model.groups.tabs.first)
        model.focus(first)

        let host = NSHostingView(rootView: WorkspaceSidebar().environment(model).environment(model.app))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        let found = await eventuallyFind { Self.scrollView(in: host) }
        let scrollView = try XCTUnwrap(found)
        try await Task.sleep(for: .milliseconds(300))
        let resting = scrollView.contentView.bounds.minY

        model.focus(model.groups.tabs[1])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(scrollView.contentView.bounds.minY, resting, accuracy: 1, "a row in view moves nothing")

        let last = try XCTUnwrap(model.groups.tabs.last)
        model.focus(last)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, resting + 100, "the list scrolls down to the last tab")

        let down = scrollView.contentView.bounds.minY
        model.focus(first)
        try await Task.sleep(for: .milliseconds(800))
        let up = scrollView.contentView.bounds.minY
        XCTAssertLessThan(up, down - 100, "and back up to the first")
        XCTAssertGreaterThan(up, resting + 1, "by the least travel: the rows above it stay out of view")
    }

    private func eventuallyFind<T>(_ find: () -> T?) async -> T? {
        for _ in 0..<40 {
            if let found = find() { return found }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return find()
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView || scroll.documentView is NSCollectionView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }
    #endif
}
