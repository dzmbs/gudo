import CoreGraphics
import Foundation

/// A box of terminal cells: `cols × rows` from column `col`, starting `row` rows below the
/// overlay's anchor row (negative: above it).
public struct CellBox: Equatable, Sendable {
    public var col: Int
    public var row: Int
    public var cols: Int
    public var rows: Int

    public init(col: Int, row: Int, cols: Int, rows: Int) {
        self.col = col
        self.row = row
        self.cols = cols
        self.rows = rows
    }
}

/// The draw overlay's coordinate systems (docs/DAEMON.md §7.11):
///
/// - **Scene px**: the overlay's Excalidraw scene. The origin is the left edge of the anchor
///   row's top; **20 scene px = one row**, and a column is `20 · cellWidth / cellHeight` scene
///   px, i.e. the contract's 10 px for the usual 1 : 2 cell (Excalidraw zooms uniformly, so
///   rows are exact and columns follow the font's aspect). Every device maps the scene with its
///   own cell size, so ink stays on the text across fonts and devices.
/// - **View points**: the pane's terminal view.
/// - **Cells**: the grid, for placements (`CellBox`).
public struct OverlayGeometry: Equatable, Sendable {
    /// Scene px per terminal row.
    public static let pxPerRow: CGFloat = 20
    /// Scene px per column in the contract (exact for a 1 : 2 cell).
    public static let pxPerColumn: CGFloat = 10

    public var cell: CGSize
    /// The view point of the scene origin: the grid's left edge at the anchor row's top.
    public var origin: CGPoint

    public init(cell: CGSize, origin: CGPoint) {
        self.cell = cell
        self.origin = origin
    }

    /// The overlay anchored at viewport row `anchorRow` of a grid whose first cell is at
    /// `gridOrigin` (view points).
    public init(cell: CGSize, gridOrigin: CGPoint, anchorRow: Int) {
        self.init(cell: cell, origin: CGPoint(x: gridOrigin.x, y: gridOrigin.y + CGFloat(anchorRow) * cell.height))
    }

    /// View points per scene px (Excalidraw's zoom).
    public var zoom: CGFloat { cell.height / Self.pxPerRow }

    /// Scene px per column on this device.
    public var sceneColumnWidth: CGFloat { cell.width / zoom }

    public func view(fromScene point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * zoom, y: origin.y + point.y * zoom)
    }

    public func scene(fromView point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / zoom, y: (point.y - origin.y) / zoom)
    }

    public func view(fromScene rect: CGRect) -> CGRect {
        let topLeft = view(fromScene: rect.origin)
        return CGRect(x: topLeft.x, y: topLeft.y, width: rect.width * zoom, height: rect.height * zoom)
    }

    /// The cells a scene rect touches, clamped to columns `0..<maxCols`; at least one cell.
    public func cells(covering scene: CGRect, maxCols: Int) -> CellBox {
        let viewRect = CGRect(x: scene.minX * zoom, y: scene.minY * zoom, width: scene.width * zoom, height: scene.height * zoom)
        let epsilon: CGFloat = 1e-6
        var firstCol = Int((viewRect.minX / cell.width + epsilon).rounded(.down))
        var endCol = Int((viewRect.maxX / cell.width - epsilon).rounded(.up))
        let firstRow = Int((viewRect.minY / cell.height + epsilon).rounded(.down))
        var endRow = Int((viewRect.maxY / cell.height - epsilon).rounded(.up))
        firstCol = min(max(firstCol, 0), max(maxCols - 1, 0))
        endCol = min(max(endCol, firstCol + 1), max(maxCols, firstCol + 1))
        endRow = max(endRow, firstRow + 1)
        return CellBox(col: firstCol, row: firstRow, cols: endCol - firstCol, rows: endRow - firstRow)
    }

    /// A cell box in scene px (the export bounds that make the PNG cover exactly those cells).
    public func sceneRect(of box: CellBox) -> CGRect {
        CGRect(
            x: CGFloat(box.col) * sceneColumnWidth, y: CGFloat(box.row) * Self.pxPerRow,
            width: CGFloat(box.cols) * sceneColumnWidth, height: CGFloat(box.rows) * Self.pxPerRow)
    }

    public static func viewportRow(atY y: CGFloat, gridOriginY: CGFloat, cellHeight: CGFloat) -> Int {
        Int(((y - gridOriginY) / cellHeight).rounded(.down))
    }
}
