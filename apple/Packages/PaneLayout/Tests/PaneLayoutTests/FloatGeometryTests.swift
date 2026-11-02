import CoreGraphics
import Testing
@testable import PaneLayout

@Suite struct FloatGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private typealias G = FloatGeometry

    @Test func aWindowNearAnEdgeSticksAtTheMarginAndDrawsItsGuide() {
        let (rect, guides) = G.snap(CGRect(x: 13, y: 300, width: 400, height: 300), in: bounds, others: [])
        #expect(rect.minX == G.edgeMargin)
        #expect(rect.size == CGSize(width: 400, height: 300), "moving never resizes")
        #expect(guides == [G.Guide(axis: .vertical, position: G.edgeMargin, from: 0, to: 800)])
    }

    @Test func bothAxesSnapIntoACorner() {
        let (rect, guides) = G.snap(CGRect(x: 795, y: 495, width: 400, height: 300), in: bounds, others: [])
        #expect(rect.maxX == 1200 - G.edgeMargin)
        #expect(rect.maxY == 800 - G.edgeMargin)
        #expect(guides.count == 2)
    }

    @Test func edgesStickToThirdsAndHalves() {
        let (rect, _) = G.snap(CGRect(x: 405, y: 120, width: 200, height: 200), in: bounds, others: [])
        #expect(rect.minX == 400, "left edge on the first third")
        let (centred, _) = G.snap(CGRect(x: 395, y: 120, width: 200, height: 200), in: bounds, others: [])
        #expect(centred.minX == 400)
        let (half, _) = G.snap(CGRect(x: 100, y: 120, width: 496, height: 200), in: bounds, others: [])
        #expect(half.maxX == 600, "right edge on the half")
    }

    @Test func windowsSitBesideOrAlignedWithEachOther() {
        let other = CGRect(x: 700, y: 100, width: 300, height: 300)
        let (beside, guides) = G.snap(CGRect(x: 1013, y: 220, width: 150, height: 150), in: bounds, others: [other])
        #expect(beside.minX == other.maxX + G.windowGap)
        #expect(guides.first?.from == other.minY, "the guide runs along the other window")
        let (aligned, _) = G.snap(CGRect(x: 120, y: 104, width: 300, height: 200), in: bounds, others: [other])
        #expect(aligned.minY == other.minY)
    }

    @Test func farFromEveryLineNothingSnaps() {
        let rect = CGRect(x: 150, y: 150, width: 210, height: 150)
        let (out, guides) = G.snap(rect, in: bounds, others: [])
        #expect(out == rect)
        #expect(guides.isEmpty)
    }

    @Test func resizingSnapsOnlyTheEdgesItMoves() {
        let rect = CGRect(x: 300, y: 300, width: 300, height: 200)
        let (out, _) = G.snap(CGRect(x: 300, y: 300, width: 895, height: 200), in: bounds, others: [], moving: .right)
        #expect(out.minX == 300)
        #expect(out.maxX == 1200 - G.edgeMargin)
        let (top, _) = G.snap(CGRect(x: 300, y: 13, width: 300, height: 487), in: bounds, others: [], moving: .top)
        #expect(top.minY == G.edgeMargin && top.maxY == rect.maxY)
    }

    @Test func resizeKeepsAUsableSizeInsideTheTab() {
        let rect = CGRect(x: 300, y: 300, width: 300, height: 200)
        let small = G.resized(rect, edges: [.left, .top], by: CGSize(width: 500, height: 500), in: bounds)
        #expect(small.size == G.minimumSize)
        #expect(small.maxX == rect.maxX && small.maxY == rect.maxY, "the opposite corner stays")
        let big = G.resized(rect, edges: .right, by: CGSize(width: 5000, height: 0), in: bounds)
        #expect(big.maxX == bounds.maxX)
    }

    @Test func aFlickCarriesTheWindowButKeepsItInside() {
        let rect = CGRect(x: 300, y: 300, width: 300, height: 200)
        let still = G.projected(rect, velocity: .zero, in: bounds)
        #expect(still == rect)
        let thrown = G.projected(rect, velocity: CGVector(dx: 1000, dy: 0), in: bounds)
        #expect(thrown.minX > rect.minX + 400)
        let far = G.projected(rect, velocity: CGVector(dx: 50_000, dy: -50_000), in: bounds)
        #expect(far.maxX == bounds.maxX - G.edgeMargin && far.minY == G.edgeMargin)
    }

    @Test func fractionsHoldAcrossTabSizes() {
        let frame = FloatFrame(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let small = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let large = CGRect(x: 40, y: 20, width: 2000, height: 1200)
        #expect(frame.rect(in: small) == CGRect(x: 250, y: 300, width: 500, height: 150))
        #expect(FloatFrame(frame.rect(in: large), in: large) == frame)
        // On a phone-sized tab the window keeps a usable size, still inside.
        let phone = CGRect(x: 0, y: 0, width: 390, height: 700)
        let rect = G.rect(of: frame, in: phone)
        #expect(rect.width == G.minimumSize.width && phone.contains(rect))
    }

    @Test func dropsPickTheEdgeBandThenThePaneSide() {
        let left = (PaneId(1), CGRect(x: 0, y: 0, width: 600, height: 800))
        let right = (PaneId(2), CGRect(x: 600, y: 0, width: 600, height: 800))
        let panes = [left, right]
        #expect(G.drop(at: CGPoint(x: 10, y: 400), in: bounds, panes: panes, dragged: PaneId(2)) == .edge(.left))
        #expect(G.drop(at: CGPoint(x: 300, y: 700), in: bounds, panes: panes, dragged: PaneId(2)) == .beside(PaneId(1), .down))
        #expect(G.drop(at: CGPoint(x: 900, y: 400), in: bounds, panes: panes, dragged: PaneId(2)) == .cancel, "on itself")
        let target = CGRect(x: 550, y: 40, width: 100, height: 30)
        #expect(G.drop(at: CGPoint(x: 600, y: 50), in: bounds, panes: panes, dragged: PaneId(2), floatTarget: target) == .float)
        #expect(G.drop(at: CGPoint(x: -10, y: 400), in: bounds, panes: panes, dragged: PaneId(2)) == .float)
        // A window in front wins over the tiled pane under it.
        let window = (PaneId(3), CGRect(x: 200, y: 200, width: 300, height: 300))
        #expect(G.drop(at: CGPoint(x: 250, y: 350), in: bounds, panes: [window] + panes, dragged: PaneId(2)) == .beside(PaneId(3), .left))
    }

    @Test func previewsShowWhatTheDropGives() {
        let panes = [(PaneId(1), CGRect(x: 0, y: 0, width: 600, height: 800))]
        #expect(G.preview(of: .beside(PaneId(1), .down), in: bounds, panes: panes) == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(G.preview(of: .edge(.right), in: bounds, panes: panes) == CGRect(x: 800, y: 0, width: 400, height: 800))
        #expect(G.preview(of: .float, in: bounds, panes: panes) == nil)
    }

    @Test func trayChipsRunRightToLeftAndWrap() {
        let chips = G.trayChips(count: 3, chip: CGSize(width: 500, height: 30), in: bounds)
        #expect(chips[0].maxX == bounds.maxX - G.edgeMargin && chips[0].maxY == bounds.maxY - G.edgeMargin)
        #expect(chips[1].maxX < chips[0].minX)
        #expect(chips[2].maxY < chips[0].minY, "two fit per row; the third goes up")
    }

    @Test func pictureInPictureRestsInTheCornerAFlickPointsAt() {
        let phone = CGRect(x: 0, y: 0, width: 390, height: 800)
        let size = CGSize(width: 160, height: 110)
        let corners = G.pipCorners(size: size, in: phone)
        #expect(corners.count == 4)
        let bottomRight = G.pipCorner(for: CGPoint(x: 200, y: 400), velocity: CGVector(dx: 800, dy: 2000), corners: corners)
        #expect(bottomRight?.maxX == 390 - 12 && bottomRight?.maxY == 800 - 12)
        let topLeft = G.pipCorner(for: CGPoint(x: 100, y: 100), velocity: .zero, corners: corners)
        #expect(topLeft?.minX == 12 && topLeft?.minY == 12)
    }

    @Test func pictureInPictureNeverSitsOnTheFold() {
        let open = CGRect(x: 0, y: 0, width: 951, height: 669)
        let fold = CGRect(x: 463, y: 0, width: 24, height: 669)
        let corners = G.pipCorners(size: CGSize(width: 200, height: 130), in: open, fold: fold)
        #expect(corners.count == 8)
        #expect(corners.allSatisfy { !$0.intersects(fold) })
    }
}
