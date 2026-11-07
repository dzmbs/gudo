import GudoCore
import TerminalCore
import TerminalRenderer
import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import App

@MainActor
final class WindowSizingTests: XCTestCase {
    func testNativeViewFitsAndCentersSharedGridsWithoutReflow() throws {
        for (columns, rows, width, height) in [(20, 5, 600, 400), (160, 50, 220, 300)] {
            let terminal = Terminal(cols: UInt16(columns), rows: UInt16(rows)) { _ in }
            let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
            surface.sizeFollowsStream = true
            let view = TerminalView(surface: surface)
            view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            surface.layout(size: view.bounds.size, scale: 2)
            let first = surface.rect(for: GridPoint(x: 0, y: 0))
            let last = surface.rect(for: GridPoint(x: columns - 1, y: rows - 1))
            XCTAssertGreaterThanOrEqual(first.minX, 0)
            XCTAssertGreaterThanOrEqual(first.minY, 0)
            XCTAssertLessThanOrEqual(last.maxX, view.bounds.width + 0.01)
            XCTAssertLessThanOrEqual(last.maxY, view.bounds.height + 0.01)
            XCTAssertEqual(first.minX, view.bounds.width - last.maxX, accuracy: 0.01)
            XCTAssertEqual(first.minY, view.bounds.height - last.maxY, accuracy: 0.01)
            XCTAssertEqual(surface.cell(at: CGPoint(x: last.midX, y: last.midY)), GridPoint(x: columns - 1, y: rows - 1))
            XCTAssertEqual(terminal.size.cols, columns)
            XCTAssertEqual(terminal.size.rows, rows)
        }
    }

    func testVisibilityAndActivityRemainSeparate() throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let model = WindowModel(app: .shared)
        defer { model.close() }
        XCTAssertTrue(model.isOnScreen)
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.sizingActivity = .active
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.isOnScreen = false
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.isOnScreen = true
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.destination = .inbox
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.destination = .terminal
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.close()
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
    }
}
