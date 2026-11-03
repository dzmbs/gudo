import Foundation
import Testing
@testable import PaneLayout

// Ids are allocated in order: the first tab holds pane 1 (tab id 2); each split or new tab takes
// the next number.
private let p1 = PaneId(1)

private func ratio(_ node: Node) -> Double? {
    if case .split(_, let ratio, _, _) = node { ratio } else { nil }
}

/// [p1 / p4] | [p3 / p5]
private func grid() -> Session {
    var session = Session()
    session.apply(.split(p1, .horizontal))  // p3
    session.apply(.split(p1, .vertical))  // p4
    session.apply(.split(PaneId(3), .vertical))  // p5
    return session
}

@Suite struct SplitTests {
    @Test func newPaneGoesSecondAndTakesFocus() {
        var session = Session()
        session.apply(.split(p1, .horizontal))
        let tab = session.activeTab!
        #expect(tab.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(p1), second: .leaf(PaneId(3))))
        #expect(tab.focused == PaneId(3))
    }

    @Test func splittingANestedPaneKeepsTheRestOfTheTree() {
        let session = grid()
        #expect(session.activeTab!.root == .split(
            axis: .horizontal, ratio: 0.5,
            first: .split(axis: .vertical, ratio: 0.5, first: .leaf(p1), second: .leaf(PaneId(4))),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(PaneId(3)), second: .leaf(PaneId(5)))))
        #expect(session.panes == [p1, PaneId(3), PaneId(4), PaneId(5)])
    }

    @Test func unknownPaneIsIgnored() {
        var session = Session()
        let before = session
        session.apply(.split(PaneId(99), .vertical))
        session.apply(.close(PaneId(99)))
        session.apply(.resize(PaneId(99), .left, amount: 0.1))
        #expect(session == before)
    }
}

@Suite struct CloseTests {
    @Test func closingTheLastPaneClosesTheTab() {
        var session = Session()
        session.apply(.newTab)  // tab 4, pane 3
        session.apply(.close(PaneId(3)))
        #expect(session.tabs.map(\.id) == [TabId(2)])
        #expect(session.activeTabId == TabId(2))
        session.apply(.close(p1))
        #expect(session.tabs.isEmpty)
        #expect(session.activeTabId == nil)
    }

    @Test func siblingSubtreeTakesTheParentsPlace() {
        var session = Session()
        session.apply(.split(p1, .horizontal))  // p3
        session.apply(.split(PaneId(3), .vertical))  // p5
        session.apply(.resize(PaneId(3), .down, amount: 0.2))
        session.apply(.focus(p1))
        session.apply(.close(p1))
        let tab = session.activeTab!
        #expect(tab.root == .split(axis: .vertical, ratio: 0.7, first: .leaf(PaneId(3)), second: .leaf(PaneId(4))))
        #expect(tab.focused == PaneId(3), "closing a first child focuses the sibling's first pane")
    }

    @Test func closingASecondChildFocusesTheSiblingsLastPane() {
        var session = grid()
        session.apply(.focus(PaneId(3)))
        session.apply(.close(PaneId(3)))
        session.apply(.close(PaneId(5)))
        #expect(session.activeTab!.root == .split(axis: .vertical, ratio: 0.5, first: .leaf(p1), second: .leaf(PaneId(4))))
        #expect(session.activeTab!.focused == PaneId(4))
    }

    @Test func closingAnotherPaneKeepsFocusAndZoom() {
        var session = grid()
        session.apply(.focus(p1))
        session.apply(.toggleZoom)
        session.apply(.close(PaneId(5)))
        #expect(session.activeTab!.focused == p1)
        #expect(session.activeTab!.zoomed == p1)
    }

    @Test func aZoomSetTwiceStaysSet() {
        var session = grid()
        let tab = session.activeTab!.id
        session.setZoom(p1, inTab: tab)
        session.setZoom(p1, inTab: tab)
        #expect(session.activeTab!.zoomed == p1)
        session.setZoom(nil, inTab: tab)
        session.setZoom(nil, inTab: tab)
        #expect(session.activeTab!.zoomed == nil)
        session.setZoom(PaneId(99), inTab: tab)
        #expect(session.activeTab!.zoomed == nil, "not in the tab")
        var single = Session()
        single.setZoom(p1, inTab: single.activeTab!.id)
        #expect(single.activeTab!.zoomed == nil, "a tab of one pane")
    }

    @Test func closingTheZoomedPaneUnzooms() {
        var session = grid()
        session.apply(.toggleZoom)
        session.apply(.close(PaneId(5)))
        #expect(session.activeTab!.zoomed == nil)
        #expect(session.activeTab!.focused == PaneId(3))
    }
}

@Suite struct FocusDirectionTests {
    private func focused(after directions: [Direction], from pane: PaneId, in session: Session) -> PaneId {
        var session = session
        session.apply(.focus(pane))
        directions.forEach { session.apply(.focusDirection($0)) }
        return session.activeTab!.focused
    }

    @Test func movesBetweenGridNeighbours() {
        let session = grid()
        #expect(focused(after: [.right], from: p1, in: session) == PaneId(3))
        #expect(focused(after: [.down], from: p1, in: session) == PaneId(4))
        #expect(focused(after: [.left], from: PaneId(5), in: session) == PaneId(4))
        #expect(focused(after: [.up], from: PaneId(5), in: session) == PaneId(3))
        #expect(focused(after: [.right, .down, .left, .up], from: p1, in: session) == p1)
    }

    @Test func stopsAtTheEdgeWithoutWrapping() {
        let session = grid()
        #expect(focused(after: [.left], from: p1, in: session) == p1)
        #expect(focused(after: [.up], from: p1, in: session) == p1)
        #expect(focused(after: [.right], from: PaneId(5), in: session) == PaneId(5))
        #expect(focused(after: [.down], from: PaneId(5), in: session) == PaneId(5))
    }

    @Test func prefersTheNeighbourSharingTheLongestEdge() {
        var session = grid()
        session.apply(.resize(p1, .down, amount: -0.2))  // left column: p1 0..0.3, p4 0.3..1
        session.apply(.resize(PaneId(3), .down, amount: 0.2))  // right column: p3 0..0.7, p5 0.7..1
        #expect(focused(after: [.right], from: PaneId(4), in: session) == PaneId(3))  // 0.4 vs 0.3 shared
        #expect(focused(after: [.left], from: PaneId(5), in: session) == PaneId(4))
        #expect(focused(after: [.left], from: PaneId(3), in: session) == PaneId(4))  // 0.4 vs 0.3 shared
    }

    @Test func neverMovesDiagonally() {
        var session = Session()
        session.apply(.split(p1, .vertical))  // p3 below
        session.apply(.split(p1, .horizontal))  // p4 right of p1, above p3
        #expect(focused(after: [.left], from: PaneId(4), in: session) == p1)
        #expect(focused(after: [.down], from: PaneId(4), in: session) == PaneId(3))
        #expect(focused(after: [.up], from: PaneId(3), in: session) == p1, "equal overlap: reading order")
    }

    @Test func unzooms() {
        var session = grid()
        session.apply(.focus(p1))
        session.apply(.toggleZoom)
        session.apply(.focusDirection(.right))
        #expect(session.activeTab!.focused == PaneId(3))
        #expect(session.activeTab!.zoomed == nil)
    }
}

@Suite struct ResizeTests {
    private func twoPanes() -> Session {
        var session = Session()
        session.apply(.split(p1, .horizontal))  // p1 | p3
        return session
    }

    @Test func movesTheDividerOnThePanesSide() {
        var session = twoPanes()
        session.apply(.resize(p1, .right, amount: 0.1))
        #expect(ratio(session.activeTab!.root) == 0.6)
        session.apply(.resize(PaneId(3), .left, amount: 0.2))
        #expect(ratio(session.activeTab!.root)!.isApproximately(0.4))
    }

    @Test func atTheWindowEdgeMovesTheOppositeDivider() {
        var session = twoPanes()
        session.apply(.resize(PaneId(3), .right, amount: 0.1))
        #expect(ratio(session.activeTab!.root) == 0.6)
        session.apply(.resize(p1, .left, amount: 0.3))
        #expect(ratio(session.activeTab!.root)!.isApproximately(0.3))
    }

    @Test func clampsSoNoChildCollapses() {
        var session = twoPanes()
        session.apply(.resize(p1, .right, amount: 5))
        #expect(ratio(session.activeTab!.root) == Node.ratioRange.upperBound)
        session.apply(.resize(p1, .left, amount: 5))
        #expect(ratio(session.activeTab!.root) == Node.ratioRange.lowerBound)
    }

    @Test func withoutASplitOnThatAxisIsANoOp() {
        var session = twoPanes()
        let before = session
        session.apply(.resize(p1, .down, amount: 0.1))
        session.apply(.resize(p1, .up, amount: 0.1))
        #expect(session == before)
    }

    @Test func choosesTheDeepestSplitFacingTheDirection() {
        var session = Session()
        session.apply(.split(p1, .horizontal))  // p1 | p3
        session.apply(.split(PaneId(3), .horizontal))  // p1 | (p3 | p4)
        let p3 = PaneId(3)

        session.apply(.resize(p3, .right, amount: 0.1))  // p3's right edge: the inner divider
        guard case .split(_, let outer, _, let inner) = session.activeTab!.root else { Issue.record(); return }
        #expect(outer == 0.5)
        #expect(ratio(inner) == 0.6)

        session.apply(.resize(p3, .left, amount: 0.1))  // p3's left edge: the outer divider
        guard case .split(_, let outer2, _, let inner2) = session.activeTab!.root else { Issue.record(); return }
        #expect(outer2 == 0.4)
        #expect(ratio(inner2) == 0.6)
    }
}

@Suite struct ZoomTests {
    @Test func aSinglePaneCannotZoom() {
        var session = Session()
        session.apply(.toggleZoom)
        #expect(session.activeTab!.zoomed == nil)
    }

    @Test func togglesTheFocusedPaneAndSplittingUnzooms() {
        var session = grid()
        session.apply(.focus(PaneId(4)))
        session.apply(.toggleZoom)
        #expect(session.activeTab!.zoomed == PaneId(4))
        session.apply(.toggleZoom)
        #expect(session.activeTab!.zoomed == nil)
        session.apply(.toggleZoom)
        session.apply(.split(PaneId(4), .horizontal))
        #expect(session.activeTab!.zoomed == nil)
    }
}

@Suite struct TabTests {
    @Test func newTabOpensAfterTheActiveTab() {
        var session = Session()  // tab 2
        session.apply(.newTab)  // tab 4
        session.apply(.focus(p1))
        session.apply(.newTab)  // tab 6, between 2 and 4
        #expect(session.tabs.map(\.id) == [TabId(2), TabId(6), TabId(4)])
        #expect(session.activeTabId == TabId(6))
    }

    @Test func closingTheActiveTabActivatesItsRightNeighbourElseItsLeft() {
        var session = Session()
        session.apply(.newTab)  // tab 4
        session.apply(.newTab)  // tab 6
        session.apply(.focus(PaneId(3)))  // activates tab 4
        session.apply(.closeTab(TabId(4)))
        #expect(session.activeTabId == TabId(6))
        session.apply(.closeTab(TabId(6)))
        #expect(session.activeTabId == TabId(2))
    }

    @Test func closingAnInactiveTabKeepsTheActiveOne() {
        var session = Session()
        session.apply(.newTab)
        session.apply(.closeTab(TabId(2)))
        #expect(session.activeTabId == TabId(4))
    }

    @Test func moveTabClampsTheIndex() {
        var session = Session()
        session.apply(.newTab)
        session.apply(.newTab)
        session.apply(.moveTab(TabId(2), to: 99))
        #expect(session.tabs.map(\.id) == [TabId(4), TabId(6), TabId(2)])
        session.apply(.moveTab(TabId(2), to: -3))
        #expect(session.tabs.map(\.id) == [TabId(2), TabId(4), TabId(6)])
        session.apply(.moveTab(TabId(6), to: 1))
        #expect(session.tabs.map(\.id) == [TabId(2), TabId(6), TabId(4)])
    }

    @Test func renameAndResetTitle() {
        var session = Session()
        session.apply(.rename(TabId(2), "build"))
        #expect(session.activeTab!.title == "build")
        session.apply(.rename(TabId(2), ""))
        #expect(session.activeTab!.title == nil)
    }

    @Test func focusingAPaneActivatesItsTab() {
        var session = Session()
        session.apply(.newTab)
        #expect(session.activeTabId == TabId(4))
        session.apply(.focus(p1))
        #expect(session.activeTabId == TabId(2))
    }
}

@Test func sessionRoundTripsThroughJSON() throws {
    var session = grid()
    session.apply(.toggleZoom)
    session.apply(.newTab)
    session.apply(.rename(TabId(7), "logs"))
    let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
    #expect(decoded == session)
}

@MainActor @Test func localStoreAppliesOps() {
    let store = LocalLayoutStore()
    store.apply(.split(p1, .vertical))
    #expect(store.session.panes == [p1, PaneId(3)])
}

private extension Double {
    func isApproximately(_ other: Double) -> Bool { abs(self - other) < 1e-9 }
}
