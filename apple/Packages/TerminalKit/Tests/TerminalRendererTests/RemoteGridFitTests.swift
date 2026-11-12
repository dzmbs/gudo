import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import TerminalCore
@testable import TerminalRenderer

@MainActor
@Suite struct RemoteGridFitTests {
    private func capture(_ image: CGImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["GUDO_GRID_FIT_CAPTURE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
    }

    @Test func smallerRemoteGridIsCenteredWithoutReflow() throws {
        let terminal = Terminal(cols: 20, rows: 5) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.sizeFollowsStream = true
        let viewport = CGSize(width: 600, height: 400)
        surface.layout(size: viewport, scale: 2)
        let cell = try #require(surface.cellSize)
        let first = surface.rect(for: GridPoint(x: 0, y: 0))
        #expect(abs(first.minX - (viewport.width - 20 * cell.width) / 2) < 0.01)
        #expect(abs(first.minY - (viewport.height - 5 * cell.height) / 2) < 0.01)
        #expect(terminal.size.cols == 20 && terminal.size.rows == 5)
        #expect(cell.width == CGFloat(try #require(surface.grid).cellWidth) / 2)
        terminal.write(Array("\u{1b}[48;2;90;45;160m\u{1b}[2J\u{1b}[2;2HShared grid: 20 x 5".utf8))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        try capture(try #require(surface.snapshot()), name: "centered-small-grid")
    }

    @Test func fittedCellBackgroundsUseTheSameTransformAsHitTesting() throws {
        let terminal = Terminal(cols: 160, rows: 50) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.sizeFollowsStream = true
        surface.layout(size: CGSize(width: 220, height: 300), scale: 2)
        terminal.write(Array("\u{1b}[?25l\u{1b}[48;2;255;0;0m\u{1b}[2J\u{1b}[50;160H\u{1b}[48;2;0;255;0m ".utf8))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        let image = try #require(surface.snapshot())
        let data = try #require(image.dataProvider?.data) as Data
        func color(at point: CGPoint) -> (red: UInt8, green: UInt8, blue: UInt8) {
            let offset = Int(point.y * 2) * image.bytesPerRow + Int(point.x * 2) * 4
            return (data[offset + 2], data[offset + 1], data[offset])
        }
        let first = surface.rect(for: GridPoint(x: 0, y: 0))
        let last = surface.rect(for: GridPoint(x: 159, y: 49))
        let red = color(at: CGPoint(x: first.midX, y: first.midY))
        let green = color(at: CGPoint(x: last.midX, y: last.midY))
        let margin = color(at: CGPoint(x: 1, y: 1))
        #expect(red.red > 200 && red.green < 60 && red.blue < 60)
        // sRGB green has nonzero red and blue in the Display P3 snapshot.
        #expect(green.green > 200 && green.red < 150 && green.blue < 100, "last cell: \(green)")
        #expect(margin.red < 80 && margin.green < 80 && margin.blue < 80)
        try capture(image, name: "fitted-large-grid")
    }

    @Test func aHostResizeChangesPresentationWithoutChangingTheRequestedGrid() throws {
        let terminal = Terminal(cols: 160, rows: 50) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.sizeFollowsStream = true
        var requests: [TerminalSurface.Grid] = []
        surface.onGridChange = { requests.append($0) }
        surface.layout(size: CGSize(width: 220, height: 300), scale: 2)
        let wanted = surface.grid
        let fittedCell = try #require(surface.cellSize)
        terminal.resize(cols: 20, rows: 5, cellWidth: 10, cellHeight: 20)
        let centeredCell = try #require(surface.cellSize)
        #expect(centeredCell.width > fittedCell.width)
        #expect(surface.grid == wanted)
        #expect(requests.count == 1)
        let first = surface.rect(for: GridPoint(x: 0, y: 0))
        #expect(abs(first.minX - (220 - 20 * centeredCell.width) / 2) < 0.01)
    }

    @Test func largerRemoteGridFitsAndHitTestingReachesItsLastCell() throws {
        let terminal = Terminal(cols: 160, rows: 50) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.sizeFollowsStream = true
        let viewport = CGSize(width: 220, height: 300)
        surface.layout(size: viewport, scale: 2)
        let first = surface.rect(for: GridPoint(x: 0, y: 0))
        let last = surface.rect(for: GridPoint(x: 159, y: 49))
        #expect(first.minX >= 0 && first.minY >= 0)
        #expect(last.maxX <= viewport.width && last.maxY <= viewport.height)
        #expect(surface.cell(at: CGPoint(x: last.midX, y: last.midY)) == GridPoint(x: 159, y: 49))
        #expect(terminal.size.cols == 160 && terminal.size.rows == 50)
        let pixels = surface.pixels(CGPoint(x: last.midX, y: last.midY))
        let geometry = surface.mouseGeometry
        #expect(Int((pixels.x - Double(geometry.paddingLeft)) / Double(geometry.cellWidth)) == 159)
    }
}

extension LayoutHoldTests {
    /// Waits for grid changes, which another suite's layout hold would hold.
    @MainActor
    @Suite struct StreamResizeTests {
        /// While a resize this view asked for is on its way, the stream's grid keeps its cell size
        /// and its top-left corner: text never shrinks, grows or moves to the middle under a drag.
        @Test func aGridOnItsWayKeepsItsSizeAndCorner() async throws {
            let terminal = Terminal(cols: 80, rows: 20) { _ in }
            let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
            surface.sizeFollowsStream = true
            surface.layout(size: CGSize(width: 2000, height: 1000), scale: 2)
            let settled = try #require(surface.grid)
            terminal.resize(cols: settled.cols, rows: settled.rows, cellWidth: settled.cellWidth, cellHeight: settled.cellHeight)
            let cell = try #require(surface.cellSize)
            let corner = surface.rect(for: GridPoint(x: 0, y: 0)).origin

            for width in [1400.0, 2600.0] {
                let before = surface.grid
                surface.layout(size: CGSize(width: width, height: 1000), scale: 2)
                let deadline = ContinuousClock.now + .seconds(3)
                while surface.grid == before, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                #expect(surface.grid != before, "a new grid was asked for")
                #expect(terminal.size.cols == Int(settled.cols), "the stream has not resized yet")
                #expect(surface.cellSize == cell)
                #expect(surface.rect(for: GridPoint(x: 0, y: 0)).origin == corner)
            }

            // A size the stream never takes (another device sizes the pane) is fitted after a while.
            try await Task.sleep(for: TerminalSurface.streamResizeWait + .milliseconds(100))
            #expect(surface.rect(for: GridPoint(x: 0, y: 0)).origin != corner)
        }
    }
}
