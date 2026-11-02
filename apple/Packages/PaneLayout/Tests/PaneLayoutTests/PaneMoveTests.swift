import Foundation
import Testing
@testable import PaneLayout

/// Tab 2: p1 | p3 (p3 focused); tab 5: p4.
private func session() -> Session {
    var session = Session()
    session.apply(.split(PaneId(1), .horizontal))
    session.apply(.newTab)
    session.apply(.focus(PaneId(3)))
    return session
}

@Suite struct PaneMoveTests {
    @Test func moveToNewTabGoesRightAfterItsTab() {
        var layout = session()
        layout.apply(.movePaneToNewTab(PaneId(3)))
        #expect(layout.tabs.count == 3)
        #expect(layout.tabs[0].root == .leaf(PaneId(1)))
        #expect(layout.tabs[0].focused == PaneId(1))
        #expect(layout.tabs[1].root == .leaf(PaneId(3)))
        #expect(layout.activeTabId == layout.tabs[1].id)
        #expect(layout.tabs[2].root == .leaf(PaneId(4)))
    }

    @Test func aTabsOnlyPaneStays() {
        var layout = session()
        let before = layout
        layout.apply(.movePaneToNewTab(PaneId(4)))
        #expect(layout == before)
    }

    @Test func movePaneSplitsTheTargetOnItsSide() {
        var layout = session()
        layout.apply(.movePane(PaneId(3), beside: PaneId(4), side: .up))
        #expect(layout.tabs[0].root == .leaf(PaneId(1)))
        #expect(layout.tabs[1].root == .split(axis: .vertical, ratio: 0.5, first: .leaf(PaneId(3)), second: .leaf(PaneId(4))))
        #expect(layout.activeTab?.focused == PaneId(3))
        // Its tab's only pane: the tab goes.
        layout.apply(.movePane(PaneId(1), beside: PaneId(4), side: .right))
        #expect(layout.tabs.count == 1)
        #expect(layout.panes == [PaneId(1), PaneId(3), PaneId(4)])
        // Beside itself: nothing.
        let before = layout
        layout.apply(.movePane(PaneId(1), beside: PaneId(1), side: .left))
        #expect(layout == before)
    }

    @Test func mergeTabKeepsItsArrangementAndFocus() {
        var layout = session()
        layout.apply(.mergeTab(layout.tabs[0].id, beside: PaneId(4), side: .left))
        #expect(layout.tabs.count == 1)
        #expect(layout.tabs[0].root == .split(
            axis: .horizontal, ratio: 0.5,
            first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(1)), second: .leaf(PaneId(3))),
            second: .leaf(PaneId(4))))
        #expect(layout.activeTab?.focused == PaneId(3))
        // Into itself: nothing.
        let before = layout
        layout.apply(.mergeTab(layout.tabs[0].id, beside: PaneId(4), side: .left))
        #expect(layout == before)
    }

    @Test func zoomOnTheMovedPaneIsDropped() {
        var layout = session()
        layout.apply(.toggleZoom)
        layout.apply(.movePaneToNewTab(PaneId(3)))
        #expect(layout.tabs[0].zoomed == nil)
    }

    @MainActor @Test func theWindowFollowsAMovedPane() {
        let base = LocalLayoutStore(session: session())
        let window = WindowLayoutStore(base: base, selecting: TabId(2))
        window.apply(.focus(PaneId(3)))
        window.apply(.movePaneToNewTab(PaneId(3)))
        #expect(window.session.activeTab?.root == .leaf(PaneId(3)))
        window.apply(.mergeTab(window.session.activeTabId!, beside: PaneId(1), side: .down))
        #expect(window.session.activeTab?.focused == PaneId(3))
        #expect(window.session.activeTab?.root.panes == [PaneId(1), PaneId(3)])
    }

    @MainActor @Test func aMixedTabsPaneMovesToANewTabOnItsHost() {
        let hosts = Hosts()
        let id = hosts.mixed()
        hosts.store.split(id, onHost: "alpha", axis: .vertical)
        let alphaPanes = hosts.tab(id).panes(onHost: "alpha")
        #expect(alphaPanes.count == 2)
        let moving = HostPane(hostId: "alpha", pane: alphaPanes[1])
        hosts.deferred = true
        #expect(hosts.store.moveToNewTab(leaf: hosts.tab(id).leaf(for: moving)!, in: id) == nil)
        #expect(hosts.sent.last?.1 == .movePaneToNewTab(moving.pane))
        // Still in the carrier until alpha answers: not adopted back.
        hosts.store.reconcile()
        #expect(hosts.tab(id).leaf(for: moving) == nil)
        hosts.flush()
        #expect(hosts.tab(id).leaf(for: moving) == nil)
        #expect(hosts.sessions["alpha"]!.tabs.count == 2)
        #expect(hosts.sessions["alpha"]!.tabs[1].root == .leaf(moving.pane))
        #expect(hosts.tab(id).hosts == ["alpha", "beta"])
    }

    @MainActor @Test func aMixedTabsEditorMovesToATabOfItsOwn() {
        let hosts = Hosts()
        let id = hosts.mixed()
        let editor = EditorMember(hostId: "beta", folder: "/w")
        let leaf = hosts.store.addEditor(editor, to: id)!
        let moved = hosts.store.moveToNewTab(leaf: leaf, in: id)
        #expect(moved != nil)
        #expect(hosts.store.tab(moved!)?.editors.values.first == editor)
        #expect(hosts.tab(id).editors.isEmpty)
    }
}
