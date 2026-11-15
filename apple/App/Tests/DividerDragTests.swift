import DesignSystem
import PaneLayout
import TerminalRenderer
import XCTest
@testable import App

/// A dragged divider shows no cols × rows overlay: the panes resizing under the pointer are the
/// feedback. A divider moved from the keyboard still shows the grid it lands on.
@MainActor
final class DividerDragTests: XCTestCase {
    private final class Quiet: PaneBackend, @unchecked Sendable {
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
    }

    private var workspace: Workspace!

    private func make() -> PaneId {
        var session = Session()
        let left = session.activeTab!.focused
        session.apply(.split(left, .horizontal))
        workspace = Workspace(layout: LocalLayoutStore(session: session)) { _ in Quiet() }
        workspace.layoutChangeUntil = .now
        return left
    }

    override func tearDown() {
        workspace?.close()
        super.tearDown()
    }

    func testADividerDragShowsNoSizeOverlay() {
        let left = make()
        workspace.apply(.setRatio(left, .horizontal, ratio: 0.7))
        XCTAssertTrue(ContinuousClock.now < workspace.keyboardResizeUntil, "the grids it changes show no overlay")
    }

    /// A split, a zoom, a float or a dock moves the panes in the structural spring: their grids
    /// change while it runs or as its stills give way, and no cols × rows overlay shows for any.
    func testLayoutChangesShowNoSizeOverlayThroughTheirMotion() {
        let left = make()
        let motion = Duration.seconds(DS.Motion.structuralSettle) + TerminalSurface.redrawWait
        let ops: [LayoutOp] = [.split(left, .vertical), .toggleZoom, .toggleZoom, .float(left, frame: nil), .dock(left, beside: nil, side: .right)]
        for op in ops {
            workspace.layoutChangeUntil = .now
            workspace.apply(op)
            XCTAssertGreaterThanOrEqual(workspace.keyboardResizeUntil, .now + motion, "\(op)")
        }
    }

    func testAKeyboardDividerMoveKeepsTheOverlay() {
        let left = make()
        workspace.apply(.resize(left, .right, amount: 0.05))
        XCTAssertFalse(ContinuousClock.now < workspace.keyboardResizeUntil)
    }
}
