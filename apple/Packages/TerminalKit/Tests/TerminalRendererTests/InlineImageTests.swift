import CoreGraphics
import Foundation
import Metal
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// Inline images (placements) drawn as quads over the cells, following pinned rows.
@MainActor
@Suite struct InlineImageTests {
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, width: Int = 8, height: Int = 8) -> CGImage {
        let pixels = [UInt8]((0..<width * height).flatMap { _ in [r, g, b, 255] })
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// BGRA pixel of a snapshot at a view point.
    private func pixel(_ image: CGImage, at point: CGPoint, scale: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = image.dataProvider!.data! as Data
        let x = Int(point.x * scale), y = Int(point.y * scale)
        let i = y * image.bytesPerRow + x * 4
        return (data[i + 2], data[i + 1], data[i])
    }

    @Test func imageVertexMatchesShaderLayout() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: MetalRenderer.shaderSource(), options: nil)
        let vertex = try #require(library.makeFunction(name: "image_vertex"))
        let attributes = try #require(vertex.vertexAttributes)
        #expect(attributes.map(\.name) == ["grid_pos", "cell_offset", "source_rect", "dest_size"])
        #expect(MemoryLayout<ImageVertex>.offset(of: \.sourceRect) == 16)
        #expect(MemoryLayout<ImageVertex>.offset(of: \.destSize) == 32)
    }

    /// What eight placements on screen add to a frame while output scrolls every row (the
    /// renderer's ~2 ms budget is for the whole frame; the image pass must stay a small part).
    @Test func placementsAddLittleToAFrame() throws {
        func run(images: Bool) throws -> Double {
            let terminal = Terminal(cols: 120, rows: 40) { _ in }
            let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
            surface.layout(size: CGSize(width: 1000, height: 700), scale: 2)
            terminal.write(Array((0..<60).map { "line \($0)\r\n" }.joined().utf8))
            if images {
                surface.setInlineImage(try #require(InlineImagePixels(image: solid(200, 80, 40, width: 800, height: 300))), key: "img")
                let pins = (0..<8).compactMap { terminal.pinRow(viewportRow: $0 * 4) }
                surface.inlineImages = {
                    terminal.viewportRows(of: pins).compactMap { row in
                        row.map { InlineImagePlacement(key: "img", col: 10, row: $0, cols: 40, rows: 6) }
                    }
                }
            }
            _ = surface.renderIfDirty(offscreen: true)
            let frames = 300
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0..<frames {
                terminal.write(Array("output \(i)\r\n".utf8))
                surface.outputArrived()
                _ = surface.renderIfDirty(offscreen: true)
            }
            return (CFAbsoluteTimeGetCurrent() - start) / Double(frames) * 1000
        }
        _ = try run(images: false)  // warm up (shader compile, atlas)
        let without = try run(images: false)
        let with = try run(images: true)
        print(String(format: "inline images: %.3f ms/frame with 8 placements vs %.3f without (+%.3f; full redraw per frame, debug build)", with, without, with - without))
        #expect(with - without < 0.3)
    }

    @Test func placementDrawsOverItsCellsAndScrollsWithPinnedRow() throws {
        let terminal = Terminal(cols: 20, rows: 6) { _ in }
        terminal.write(Array("a\r\nb\r\nc\r\n".utf8))
        let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        let cell = try #require(surface.cellSize)

        surface.setInlineImage(try #require(InlineImagePixels(image: solid(255, 0, 0))), key: "red")
        let pin = try #require(terminal.pinRow(viewportRow: 1))
        surface.inlineImages = {
            terminal.viewportRows(of: [pin]).compactMap { row in
                row.map { InlineImagePlacement(key: "red", col: 2, row: $0, cols: 4, rows: 2) }
            }
        }
        #expect(surface.renderIfDirty(offscreen: true))
        let frame = try #require(surface.inlineImageFrames.first?.rect)
        #expect(abs(frame.width - 4 * cell.width) < 0.01 && abs(frame.height - 2 * cell.height) < 0.01)
        #expect(surface.inlineImages(at: CGPoint(x: frame.midX, y: frame.midY)).first?.key == "red")

        let snapshot = try #require(surface.snapshot())
        let inside = pixel(snapshot, at: CGPoint(x: frame.midX, y: frame.midY), scale: 2)
        #expect(inside.r > 200 && inside.g < 60 && inside.b < 60)
        let outside = pixel(snapshot, at: CGPoint(x: frame.maxX + cell.width * 3, y: frame.midY), scale: 2)
        #expect(outside.r < 100)

        // Output that scrolls the screen moves the pinned row (and the image) up with it.
        let rows = Int(try #require(surface.grid).rows)
        terminal.write(Array((0..<(rows - 2)).map { "\($0)\r\n" }.joined().utf8))
        surface.outputArrived()
        #expect(surface.renderIfDirty(offscreen: true))
        let row = try #require(terminal.viewportRows(of: [pin]).first ?? nil)
        #expect(row < 1)
        let moved = try #require(surface.inlineImageFrames.first?.rect)
        #expect(abs((frame.minY - moved.minY) - CGFloat(1 - row) * cell.height) < 0.01)
    }
}
