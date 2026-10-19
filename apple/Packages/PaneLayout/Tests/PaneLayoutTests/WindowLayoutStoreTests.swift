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
    @Test func windowsSelectTabsIndependently() {
        let base = twoTabs()
        let a = WindowLayoutStore(base: base)
        let b = WindowLayoutStore(base: base)
        #expect(a.session.activeTabId == TabId(2))
        b.select(tab: TabId(4))
        #expect(b.session.activeTabId == TabId(4))
        #expect(a.session.activeTabId == TabId(2))
        // The base heard the last focus (a daemon keeps it for other devices).
        #expect(base.session.activeTabId == TabId(4))
    }

    @Test func focusInATabIsPerWindow() {
        let base = twoTabs()
        let a = WindowLayoutStore(base: base)
        let b = WindowLayoutStore(base: base)
        a.apply(.focus(PaneId(5)))
        #expect(a.session.activeTab?.focused == PaneId(5))
        b.apply(.focus(PaneId(1)))
        #expect(b.session.activeTab?.focused == PaneId(1))
        #expect(a.session.activeTab?.focused == PaneId(5))
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
        let a = WindowLayoutStore(base: base)
        let b = WindowLayoutStore(base: base)
        b.select(tab: TabId(4))
        a.apply(.newTab)
        let new = try! #require(base.session.tabs.map(\.id).first { ![TabId(2), TabId(4)].contains($0) })
        #expect(a.session.activeTabId == new)
        #expect(b.session.activeTabId == TabId(4))
        // After a's tab, not after b's (the base was aligned with a first).
        #expect(base.session.tabs.map(\.id) == [TabId(2), new, TabId(4)])
    }

    @Test func aSplitFocusesTheNewPaneInThatWindow() {
        let base = twoTabs()
        let a = WindowLayoutStore(base: base)
        let b = WindowLayoutStore(base: base)
        b.apply(.focus(PaneId(1)))
        a.apply(.split(PaneId(5), .horizontal))
        let new = try! #require(base.session.panes.subtracting([PaneId(1), PaneId(3), PaneId(5)]).first)
        #expect(a.session.activeTab?.focused == new)
        #expect(b.session.activeTab?.focused == PaneId(1))
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
        let a = WindowLayoutStore(base: base)
        let b = WindowLayoutStore(base: base)
        a.select(tab: TabId(2))
        b.apply(.closeTab(TabId(2)))
        #expect(a.session.activeTabId == TabId(4))
        await settle()
        #expect(a.activeTabId == TabId(4))
    }

    @Test func aFocusedPaneClosedElsewhereFallsBackToTheTabsFocus() async {
        let base = twoTabs()
        let a = WindowLayoutStore(base: base)
        let b = WindowLayoutStore(base: base)
        a.apply(.focus(PaneId(5)))
        b.apply(.close(PaneId(5)))
        #expect(a.session.activeTab?.focused == PaneId(1))
        await settle()
        #expect(a.focusedPanes[TabId(2)] == nil)
    }

    @Test func directionalFocusUsesTheWindowsOwnFocus() {
        let base = twoTabs()
        let a = WindowLayoutStore(base: base)
        let b = WindowLayoutStore(base: base)
        a.apply(.focus(PaneId(1)))
        b.apply(.focus(PaneId(5)))
        a.apply(.focusDirection(.down))
        #expect(a.session.activeTab?.focused == PaneId(5))
        b.apply(.focusDirection(.up))
        #expect(b.session.activeTab?.focused == PaneId(1))
    }

    @Test func zoomActsOnTheWindowsPane() {
        let base = twoTabs()
        let a = WindowLayoutStore(base: base)
        let b = WindowLayoutStore(base: base)
        a.apply(.focus(PaneId(5)))
        b.select(tab: TabId(4))
        a.apply(.toggleZoom)
        #expect(base.session.tabs.first?.zoomed == PaneId(5))
        #expect(a.session.activeTab?.zoomed == PaneId(5))
        #expect(a.view.visible == [PaneId(5)])
        #expect(b.session.activeTabId == TabId(4))
    }

    @Test func viewNamesTheWindowsVisiblePanes() {
        let base = twoTabs()
        let a = WindowLayoutStore(base: base)
        a.apply(.focus(PaneId(5)))
        #expect(a.view.focused == PaneId(5))
        #expect(Set(a.view.visible) == [PaneId(1), PaneId(5)])
    }
}
