import CoreGraphics
import Testing
@testable import DrawingKit

/// Anchor math: scene px ↔ view points ↔ cells (docs/DAEMON.md §7.11: 20 scene px per row,
/// 10 per column for a 1 : 2 cell).
@Suite struct OverlayGeometryTests {
    // An 8 × 16 pt cell (1 : 2): the contract's 10 × 20 scene px per cell exactly.
    let geometry = OverlayGeometry(cell: CGSize(width: 8, height: 16), gridOrigin: CGPoint(x: 2, y: 2), anchorRow: 5)

    @Test func originIsTheAnchorRowsLeftEdge() {
        #expect(geometry.origin == CGPoint(x: 2, y: 2 + 5 * 16))
        #expect(geometry.view(fromScene: .zero) == geometry.origin)
        #expect(geometry.zoom == 0.8)
    }

    @Test func tenByTwentyScenePxIsOneCellForAOneToTwoCell() {
        #expect(geometry.sceneColumnWidth == OverlayGeometry.pxPerColumn)
        let p = geometry.view(fromScene: CGPoint(x: 10, y: 20))
        #expect(p == CGPoint(x: geometry.origin.x + 8, y: geometry.origin.y + 16))
        // Round trip.
        let back = geometry.scene(fromView: p)
        #expect(abs(back.x - 10) < 1e-9 && abs(back.y - 20) < 1e-9)
    }

    @Test func rowsStayExactForOtherAspects() {
        // JetBrains Mono at 13 pt on a 2x screen: 8 × 17 pt cells.
        let g = OverlayGeometry(cell: CGSize(width: 8, height: 17), origin: .zero)
        #expect(g.view(fromScene: CGPoint(x: 0, y: 60)).y == 51)  // three rows
        #expect(abs(g.sceneColumnWidth - 20 * 8 / 17) < 1e-9)
        #expect(abs(g.view(fromScene: CGPoint(x: g.sceneColumnWidth * 4, y: 0)).x - 32) < 1e-9)  // four columns
    }

    @Test func coveredCellsSpanTouchedCells() {
        // A rectangle from (15, 5) to (42, 47) scene px: columns 1...4, rows 0...2.
        let box = geometry.cells(covering: CGRect(x: 15, y: 5, width: 27, height: 42), maxCols: 80)
        #expect(box == CellBox(col: 1, row: 0, cols: 4, rows: 3))
        // Exactly on cell edges: no extra cell.
        #expect(geometry.cells(covering: CGRect(x: 10, y: 20, width: 20, height: 40), maxCols: 80) == CellBox(col: 1, row: 1, cols: 2, rows: 2))
    }

    @Test func coveredCellsAboveTheAnchorHaveNegativeRows() {
        let box = geometry.cells(covering: CGRect(x: 0, y: -45, width: 9, height: 30), maxCols: 80)
        #expect(box == CellBox(col: 0, row: -3, cols: 1, rows: 3))
    }

    @Test func coveredCellsClampToTheGridWidth() {
        let box = geometry.cells(covering: CGRect(x: -30, y: 0, width: 2000, height: 10), maxCols: 80)
        #expect(box.col == 0 && box.cols == 80 && box.rows == 1)
    }

    @Test func sceneRectOfABoxIsTheExportBounds() {
        let box = CellBox(col: 1, row: -2, cols: 4, rows: 3)
        #expect(geometry.sceneRect(of: box) == CGRect(x: 10, y: -40, width: 40, height: 60))
        // And back to the same cells.
        #expect(geometry.cells(covering: geometry.sceneRect(of: box), maxCols: 80) == box)
    }

    @Test func viewportRowOfAPoint() {
        #expect(OverlayGeometry.viewportRow(atY: 2, gridOriginY: 2, cellHeight: 16) == 0)
        #expect(OverlayGeometry.viewportRow(atY: 2 + 16 * 3 + 15.9, gridOriginY: 2, cellHeight: 16) == 3)
    }
}
