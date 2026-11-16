import CoreGraphics
import Testing
import TerminalCore
@testable import TerminalRenderer

@MainActor
@Suite struct PaddingBalanceTests {
    private func balancedSurface(size: CGSize) throws -> TerminalSurface {
        var appearance = TerminalAppearance()
        appearance.fontSize = 12
        appearance.padding = 4
        appearance.paddingBalance = true
        let surface = try TerminalSurface(terminal: Terminal(cols: 80, rows: 24) { _ in }, appearance: appearance)
        surface.layout(size: size, scale: 2)
        return surface
    }

    @Test func panesOfEveryHeightStartTheirFirstRowAtThePadding() throws {
        let heights: [CGFloat] = [300, 307, 313, 331, 419, 760]
        for height in heights {
            let surface = try balancedSurface(size: CGSize(width: 600, height: height))
            let firstRow = surface.rect(for: GridPoint(x: 0, y: 0))
            #expect(abs(firstRow.minY - 4) < 0.01, "height \(height): first row at \(firstRow.minY)")
        }
    }

    @Test func theLeftoverWidthIsSplitEvenly() throws {
        let surface = try balancedSurface(size: CGSize(width: 611, height: 400))
        let grid = try #require(surface.grid)
        let first = surface.rect(for: GridPoint(x: 0, y: 0))
        let last = surface.rect(for: GridPoint(x: Int(grid.cols) - 1, y: 0))
        #expect(abs(first.minX - (611 - last.maxX)) <= 0.5)
    }
}
