import Foundation
import Observation
import Testing
@testable import PaneLayout

/// A store that applies focus/ratio ops at once and the rest only on `flush()`, like the
/// daemon's (ids come with its answer).
@MainActor
@Observable
private final class DeferredStore: LayoutStore {
    private(set) var session: Session
    @ObservationIgnored private var queued: [LayoutOp] = []

    init(_ session: Session) {
        self.session = session
    }

    func apply(_ op: LayoutOp) {
        switch op {
        case .focus, .focusDirection, .resize, .toggleZoom, .moveTab, .rename:
            session.apply(op)
        default:
            queued.append(op)
        }
    }

    func flush() {
        for op in queued { session.apply(op) }
        queued = []
    }
}

/// Lets `follow()`'s main-actor tasks run.
@MainActor
private func settle() async {
    for _ in 0..<5 { await Task.yield() }
}

/// Two tabs (panes 1 and 3), the first split (pane 4 below pane 1).
@MainActor
private func twoTabs() -> LocalLayoutStore {
    var session = Session()  // tab 2: p1
    session.apply(.newTab)  // tab 4: p3
    session.apply(.split(PaneId(1), .vertical))  // p5 in tab 2
    session.apply(.focus(PaneId(1)))
    return LocalLayoutStore(session: session)
}

@MainActor
@Suite struct WindowLayoutStoreTests {
    /// Every sidebar row reads the window's session (the tab on screen): with 500 tabs a render
    /// composed it 500 times, O(tabs²). Unchanged, it is composed once; a change still shows.
    @Test func readingTheSessionOfAWideLayoutIsCheapAndStaysCurrent() {
        var session = Session()
        for _ in 1..<500 { session.apply(.newTab) }
        let base = LocalLayoutStore(session: session)
        let window = WindowLayoutStore(base: base)
        let start = ContinuousClock.now
        for _ in 0..<2_000 { _ = window.session.activeTabId }
        #expect(ContinuousClock.now - start < .milliseconds(200))

        let second = window.session.tabs[1]
        window.select(tab: second.id)
        #expect(window.session.activeTabId == second.id)
        window.apply(.split(second.focused, .vertical))
        #expect(window.session.activeTab?.root.panes.count == 2)
        #expect(window.session.tabs.count == 500)
    }

    @Test func windowsSelectTabsIndependently() {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        let windowB = WindowLayoutStore(base: base)
        #expect(windowA.session.activeTabId == TabId(2))
        windowB.select(tab: TabId(4))
        #expect(windowB.session.activeTabId == TabId(4))
        #expect(windowA.session.activeTabId == TabId(2))
        // The base heard the last focus (a daemon keeps it for other devices).
        #expect(base.session.activeTabId == TabId(4))
    }

    @Test func focusInATabIsPerWindow() {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        let windowB = WindowLayoutStore(base: base)
        windowA.apply(.focus(PaneId(5)))
        #expect(windowA.session.activeTab?.focused == PaneId(5))
        windowB.apply(.focus(PaneId(1)))
        #expect(windowB.session.activeTab?.focused == PaneId(1))
        #expect(windowA.session.activeTab?.focused == PaneId(5))
    }

    @Test func aWindowOpensOnTheTabItAsksFor() {
        let base = twoTabs()
        let window = WindowLayoutStore(base: base, selecting: TabId(4))
        #expect(window.session.activeTabId == TabId(4))
        let unknown = WindowLayoutStore(base: base, selecting: TabId(99))
        #expect(unknown.session.activeTabId == base.session.activeTabId)
    }

    @Test func aNewTabIsSelectedOnlyInTheWindowThatOpenedIt() {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        let windowB = WindowLayoutStore(base: base)
        windowB.select(tab: TabId(4))
        windowA.apply(.newTab)
        let new = try! #require(base.session.tabs.map(\.id).first { ![TabId(2), TabId(4)].contains($0) })
        #expect(windowA.session.activeTabId == new)
        #expect(windowB.session.activeTabId == TabId(4))
        // After windowA's tab, not windowB's (the base was aligned with windowA first).
        #expect(base.session.tabs.map(\.id) == [TabId(2), new, TabId(4)])
    }

    @Test func aSplitFocusesTheNewPaneInThatWindow() {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        let windowB = WindowLayoutStore(base: base)
        windowB.apply(.focus(PaneId(1)))
        windowA.apply(.split(PaneId(5), .horizontal))
        let new = try! #require(base.session.panes.subtracting([PaneId(1), PaneId(3), PaneId(5)]).first)
        #expect(windowA.session.activeTab?.focused == new)
        #expect(windowB.session.activeTab?.focused == PaneId(1))
    }

    @Test func remoteOpsAreAdoptedWhenTheirAnswerArrives() async {
        var session = Session()
        session.apply(.newTab)
        let base = DeferredStore(session)
        let window = WindowLayoutStore(base: base)
        window.select(tab: TabId(2))
        window.apply(.newTab)
        #expect(window.session.activeTabId == TabId(2))
        base.flush()
        await settle()
        #expect(window.session.tabs.count == 3)
        #expect(window.session.activeTabId == window.session.tabs[1].id)
    }

    @Test func aTabClosedElsewhereHandsOverToItsNeighbour() async {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        let windowB = WindowLayoutStore(base: base)
        windowA.select(tab: TabId(2))
        windowB.apply(.closeTab(TabId(2)))
        #expect(windowA.session.activeTabId == TabId(4))
        await settle()
        #expect(windowA.activeTabId == TabId(4))
    }

    @Test func aFocusedPaneClosedElsewhereFallsBackToTheTabsFocus() async {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        let windowB = WindowLayoutStore(base: base)
        windowA.apply(.focus(PaneId(5)))
        windowB.apply(.close(PaneId(5)))
        #expect(windowA.session.activeTab?.focused == PaneId(1))
        await settle()
        #expect(windowA.focusedPanes[TabId(2)] == nil)
    }

    @Test func directionalFocusUsesTheWindowsOwnFocus() {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        let windowB = WindowLayoutStore(base: base)
        windowA.apply(.focus(PaneId(1)))
        windowB.apply(.focus(PaneId(5)))
        windowA.apply(.focusDirection(.down))
        #expect(windowA.session.activeTab?.focused == PaneId(5))
        windowB.apply(.focusDirection(.up))
        #expect(windowB.session.activeTab?.focused == PaneId(1))
    }

    @Test func zoomActsOnTheWindowsPane() {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        let windowB = WindowLayoutStore(base: base)
        windowA.apply(.focus(PaneId(5)))
        windowB.select(tab: TabId(4))
        windowA.apply(.toggleZoom)
        #expect(base.session.tabs.first?.zoomed == PaneId(5))
        #expect(windowA.session.activeTab?.zoomed == PaneId(5))
        #expect(windowA.view.visible == [PaneId(5)])
        #expect(windowB.session.activeTabId == TabId(4))
    }

    @Test func viewNamesTheWindowsVisiblePanes() {
        let base = twoTabs()
        let windowA = WindowLayoutStore(base: base)
        windowA.apply(.focus(PaneId(5)))
        #expect(windowA.view.focused == PaneId(5))
        #expect(Set(windowA.view.visible) == [PaneId(1), PaneId(5)])
    }
}
