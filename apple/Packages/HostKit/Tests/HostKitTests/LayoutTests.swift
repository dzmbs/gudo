import Foundation
@testable import HostKit
import PaneLayout
import Testing
import GudoCore

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

    @Test func hostileRatiosAreMadeSafe() throws {
        for (hostile, expected) in [(Float.nan, 0.5), (.infinity, 0.5), (-.infinity, 0.5), (7, 0.95), (-1, 0.05), (0, 0.05)] {
            var layout = sampleLayout()
            layout.tabs[0].nodes[0] = .split(axis: .horizontal, ratio: hostile, first: 1, second: 2)
            let root = try #require(LayoutConversion.session(layout).activeTab?.root)
            guard case .split(_, let ratio, _, _) = root else { Issue.record("not a split"); continue }
            #expect(ratio == expected, "\(hostile)")
        }
    }

    @Test func opsMapToTheDaemonVocabulary() {
        let session = LayoutConversion.session(sampleLayout())
        func op(_ local: PaneLayout.LayoutOp) -> GudoCore.LayoutOp? {
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
        var sent: [GudoCore.LayoutOp] = []
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

    @Test func aZoomNeverShowsUndoneByAnEarlierEcho() {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.receive(sampleLayout(revision: 1, focused: 3))

        // The header's Zoom button: focus the pane, then zoom it.
        store.apply(.focus(PaneId(2)))
        store.apply(.toggleZoom)
        #expect(store.session.activeTab?.zoomed == PaneId(2))
        // The daemon's layout after the focus, before the zoom: still zoomed here.
        store.receive(sampleLayout(revision: 2, focused: 2))
        #expect(store.session.activeTab?.zoomed == PaneId(2))
        // Its layout after the zoom, then the answers.
        store.receive(sampleLayout(revision: 3, focused: 2, zoomed: 2))
        #expect(store.session.activeTab?.zoomed == PaneId(2))
        store.acknowledge(1, failed: false)
        store.acknowledge(2, failed: false)
        #expect(store.session.activeTab?.zoomed == PaneId(2))

        // Back: the echo of the zoom does not zoom it again.
        store.apply(.toggleZoom)
        #expect(store.session.activeTab?.zoomed == nil)
        store.receive(sampleLayout(revision: 4, focused: 2, zoomed: 2))
        #expect(store.session.activeTab?.zoomed == nil)
        store.receive(sampleLayout(revision: 5, focused: 2))
        store.acknowledge(3, failed: false)
        #expect(store.session.activeTab?.zoomed == nil)

        // A refused zoom goes.
        store.apply(.toggleZoom)
        store.acknowledge(4, failed: true)
        #expect(store.session.activeTab?.zoomed == nil)
    }

    @Test func directionalFocusHoldsUntilTheDaemonHasIt() {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.receive(sampleLayout(revision: 1, focused: 1))
        store.apply(.focusDirection(.right))
        let moved = store.session.activeTab?.focused
        #expect(moved != PaneId(1))
        store.receive(sampleLayout(revision: 2, focused: 1))
        #expect(store.session.activeTab?.focused == moved)
    }

    private func rootRatio(_ store: DaemonLayoutStore) -> Double? {
        guard case .split(_, let ratio, _, _) = store.session.activeTab?.root else { return nil }
        return ratio
    }

    /// The daemon's answers to a drag's earlier ratios arrive while the pointer has moved on,
    /// and the last one after it is let go: the divider stays where the pointer left it.
    @Test func aDraggedDividerNeverStepsBackForAnEcho() {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.supportsSplitRatios = true
        store.ratioInterval = .zero
        store.receive(sampleLayout(revision: 1))
        let ratios = [0.55, 0.6, 0.65]
        for ratio in ratios { store.apply(.setRatio(PaneId(1), .horizontal, ratio: ratio)) }
        let final = LayoutConversion.wireRatio(0.65)
        #expect(sent == ratios.map { .setRatio(paneId: 1, axis: .horizontal, ratio: Float($0)) })
        #expect(rootRatio(store) == final)

        store.receive(sampleLayout(revision: 2, ratio: 0.55))
        store.acknowledge(1, failed: false)
        #expect(rootRatio(store) == final)
        store.receive(sampleLayout(revision: 3, ratio: 0.6))
        store.acknowledge(2, failed: false)
        #expect(rootRatio(store) == final)
        store.receive(sampleLayout(revision: 4, ratio: 0.65))
        store.acknowledge(3, failed: false)
        #expect(rootRatio(store) == final, "the daemon's ratio is the one drawn")
    }

    @Test func aDraggedDividerIsSentAtMostOncePerInterval() async throws {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.supportsSplitRatios = true
        store.ratioInterval = .milliseconds(40)
        store.receive(sampleLayout(revision: 1))

        store.apply(.setRatio(PaneId(1), .horizontal, ratio: 0.55))
        store.apply(.setRatio(PaneId(1), .horizontal, ratio: 0.6))
        store.apply(.setRatio(PaneId(1), .horizontal, ratio: 0.65))
        #expect(sent == [.setRatio(paneId: 1, axis: .horizontal, ratio: 0.55)])
        #expect(rootRatio(store) == LayoutConversion.wireRatio(0.65), "the divider follows the pointer at once")
        store.receive(sampleLayout(revision: 2, ratio: 0.55))
        store.acknowledge(1, failed: false)
        #expect(rootRatio(store) == LayoutConversion.wireRatio(0.65))

        let deadline = ContinuousClock.now + .seconds(5)
        while sent.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sent.last == .setRatio(paneId: 1, axis: .horizontal, ratio: 0.65), "the last ratio always goes")
        #expect(sent.count == 2)
    }

    /// A daemon without `SetRatio` gets each ratio as the step from the one before; the ratio
    /// still holds against its echoes.
    @Test func olderDaemonsGetStepsAndTheDividerStillHolds() {
        var sent: [GudoCore.LayoutOp] = []
        let store = DaemonLayoutStore { sent.append($0); return UInt64(sent.count) }
        store.receive(sampleLayout(revision: 1))
        store.apply(.setRatio(PaneId(1), .horizontal, ratio: 0.6))
        store.apply(.setRatio(PaneId(1), .horizontal, ratio: 0.55))
        let steps = sent.compactMap { op -> Float? in
            guard case .resize(paneId: 1, axis: .horizontal, let delta) = op else { return nil }
            return delta
        }
        #expect(steps.count == 2)
        #expect(abs(steps[0] - 0.1) < 1e-6 && abs(steps[1] + 0.05) < 1e-6)
        store.receive(sampleLayout(revision: 2, ratio: 0.6))
        store.acknowledge(1, failed: false)
        #expect(rootRatio(store) == LayoutConversion.wireRatio(0.55))
    }

    @Test func zoomedTabsShowOnlyTheZoomedPane() {
        let store = DaemonLayoutStore { _ in 0 }
        store.receive(sampleLayout(zoomed: 2))
        #expect(store.view.visible == [2])
        store.receive(sampleLayout(revision: 2))
        #expect(store.view.visible == [1, 2, 3])
    }
}
