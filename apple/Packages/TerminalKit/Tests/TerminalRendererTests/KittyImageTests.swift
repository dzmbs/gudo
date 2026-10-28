import CoreGraphics
import Foundation
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// Kitty graphics drawn by the Metal renderer from the render state's placements.
@MainActor
@Suite struct KittyImageTests {
    private func apc(_ params: String, _ payload: [UInt8] = []) -> [UInt8] {
        Array("\u{1b}_G\(params);\(Data(payload).base64EncodedString())\u{1b}\\".utf8)
    }

    private func solid(_ width: Int, _ height: Int, _ pixel: [UInt8]) -> [UInt8] {
        Array((0..<width * height).flatMap { _ in pixel })
    }

    /// RGB of a snapshot at a view point.
    private func color(_ image: CGImage, at point: CGPoint, scale: CGFloat = 2) -> (r: Int, g: Int, b: Int) {
        let data = image.dataProvider!.data! as Data
        let i = Int(point.y * scale) * image.bytesPerRow + Int(point.x * scale) * 4
        return (Int(data[i + 2]), Int(data[i + 1]), Int(data[i]))
    }

    private func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 200 && c.g < 60 && c.b < 60 }

    private func surface(_ terminal: Terminal) throws -> TerminalSurface {
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        return surface
    }

    @Test func imageDrawsOverItsCellsWithOffsetAndSource() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try surface(terminal)
        let grid = try #require(surface.grid)
        // Left half red, right half blue; only the left half (source rect) is placed, over 4×2
        // cells from column 3 of row 2.
        let half = Int(grid.cellWidth) * 2
        let pixels = (0..<Int(grid.cellHeight) * 2).flatMap { _ in
            solid(half, 1, [255, 0, 0, 255]) + solid(half, 1, [0, 0, 255, 255])
        }
        terminal.write(Array("\u{1b}[3;4H".utf8) + apc(
            "a=T,f=32,s=\(half * 2),v=\(grid.cellHeight * 2),i=1,w=\(half),c=4,r=2,C=1,q=2", pixels))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        #expect(surface.kittyPlacements.count == 1)

        let snapshot = try #require(surface.snapshot())
        let first = surface.rect(for: GridPoint(x: 3, y: 2))
        let last = surface.rect(for: GridPoint(x: 6, y: 3))
        #expect(isRed(color(snapshot, at: CGPoint(x: first.midX, y: first.midY))))
        #expect(isRed(color(snapshot, at: CGPoint(x: last.midX, y: last.midY))))
        let after = surface.rect(for: GridPoint(x: 8, y: 2))
        #expect(!isRed(color(snapshot, at: CGPoint(x: after.midX, y: after.midY))))
        #expect(color(snapshot, at: CGPoint(x: last.midX, y: last.midY)).b < 60)
    }

    @Test func layersOrderImagesAgainstBackgrounds() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try surface(terminal)
        // Below the backgrounds: a green cell background hides it, a default one does not.
        terminal.write(Array("\u{1b}[1;1H\u{1b}[42m  \u{1b}[0m\u{1b}[1;1H".utf8)
            + apc("a=T,f=32,s=1,v=1,i=2,c=4,r=1,z=-1073741825,C=1,q=2", [255, 0, 0, 255])
            + Array("\u{1b}[5;10H".utf8))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        let snapshot = try #require(surface.snapshot())
        let covered = surface.rect(for: GridPoint(x: 0, y: 0))
        let shown = surface.rect(for: GridPoint(x: 3, y: 0))
        let green = color(snapshot, at: CGPoint(x: covered.midX, y: covered.midY))
        #expect(green.g > green.r)
        #expect(isRed(color(snapshot, at: CGPoint(x: shown.midX, y: shown.midY))))
    }

    @Test func remoteCellsAreScaledToTheRenderersCells() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try surface(terminal)
        surface.sizeFollowsStream = true
        // The host lays out 5×10 px cells: a 10×20 px image covers 2×2 of them.
        terminal.resize(cols: 20, rows: 6, cellWidth: 5, cellHeight: 10)
        terminal.write(apc("a=T,f=32,s=10,v=20,i=3,C=1,q=2", solid(10, 20, [255, 0, 0, 255])))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        let snapshot = try #require(surface.snapshot())
        let inside = surface.rect(for: GridPoint(x: 1, y: 1))
        let outside = surface.rect(for: GridPoint(x: 2, y: 2))
        #expect(isRed(color(snapshot, at: CGPoint(x: inside.maxX - 1, y: inside.maxY - 1))))
        #expect(!isRed(color(snapshot, at: CGPoint(x: outside.midX, y: outside.midY))))
    }

    @Test func restoredImageAppearsWhenItsPixelsArrive() throws {
        let host = Terminal(cols: 20, rows: 6) { _ in }
        host.resize(cols: 20, rows: 6, cellWidth: 14, cellHeight: 28)
        host.write(apc("a=T,f=32,s=1,v=1,i=4,c=3,r=2,q=2", [255, 0, 0, 255]))
        let snapshot = try #require(host.encodeSnapshot())
        let (ready, rest) = try #require(Terminal.splitSnapshot(snapshot, images: false))

        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try surface(terminal)
        surface.sizeFollowsStream = true
        try terminal.restore(snapshot: ready)
        surface.outputArrived()
        _ = surface.renderIfDirty(offscreen: true)
        let cell = surface.rect(for: GridPoint(x: 1, y: 1))
        #expect(!isRed(color(try #require(surface.snapshot()), at: CGPoint(x: cell.midX, y: cell.midY))))

        try terminal.appendHistory(rest)
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        #expect(isRed(color(try #require(surface.snapshot()), at: CGPoint(x: cell.midX, y: cell.midY))))
    }

    @Test func animationFramesAdvanceWithTheTick() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        terminal.resize(cols: 20, rows: 6, cellWidth: 10, cellHeight: 20)
        #expect(terminal.tickKittyAnimations(nowMs: 0) == nil)
        terminal.write(apc("a=T,f=32,s=1,v=1,i=5,q=2", [255, 0, 0, 255]))
        terminal.write(apc("a=f,f=32,s=1,v=1,i=5,z=100,q=2", [0, 0, 255, 255]))
        terminal.write(apc("a=a,i=5,s=3,v=1,q=2"))
        let first = try #require(terminal.kittyImage(id: 5))
        var now: UInt64 = 1000
        var next = terminal.tickKittyAnimations(nowMs: now)
        var seen = Set([first.rgba])
        for _ in 0..<4 {
            now = max(now + 1, next ?? now + 100)
            next = terminal.tickKittyAnimations(nowMs: now)
            seen.insert(try #require(terminal.kittyImage(id: 5)).rgba)
        }
        #expect(next != nil)
        #expect(seen == [Data([255, 0, 0, 255]), Data([0, 0, 255, 255])])
    }
}
