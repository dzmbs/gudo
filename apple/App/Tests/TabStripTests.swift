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

    /// A selected chip comes to rest clear of the fade at the edge it was brought in by, so the
    /// fade never eats into a chip shown whole.
    func testTheSelectedChipLandsClearOfTheEdgesFade() throws {
        let visible: ClosedRange<CGFloat> = 300...800
        let fade = DS.Size.tabStripFade
        /// Where a chip `width` wide starts once scrolled to `anchor`.
        func landing(_ anchor: UnitPoint, width: CGFloat) -> CGFloat {
            visible.lowerBound + anchor.x * (visible.upperBound - visible.lowerBound - width)
        }
        let underTrailingFade = try XCTUnwrap(StripSpans.anchor(chip: 640...790, visible: visible, clear: fade))
        XCTAssertEqual(landing(underTrailingFade, width: 150) + 150, visible.upperBound - fade, accuracy: 0.01)
        let pastLeadingEdge = try XCTUnwrap(StripSpans.anchor(chip: 250...400, visible: visible, clear: fade))
        XCTAssertEqual(landing(pastLeadingEdge, width: 150), visible.lowerBound + fade, accuracy: 0.01)
        XCTAssertNil(StripSpans.anchor(chip: 400...560, visible: visible, clear: fade), "clear of both fades: stays")
        let tooWide = try XCTUnwrap(StripSpans.anchor(chip: 700...1180, visible: visible, clear: fade))
        XCTAssertEqual(tooWide, .trailing, "no room for the fade: to the edge")
    }

    func testOnlyAResizeReScrolls() {
        XCTAssertFalse(StripSpans.isResize(from: 0...500, to: 120...620), "a scroll")
        XCTAssertTrue(StripSpans.isResize(from: 0...1300, to: 0...520))
    }

    /// A line between every two chips, except either side of the selected one.
    func testSeparatorsStandBetweenChipsExceptBesideTheSelection() {
        XCTAssertFalse(TabBar.showsSeparator(before: 0, active: nil))
        XCTAssertEqual((1..<6).map { TabBar.showsSeparator(before: $0, active: nil) }, Array(repeating: true, count: 5))
        XCTAssertEqual((1..<6).map { TabBar.showsSeparator(before: $0, active: 3) }, [true, true, false, false, true])
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

    /// After the window narrows, the selected chip is brought back whole into view.
    func testTheSelectedChipStaysInViewWhenTheWindowNarrows() async throws {
        let (model, workspace) = try await stripModel(tabs: 14)
        defer { model.close() }
        let frames = ChipFrames()
        let window = stripWindow(model: model, workspace: workspace, width: 1300, frames: frames)
        defer { window.close() }
        _ = try await settled(frames, count: 14)
        let last = try XCTUnwrap(model.groups.tabs.last)
        model.focus(last)
        _ = try await settled(frames, count: 14)
        window.setContentSize(NSSize(width: 520, height: 60))
        _ = try await settled(frames, count: 14)
        let scrollView = try XCTUnwrap(Self.scrollView(in: try XCTUnwrap(window.contentView)))
        let shown = scrollView.convert(scrollView.bounds, to: nil)
        let chip = try XCTUnwrap(frames.byTab[last])
        XCTAssertGreaterThanOrEqual(chip.minX, shown.minX - 1, "cut at the leading edge")
        XCTAssertLessThanOrEqual(chip.maxX, shown.maxX + 1, "cut at the trailing edge")
    }

    /// A chip cut by the strip's trailing edge dissolves into it, over a quarter of the narrowest
    /// chip, rather than ending in a hard line by the + button. Measured on the selected chip,
    /// whose fill is solid where the title's glyphs come and go.
    func testAChipCutByTheTrailingEdgeFadesOutOverAQuarterChip() async throws {
        MockPaneStatus.fixture = [:]
        defer { MockPaneStatus.fixture = nil }
        let (model, workspace) = try await stripModel(tabs: 8)
        defer { model.close() }
        let frames = ChipFrames()
        let window = stripWindow(model: model, workspace: workspace, width: 700, frames: frames)
        defer { window.close() }
        let selected = try XCTUnwrap(model.groups.tabs.last)
        model.focus(selected)
        _ = try await settled(frames, count: 8)
        let host = try XCTUnwrap(window.contentView)
        let scrollView = try XCTUnwrap(Self.scrollView(in: host))
        let shown = scrollView.convert(scrollView.bounds, to: nil)
        // The selected chip cut through its middle by the trailing edge.
        let chip = try XCTUnwrap(frames.byTab[selected])
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX + chip.midX - shown.maxX, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(600))
        let cut = try XCTUnwrap(frames.byTab[selected])
        XCTAssertEqual(cut.midX, shown.maxX, accuracy: 1)

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let row = Int((cut.minY + 6) * scale)
        let background = try XCTUnwrap(bitmap.colorAt(x: Int((shown.maxX + 1) * scale), y: row))
        /// How far the fill stands out from the background `distance` points before the edge.
        func fill(before distance: CGFloat) -> CGFloat {
            guard let color = bitmap.colorAt(x: Int((shown.maxX - distance) * scale), y: row) else { return 0 }
            return abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                + abs(color.blueComponent - background.blueComponent)
        }
        let whole = fill(before: cut.width / 2 - 12)
        XCTAssertGreaterThan(whole, 0.02, "the selected chip's fill shows before the fade")
        let quarterChip = DS.Size.tabMinWidth / 4
        XCTAssertLessThan(fill(before: quarterChip / 2), whole * 0.6, "half way into the fade the chip is half gone")
        XCTAssertLessThan(fill(before: DS.Space.xs), whole * 0.2, "by the edge it has all but gone")
        XCTAssertGreaterThan(fill(before: quarterChip + 2), whole * 0.9, "the fade is no longer than it needs to be")

        // The + stands clear of the strip's edge, with a gap of its own after the fade.
        let middle = Int((cut.midY) * scale)
        let gapBackground = try XCTUnwrap(bitmap.colorAt(x: Int((shown.maxX + 1) * scale), y: middle))
        let plusInk = stride(from: shown.maxX + 1, to: shown.maxX + 40, by: 0.5).first { x in
            guard let color = bitmap.colorAt(x: Int(x * scale), y: middle) else { return false }
            return abs(color.redComponent - gapBackground.redComponent) + abs(color.greenComponent - gapBackground.greenComponent)
                + abs(color.blueComponent - gapBackground.blueComponent) > 0.15
        }
        let gap = try XCTUnwrap(plusInk, "the + after the strip") - shown.maxX
        XCTAssertGreaterThanOrEqual(gap, DS.Space.l, "the + keeps its own gap after the strip's edge")
    }

    /// A chip cut by the leading edge leaves clear space next to what stands before the strip
    /// (the sidebar toggle in the title bar), as the trailing edge does before +.
    func testAChipCutByTheLeadingEdgeLeavesClearSpaceBeforeItsFade() async throws {
        MockPaneStatus.fixture = [:]
        defer { MockPaneStatus.fixture = nil }
        let (model, workspace) = try await stripModel(tabs: 8)
        defer { model.close() }
        let frames = ChipFrames()
        let window = stripWindow(model: model, workspace: workspace, width: 700, frames: frames)
        defer { window.close() }
        let selected = try XCTUnwrap(model.groups.tabs.dropFirst(3).first)
        model.focus(selected)
        _ = try await settled(frames, count: 8)
        let host = try XCTUnwrap(window.contentView)
        let scrollView = try XCTUnwrap(Self.scrollView(in: host))
        let shown = scrollView.convert(scrollView.bounds, to: nil)
        let chip = try XCTUnwrap(frames.byTab[selected])
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX + chip.midX - shown.minX, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(600))
        let cut = try XCTUnwrap(frames.byTab[selected])
        XCTAssertEqual(cut.midX, shown.minX, accuracy: 1)

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let row = Int((cut.minY + 6) * scale)
        let background = try XCTUnwrap(bitmap.colorAt(x: Int((shown.minX - 1) * scale), y: row))
        /// How far the fill stands out from the background `distance` points after the edge.
        func fill(after distance: CGFloat) -> CGFloat {
            guard let color = bitmap.colorAt(x: Int((shown.minX + distance) * scale), y: row) else { return 0 }
            return abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                + abs(color.blueComponent - background.blueComponent)
        }
        let whole = fill(after: cut.width / 2 - 12)
        XCTAssertGreaterThan(whole, 0.02, "the selected chip's fill shows after the fade")
        XCTAssertLessThan(fill(after: DS.Space.xs), whole * 0.05, "nothing of the chip right after the edge")
        XCTAssertLessThan(fill(after: DS.Space.s - 1), whole * 0.05, "nothing of the chip right after the edge")
        let rampStart = DS.Space.s
        let ramp = DS.Size.tabStripFade - rampStart
        XCTAssertLessThan(fill(after: rampStart + ramp / 4), whole * 0.15, "a quarter into the fade a glyph is all but gone, not a sliver")
        XCTAssertGreaterThan(fill(after: DS.Size.tabMinWidth / 4 + 2), whole * 0.9, "the fade is no longer than it needs to be")
    }

    /// The strip lists tabs in the order the sidebar and ⌘1…⌘9 do: a project's tabs first.
    func testTheStripFollowsTheSidebarsOrder() async throws {
        let (model, workspace) = try await stripModel(tabs: 5)
        defer { model.close() }
        let refs = workspace.session.tabs.map { TabRef(hostId: model.currentGroupId, tab: $0.id) }
        model.newProject(from: [refs[3], refs[1]], name: "order", naming: false)
        XCTAssertEqual(Array(model.groups.tabs.prefix(2)), [refs[3], refs[1]])
        let frames = ChipFrames()
        let window = stripWindow(model: model, workspace: workspace, width: 1300, frames: frames)
        defer { window.close() }
        let settledFrames = try await settled(frames, count: 5)
        let stripOrder = settledFrames.sorted { $0.value.minX < $1.value.minX }.map(\.key)
        XCTAssertEqual(stripOrder, model.groups.tabs)
        XCTAssertEqual(stripOrder.map { model.groups.shortcutNumber(of: $0) }, [1, 2, 3, 4, 5])
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
        // An offscreen window gets no display frames, so an animated scroll never moves; under
        // Reduce Motion the strip goes to the same place at once.
        let strip = TabBar(workspace: workspace)
            .environment(model)
            .environment(AppModel.shared)
            .environment(\.forcedChromeAccessibility, ChromeAccessibility(reduceMotion: true))
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

        let shownRef = try XCTUnwrap(model.currentTab)
        model.newTab()
        let newPaneId = try XCTUnwrap(workspace.focusedPane)
        XCTAssertNotEqual(newPaneId, shownPane.id)
        let newRef = try XCTUnwrap(model.currentTab)
        func rows() -> [TabRef] {
            model.sidebarItems(drop: nil, projectMove: nil).items.compactMap { if case .row(let ref, _) = $0 { ref } else { nil } }
        }
        // The row, the selection and the title wait for the content.
        XCTAssertEqual(model.arrivingTab, newRef)
        XCTAssertFalse(rows().contains(newRef), "the new row leads its content")
        XCTAssertEqual(model.shownTab, shownRef)
        try await eventually("the new terminal is laid out") { workspace.pane(newPaneId)?.view.window != nil }
        XCTAssertNotNil(shownPane.view.window, "the shown terminal stays meanwhile")
        XCTAssertEqual(model.shownTab, shownRef)
        try await eventually("the new tab takes over") { shownPane.view.window == nil }
        XCTAssertNotNil(workspace.pane(newPaneId)?.view.window)
        XCTAssertNil(model.arrivingTab)
        XCTAssertEqual(model.shownTab, newRef)
        XCTAssertTrue(rows().contains(newRef))
        let title = try XCTUnwrap(workspace.shownTab.map(workspace.title(of:)))
        XCTAssertNotEqual(title, "Shell", "the row comes with its name")
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

    func testANewTabArrivesWithItsContent() async throws {
        let handoff = TabHandoff(deadline: .seconds(60))
        let readiness = Readiness()
        let first = TabId(1), second = TabId(2)
        handoff.select(first) { true }
        handoff.arrive(second)
        handoff.select(second) { readiness.ready.contains(second) }
        XCTAssertEqual(handoff.arriving, second)
        readiness.ready.insert(second)
        try await eventually("shown once ready") { handoff.shown == second }
        XCTAssertNil(handoff.arriving)
    }

    func testAnArrivalNeverSelectedLetsGoAtTheDeadline() async throws {
        let handoff = TabHandoff(deadline: .milliseconds(50))
        handoff.select(TabId(1)) { true }
        handoff.arrive(TabId(2))
        XCTAssertEqual(handoff.arriving, TabId(2))
        try await eventually("let go") { handoff.arriving == nil }

        handoff.arrive(TabId(3))
        handoff.select(TabId(1)) { true }
        handoff.select(TabId(4)) { true }
        XCTAssertNil(handoff.arriving, "another selection wins")
    }

    func testATabThatNeverDrawsShowsAtTheDeadline() async throws {
        let handoff = TabHandoff(deadline: .milliseconds(50))
        let first = TabId(1), second = TabId(2)
        handoff.select(first) { true }
        handoff.select(second) { false }
        try await eventually("shown at the deadline") { handoff.shown == second }
    }
}
