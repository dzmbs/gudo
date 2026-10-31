import CoreGraphics
import XCTest
@testable import App

/// iPhone Duo: what the hinge and the division region make of a window, and that moving between
/// postures keeps what is on screen.
@MainActor
final class FoldTests: XCTestCase {
    /// The inner screen held wide and tall, and the cover screen (points, simulator profile).
    private let wide = CGSize(width: 951, height: 669)
    private let tall = CGSize(width: 669, height: 951)
    private let cover = CGSize(width: 466, height: 678)

    // MARK: Posture

    func testPostureComesFromTheHingeAndTheFoldsDirection() {
        XCTAssertEqual(FoldGeometry(windowSize: wide).posture, .none, "no hinge: not a foldable")
        XCTAssertEqual(FoldGeometry.simulated(.folded, in: cover).posture, .folded)
        XCTAssertEqual(FoldGeometry.simulated(.flat, in: wide).posture, .flat)
        XCTAssertEqual(FoldGeometry.simulated(.book, in: wide).posture, .book)
        XCTAssertEqual(FoldGeometry.simulated(.tabletop, in: tall).posture, .tabletop)
        // A book held tall is still a book: the fold's own shape decides, not the window's.
        XCTAssertEqual(FoldGeometry.simulated(.book, in: tall).posture, .book)
    }

    func testPartlyOpenWithoutAFoldInTheWindowIsTheCoverOrOneSideOfASplit() {
        let hinge = HingeReading(status: .partiallyOpen, angle: 1.2)
        // Partly closed, still on the cover screen: no division crosses it.
        XCTAssertEqual(FoldGeometry(hinge: hinge, windowSize: cover).posture, .folded)
        // One app of a 50/50 Split View on the inner screen: the fold lies outside its window.
        let half = FoldGeometry(hinge: hinge, division: CGRect(x: 470, y: 0, width: 24, height: 669),
                                isDivisionActive: true, windowSize: CGSize(width: 463, height: 669))
        XCTAssertNil(half.foldLine)
        XCTAssertEqual(FoldLayout.plan(half), .standard)
    }

    func testAnUnknownHingeFallsBackToTheWindowsWidth() {
        let hinge = HingeReading(status: .unknown, angle: 0)
        XCTAssertEqual(FoldGeometry(hinge: hinge, windowSize: cover).posture, .folded)
        XCTAssertEqual(FoldGeometry(hinge: hinge, windowSize: wide).posture, .flat)
    }

    // MARK: Layout

    func testEachPostureHasItsLayout() {
        // Cover: the phone layout.
        XCTAssertEqual(FoldLayout.plan(.simulated(.folded, in: cover)), .standard)
        // Open wide: a page each side of a thin band over the flat fold.
        XCTAssertEqual(FoldLayout.plan(.simulated(.flat, in: wide)), .pages(leading: 469.5, gutter: 12))
        // A book: the pages part at the division, margins included.
        XCTAssertEqual(FoldLayout.plan(.simulated(.book, in: wide)), .pages(leading: 463.5, gutter: 24))
        // Laptop: the screen above the division, the deck below.
        XCTAssertEqual(FoldLayout.plan(.simulated(.tabletop, in: tall)), .deck(top: 463.5, gutter: 24))
        // Open tall and flat: one screen, as Apple's layout guidance has it for a flat fold.
        XCTAssertEqual(FoldLayout.plan(.simulated(.flat, in: tall)), .standard)
        // Not a foldable: unchanged, on any size.
        XCTAssertEqual(FoldLayout.plan(FoldGeometry(windowSize: CGSize(width: 1366, height: 1024))), .standard)
    }

    func testNoTextOrControlLandsUnderTheFold() throws {
        for (posture, size) in [(FoldPosture.flat, wide), (.book, wide), (.tabletop, tall)] {
            let fold = FoldGeometry.simulated(posture, in: size)
            let gutter = try XCTUnwrap(fold.gutter, "\(posture)")
            let line = try XCTUnwrap(fold.foldLine)
            // The band covers the fold line itself.
            if line.isVertical {
                XCTAssertTrue(gutter.minX <= line.frame.midX && line.frame.midX <= gutter.maxX, "\(posture)")
            } else {
                XCTAssertTrue(gutter.minY <= line.frame.midY && line.frame.midY <= gutter.maxY, "\(posture)")
            }
            // And the content either side of it starts outside the band.
            switch FoldLayout.plan(fold) {
            case .pages(let leading, let width):
                XCTAssertEqual(leading, gutter.minX)
                XCTAssertEqual(leading + width, gutter.maxX)
            case .deck(let top, let height):
                XCTAssertEqual(top, gutter.minY)
                XCTAssertEqual(top + height, gutter.maxY)
            case .standard:
                XCTFail("\(posture) should split the window")
            }
        }
    }

    func testAFoldTooCloseToAnEdgeLeavesTheWindowWhole() {
        // A fold 200 pt in leaves a page narrower than a phone: no pages.
        var fold = FoldGeometry.simulated(.book, in: wide)
        fold.division = CGRect(x: 188, y: 0, width: 24, height: 669)
        XCTAssertEqual(FoldLayout.plan(fold), .standard)
    }

    func testPlacementIsRelativeToTheView() {
        let pages = FoldLayout.pages(leading: 463.5, gutter: 24)
        XCTAssertEqual(pages.leadingPage(from: 0), 463.5)
        // A view that starts 20 pt in (a leading vertical bar) still meets the fold.
        XCTAssertEqual(pages.leadingPage(from: 20), 443.5)
        XCTAssertNil(pages.deckTop(from: 0))
        XCTAssertEqual(FoldLayout.deck(top: 463.5, gutter: 24).deckTop(from: 24), 439.5)
    }

    // MARK: The window across postures

    private func makeModel() -> WindowModel {
        let model = WindowModel(app: .shared)
        model.start()
        DesignFixtures.projects(model)
        model.widthBucket = .regular
        return model
    }

    private func close(_ model: WindowModel) {
        model.close()
        for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) }
    }

    func testTwoColumnsFollowTheFold() {
        let model = makeModel()
        defer { close(model) }
        model.isSidebarShown = false
        model.updateFold(.simulated(.flat, in: wide))
        XCTAssertTrue(model.isTwoColumns, "open wide: a tab per page")
        model.isSidebarShown = true
        XCTAssertFalse(model.isTwoColumns, "the sidebar is the left page")
        model.isSidebarShown = false
        model.updateFold(.simulated(.tabletop, in: tall))
        XCTAssertFalse(model.isTwoColumns, "laptop: one screen above the deck")
        model.updateFold(.simulated(.folded, in: cover))
        model.widthBucket = .compact
        XCTAssertFalse(model.isTwoColumns, "cover: the phone layout")
    }

    func testACompactWindowKeepsThePhoneLayoutInAnyPosture() {
        let model = makeModel()
        defer { close(model) }
        model.widthBucket = .compact
        for posture in FoldPosture.allCases {
            model.updateFold(.simulated(posture, in: cover))
            XCTAssertEqual(model.foldLayout, .standard, "\(posture)")
        }
        model.widthBucket = .regular
        model.updateFold(.simulated(.tabletop, in: tall))
        XCTAssertEqual(model.foldLayout, .deck(top: 463.5, gutter: 24))
    }

    func testABookNeverRunsOneColumnUnderTheFold() {
        let model = makeModel()
        defer { close(model) }
        model.isSidebarShown = false
        model.twoColumnsChoice = false
        model.updateFold(.simulated(.flat, in: wide))
        XCTAssertFalse(model.isTwoColumns, "flat: the user's choice holds")
        model.updateFold(.simulated(.book, in: wide))
        XCTAssertTrue(model.isTwoColumns, "a book keeps its pages apart")
    }

    /// Dragging between pages: a column dropped on the other trades places; another tab dropped
    /// on a page shows there and takes the keyboard, the other page keeping its tab.
    func testDroppingATabOnAPage() throws {
        let model = makeModel()
        defer { close(model) }
        model.isSidebarShown = false
        model.updateFold(.simulated(.book, in: wide))
        let columns = try XCTUnwrap(model.columns)
        let left = try XCTUnwrap(columns.left)
        let right = try XCTUnwrap(columns.right)

        model.place(right, inLeftColumn: true)
        XCTAssertEqual(model.columns?.left, right)
        XCTAssertEqual(model.columns?.right, left)

        let third = try XCTUnwrap(model.groups.tabs.first { $0 != left && $0 != right })
        model.place(third, inLeftColumn: true)
        XCTAssertEqual(model.columns?.left, third)
        XCTAssertEqual(model.columns?.right, left, "the other page keeps its tab")
        XCTAssertEqual(model.currentTab, third)
    }

    func testTurningColumnsOnAcrossAFoldGivesTheLeftPageToATab() {
        let model = makeModel()
        defer { close(model) }
        model.isSidebarShown = true
        model.updateFold(.simulated(.flat, in: wide))
        XCTAssertFalse(model.isTwoColumns)
        model.toggleTwoColumns()
        XCTAssertTrue(model.isTwoColumns)
        XCTAssertFalse(model.isSidebarShown)
    }

    /// Unfolding, opening into a book, standing it up as a laptop and closing again keep the same
    /// tab, focused pane, pane objects (their scrollback and the key bar's per-pane drafts live
    /// on them) and columns.
    func testAFoldCycleKeepsWhatIsOnScreen() throws {
        let model = makeModel()
        defer { close(model) }
        model.isSidebarShown = false
        model.updateFold(.simulated(.flat, in: wide))
        let current = try XCTUnwrap(model.currentTab)
        let columns = try XCTUnwrap(model.columns)
        let workspace = try XCTUnwrap(model.workspace)
        let focused = workspace.focusedPane
        let panes = workspace.panes.mapValues(ObjectIdentifier.init)

        let cycle: [(FoldPosture, CGSize, WidthBucket)] = [
            (.book, wide, .regular), (.tabletop, tall, .regular), (.flat, tall, .regular),
            (.folded, cover, .compact), (.flat, wide, .regular),
        ]
        for (posture, size, bucket) in cycle {
            model.widthBucket = bucket
            model.updateFold(.simulated(posture, in: size))
            XCTAssertEqual(model.currentTab, current, "\(posture)")
            XCTAssertTrue(model.workspace === workspace, "\(posture)")
            XCTAssertEqual(workspace.focusedPane, focused, "\(posture)")
            XCTAssertEqual(workspace.panes.mapValues(ObjectIdentifier.init), panes, "\(posture): no pane rebuilt")
        }
        // Back open wide: the same two tabs in the same columns.
        XCTAssertEqual(model.columns?.left, columns.left)
        XCTAssertEqual(model.columns?.right, columns.right)
    }

    func testOnlyALayoutChangeHoldsTheTerminalGrids() {
        let model = makeModel()
        defer { close(model) }
        model.updateFold(.simulated(.flat, in: wide))
        let workspace = model.workspace
        workspace?.layoutChangeUntil = .now
        // The hinge moving within a book changes nothing on screen: no reflow.
        var book = FoldGeometry.simulated(.book, in: wide)
        model.updateFold(book)
        let afterOpening = workspace?.layoutChangeUntil
        book.hinge?.angle = 1.9
        model.updateFold(book)
        XCTAssertEqual(workspace?.layoutChangeUntil, afterOpening, "an angle alone is not a layout change")
        XCTAssertEqual(model.fold.hinge?.angle, 1.9)
    }
}
