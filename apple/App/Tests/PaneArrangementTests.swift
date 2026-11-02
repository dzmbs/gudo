import Foundation
import HostKit
import PaneLayout
import XCTest
@testable import App

/// The canvas controller: what a dragged pane or a held window lands on, the region lit before
/// the drop, and the op each gesture ends in.
@MainActor
final class PaneArrangementTests: XCTestCase {
    private final class Quiet: PaneBackend, @unchecked Sendable {
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
    }

    private let size = CGSize(width: 1000, height: 600)
    private var workspace: Workspace!
    private var arrangement: PaneArrangement!

    /// Panes 1 | 3 side by side, and pane 5 under 3 when `three`.
    private func make(three: Bool = false) -> (PaneId, PaneId, PaneId?) {
        var session = Session()
        let first = session.activeTab!.focused
        session.apply(.split(first, .horizontal))
        let second = session.activeTab!.focused
        var third: PaneId?
        if three {
            session.apply(.split(second, .vertical))
            third = session.activeTab!.focused
        }
        start(session)
        return (first, second, third)
    }

    /// A fresh workspace on `session`, laid out.
    private func start(_ session: Session) {
        workspace?.close()
        workspace = Workspace(layout: LocalLayoutStore(session: session)) { _ in Quiet() }
        arrangement = PaneArrangement()
        relayout()
    }

    /// Lays the canvas out from the session, as each layout pass does.
    @discardableResult
    private func relayout() -> CanvasLayout {
        let tab = workspace.session.activeTab!
        let layout = CanvasLayout(
            node: workspace.session.tiledRoot(of: tab) ?? tab.root,
            floats: FloatScene(workspace: workspace, tab: tab, hidden: false),
            zoomed: tab.zoomed, focused: tab.focused, size: size, gap: 1, header: 24, cell: nil, padding: 0,
            live: arrangement.live)
        arrangement.update(layout: layout, tree: HostTabTree(workspace: workspace))
        return layout
    }

    private func frame(of pane: PaneId) -> CGRect {
        relayout().leaves.first { $0.pane == pane }!.frame
    }

    private var tiledOrder: [PaneId] {
        workspace.session.activeTab.flatMap { workspace.session.tiledRoot(of: $0) }?.panes ?? []
    }

    override func tearDown() {
        workspace?.close()
        super.tearDown()
    }

    func testDraggingOntoAPaneLightsWhereItWillBeAndDropsThere() {
        let (left, right, _) = make()
        let target = frame(of: right)
        let point = CGPoint(x: target.maxX - 60, y: target.midY)
        arrangement.drag(left, to: point)
        XCTAssertEqual(arrangement.paneDrag?.drop, .beside(right, .right))
        // Its own place closes, so it takes the tab's right half, not half of the right pane.
        let lit = arrangement.paneDrag?.preview
        XCTAssertEqual(lit?.minX ?? 0, size.width / 2, accuracy: 2)
        XCTAssertEqual(lit?.width ?? 0, size.width / 2, accuracy: 2)
        XCTAssertEqual(arrangement.preview?.leaf(right)?.frame.minX, 0, "the other pane makes room")
        arrangement.endDrag(left, at: point)
        XCTAssertNil(arrangement.paneDrag)
        XCTAssertEqual(tiledOrder, [right, left])
        XCTAssertEqual(frame(of: left), lit)
        XCTAssertNotNil(arrangement.landing, "the region stays lit until the pane is there")
    }

    /// Two panes stacked; the bottom one dragged over the left part of the top one. The top
    /// pane's left half lights, but with its own slot gone the bottom pane takes the tab's
    /// whole left half: that is what must light.
    func testDraggingOutOfATwoPaneSplitLightsTheFrameItReallyGets() {
        var session = Session()
        let top = session.activeTab!.focused
        session.apply(.split(top, .vertical))
        let bottom = session.activeTab!.focused
        start(session)
        let over = frame(of: top)
        let point = CGPoint(x: over.minX + over.width * 0.15, y: over.midY)
        arrangement.drag(bottom, to: point)
        XCTAssertEqual(arrangement.paneDrag?.drop, .beside(top, .left))
        let lit = try? XCTUnwrap(arrangement.paneDrag?.preview)
        XCTAssertEqual(lit?.minY, 0)
        XCTAssertEqual(lit?.height ?? 0, size.height, accuracy: 1, "the whole height: its slot below is gone")
        XCTAssertEqual(lit?.width ?? 0, size.width / 2, accuracy: 2)
        arrangement.endDrag(bottom, at: point)
        XCTAssertEqual(frame(of: bottom), lit)
    }

    /// Every zone over every pane, and every edge of the tab, for every pane dragged, in a two
    /// pane split each way and a three pane tab: the frame lit is the frame the drop gives.
    func testEveryZoneLightsExactlyTheFrameTheDropGives() {
        let layouts: [(String, (inout Session) -> Void)] = [
            ("side by side", { $0.apply(.split($0.activeTab!.focused, .horizontal)) }),
            ("stacked", { $0.apply(.split($0.activeTab!.focused, .vertical)) }),
            ("three", { s in
                s.apply(.split(s.activeTab!.focused, .horizontal))
                s.apply(.split(s.activeTab!.focused, .vertical))
            }),
        ]
        var checked = 0
        for (name, build) in layouts {
            var initial = Session()
            build(&initial)
            let panes = initial.activeTab!.root.panes
            for dragged in panes {
                start(initial)
                var points: [CGPoint] = [
                    CGPoint(x: 10, y: size.height / 2), CGPoint(x: size.width - 10, y: size.height / 2),
                    CGPoint(x: size.width / 2, y: 10), CGPoint(x: size.width / 2, y: size.height - 10),
                ]
                for target in panes where target != dragged {
                    let r = frame(of: target)
                    points += [
                        CGPoint(x: r.minX + r.width * 0.2, y: r.midY), CGPoint(x: r.maxX - r.width * 0.2, y: r.midY),
                        CGPoint(x: r.midX, y: r.minY + r.height * 0.2), CGPoint(x: r.midX, y: r.maxY - r.height * 0.2),
                    ]
                }
                for point in points {
                    start(initial)
                    arrangement.drag(dragged, to: point)
                    guard let drop = arrangement.paneDrag?.drop, drop != .cancel, drop != .float else { continue }
                    let lit = arrangement.paneDrag?.preview
                    let shown = arrangement.preview.map { $0.leaves.map { ($0.pane, $0.frame) } }
                    arrangement.endDrag(dragged, at: point)
                    let after = relayout()
                    XCTAssertEqual(after.leaf(dragged)?.frame, lit, "\(name): pane \(dragged) at \(point) (\(drop))")
                    // The panes making room were shown where they end up, too.
                    for (pane, frame) in shown ?? [] {
                        XCTAssertEqual(after.leaf(pane)?.frame, frame, "\(name): pane \(pane) beside the drop at \(point)")
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }

    /// Along a boundary between two zones the lit one stays until the hand is clearly in the
    /// other: no flicker.
    func testTheZoneUnderTheHandHoldsNearItsBoundary() {
        let (left, right, _) = make()
        let r = frame(of: right)
        // The diagonal between the right pane's top and right zones.
        let onTop = CGPoint(x: r.maxX - r.width * 0.3, y: r.minY + r.height * 0.1)
        arrangement.drag(left, to: onTop)
        XCTAssertEqual(arrangement.paneDrag?.drop, .beside(right, .up))
        let x = r.maxX - r.width * 0.25
        let diagonalY = r.minY + (r.maxX - x) * r.height / r.width
        arrangement.drag(left, to: CGPoint(x: x, y: diagonalY + 4))
        XCTAssertEqual(arrangement.paneDrag?.drop, .beside(right, .up), "4 pt past the diagonal: still the top")
        arrangement.drag(left, to: CGPoint(x: x, y: diagonalY + 40))
        XCTAssertEqual(arrangement.paneDrag?.drop, .beside(right, .right))
    }

    func testDroppingOnItselfChangesNothing() {
        let (left, right, _) = make()
        let own = frame(of: left)
        arrangement.drag(left, to: CGPoint(x: own.midX, y: own.midY))
        XCTAssertEqual(arrangement.paneDrag?.drop, .cancel)
        XCTAssertNil(arrangement.paneDrag?.preview)
        arrangement.endDrag(left, at: CGPoint(x: own.midX, y: own.midY))
        XCTAssertEqual(tiledOrder, [left, right])
    }

    func testTheTabsEdgeBandTakesAWholeEdge() {
        let (_, right, below) = make(three: true)
        let point = CGPoint(x: 10, y: size.height / 2)
        arrangement.drag(below!, to: point)
        XCTAssertEqual(arrangement.paneDrag?.drop, .edge(.left))
        let lit = arrangement.paneDrag?.preview
        XCTAssertEqual(lit?.width ?? 0, size.width / 3, accuracy: 2)
        arrangement.endDrag(below!, at: point)
        XCTAssertEqual(frame(of: below!), lit)
        XCTAssertEqual(frame(of: below!).width, size.width / 3, accuracy: 2, "a third of the tab, as lit")
        XCTAssertEqual(tiledOrder.first, below)
        XCTAssertEqual(frame(of: below!).height, size.height, accuracy: 1, "along the whole edge")
        XCTAssertTrue(tiledOrder.contains(right))
    }

    func testTheFloatTargetFloatsThePaneWhereItIsLetGo() {
        let (_, right, below) = make(three: true)
        let target = relayout().floatTarget
        let point = CGPoint(x: target.midX, y: target.midY)
        arrangement.drag(below!, to: point)
        XCTAssertEqual(arrangement.paneDrag?.drop, .float)
        arrangement.endDrag(below!, at: point)
        let window = workspace.window(of: below!)
        XCTAssertNotNil(window)
        XCTAssertFalse(workspace.session.isFloating(right))
        // Centred under the hand.
        let rect = window!.frame.rect(in: CGRect(origin: .zero, size: size))
        XCTAssertEqual(rect.midX, point.x, accuracy: 1)
    }

    func testAMovedWindowSnapsToTheTabsMiddleAndKeepsWhereItSnapped() {
        let (_, right, below) = make(three: true)
        workspace.apply(.float(below!, frame: FloatFrame(x: 0.1, y: 0.1, width: 0.3, height: 0.4)))
        let card = relayout().cards[0]
        // Its left edge 4 pt short of the middle.
        let dx = size.width / 2 - 4 - card.frame.minX
        arrangement.move(card.id, by: CGSize(width: dx, height: 0), at: CGPoint(x: card.frame.midX + dx, y: card.frame.minY + 10))
        XCTAssertEqual(arrangement.live[card.id]?.minX, size.width / 2)
        XCTAssertTrue(arrangement.guides.contains { $0.axis == .vertical && $0.position == size.width / 2 })
        arrangement.endMove(card.id, by: CGSize(width: dx, height: 0), velocity: .zero)
        XCTAssertNil(arrangement.live[card.id])
        XCTAssertTrue(arrangement.guides.isEmpty)
        XCTAssertEqual(workspace.window(of: below!)!.frame.x, 0.5, accuracy: 0.001)
        XCTAssertFalse(workspace.session.isFloating(right))
    }

    func testAWindowHeldOverAPanesEdgeDocksThereAfterADwell() async throws {
        let (left, right, below) = make(three: true)
        workspace.apply(.float(below!, frame: FloatFrame(x: 0.1, y: 0.1, width: 0.3, height: 0.4)))
        let card = relayout().cards[0]
        let target = frame(of: left)
        let point = CGPoint(x: target.minX + 60, y: target.midY)
        let by = CGSize(width: point.x - card.frame.midX, height: point.y - card.frame.minY)
        arrangement.move(card.id, by: by, at: point)
        XCTAssertNil(arrangement.dockPreview, "passing over a pane offers nothing at once")
        try await Task.sleep(for: .milliseconds(600))
        let lit = try XCTUnwrap(arrangement.dockPreview)
        XCTAssertEqual(lit.minX, target.minX)
        XCTAssertEqual(lit.width, target.width / 2, accuracy: 2)
        arrangement.endMove(card.id, by: by, velocity: .zero)
        XCTAssertFalse(workspace.session.isFloating(below!))
        XCTAssertEqual(tiledOrder, [below!, left, right])
        XCTAssertEqual(frame(of: below!), lit, "it docks where it was lit")
    }

    func testAWindowResizedSmallStopsAtTheSmallestUsefulSize() {
        let (_, _, below) = make(three: true)
        workspace.apply(.float(below!, frame: FloatFrame(x: 0.3, y: 0.3, width: 0.4, height: 0.4)))
        let card = relayout().cards[0]
        arrangement.resize(card.id, edges: [.right, .bottom], by: CGSize(width: -1000, height: -1000))
        let live = arrangement.live[card.id]!
        XCTAssertEqual(live.size, FloatGeometry.minimumSize)
        XCTAssertEqual(live.origin, card.frame.origin, "the opposite corner stays put")
        arrangement.endResize(card.id)
        XCTAssertNil(arrangement.live[card.id])
    }

    func testATrayChipStandsInForAMinimizedWindowAndTheWindowGrowsBackFromIt() {
        let (_, _, below) = make(three: true)
        workspace.apply(.float(below!, frame: nil))
        workspace.apply(.setFloat(below!, frame: nil, minimized: true, pinned: nil))
        let layout = relayout()
        XCTAssertEqual(layout.chips.count, 1)
        let leaf = layout.leaves.first { $0.pane == below }!
        XCTAssertFalse(leaf.visible)
        let window = FloatGeometry.rect(of: workspace.window(of: below!)!.frame, in: layout.bounds)
        XCTAssertEqual(leaf.frame, window, "its size, and so its grid, stays as it was")
        // Drawn shrunk onto its chip, so restoring grows it out of the chip.
        let chip = layout.chips[0].frame
        let anchor = CGPoint(x: leaf.frame.minX + leaf.hiddenAnchor.x * leaf.frame.width, y: leaf.frame.minY + leaf.hiddenAnchor.y * leaf.frame.height)
        let centre = CGPoint(x: anchor.x + (leaf.frame.midX - anchor.x) * leaf.scale, y: anchor.y + (leaf.frame.midY - anchor.y) * leaf.scale)
        XCTAssertEqual(centre.x, chip.midX, accuracy: 0.5)
        XCTAssertEqual(centre.y, chip.midY, accuracy: 0.5)
        XCTAssertEqual(leaf.frame.width * leaf.scale, chip.width, accuracy: 0.5)
        XCTAssertEqual(layout.chips[0].frame.maxX, size.width - FloatGeometry.edgeMargin)
    }
}
