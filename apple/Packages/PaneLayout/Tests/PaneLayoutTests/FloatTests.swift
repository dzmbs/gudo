import CoreGraphics
import Foundation
import Testing
@testable import PaneLayout

/// Floating windows in the local model: the same rules the daemon keeps (DAEMON.md §1), so a
/// layout this device keeps behaves like a host's.
@Suite struct FloatTests {
    /// p1 | p2 | p3.
    private func three() -> (Session, [PaneId]) {
        var s = Session()
        let p1 = s.activeTab!.focused
        s.apply(.split(p1, .horizontal))
        let p2 = s.activeTab!.focused
        s.apply(.split(p2, .horizontal))
        let p3 = s.activeTab!.focused
        return (s, [p1, p2, p3])
    }

    private func tiled(_ s: Session) -> [PaneId] {
        s.tiledRoot(of: s.activeTab!)?.panes ?? []
    }

    private func windows(_ s: Session) -> [[PaneId]] {
        s.floats.map(\.panes)
    }

    /// Every window is one subtree of one tab, back to front, and every tab keeps a tiled pane.
    private func checkInvariants(_ s: Session, sourceLocation: SourceLocation = #_sourceLocation) {
        for window in s.floats {
            let tab = s.tab(containing: window.panes[0])
            #expect(tab?.root.subtree(of: window.panes)?.panes == window.panes, sourceLocation: sourceLocation)
        }
        for tab in s.tabs { #expect(s.tiledRoot(of: tab) != nil, sourceLocation: sourceLocation) }
        let zs = s.floats.map(\.z)
        #expect(zs == zs.sorted() && Set(zs).count == zs.count, sourceLocation: sourceLocation)
    }

    @Test func aPaneFloatsAndDocksBackWhereItWas() {
        var (s, p) = three()
        let tree = s.activeTab!.root
        s.apply(.float(p[1], frame: nil))
        #expect(windows(s) == [[p[1]]])
        #expect(tiled(s) == [p[0], p[2]])
        #expect(s.activeTab!.root == tree, "the tree is what older clients see")
        s.apply(.dock(p[1], beside: nil, side: .right))
        #expect(s.floats.isEmpty)
        #expect(s.activeTab!.focused == p[1])
        #expect(s.activeTab!.root == tree)

        s.apply(.float(p[0], frame: nil))
        s.apply(.float(p[1], frame: nil))
        s.apply(.float(p[2], frame: nil))
        #expect(tiled(s) == [p[2]], "a tab keeps a tiled pane")
        checkInvariants(s)
    }

    @Test func newFloatsCascadeAndNeverStealFocus() {
        var (s, p) = three()
        s.apply(.focus(p[0]))
        s.apply(.newFloat(beside: p[2], frame: nil, focus: false))
        s.apply(.newFloat(beside: p[0], frame: nil, focus: false))
        #expect(s.activeTab!.focused == p[0])
        #expect(s.floats.count == 2)
        #expect(s.floats[0].frame != s.floats[1].frame)
        #expect(Array(s.activeTab!.root.panes.prefix(3)) == p)
        s.apply(.newFloat(beside: p[0], frame: nil, focus: true))
        #expect(s.activeTab!.focused == s.floats.last!.panes[0])
        checkInvariants(s)
    }

    @Test func focusRaisesAndRestoresFromTheTray() {
        var (s, p) = three()
        s.apply(.float(p[0], frame: nil))
        s.apply(.float(p[1], frame: nil))
        s.apply(.setFloat(p[0], frame: nil, minimized: true, pinned: nil))
        s.apply(.focus(p[0]))
        #expect(windows(s) == [[p[1]], [p[0]]])
        #expect(s.floats[1].minimized == false)
        s.apply(.setFloat(p[0], frame: nil, minimized: true, pinned: true))
        #expect(s.activeTab!.focused == p[2], "focus goes back to the tiled panes")
        #expect(s.floats[1].pinned)
        checkInvariants(s)
    }

    @Test func windowsHoldSplitsAndPanesMoveInAndOut() {
        var (s, p) = three()
        s.apply(.newFloat(beside: p[0], frame: nil, focus: true))
        let f = s.activeTab!.focused
        s.apply(.split(f, .vertical))
        let g = s.activeTab!.focused
        #expect(windows(s) == [[f, g]])
        s.apply(.movePane(p[1], beside: g, side: .right))
        #expect(windows(s) == [[f, g, p[1]]])
        #expect(tiled(s) == [p[0], p[2]])
        s.apply(.movePane(f, beside: p[0], side: .down))
        #expect(windows(s) == [[g, p[1]]])
        #expect(tiled(s) == [p[0], f, p[2]])
        s.apply(.float(p[1], frame: nil))
        #expect(windows(s) == [[g], [p[1]]])
        #expect(s.floats[1].frame.x > s.floats[0].frame.x)
        checkInvariants(s)
    }

    @Test func dockingBesideAPaneKeepsTheWindowsSplits() {
        var (s, p) = three()
        s.apply(.newFloat(beside: p[0], frame: nil, focus: true))
        let f = s.activeTab!.focused
        s.apply(.split(f, .vertical))
        let g = s.activeTab!.focused
        s.apply(.dock(g, beside: p[2], side: .down))
        #expect(s.floats.isEmpty)
        #expect(s.activeTab!.root.subtree(of: [p[2], f, g]) == .split(
            axis: .vertical, ratio: 0.5, first: .leaf(p[2]),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(f), second: .leaf(g))))
        #expect(s.activeTab!.focused == g)
        checkInvariants(s)
    }

    @Test func theLastTiledPaneClosingDocksTheFrontWindow() {
        var s = Session()
        let p1 = s.activeTab!.focused
        s.apply(.newFloat(beside: p1, frame: nil, focus: false))
        let a = s.floats[0].panes[0]
        s.apply(.newFloat(beside: p1, frame: nil, focus: false))
        let b = s.floats[1].panes[0]
        s.apply(.close(p1))
        #expect(windows(s) == [[a]])
        #expect(tiled(s) == [b])
        checkInvariants(s)
    }

    @Test func panesMoveToAWholeEdge() {
        var (s, p) = three()
        let id = s.activeTab!.id
        s.apply(.movePaneToEdge(p[2], tab: id, side: .up))
        guard case .split(.vertical, _, .leaf(let top), _) = s.activeTab!.root else {
            Issue.record("not along the top: \(s.activeTab!.root)")
            return
        }
        #expect(top == p[2])
        #expect(s.activeTab!.focused == p[2])
    }

    @Test func focusMovesWithinItsLayer() {
        var (s, p) = three()
        s.apply(.float(p[1], frame: nil))
        s.apply(.focus(p[0]))
        s.apply(.focusDirection(.right))
        #expect(s.activeTab!.focused == p[2], "over the floating pane's slot")
        s.apply(.focus(p[1]))
        s.apply(.focusDirection(.left))
        #expect(s.activeTab!.focused == p[1], "a one-pane window's edge")
    }

    @Test func framesStayInsideTheTab() {
        var (s, p) = three()
        s.apply(.float(p[1], frame: FloatFrame(x: 0.95, y: -1, width: 0.5, height: 0.01)))
        #expect(s.floats[0].frame == FloatFrame(x: 0.5, y: 0, width: 0.5, height: FloatFrame.minimumSide))
        s.apply(.setFloat(p[1], frame: FloatFrame(x: .nan, y: 0, width: 1, height: 1), minimized: nil, pinned: nil))
        #expect(s.floats[0].frame.x == 0.5, "a frame that is not finite is ignored")
    }

    @Test func layoutsSavedBeforeFloatsStillDecode() throws {
        let (s, _) = three()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        json["floats"] = nil
        json["lastFloat"] = nil
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == s)
    }
}

extension FloatTests {
    @Test func dividersMoveOnlyWithinTheirLayer() {
        // (p1 | p2) | p3 with p2 floating: on screen p1 | p3.
        var s = Session()
        let p1 = s.activeTab!.focused
        s.apply(.split(p1, .horizontal))
        s.apply(.split(p1, .horizontal))
        let p2 = s.activeTab!.focused
        s.apply(.float(p2, frame: nil))
        s.apply(.resize(p1, .right, amount: 0.1))
        guard case .split(_, let ratio, .split(_, let hidden, _, _), _) = s.activeTab!.root else {
            Issue.record("shape: \(s.activeTab!.root)")
            return
        }
        #expect(abs(ratio - 0.6) < 1e-9, "the divider on screen moved")
        #expect(hidden == 0.5, "the floated pane's split stays")
    }
}
