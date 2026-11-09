import DesignSystem
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Stable strip chips (`TabStripWidths`) and the readiness-gated tab handoff (`TabHandoff`).
@MainActor
final class TabStripTests: XCTestCase {
    // MARK: Widths

    func testAddingATabKeepsTheOtherChipsWidth() {
        var widths = TabStripWidths()
        widths.stripWidth = 1000
        widths.tabsChanged(to: 5)
        XCTAssertEqual(widths.chipWidth, 200)
        widths.tabsChanged(to: 6)
        XCTAssertEqual(widths.chipWidth, 200, "the strip scrolls instead")
        widths.pointerLeft()
        XCTAssertEqual(widths.chipWidth, 166)
    }

    func testFewTabsStayAtTheWidestWidth() {
        var widths = TabStripWidths()
        widths.stripWidth = 1000
        widths.tabsChanged(to: 1)
        XCTAssertEqual(widths.chipWidth, DS.Size.tabMaxWidth)
        widths.tabsChanged(to: 4)
        XCTAssertEqual(widths.chipWidth, DS.Size.tabMaxWidth)
        XCTAssertNil(widths.heldWidth)
    }

    func testManyTabsScrollAtTheNarrowestWidth() {
        var widths = TabStripWidths()
        widths.stripWidth = 1000
        widths.tabsChanged(to: 20)
        XCTAssertEqual(widths.chipWidth, DS.Size.tabMinWidth)
        widths.tabsChanged(to: 21)
        XCTAssertEqual(widths.chipWidth, DS.Size.tabMinWidth)
    }

    func testAClosedTabUnderThePointerKeepsTheWidthUntilThePointerLeaves() {
        var widths = TabStripWidths()
        widths.stripWidth = 1000
        widths.tabsChanged(to: 6)
        widths.isPointerInside = true
        widths.tabsChanged(to: 5)
        XCTAssertEqual(widths.chipWidth, 166, "the next close button lands under the pointer")
        widths.pointerLeft()
        XCTAssertEqual(widths.chipWidth, 200)
    }

    func testAClosedTabAwayFromThePointerSettlesAtOnce() {
        var widths = TabStripWidths()
        widths.stripWidth = 1000
        widths.tabsChanged(to: 6)
        widths.tabsChanged(to: 5)
        XCTAssertEqual(widths.chipWidth, 200)
    }

    func testResizingTheStripSettlesAHeldWidth() {
        var widths = TabStripWidths()
        widths.stripWidth = 1000
        widths.tabsChanged(to: 5)
        widths.tabsChanged(to: 6)
        widths.stripWidth = 1200
        XCTAssertEqual(widths.chipWidth, 200)
    }

    // MARK: The strip on screen

    #if os(macOS)
    /// ⌘T in a full strip: every chip already there keeps its frame.
    func testANewTabLeavesTheOtherChipsInPlace() async throws {
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        for tab in workspace.session.tabs.dropFirst() { workspace.apply(.closeTab(tab.id)) }
        for _ in 0..<5 { workspace.apply(.newTab) }

        let frames = ChipFrames()
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 1300, height: 60), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let strip = TabBar(workspace: workspace)
            .environment(model)
            .environment(AppModel.shared)
            .environment(\.tabChipFrames) { ref, frame in frames.byTab[ref] = frame }
        window.contentView = NSHostingView(rootView: strip)
        window.orderFrontRegardless()

        let before = try await settled(frames, count: 6)
        workspace.apply(.newTab)
        let after = try await settled(frames, count: 7)
        // The strip may scroll to show the new tab; the others keep their size and spacing.
        let anchor = try XCTUnwrap(before.min { $0.value.minX < $1.value.minX }?.key)
        let shiftBefore = try XCTUnwrap(before[anchor]).minX, shiftAfter = try XCTUnwrap(after[anchor]).minX
        for (ref, frame) in before {
            let moved = try XCTUnwrap(after[ref], "\(ref) gone when a tab was added")
            XCTAssertEqual(moved.size, frame.size, "\(ref) changed size when a tab was added")
            XCTAssertEqual(moved.minX - shiftAfter, frame.minX - shiftBefore, "\(ref) moved among the other chips when a tab was added")
        }
    }

    private final class ChipFrames {
        var byTab: [TabRef: CGRect] = [:]
    }

    /// The chips' frames once `count` are laid out and two looks agree.
    private func settled(_ frames: ChipFrames, count: Int) async throws -> [TabRef: CGRect] {
        var previous: [TabRef: CGRect] = [:]
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            let current = frames.byTab
            if current.count >= count, current == previous { return current }
            previous = current
        }
        XCTFail("chips did not settle: \(previous.count) of \(count)")
        return previous
    }

    /// An offscreen window never presents frames, so the shown terminal stays until the deadline.
    func testANewTabIsLaidOutUnderTheShownOneUntilItTakesOver() async throws {
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        window.orderFrontRegardless()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        let shownPane = try XCTUnwrap(workspace.focusedPane.flatMap { workspace.pane($0) })
        try await eventually("the first tab is on screen") { shownPane.view.window != nil }

        model.newTab()
        let newPaneId = try XCTUnwrap(workspace.focusedPane)
        XCTAssertNotEqual(newPaneId, shownPane.id)
        try await eventually("the new terminal is laid out") { workspace.pane(newPaneId)?.view.window != nil }
        XCTAssertNotNil(shownPane.view.window, "the shown terminal stays meanwhile")
        try await eventually("the new tab takes over") { shownPane.view.window == nil }
        XCTAssertNotNil(workspace.pane(newPaneId)?.view.window)
    }
    #endif

    // MARK: Handoff

    private final class Readiness {
        var ready: Set<TabId> = []
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    func testTheShownTabStaysUntilTheNewOneHasAFrame() async throws {
        let handoff = TabHandoff(deadline: .seconds(60))
        let readiness = Readiness()
        let first = TabId(1), second = TabId(2)
        handoff.select(first) { readiness.ready.contains(first) }
        XCTAssertEqual(handoff.shown, first, "nothing to keep on screen: shown at once")
        handoff.select(second) { readiness.ready.contains(second) }
        XCTAssertEqual(handoff.shown, first)
        XCTAssertEqual(handoff.layers, [second, first], "laid out under the shown tab")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(handoff.shown, first)
        readiness.ready.insert(second)
        try await eventually("shown once ready") { handoff.shown == second }
        XCTAssertNil(handoff.incoming)
        XCTAssertEqual(handoff.layers, [second])
    }

    func testTheNewestSelectionWins() async throws {
        let handoff = TabHandoff(deadline: .seconds(60))
        let readiness = Readiness()
        let first = TabId(1), second = TabId(2), third = TabId(3)
        handoff.select(first) { true }
        handoff.select(second) { readiness.ready.contains(second) }
        handoff.select(third) { readiness.ready.contains(third) }
        XCTAssertEqual(handoff.layers, [third, first])
        readiness.ready.insert(second)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handoff.shown, first, "an older tab getting ready replaces nothing")
        readiness.ready.insert(third)
        try await eventually("the newest selection shows") { handoff.shown == third }
    }

    func testGoingBackCancelsTheWait() async throws {
        let handoff = TabHandoff(deadline: .seconds(60))
        let readiness = Readiness()
        let first = TabId(1), second = TabId(2)
        handoff.select(first) { true }
        handoff.select(second) { readiness.ready.contains(second) }
        handoff.select(first) { true }
        XCTAssertEqual(handoff.layers, [first])
        readiness.ready.insert(second)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handoff.shown, first)
    }

    func testATabThatNeverDrawsShowsAtTheDeadline() async throws {
        let handoff = TabHandoff(deadline: .milliseconds(50))
        let first = TabId(1), second = TabId(2)
        handoff.select(first) { true }
        handoff.select(second) { false }
        try await eventually("shown at the deadline") { handoff.shown == second }
    }
}
