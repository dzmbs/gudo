import CoreGraphics
import DesignSystem
import PaneLayout
import SwiftUI
import TerminalRenderer
import XCTest
@testable import App
#if os(macOS)
import AppKit
#endif

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

    /// A new pane's terminal is hidden while it arrives, but what it has drawn shows: its
    /// first frame is its still as soon as it is drawn, and each frame after it, so its prompt
    /// is there on the way in instead of popping in when the spring settles.
    func testAnArrivingPaneShowsWhatItsTerminalDrawsOnTheWayIn() async throws {
        let arrangement = PaneArrangement()
        let before = Self.canvas(Self.one, headers: false), after = Self.canvas(Self.two)
        let prompt = Self.solid(0, 1, 0, size: CGSize(width: 8, height: 8))
        let output = Self.solid(0, 0, 1, size: CGSize(width: 8, height: 8))
        var drawn: DrawnFrame?
        let start = ContinuousClock.now
        arrangement.begin(
            CanvasMotion(from: before, to: after), in: after, raising: nil, for: DS.Motion.structuralSettle,
            image: { _ in Self.picture }, departed: { _ in nil }, drawn: { pane in pane == PaneId(2) ? drawn : nil })
        XCTAssertNil(arrangement.still(of: PaneId(2)), "nothing drawn yet: its background")

        drawn = DrawnFrame(generation: 1) { prompt }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(arrangement.still(of: PaneId(2)) === prompt, "its first frame, on the way in")
        drawn = DrawnFrame(generation: 2) { output }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(arrangement.still(of: PaneId(2)) === output, "and the frames after it")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(DS.Motion.structuralSettle), "while it is still arriving")
        XCTAssertTrue(arrangement.hidesTerminal(of: PaneId(2)), "its live terminal waits for the spring")

        let version = arrangement.settledVersion
        while arrangement.settledVersion == version, ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(arrangement.still(of: PaneId(2)))
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

    /// The detail slides by a value of its own: its frame, laid out once and never animated,
    /// cannot take the slide's animation with it.
    func testTheDetailSlidesByAnOffsetThatAnimatesOnItsOwn() {
        var slide = SlideOffset(x: 0)
        slide.animatableData = 130
        XCTAssertEqual(slide.x, 130)
    }

    /// The tab strip coming or going moves the panes under it in the structural spring, from
    /// where they were: never by the strip's height in one step, and only towards rest.
    func testTheTabStripMakesRoomForThePanesInTheSpring() {
        for stripShown in [true, false] {
            let timeline = KeyframeTimeline(initialValue: CGFloat(0)) { StripRoom.keyframes(stripShown: stripShown) }
            let times = Array(stride(from: 0, to: DS.Motion.structuralSettle, by: 1.0 / 120)) + [DS.Motion.structuralSettle]
            let offsets = times.map { timeline.value(time: $0) }
            XCTAssertEqual(offsets.first ?? 0, stripShown ? -DS.Size.tabStrip : DS.Size.tabStrip, accuracy: 0.01, "they start where they were")
            XCTAssertEqual(offsets.last ?? 1, 0, accuracy: DS.Size.tabStrip * DS.Motion.restFraction + 0.01, "at rest with the spring")
            let steps = zip(offsets, offsets.dropFirst()).map { abs($1 - $0) }
            XCTAssertLessThan(steps.max() ?? .infinity, DS.Size.tabStrip / 4, "no frame jumps")
            let distances = offsets.map(abs)
            XCTAssertTrue(zip(distances, distances.dropFirst()).allSatisfy { $1 <= $0 + 0.001 }, "only towards rest")
            XCTAssertLessThanOrEqual(timeline.duration, DS.Motion.structuralSettle + 0.001)
        }
    }

    // MARK: Drawn frames

    private static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, size: CGSize) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()!
    }

    /// The colour at `point` (pixels from the top left) of `image`, as 0–255 RGB.
    private static func pixel(_ image: CGImage, at point: CGPoint) -> [Int] {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = floor(point.x), y = floor(point.y)
        context.draw(image, in: CGRect(x: -x, y: y - CGFloat(image.height) + 1, width: CGFloat(image.width), height: CGFloat(image.height)))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
    }

    private static func render(_ view: some View, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private static func close(_ lhs: [Int], _ rhs: [Int], within tolerance: Int = 12) -> Bool {
        zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// A new pane on its way in is drawn from its leading corner: on any frame of a split right
    /// its header (the top-left of its content) is what shows at the edge it comes in at.
    func testAnArrivingPaneShowsItsHeaderFromItsFirstFrame() throws {
        let frame = CGRect(x: 300, y: 0, width: 300, height: 100)
        let seed = CGRect(x: 600, y: 0, width: 0, height: 100)
        let header = Color(red: 0, green: 0, blue: 1), body = Color(red: 0.5, green: 0.5, blue: 0.5)
        for progress in [0.05, 0.3, 0.7] {
            let shown = CanvasMotion.mix(seed, frame, progress)
            let travel = ArrivingTravel.travel(PaneTravel(shown: frame, frame: frame, background: body), seed: shown)
            let pane = body.overlay(alignment: .topLeading) { header.frame(width: 12, height: 12) }
                .frame(width: frame.width, height: frame.height)
                .modifier(travel)
            let image = try Self.render(ZStack(alignment: .topLeading) { Color.black; pane }, size: CGSize(width: 600, height: 100))
            XCTAssertTrue(Self.close(Self.pixel(image, at: CGPoint(x: shown.minX + 4, y: 4)), [0, 0, 255]), "at \(progress): its header at its leading edge")
            XCTAssertTrue(Self.close(Self.pixel(image, at: CGPoint(x: shown.minX - 4, y: 50)), [0, 0, 0]), "nothing of it before its edge")
        }
        XCTAssertEqual(ArrivingTravel.travel(PaneTravel(shown: frame, frame: frame), seed: nil).shown, frame, "landed, it is a pane like any other")
    }

    /// A floating pane's ring is drawn on the rectangle it travels through: whole on every
    /// side on every frame, never cut where the pane is laid out beyond it. Its window shadow
    /// shows outside it, and goes once it is back in the tree.
    func testAFloatingPanesRingIsWholeInFlightAndItsShadowShows() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let shown = CGRect(x: 60, y: 40, width: 200, height: 150)
        let content = Color(red: 0.1, green: 0.1, blue: 0.1)
        let canvas = Color(red: 0.5, green: 0.5, blue: 0.5)
        func drawn(_ chrome: TravelChrome) throws -> CGImage {
            try Self.render(ZStack(alignment: .topLeading) {
                canvas
                content.frame(width: frame.width, height: frame.height)
                    .modifier(PaneTravel(shown: shown, frame: frame, chrome: chrome))
            }, size: frame.size)
        }
        let image = try drawn(TravelChrome(radii: RectangleCornerRadii(), lifted: true, focused: true))
        let accent = Self.pixel(try Self.render(Rectangle().fill(DS.Palette.accent), size: CGSize(width: 4, height: 4)), at: CGPoint(x: 1, y: 1))
        let inside = Self.pixel(image, at: CGPoint(x: shown.midX, y: shown.midY))
        for (side, point) in [
            ("leading", CGPoint(x: shown.minX, y: shown.midY)), ("trailing", CGPoint(x: shown.maxX - 1, y: shown.midY)),
            ("top", CGPoint(x: shown.midX, y: shown.minY)), ("bottom", CGPoint(x: shown.midX, y: shown.maxY - 1)),
        ] {
            let edge = Self.pixel(image, at: point)
            XCTAssertTrue(Self.close(edge, accent, within: 40), "\(side) edge in the accent: \(edge) vs \(accent)")
            XCTAssertFalse(Self.close(edge, inside), "\(side) edge drawn")
        }
        let below = Self.pixel(image, at: CGPoint(x: shown.midX, y: shown.maxY + 8))
        XCTAssertLessThan(below[0], 120, "the window's shadow under it: \(below)")
        let docked = Self.pixel(try drawn(TravelChrome(radii: .init(), lifted: false, focused: false)), at: CGPoint(x: shown.midX, y: shown.maxY + 8))
        XCTAssertTrue(Self.close(docked, [128, 128, 128], within: 3), "no shadow once in the tree: \(docked)")
    }

    /// Docking: the pane goes over the tiled panes and their lines while it lands, solid, and
    /// the line beside its slot shows only once it has.
    func testADockingPaneLandsOverTheDividersWhichWaitForIt() async throws {
        var session = Session()
        let first = try XCTUnwrap(session.activeTab).focused
        session.apply(.split(first, .horizontal))
        let second = try XCTUnwrap(session.activeTab).focused
        session.apply(.float(second, frame: nil))
        let tab = try XCTUnwrap(session.activeTab)
        let floated = CanvasLayout(
            node: session.tiledRoot(of: tab) ?? tab.root, floats: FloatScene(session: session, tab: tab, hidden: false),
            zoomed: nil, focused: second, size: Self.size, gap: Self.gap, header: PaneHeader.height, cell: nil, padding: 4)
        XCTAssertNotNil(floated.leaf(second)?.window)
        session.apply(.dock(second, beside: first, side: .right))
        let docked = try XCTUnwrap(CanvasLayout(session: session, like: floated))
        XCTAssertNil(docked.leaf(second)?.window)

        let motion = CanvasMotion(from: floated, to: docked)
        XCTAssertEqual(motion.docking, [second])
        let arrangement = PaneArrangement()
        let start = ContinuousClock.now
        arrangement.begin(motion, in: docked, raising: nil, for: DS.Motion.structuralSettle, image: { _ in Self.picture }, departed: { _ in nil })
        let landing = SplitTreeView.drawn(docked, motion: arrangement)
        let pane = try XCTUnwrap(landing.leaf(second))
        XCTAssertEqual(pane.opacity, 1, "solid while it docks")
        let slot = try XCTUnwrap(landing.dividers.first { $0.divider.next == second || $0.divider.leadingSide == second })
        XCTAssertGreaterThan(pane.z, slot.z, "over the line")
        XCTAssertEqual(slot.opacity, 0, "the slot's line waits for the card")
        XCTAssertNotNil(SplitTreeView.chrome(of: pane, docking: arrangement.motion.docking), "its window look fades as it lands")

        let version = arrangement.settledVersion
        while arrangement.settledVersion == version, ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(2))
        }
        let landed = SplitTreeView.drawn(docked, motion: arrangement)
        XCTAssertEqual(landed.dividers.first { $0.id == slot.id }?.opacity, 1, "the line shows once it has landed")
        XCTAssertLessThan(landed.leaf(second)?.z ?? 1, CanvasLayout.zoomZ)
        XCTAssertNil(SplitTreeView.chrome(of: try XCTUnwrap(landed.leaf(second)), docking: arrangement.motion.docking))
    }

    #if os(macOS)
    /// The frames a real window draws: it sits on the main display under the desktop picture,
    /// where no one sees it but its animations get display frames (a window off every display
    /// jumps to the end of each, which is why drawing at points along a spring missed this).
    /// Just after an animated change the still covers its pane whole: it must not fade in over
    /// a terminal that hid at once, which drew the pane blank. Just after it goes, the live
    /// pane shows alone: no crossfade of two grids, which showed a zoom's right prompt twice.
    func testAStillIsWholeOnTheFirstFrameAndGoesInOne() async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let screen = try XCTUnwrap(NSScreen.main)
        try XCTSkipIf(session?["CGSSessionScreenIsLocked"] as? Bool == true, "a locked display draws no frames")
        let probe = StillProbe()
        let window = NSWindow(
            contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 200, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = NSHostingView(rootView: StillProbeView(probe: probe))
        window.orderBack(nil)
        defer { window.close() }
        func drawn(after seconds: Double) async throws -> [Int] {
            try await Task.sleep(for: .seconds(seconds))
            let image = try XCTUnwrap(Self.windowImage(window.windowNumber))
            return Self.pixel(image, at: CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2))
        }
        let live = try await drawn(after: 0.4)
        XCTAssertTrue(Self.close(live, [255, 0, 0]), "the live pane: \(live)")
        withAnimation(DS.Motion.structural) { probe.still = Self.solid(0, 1, 0, size: CGSize(width: 200, height: 100)) }
        let first = try await drawn(after: 0.03)
        XCTAssertTrue(Self.close(first, [0, 255, 0]), "the still, whole, as the motion starts: \(first)")
        _ = try await drawn(after: 0.4)
        withAnimation(DS.Motion.micro) { probe.still = nil }
        let back = try await drawn(after: 0.03)
        XCTAssertTrue(Self.close(back, [255, 0, 0]), "the live pane alone as the still goes: \(back)")
    }

    /// The window server's picture of one of our own windows.
    private static func windowImage(_ number: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // .optionIncludingWindow; .boundsIgnoreFraming | .nominalResolution
        return create(.null, 1 << 3, UInt32(number), (1 << 0) | (1 << 4))?.takeRetainedValue()
    }
    #endif

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

#if os(macOS)
@MainActor
@Observable
private final class StillProbe {
    var still: CGImage?
}

/// A pane as the canvas draws it, under a still the test puts on and takes off.
private struct StillProbeView: View {
    let probe: StillProbe

    var body: some View {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        Color(red: 1, green: 0, blue: 0)
            .frame(width: frame.width, height: frame.height)
            .modifier(PaneTravel(shown: frame, frame: frame, still: probe.still))
            .environment(\.displayScale, 1)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
    }
}
#endif
