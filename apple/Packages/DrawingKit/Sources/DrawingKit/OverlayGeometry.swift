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

    /// One cell in view points.
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

    public func view(fromScene p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x * zoom, y: origin.y + p.y * zoom)
    }

    public func scene(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom)
    }

    public func view(fromScene r: CGRect) -> CGRect {
        let o = view(fromScene: r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// The cells a scene rect touches, clamped to columns `0..<maxCols`; at least one cell.
    public func cells(covering scene: CGRect, maxCols: Int) -> CellBox {
        let v = CGRect(x: scene.minX * zoom, y: scene.minY * zoom, width: scene.width * zoom, height: scene.height * zoom)
        let eps: CGFloat = 1e-6
        var col0 = Int((v.minX / cell.width + eps).rounded(.down))
        var col1 = Int((v.maxX / cell.width - eps).rounded(.up))
        let row0 = Int((v.minY / cell.height + eps).rounded(.down))
        var row1 = Int((v.maxY / cell.height - eps).rounded(.up))
        col0 = min(max(col0, 0), max(maxCols - 1, 0))
        col1 = min(max(col1, col0 + 1), max(maxCols, col0 + 1))
        row1 = max(row1, row0 + 1)
        return CellBox(col: col0, row: row0, cols: col1 - col0, rows: row1 - row0)
    }

    /// A cell box in scene px (the export bounds that make the PNG cover exactly those cells).
    public func sceneRect(of box: CellBox) -> CGRect {
        CGRect(
            x: CGFloat(box.col) * sceneColumnWidth, y: CGFloat(box.row) * Self.pxPerRow,
            width: CGFloat(box.cols) * sceneColumnWidth, height: CGFloat(box.rows) * Self.pxPerRow)
    }

    /// The viewport row of a view point (relative to the grid origin `gridOriginY`).
    public static func viewportRow(atY y: CGFloat, gridOriginY: CGFloat, cellHeight: CGFloat) -> Int {
        Int(((y - gridOriginY) / cellHeight).rounded(.down))
    }
}
