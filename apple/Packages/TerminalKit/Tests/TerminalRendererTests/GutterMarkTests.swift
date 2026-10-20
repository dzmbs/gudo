import CoreGraphics
import Foundation
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// Command marks: stripes in the left padding beside a command's rows, following pinned rows.
@MainActor
@Suite struct GutterMarkTests {
    /// BGRA pixel of a snapshot at a pixel position.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = image.dataProvider!.data! as Data
        let i = y * image.bytesPerRow + x * 4
        return (data[i + 2], data[i + 1], data[i])
    }

    private func surface(_ terminal: Terminal) throws -> TerminalSurface {
        var appearance = TerminalAppearance()
        appearance.fontSize = 12
        // Ghostty's `window-padding-x = 4`: room for the 3 pt stripe and air.
        appearance.padding = 4
        let surface = try TerminalSurface(terminal: terminal, appearance: appearance)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        return surface
    }

    @Test func stripeDrawsInTheLeftPaddingBesideItsRows() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        terminal.write(Array("$ false\r\nboom\r\n$ \r\n".utf8))
        let surface = try surface(terminal)
        let cell = try #require(surface.cellSize)
        let pin = try #require(terminal.pinRow(viewportRow: 0))
        surface.gutterMarks = {
            terminal.viewportRows(of: [pin]).compactMap { row in
                row.map { GutterMark(id: 7, row: $0, rows: 2, tint: .palette(1)) }
            }
        }
        #expect(surface.renderIfDirty(offscreen: true))
        let frame = try #require(surface.gutterMarkFrames.first)
        #expect(frame.mark.id == 7)
        #expect(abs(frame.rect.height - 2 * cell.height) < 0.01)
        #expect(surface.gutterMark(at: CGPoint(x: 200, y: frame.rect.midY))?.id == 7)
        #expect(surface.gutterMark(at: CGPoint(x: 200, y: frame.rect.maxY + cell.height)) == nil)

        // Red (the default palette's ANSI red) in the gutter beside the rows, nothing in the
        // first column or below.
        let snapshot = try #require(surface.snapshot())
        let width = TerminalSurface.gutterWidth(paddingLeft: 8, scale: 2)
        let x = max(0, 8 - width - 4) + width / 2
        let y = Int((frame.rect.midY * 2).rounded())
        let stripe = pixel(snapshot, x: x, y: y)
        #expect(stripe.r > 150 && stripe.g < 120 && stripe.b < 120)
        let below = pixel(snapshot, x: x, y: Int(((frame.rect.maxY + cell.height * 1.5) * 2).rounded()))
        #expect(below.r < 100)
    }

    @Test func stripeScrollsWithItsPinnedRow() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try surface(terminal)
        let cell = try #require(surface.cellSize)
        // The layout sized the grid: fill it so the cursor ends on its last row.
        let rows = Int(try #require(surface.grid).rows)
        terminal.write(Array((String(repeating: "x\r\n", count: rows - 2) + "$ true\r\n").utf8))
        let pin = try #require(terminal.pinRow(viewportRow: rows - 2))
        surface.gutterMarks = {
            terminal.viewportRows(of: [pin]).compactMap { row in
                row.map { GutterMark(id: 1, row: $0, rows: 1, tint: .foreground, opacity: 0.2) }
            }
        }
        #expect(surface.renderIfDirty(offscreen: true))
        let before = try #require(surface.gutterMarkFrames.first?.rect)
        // One more line scrolls the screen by a row: the stripe moves up with its text.
        terminal.write(Array("a\r\n".utf8))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        let after = try #require(surface.gutterMarkFrames.first?.rect)
        #expect(abs((before.minY - after.minY) - cell.height) < 0.01)
        // More output pushes it off the viewport: no frame, nothing to hit.
        terminal.write(Array(String(repeating: "y\r\n", count: rows).utf8))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        #expect(surface.gutterMarkFrames.isEmpty)
    }
}
