import CoreGraphics
import DesignSystem
import PaneLayout
import SwiftUI
import TerminalRenderer
import XCTest
@testable import App

/// Splitting, closing and zooming lay every pane out once, at its new frame, and move only the
/// rectangle it is shown in, over a still, sampled per display frame along the structural spring.
@MainActor
final class PaneMotionTests: XCTestCase {
    private static let size = CGSize(width: 1200, height: 800)
    private static let gap: CGFloat = 1

    private static func canvas(_ node: Node, zoomed: PaneId? = nil, headers: Bool = true) -> CanvasLayout {
        CanvasLayout(
            node: node, floats: .none, zoomed: zoomed, focused: node.panes.first, size: size, gap: gap,
            header: PaneHeader.height, cell: nil, padding: 4, headers: headers)
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

    /// The first split brings the pane headers: the terminal under its still goes down to make
    /// room in the same spring, from where it was, never in one step.
    func testTheFirstSplitMakesRoomForTheHeadersInTheSpring() throws {
        let before = Self.canvas(Self.one, headers: false), after = Self.canvas(Self.two)
        let tops = Self.frames(from: before, to: after).compactMap { $0.leaf(PaneId(1))?.header }
        XCTAssertEqual(tops.first ?? -1, 0, accuracy: 0.01, "the terminal starts where it was")
        XCTAssertEqual(tops.last ?? 0, PaneHeader.height, accuracy: PaneHeader.height * DS.Motion.restFraction + 0.01)
        let steps = zip(tops, tops.dropFirst()).map { $1 - $0 }
        XCTAssertLessThan(steps.max() ?? .infinity, PaneHeader.height / 4, "no frame moves it by much")
        XCTAssertTrue(steps.allSatisfy { $0 >= -0.001 }, "it only goes down")

        let back = Self.frames(from: after, to: before).compactMap { $0.leaf(PaneId(1))?.header }
        XCTAssertEqual(back.first ?? 0, PaneHeader.height, accuracy: 0.01, "closing back to one pane starts below the header")
        XCTAssertEqual(back.last ?? -1, 0, accuracy: PaneHeader.height * DS.Motion.restFraction + 0.01)
    }

    func testAStillTravelsWithItsHeaderTop() {
        var travel = PaneTravel(shown: .zero, frame: .zero, stillTop: 0)
        var data = travel.animatableData
        data.second = 12
        travel.animatableData = data
        XCTAssertEqual(travel.stillTop, 12, "the header's room animates with the rectangle")
    }

    /// Split down shows its first change as soon as split right does: on the first display
    /// frame the new pane is already in view and solid (its header and the line with it), as far
    /// along its axis as split right's is along its own.
    func testSplitDownShowsItsFirstChangeAsSoonAsSplitRight() throws {
        let spring = DS.Motion.Role.structural.spring
        let firstFrame = spring.value(target: 1.0, time: 1.0 / 60)
        var shares: [CGFloat] = []
        for axis in [PaneLayout.Axis.horizontal, .vertical] {
            let after = Self.canvas(.split(axis: axis, ratio: 0.5, first: .leaf(PaneId(1)), second: .leaf(PaneId(2))))
            let frame = after.blended(from: Self.canvas(Self.one, headers: false), progress: firstFrame)
            let arriving = try XCTUnwrap(frame.leaf(PaneId(2)))
            XCTAssertEqual(arriving.opacity, 1, "\(axis): solid from its first frame, not fading in from nothing")
            let shown = axis == .horizontal ? arriving.shownFrame.width : arriving.shownFrame.height
            let whole = axis == .horizontal ? Self.size.width : Self.size.height
            XCTAssertGreaterThan(shown, PaneHeader.height / 2, "\(axis): in view on the first frame")
            shares.append(shown / whole)
        }
        XCTAssertEqual(shares[0], shares[1], accuracy: 0.002)
    }

    /// A live terminal is a platform view, which SwiftUI's clip and offset do not reach: while
    /// a pane arrives or moves, its terminal stays hidden under its still or its background,
    /// so nothing of it is drawn outside the rectangle the pane is shown in.
    func testTerminalsStayHiddenWhileTheirPanesArriveOrMove() async throws {
        let arrangement = PaneArrangement()
        let before = Self.canvas(Self.one, headers: false), after = Self.canvas(Self.two)
        let start = ContinuousClock.now
        arrangement.begin(
            CanvasMotion(from: before, to: after), in: after, raising: nil, for: DS.Motion.structuralSettle,
            image: { _ in Self.picture }, departed: { _ in nil })
        XCTAssertTrue(arrangement.hidesTerminal(of: PaneId(1)), "the moving pane shows its still")
        XCTAssertTrue(arrangement.hidesTerminal(of: PaneId(2)), "the arriving pane shows its background")
        let version = arrangement.settledVersion
        while arrangement.settledVersion == version, ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(arrangement.hidesTerminal(of: PaneId(1)))
        XCTAssertFalse(arrangement.hidesTerminal(of: PaneId(2)))
    }

    /// A layout pass that begins again from where the motion is going (the canvas lays out
    /// twice for one change) keeps what is arriving: its terminal stays hidden and it stays
    /// under the panes making room.
    func testBeginningAgainMidwayKeepsWhatIsArriving() {
        let arrangement = PaneArrangement()
        let before = Self.canvas(Self.one, headers: false), after = Self.canvas(Self.two)
        arrangement.begin(CanvasMotion(from: before, to: after), in: after, raising: nil, for: 5, image: { _ in Self.picture }, departed: { _ in nil })
        arrangement.begin(CanvasMotion(from: after, to: after), in: after, raising: nil, for: 5, image: { _ in Self.picture }, departed: { _ in nil })
        XCTAssertNotNil(arrangement.motion.seeds[PaneId(2)])
        XCTAssertTrue(arrangement.hidesTerminal(of: PaneId(2)))
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

    /// It never pops: it fades in the same spring it is squeezed out in, from solid.
    func testAClosedPaneFadesInTheSpringItIsSqueezedOutIn() throws {
        let before = Self.canvas(Self.two), after = Self.canvas(Self.one)
        let width = try XCTUnwrap(before.leaf(PaneId(2))).frame.width
        let frames = Self.frames(from: before, to: after)
        XCTAssertEqual(frames.first?.leaf(PaneId(2))?.opacity ?? 0, 1, accuracy: 0.001)
        for frame in frames {
            let closing = try XCTUnwrap(frame.leaf(PaneId(2)))
            XCTAssertEqual(closing.opacity, closing.shownFrame.width / width, accuracy: 0.01, "fading as it narrows")
        }
        var drawn = after
        drawn.depart(CanvasMotion(from: before, to: after))
        let departing = try XCTUnwrap(drawn.leaf(PaneId(2)))
        XCTAssertEqual(SplitTreeView.fade(of: departing), DS.Motion.structural)
        XCTAssertEqual(departing.header, PaneHeader.height, "it keeps the room its header had")
    }

    func testAClosedPaneGoesWithItsHeaderUntilTheSpringSettles() async throws {
        let arrangement = PaneArrangement()
        let headline = PaneHeadline(identity: .shell, shellName: "zsh", directory: "~/projects/unnamed")
        arrangement.remember(.init(headline: headline, isFocused: true), of: PaneId(2))
        let before = Self.canvas(Self.two), after = Self.canvas(Self.one)
        let start = ContinuousClock.now
        arrangement.begin(
            CanvasMotion(from: before, to: after), in: after, raising: nil, for: DS.Motion.structuralSettle,
            image: { _ in nil }, departed: { _ in Self.picture })
        XCTAssertEqual(arrangement.header(of: PaneId(2))?.headline, headline, "drawn as it last showed")
        let version = arrangement.settledVersion
        while arrangement.settledVersion == version, ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(arrangement.header(of: PaneId(2)), "gone once the spring settles")
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

    // MARK: Headers

    func testAHeaderNamesTheShellOrTheProgramAndItsFolder() {
        let shell = PaneHeadline(identity: .shell, shellName: "zsh", directory: "~/projects/unnamed")
        XCTAssertEqual(shell.program, "zsh")
        XCTAssertEqual(shell.directory, "~/projects/unnamed")
        let claude = ProgramCatalog.identity(process: "claude")
        XCTAssertEqual(PaneHeadline(identity: claude, shellName: "zsh", directory: "").program, claude.displayName)
        XCTAssertNil(PaneHeadline(identity: claude, shellName: "zsh", directory: "").directory)
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

    /// The still gives way only to a terminal that has drawn its new frame: one still waiting
    /// for the program's redraw keeps its still past the spring, then crossfades.
    func testAStillWaitsForItsTerminalsRedrawBeforeItCrossfades() async throws {
        let arrangement = PaneArrangement()
        let before = Self.canvas(Self.two), after = Self.canvas(Self.two, zoomed: PaneId(2))
        let start = ContinuousClock.now
        let redrawnAt = start + .seconds(DS.Motion.structuralSettle) + .milliseconds(60)
        arrangement.begin(
            CanvasMotion(from: before, to: after), in: after, raising: nil, for: DS.Motion.structuralSettle,
            image: { _ in Self.picture }, departed: { _ in nil }, holding: { _ in ContinuousClock.now < redrawnAt })
        let version = arrangement.settledVersion
        while arrangement.settledVersion == version, ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now, redrawnAt, "not before the terminal has drawn")
        XCTAssertLessThan(ContinuousClock.now - redrawnAt, .milliseconds(40), "as soon as it has")

        let stuck = PaneArrangement()
        let stuckStart = ContinuousClock.now
        stuck.begin(
            CanvasMotion(from: before, to: after), in: after, raising: nil, for: DS.Motion.structuralSettle,
            image: { _ in Self.picture }, departed: { _ in nil }, holding: { _ in true })
        let stuckVersion = stuck.settledVersion
        while stuck.settledVersion == stuckVersion, ContinuousClock.now - stuckStart < .seconds(2) {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertLessThan(
            ContinuousClock.now - stuckStart, .seconds(DS.Motion.structuralSettle) + TerminalSurface.redrawWait + .milliseconds(60),
            "a terminal that never redraws holds its still no longer than it holds its frame")
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

    // MARK: Float

    /// The lift is back to scale 1 when the frame's spring is at rest: no tail after the move.
    func testTheLiftBeatEndsWithTheStructuralSpring() {
        for floating in [true, false] {
            let timeline = KeyframeTimeline(initialValue: CGFloat(1)) { LiftBeat.keyframes(floating: floating) }
            XCTAssertLessThanOrEqual(timeline.duration, DS.Motion.structuralSettle + 0.001)
            XCTAssertEqual(timeline.value(time: DS.Motion.structuralSettle), 1, accuracy: 0.002)
            let away = timeline.value(time: DS.Motion.arrivalDelay)
            XCTAssertGreaterThan(abs(away - 1), 0.01, "a beat you can see")
        }
    }

    // MARK: Sidebar

    /// Showing the sidebar keeps the detail's width until it has slid in, then narrows it once;
    /// hiding widens it once, at the start, under held frames.
    func testTheSidebarSlidesAndTheDetailResizesOnce() {
        let window: CGFloat = 1200, sidebar: CGFloat = 260
        let showing = [(false, true), (true, false), (true, true)].map {
            SidebarSlide.detailWidth(window: window, sidebar: sidebar, shown: $0.0, resting: $0.1)
        }
        XCTAssertEqual(showing, [1200, 1200, 940])
        let hiding = [(true, true), (false, false), (false, true)].map {
            SidebarSlide.detailWidth(window: window, sidebar: sidebar, shown: $0.0, resting: $0.1)
        }
        XCTAssertEqual(hiding, [940, 1200, 1200])
        XCTAssertEqual(SidebarSlide.detailOffset(sidebar: sidebar, shown: true), sidebar)
        XCTAssertEqual(SidebarSlide.sidebarOffset(sidebar: sidebar, shown: false), -sidebar)
    }

    // MARK: Drawing

    func testTextKeepsClearOfTheDividers() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pane-padding-\(UUID())"))
        XCTAssertGreaterThanOrEqual(TerminalAppearance.fromPreferences(defaults).padding, DS.Space.xs)
    }

    func testATravellingPaneKeepsItsSizeAndIsCutToWhereItIsShown() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let shown = CGRect(x: 0, y: 0, width: 900, height: 800)
        let place = PaneTravel.placement(frame: frame, shown: shown)
        XCTAssertEqual(place.clip, CGRect(origin: .zero, size: shown.size))
        XCTAssertEqual(place.offset, .zero)
        XCTAssertEqual(PaneTravel.placement(frame: frame, shown: shown.offsetBy(dx: 50, dy: 0)).offset, CGSize(width: 50, height: 0))
    }
}
