import CoreGraphics
import DesignSystem
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Splitting, closing and zooming lay every pane out once, at its new frame, and move only the
/// rectangle it is shown in, over a still, sampled per display frame along the structural spring.
@MainActor
final class PaneMotionTests: XCTestCase {
    private static let size = CGSize(width: 1200, height: 800)
    private static let gap: CGFloat = 1

    private static func canvas(_ node: Node, zoomed: PaneId? = nil) -> CanvasLayout {
        CanvasLayout(
            node: node, floats: .none, zoomed: zoomed, focused: node.panes.first, size: size, gap: gap,
            header: PaneHeader.height, cell: nil, padding: 4)
    }

    private static let one = Node.leaf(PaneId(1))
    private static let two = Node.split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(1)), second: .leaf(PaneId(2)))
    private static let three = Node.split(
        axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(1)),
        second: .split(axis: .vertical, ratio: 0.5, first: .leaf(PaneId(2)), second: .leaf(PaneId(3))))

    /// The canvas as drawn at each display frame of a structural motion from `before` to `after`.
    private static func frames(from before: CanvasLayout, to after: CanvasLayout) -> [CanvasLayout] {
        let spring = DS.Motion.Role.structural.spring
        let times = Array(stride(from: 0, to: DS.Motion.structuralSettle, by: 1.0 / 120)) + [DS.Motion.structuralSettle]
        return times.map { time in
            after.blended(from: before, progress: spring.value(target: 1.0, time: time))
        }
    }

    private func assertLaidOutOnce(_ frames: [CanvasLayout], before: CanvasLayout, after: CanvasLayout, file: StaticString = #filePath, line: UInt = #line) {
        for frame in frames {
            for leaf in frame.leaves {
                let laidOut = leaf.departing ? before.leaf(leaf.pane)?.frame : after.leaf(leaf.pane)?.frame
                XCTAssertEqual(leaf.frame, laidOut, "pane \(leaf.pane) is laid out only where it ends (or, leaving, where it was)", file: file, line: line)
            }
        }
    }

    // MARK: Split

    func testASplitGrowsTheNewPaneFromTheEdgeItSplitsFrom() throws {
        let before = Self.canvas(Self.one), after = Self.canvas(Self.two)
        let motion = CanvasMotion(from: before, to: after)
        let seed = try XCTUnwrap(motion.seeds[PaneId(2)])
        XCTAssertEqual(seed, CGRect(x: 1200, y: 0, width: 0, height: 800), "the old pane's right edge")
        XCTAssertEqual(motion.moving, [PaneId(1)])
        XCTAssertTrue(motion.departures.isEmpty)
    }

    func testASplitLaysEachPaneOutOnceAndOnlyMovesWhereItIsShown() throws {
        let before = Self.canvas(Self.one), after = Self.canvas(Self.two)
        let frames = Self.frames(from: before, to: after)
        assertLaidOutOnce(frames, before: before, after: after)
        let widths = frames.compactMap { $0.leaf(PaneId(1))?.shownFrame.width }
        XCTAssertGreaterThan(Set(widths).count, 10, "the shown rectangle travels")
        XCTAssertEqual(widths.first ?? 0, 1200, accuracy: 0.01)
        XCTAssertEqual(widths.last ?? 0, after.leaf(PaneId(1))!.frame.width, accuracy: 600 * DS.Motion.restFraction + 0.01)
    }

    func testTheSplitPanesAndTheirDividerMoveTogetherWithNoGap() throws {
        let before = Self.canvas(Self.one), after = Self.canvas(Self.two)
        for frame in Self.frames(from: before, to: after) {
            let first = try XCTUnwrap(frame.leaf(PaneId(1))).shownFrame
            let second = try XCTUnwrap(frame.leaf(PaneId(2))).shownFrame
            let divider = try XCTUnwrap(frame.dividers.first).shownFrame
            XCTAssertEqual(divider.minX, first.maxX, accuracy: 0.01, "the line rides the first pane's edge")
            XCTAssertEqual(second.minX, divider.maxX, accuracy: Self.gap, "the new pane meets the line, within a hairline")
            XCTAssertEqual(second.maxX, 1200, accuracy: 0.01)
        }
    }

    // MARK: Close

    func testAClosedPaneIsSqueezedOutByTheNeighbourTakingItsSpace() throws {
        let before = Self.canvas(Self.two), after = Self.canvas(Self.one)
        let motion = CanvasMotion(from: before, to: after)
        let departure = try XCTUnwrap(motion.departures.first)
        XCTAssertEqual(departure.leaf.pane, PaneId(2))
        XCTAssertEqual(departure.collapse, CGRect(x: 1200, y: 0, width: 0, height: 800))
        XCTAssertEqual(motion.departingDividers.first?.target.minX, 1200)
        XCTAssertEqual(motion.moving, [PaneId(1)])

        let frames = Self.frames(from: before, to: after)
        assertLaidOutOnce(frames, before: before, after: after)
        for frame in frames {
            let neighbour = try XCTUnwrap(frame.leaf(PaneId(1))).shownFrame
            let closing = try XCTUnwrap(frame.leaf(PaneId(2)))
            let line = try XCTUnwrap(frame.dividers.first).shownFrame
            XCTAssertTrue(closing.departing)
            XCTAssertEqual(line.minX, neighbour.maxX, accuracy: 0.01)
            XCTAssertEqual(closing.shownFrame.minX, line.maxX, accuracy: Self.gap, "within a hairline")
        }
        XCTAssertLessThan(frames.last!.leaf(PaneId(2))!.opacity, 0.02, "faded by the end")
    }

    func testAMiddlePaneClosesTowardItsMiddle() {
        let columns = Node.split(
            axis: .horizontal, ratio: 1.0 / 3, first: .leaf(PaneId(1)),
            second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(2)), second: .leaf(PaneId(3))))
        let before = Self.canvas(columns)
        let after = Self.canvas(.split(axis: .horizontal, ratio: 0.5, first: .leaf(PaneId(1)), second: .leaf(PaneId(3))))
        let old = before.leaf(PaneId(2))!.frame
        XCTAssertEqual(CanvasMotion(from: before, to: after).departures.first?.collapse.minX ?? 0, old.midX, accuracy: 0.5)
    }

    // MARK: Zoom

    func testAZoomGrowsThePaneOverItsNeighboursLaidOutAtFullSize() throws {
        let before = Self.canvas(Self.three), after = Self.canvas(Self.three, zoomed: PaneId(2))
        let motion = CanvasMotion(from: before, to: after)
        XCTAssertTrue(motion.moving.contains(PaneId(2)))
        let frames = Self.frames(from: before, to: after)
        assertLaidOutOnce(frames, before: before, after: after)
        let tile = before.leaf(PaneId(2))!.frame
        XCTAssertEqual(frames.first?.leaf(PaneId(2))?.shownFrame, tile)
        let edges = frames.compactMap { $0.leaf(PaneId(2))?.shownFrame.minX }
        XCTAssertEqual(zip(edges, edges.dropFirst()).filter { $1 > $0 + 0.01 }.count, 0, "its left edge only heads out")

        let back = Self.frames(from: after, to: before)
        assertLaidOutOnce(back, before: after, after: before)
        XCTAssertEqual(back.last?.leaf(PaneId(2))?.shownFrame.width ?? 0, tile.width, accuracy: 1200 * DS.Motion.restFraction)
    }

    // MARK: Stills and settling

    private static let picture: CGImage = {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    func testStillsCoverEveryMovingAndDepartingPaneUntilTheSpringSettles() async throws {
        let arrangement = PaneArrangement()
        let before = Self.canvas(Self.three), after = Self.canvas(Self.two)
        var asked: Set<PaneId> = []
        let start = ContinuousClock.now
        arrangement.begin(
            CanvasMotion(from: before, to: after), in: after, raising: nil, for: DS.Motion.structuralSettle,
            image: { asked.insert($0); return Self.picture }, departed: { _ in Self.picture })
        let changed = after.leaves.filter { before.leaf($0.pane)?.frame != $0.frame }.map(\.pane)
        XCTAssertFalse(changed.isEmpty)
        for pane in changed { XCTAssertNotNil(arrangement.still(of: pane), "pane \(pane) moves over a still") }
        XCTAssertNotNil(arrangement.still(of: PaneId(3)), "the closed pane goes as its still")
        XCTAssertTrue(arrangement.isMoving)
        XCTAssertEqual(asked, Set(changed))

        let version = arrangement.settledVersion
        while arrangement.settledVersion == version, ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(2))
        }
        let settledAfter = (ContinuousClock.now - start) / .seconds(1)
        XCTAssertGreaterThanOrEqual(settledAfter, DS.Motion.structuralSettle - 0.005)
        XCTAssertLessThan(settledAfter, DS.Motion.structuralSettle + 0.1, "no pause between the motion and the live terminals")
        XCTAssertFalse(arrangement.isMoving)
        for pane in changed + [PaneId(3)] { XCTAssertNil(arrangement.still(of: pane)) }
        XCTAssertTrue(arrangement.motion.departures.isEmpty)
    }

    /// A close that lands mid-split carries on: the panes start from where they are (SwiftUI
    /// retargets the shown rectangle), and what was leaving keeps leaving.
    func testAMotionStartedMidwayCarriesOnFromTheOneUnderWay() {
        let arrangement = PaneArrangement()
        let first = Self.canvas(Self.three), second = Self.canvas(Self.two), third = Self.canvas(Self.one)
        arrangement.begin(CanvasMotion(from: first, to: second), in: second, raising: nil, for: 5, image: { _ in nil }, departed: { _ in nil })
        arrangement.begin(CanvasMotion(from: second, to: third), in: third, raising: nil, for: 5, image: { _ in nil }, departed: { _ in nil })
        XCTAssertEqual(Set(arrangement.motion.departures.map(\.leaf.pane)), [PaneId(2), PaneId(3)])
        let drawn = SplitTreeView.drawn(third, motion: arrangement)
        XCTAssertEqual(Set(drawn.leaves.map(\.pane)), [PaneId(1), PaneId(2), PaneId(3)])
    }

    // MARK: Drawing

    func testATravellingPaneKeepsItsSizeAndIsCutToWhereItIsShown() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let shown = CGRect(x: 0, y: 0, width: 900, height: 800)
        let place = PaneTravel.placement(frame: frame, shown: shown)
        XCTAssertEqual(place.clip, CGRect(origin: .zero, size: shown.size))
        XCTAssertEqual(place.offset, .zero)
        XCTAssertEqual(PaneTravel.placement(frame: frame, shown: shown.offsetBy(dx: 50, dy: 0)).offset, CGSize(width: 50, height: 0))
    }
}
