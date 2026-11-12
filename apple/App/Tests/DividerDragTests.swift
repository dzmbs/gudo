import PaneLayout
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

    func testAKeyboardDividerMoveKeepsTheOverlay() {
        let left = make()
        workspace.apply(.resize(left, .right, amount: 0.05))
        XCTAssertFalse(ContinuousClock.now < workspace.keyboardResizeUntil)
    }
}
