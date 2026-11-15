import DesignSystem
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Strip chips sized to their titles (`TabChipWidth`) and the readiness-gated tab handoff (`TabHandoff`).
@MainActor
final class TabStripTests: XCTestCase {
    // MARK: Widths

    func testAChipIsAsWideAsItsTitleWithinTheRange() {
        let range = DS.Size.tabMinWidth...DS.Size.tabMaxWidth
        XCTAssertEqual(TabChipWidth.width(ideal: 40, in: range), DS.Size.tabMinWidth, "never a sliver")
        XCTAssertEqual(TabChipWidth.width(ideal: 151.2, in: range), 152)
        XCTAssertEqual(TabChipWidth.width(ideal: 900, in: range), DS.Size.tabMaxWidth, "never the whole strip")
    }

    func testTheStripFadesOnlyTheEdgesChipsRunPast() {
        XCTAssertEqual(StripEdges(offset: 0, content: 400, container: 600), StripEdges())
        let start = StripEdges(offset: 0, content: 1200, container: 600)
        XCTAssertFalse(start.leading)
        XCTAssertTrue(start.trailing)
        let middle = StripEdges(offset: 300, content: 1200, container: 600)
        XCTAssertTrue(middle.leading)
        XCTAssertTrue(middle.trailing)
        let end = StripEdges(offset: 600, content: 1200, container: 600)
        XCTAssertTrue(end.leading)
        XCTAssertFalse(end.trailing)
    }

    func testTheSelectedChipScrollsToTheNearerEdgeOnlyWhenCut() {
        let visible: ClosedRange<CGFloat> = 300...800
        XCTAssertNil(StripSpans.anchor(chip: 400...560, visible: visible))
        XCTAssertEqual(StripSpans.anchor(chip: 200...360, visible: visible), .leading)
        XCTAssertEqual(StripSpans.anchor(chip: 700...860, visible: visible), .trailing)
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

    /// Chips size to their titles: a short one at the narrowest width, a long one at the widest,
    /// and they leave the rest of a wide strip empty.
    func testChipsSizeToTheirTitles() async throws {
        // No agent pills: only the titles set the widths.
        MockPaneStatus.fixture = [:]
        defer { MockPaneStatus.fixture = nil }
        let (model, workspace) = try await stripModel(tabs: 3)
        defer { model.close() }
        let tabs = workspace.session.tabs
        workspace.apply(.rename(tabs[0].id, "a"))
        workspace.apply(.rename(tabs[1].id, "a fairly ordinary name"))
        workspace.apply(.rename(tabs[2].id, String(repeating: "a very long tab title ", count: 8)))
        let frames = ChipFrames()
        let window = stripWindow(model: model, workspace: workspace, width: 1300, frames: frames)
        defer { window.close() }
        let settledFrames = try await settled(frames, count: 3)
        let widths = tabs.map { tab in settledFrames.first { $0.key.tab == tab.id }?.value.width ?? 0 }
        XCTAssertEqual(widths[0], DS.Size.tabMinWidth)
        XCTAssertGreaterThan(widths[1], DS.Size.tabMinWidth)
        XCTAssertLessThan(widths[1], DS.Size.tabMaxWidth)
        XCTAssertEqual(widths[2], DS.Size.tabMaxWidth)
    }

    /// The selected chip is always scrolled whole into view, however far along the strip it is.
    func testTheSelectedChipIsScrolledIntoView() async throws {
        let (model, workspace) = try await stripModel(tabs: 14)
        defer { model.close() }
        let frames = ChipFrames()
        let window = stripWindow(model: model, workspace: workspace, width: 520, frames: frames)
        defer { window.close() }
        _ = try await settled(frames, count: 14)
        let scrollView = try XCTUnwrap(Self.scrollView(in: try XCTUnwrap(window.contentView)))
        let shown = scrollView.convert(scrollView.bounds, to: nil)
        for ref in [model.groups.tabs.last, model.groups.tabs.first, model.groups.tabs[7]].compactMap(\.self) {
            model.focus(ref)
            var chip = CGRect.null
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                chip = try XCTUnwrap(frames.byTab[ref])
                if chip.minX >= shown.minX - 1, chip.maxX <= shown.maxX + 1 { break }
            }
            XCTAssertGreaterThanOrEqual(chip.minX, shown.minX - 1, "\(ref) cut at the leading edge")
            XCTAssertLessThanOrEqual(chip.maxX, shown.maxX + 1, "\(ref) cut at the trailing edge")
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    private func stripModel(tabs count: Int) async throws -> (WindowModel, Workspace) {
        let model = WindowModel(app: .shared)
        model.start()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        for tab in workspace.session.tabs.dropFirst() { workspace.apply(.closeTab(tab.id)) }
        while workspace.session.tabs.count < count { workspace.apply(.newTab) }
        return (model, workspace)
    }

    private func stripWindow(model: WindowModel, workspace: Workspace, width: CGFloat, frames: ChipFrames) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: width, height: 60), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let strip = TabBar(workspace: workspace)
            .environment(model)
            .environment(AppModel.shared)
            .environment(\.tabChipFrames) { ref, frame in frames.byTab[ref] = frame }
        window.contentView = NSHostingView(rootView: strip)
        window.orderFrontRegardless()
        return window
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
