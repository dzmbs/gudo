import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// Finding the kitty image under a point (what a drag lifts) and the PNG it carries.
@MainActor
@Suite struct KittyImageDragTests {
    private func apc(_ params: String, _ payload: [UInt8] = []) -> [UInt8] {
        Array("\u{1b}_G\(params);\(Data(payload).base64EncodedString())\u{1b}\\".utf8)
    }

    private func solid(_ width: Int, _ height: Int, _ pixel: [UInt8]) -> [UInt8] {
        Array((0..<width * height).flatMap { _ in pixel })
    }

    private func surface(_ terminal: Terminal) throws -> TerminalSurface {
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        surface.sizeFollowsStream = true
        return surface
    }

    @Test func pointFindsTheTopmostImageInRendererCells() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try surface(terminal)
        // Host cells of 5×10 px: image 1 covers 4×2 cells from (1, 1); image 2, above it in z,
        // covers 2×1 cells from (2, 1).
        terminal.resize(cols: 20, rows: 6, cellWidth: 5, cellHeight: 10)
        terminal.write(Array("\u{1b}[2;2H".utf8) + apc("a=T,f=32,s=20,v=20,i=1,C=1,q=2", solid(20, 20, [255, 0, 0, 255])))
        terminal.write(Array("\u{1b}[2;3H".utf8) + apc("a=T,f=32,s=10,v=10,i=2,z=5,C=1,q=2", solid(10, 10, [0, 0, 255, 255])))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))

        let first = surface.rect(for: GridPoint(x: 1, y: 1))
        let last = surface.rect(for: GridPoint(x: 4, y: 2))
        let one = try #require(surface.kittyImage(at: CGPoint(x: last.midX, y: last.midY)))
        #expect(one.placement.imageID == 1)
        #expect(abs(one.rect.minX - first.minX) < 0.5 && abs(one.rect.minY - first.minY) < 0.5)
        #expect(abs(one.rect.maxX - last.maxX) < 0.5 && abs(one.rect.maxY - last.maxY) < 0.5)

        let over = surface.rect(for: GridPoint(x: 2, y: 1))
        #expect(surface.kittyImage(at: CGPoint(x: over.midX, y: over.midY))?.placement.imageID == 2)
        let outside = surface.rect(for: GridPoint(x: 8, y: 4))
        #expect(surface.kittyImage(at: CGPoint(x: outside.midX, y: outside.midY)) == nil)
    }

    @Test func imageScrolledPartlyAboveIsClippedToTheGrid() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try surface(terminal)
        terminal.resize(cols: 20, rows: 6, cellWidth: 5, cellHeight: 10)
        // Four rows tall from row 4 of 6, then more lines: its top rows go above the view.
        terminal.write(Array("\u{1b}[4;1H".utf8) + apc("a=T,f=32,s=10,v=40,i=7,q=2", solid(10, 40, [255, 0, 0, 255]))
            + Array("\n\n\n".utf8))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        let found = try #require(surface.kittyImageFrames.first)
        #expect(found.placement.row < 0)
        let top = surface.rect(for: GridPoint(x: 0, y: 0))
        #expect(abs(found.rect.minY - top.minY) < 0.5)
        #expect(surface.kittyImage(at: CGPoint(x: top.midX, y: top.midY))?.placement.imageID == 7)
    }

    @Test func draggedPNGIsThePlacementsSourceRect() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        let surface = try surface(terminal)
        terminal.resize(cols: 20, rows: 6, cellWidth: 10, cellHeight: 20)
        // A 4×2 image, left half red, right half blue; only the right half placed.
        let pixels = (0..<2).flatMap { _ in solid(2, 1, [255, 0, 0, 255]) + solid(2, 1, [0, 0, 255, 255]) }
        terminal.write(apc("a=T,f=32,s=4,v=2,i=9,x=2,w=2,q=2", pixels))
        surface.outputArrived()
        _ = surface.renderIfDirty(offscreen: true)
        let placement = try #require(surface.kittyPlacements.first)
        let png = try #require(terminal.kittyPNG(placement))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2 && image.height == 2)
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[2] > 200 && bytes[0] < 60)
    }
}
