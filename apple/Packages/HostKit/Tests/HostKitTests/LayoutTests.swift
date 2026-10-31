import Foundation
@testable import HostKit
import PaneLayout
import Testing
import UnnamedCore

@Suite struct LayoutConversionTests {
    @Test func flattenedTreesBecomeSplitTrees() {
        let session = LayoutConversion.session(sampleLayout())
        let tab = try! #require(session.activeTab)
        #expect(tab.id == TabId(10))
        #expect(tab.title == nil)
        #expect(tab.focused == PaneId(3))
        #expect(tab.root == .split(
            axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(1)),
            second: .split(axis: .vertical, ratio: 0.25, first: .leaf(PaneId(2)), second: .leaf(PaneId(3)))))
        #expect(session.panes == [PaneId(1), PaneId(2), PaneId(3)])
    }

    @Test func malformedTreesAreDropped() {
        var layout = sampleLayout()
        layout.tabs[0].nodes = [.split(axis: .horizontal, ratio: 0.5, first: 0, second: 9)]
        #expect(LayoutConversion.session(layout).tabs.isEmpty)
    }

    @Test func opsMapToTheDaemonVocabulary() {
        let session = LayoutConversion.session(sampleLayout())
        func op(_ local: PaneLayout.LayoutOp) -> UnnamedCore.LayoutOp? {
            LayoutConversion.op(local, sessionId: 7, session: session)
        }
        #expect(op(.split(PaneId(3), .horizontal)) == .split(paneId: 3, axis: .horizontal, launch: .shell(cwd: nil)))
        #expect(op(.close(PaneId(2))) == .closePane(paneId: 2))
        #expect(op(.focusDirection(.left)) == .focusDirection(tabId: 10, direction: .left))
        #expect(op(.toggleZoom) == .toggleZoom(paneId: 3))
        #expect(op(.newTab) == .newTab(sessionId: 7, name: "", launch: .shell(cwd: nil)))
        #expect(op(.rename(TabId(10), "logs")) == .renameTab(tabId: 10, name: "logs"))
        #expect(op(.moveTab(TabId(10), to: -3)) == .moveTab(tabId: 10, index: 0))
        // Moving the divider right grows a pane on its left and shrinks one on its right.
        #expect(op(.resize(PaneId(1), .right, amount: 0.1)) == .resize(paneId: 1, axis: .horizontal, delta: 0.1))
        #expect(op(.resize(PaneId(2), .right, amount: 0.1)) == .resize(paneId: 2, axis: .horizontal, delta: -0.1))
        // Pane 3 is the bottom of the vertical split: moving its divider up grows it.
        #expect(op(.resize(PaneId(3), .up, amount: 0.05)) == .resize(paneId: 3, axis: .vertical, delta: 0.05))
        #expect(op(.resize(PaneId(1), .up, amount: 0.05)) == nil, "no vertical divider next to pane 1")
        #expect(op(.movePaneToNewTab(PaneId(3))) == .breakPane(paneId: 3))
        #expect(op(.movePane(PaneId(3), beside: PaneId(1), side: .left)) == .movePane(paneId: 3, target: 1, side: .left))
        #expect(op(.mergeTab(TabId(10), beside: PaneId(1), side: .down)) == .mergeTab(tabId: 10, target: 1, side: .down))
        #expect(!LayoutConversion.isOptimistic(.movePaneToNewTab(PaneId(3))), "the daemon decides")
    }
}

@MainActor
@Suite struct DaemonLayoutStoreTests {
    @Test func theDaemonIsTheSourceOfTruth() {
        var sent: [UnnamedCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        // Nothing to apply to before the first layout.
        store.apply(.newTab)
        #expect(sent.isEmpty)
        #expect(!store.hasLayout)

        store.receive(sampleLayout(revision: 5))
        #expect(store.hasLayout)
        #expect(store.sessionId == 7)

        // Splits wait for the daemon (it allocates the pane id).
        store.apply(.split(PaneId(3), .vertical))
        #expect(sent.last == .split(paneId: 3, axis: .vertical, launch: .shell(cwd: nil)))
        #expect(store.session.panes.count == 3)

        // Focus changes show at once and are sent.
        store.apply(.focus(PaneId(1)))
        #expect(store.session.activeTab?.focused == PaneId(1))
        #expect(sent.last == .focus(paneId: 1))
        #expect(store.view.focused == 1)

        // An older layout is ignored; a newer one replaces the optimistic state once the
        // daemon has answered the op (until then the op is replayed on top).
        store.receive(sampleLayout(revision: 4, focused: 2))
        #expect(store.session.activeTab?.focused == PaneId(1))
        store.receive(sampleLayout(revision: 6, focused: 2))
        #expect(store.session.activeTab?.focused == PaneId(1))
        store.acknowledge(UInt64(sent.count), failed: false)
        store.receive(sampleLayout(revision: 7, focused: 2))
        #expect(store.session.activeTab?.focused == PaneId(2))

        // A failed op drops optimistic changes.
        store.apply(.focus(PaneId(3)))
        #expect(store.session.activeTab?.focused == PaneId(3))
        store.revertToConfirmed()
        #expect(store.session.activeTab?.focused == PaneId(2))

        // After a daemon restart revisions start over.
        store.resetRevision()
        store.receive(sampleLayout(revision: 1, focused: 1))
        #expect(store.session.activeTab?.focused == PaneId(1))
    }

    @Test func zoomedTabsShowOnlyTheZoomedPane() {
        let store = DaemonLayoutStore { _ in 0 }
        store.receive(sampleLayout(zoomed: 2))
        #expect(store.view.visible == [2])
        store.receive(sampleLayout(revision: 2))
        #expect(store.view.visible == [1, 2, 3])
    }
}
