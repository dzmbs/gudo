import CoreGraphics
import Foundation
import Testing
@testable import PaneLayout

/// Floating windows in the local model: the same rules the daemon keeps (DAEMON.md §1), so a
/// layout this device keeps behaves like a host's.
@Suite struct FloatTests {
    /// p1 | p2 | p3.
    private func three() -> (Session, [PaneId]) {
        var layout = Session()
        let p1 = layout.activeTab!.focused
        layout.apply(.split(p1, .horizontal))
        let p2 = layout.activeTab!.focused
        layout.apply(.split(p2, .horizontal))
        let p3 = layout.activeTab!.focused
        return (layout, [p1, p2, p3])
    }

    private func tiled(_ layout: Session) -> [PaneId] {
        layout.tiledRoot(of: layout.activeTab!)?.panes ?? []
    }

    private func windows(_ layout: Session) -> [[PaneId]] {
        layout.floats.map(\.panes)
    }

    /// Every window is one subtree of one tab, back to front, and every tab keeps a tiled pane.
    private func checkInvariants(_ layout: Session, sourceLocation: SourceLocation = #_sourceLocation) {
        for window in layout.floats {
            let tab = layout.tab(containing: window.panes[0])
            #expect(tab?.root.subtree(of: window.panes)?.panes == window.panes, sourceLocation: sourceLocation)
        }
        for tab in layout.tabs { #expect(layout.tiledRoot(of: tab) != nil, sourceLocation: sourceLocation) }
        let stackOrder = layout.floats.map(\.z)
        #expect(stackOrder == stackOrder.sorted() && Set(stackOrder).count == stackOrder.count, sourceLocation: sourceLocation)
    }

    @Test func aPaneFloatsAndDocksBackWhereItWas() {
        var (layout, panes) = three()
        let tree = layout.activeTab!.root
        layout.apply(.float(panes[1], frame: nil))
        #expect(windows(layout) == [[panes[1]]])
        #expect(tiled(layout) == [panes[0], panes[2]])
        #expect(layout.activeTab!.root == tree, "the tree is what older clients see")
        layout.apply(.dock(panes[1], beside: nil, side: .right))
        #expect(layout.floats.isEmpty)
        #expect(layout.activeTab!.focused == panes[1])
        #expect(layout.activeTab!.root == tree)

        layout.apply(.float(panes[0], frame: nil))
        layout.apply(.float(panes[1], frame: nil))
        layout.apply(.float(panes[2], frame: nil))
        #expect(tiled(layout) == [panes[2]], "a tab keeps a tiled pane")
        checkInvariants(layout)
    }

    @Test func newFloatsCascadeAndNeverStealFocus() {
        var (layout, panes) = three()
        layout.apply(.focus(panes[0]))
        layout.apply(.newFloat(beside: panes[2], frame: nil, focus: false))
        layout.apply(.newFloat(beside: panes[0], frame: nil, focus: false))
        #expect(layout.activeTab!.focused == panes[0])
        #expect(layout.floats.count == 2)
        #expect(layout.floats[0].frame != layout.floats[1].frame)
        #expect(Array(layout.activeTab!.root.panes.prefix(3)) == panes)
        layout.apply(.newFloat(beside: panes[0], frame: nil, focus: true))
        #expect(layout.activeTab!.focused == layout.floats.last!.panes[0])
        checkInvariants(layout)
    }

    @Test func focusRaisesAndRestoresFromTheTray() {
        var (layout, panes) = three()
        layout.apply(.float(panes[0], frame: nil))
        layout.apply(.float(panes[1], frame: nil))
        layout.apply(.setFloat(panes[0], frame: nil, minimized: true, pinned: nil))
        layout.apply(.focus(panes[0]))
        #expect(windows(layout) == [[panes[1]], [panes[0]]])
        #expect(layout.floats[1].minimized == false)
        layout.apply(.setFloat(panes[0], frame: nil, minimized: true, pinned: true))
        #expect(layout.activeTab!.focused == panes[2], "focus goes back to the tiled panes")
        #expect(layout.floats[1].pinned)
        checkInvariants(layout)
    }

    @Test func windowsHoldSplitsAndPanesMoveInAndOut() {
        var (layout, panes) = three()
        layout.apply(.newFloat(beside: panes[0], frame: nil, focus: true))
        let windowPane = layout.activeTab!.focused
        layout.apply(.split(windowPane, .vertical))
        let splitPane = layout.activeTab!.focused
        #expect(windows(layout) == [[windowPane, splitPane]])
        layout.apply(.movePane(panes[1], beside: splitPane, side: .right))
        #expect(windows(layout) == [[windowPane, splitPane, panes[1]]])
        #expect(tiled(layout) == [panes[0], panes[2]])
        layout.apply(.movePane(windowPane, beside: panes[0], side: .down))
        #expect(windows(layout) == [[splitPane, panes[1]]])
        #expect(tiled(layout) == [panes[0], windowPane, panes[2]])
        layout.apply(.float(panes[1], frame: nil))
        #expect(windows(layout) == [[splitPane], [panes[1]]])
        #expect(layout.floats[1].frame.x > layout.floats[0].frame.x)
        checkInvariants(layout)
    }

    @Test func dockingBesideAPaneKeepsTheWindowsSplits() {
        var (layout, panes) = three()
        layout.apply(.newFloat(beside: panes[0], frame: nil, focus: true))
        let windowPane = layout.activeTab!.focused
        layout.apply(.split(windowPane, .vertical))
        let splitPane = layout.activeTab!.focused
        layout.apply(.dock(splitPane, beside: panes[2], side: .down))
        #expect(layout.floats.isEmpty)
        #expect(layout.activeTab!.root.subtree(of: [panes[2], windowPane, splitPane]) == .split(
            axis: .vertical, ratio: 0.5, first: .leaf(panes[2]),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(windowPane), second: .leaf(splitPane))))
        #expect(layout.activeTab!.focused == splitPane)
        checkInvariants(layout)
    }

    @Test func theLastTiledPaneClosingDocksTheFrontWindow() {
        var layout = Session()
        let p1 = layout.activeTab!.focused
        layout.apply(.newFloat(beside: p1, frame: nil, focus: false))
        let backWindowPane = layout.floats[0].panes[0]
        layout.apply(.newFloat(beside: p1, frame: nil, focus: false))
        let frontWindowPane = layout.floats[1].panes[0]
        layout.apply(.close(p1))
        #expect(windows(layout) == [[backWindowPane]])
        #expect(tiled(layout) == [frontWindowPane])
        checkInvariants(layout)
    }

    @Test func panesMoveToAWholeEdge() {
        var (layout, panes) = three()
        let tabId = layout.activeTab!.id
        layout.apply(.movePaneToEdge(panes[2], tab: tabId, side: .up))
        guard case .split(.vertical, _, .leaf(let top), _) = layout.activeTab!.root else {
            Issue.record("not along the top: \(layout.activeTab!.root)")
            return
        }
        #expect(top == panes[2])
        #expect(layout.activeTab!.focused == panes[2])
    }

    @Test func focusMovesWithinItsLayer() {
        var (layout, panes) = three()
        layout.apply(.float(panes[1], frame: nil))
        layout.apply(.focus(panes[0]))
        layout.apply(.focusDirection(.right))
        #expect(layout.activeTab!.focused == panes[2], "over the floating pane's slot")
        layout.apply(.focus(panes[1]))
        layout.apply(.focusDirection(.left))
        #expect(layout.activeTab!.focused == panes[1], "a one-pane window's edge")
    }

    @Test func framesStayInsideTheTab() {
        var (layout, panes) = three()
        layout.apply(.float(panes[1], frame: FloatFrame(x: 0.95, y: -1, width: 0.5, height: 0.01)))
        #expect(layout.floats[0].frame == FloatFrame(x: 0.5, y: 0, width: 0.5, height: FloatFrame.minimumSide))
        layout.apply(.setFloat(panes[1], frame: FloatFrame(x: .nan, y: 0, width: 1, height: 1), minimized: nil, pinned: nil))
        #expect(layout.floats[0].frame.x == 0.5, "a frame that is not finite is ignored")
    }

    @Test func layoutsSavedBeforeFloatsStillDecode() throws {
        let (layout, _) = three()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as! [String: Any]
        json["floats"] = nil
        json["lastFloat"] = nil
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == layout)
    }
}

extension FloatTests {
    @Test func dividersMoveOnlyWithinTheirLayer() {
        // (p1 | p2) | p3 with p2 floating: on screen p1 | p3.
        var layout = Session()
        let p1 = layout.activeTab!.focused
        layout.apply(.split(p1, .horizontal))
        layout.apply(.split(p1, .horizontal))
        let p2 = layout.activeTab!.focused
        layout.apply(.float(p2, frame: nil))
        layout.apply(.resize(p1, .right, amount: 0.1))
        guard case .split(_, let ratio, .split(_, let hidden, _, _), _) = layout.activeTab!.root else {
            Issue.record("shape: \(layout.activeTab!.root)")
            return
        }
        #expect(abs(ratio - 0.6) < 1e-9, "the divider on screen moved")
        #expect(hidden == 0.5, "the floated pane's split stays")
    }
}
