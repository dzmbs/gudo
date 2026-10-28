import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import TerminalCore

/// Kitty graphics as the renderer sees them: placements from the render state, pixels from the
/// terminal, across scrolling, deletion and snapshot restores.
@Suite struct KittyGraphicsTests {
    /// An APC with kitty graphics `params` and `payload` (base64-encoded here).
    private func apc(_ params: String, _ payload: [UInt8] = []) -> [UInt8] {
        Array("\u{1b}_G\(params);\(Data(payload).base64EncodedString())\u{1b}\\".utf8)
    }

    private func rgba(_ width: Int, _ height: Int, _ pixel: [UInt8]) -> [UInt8] {
        Array((0..<width * height).flatMap { _ in pixel })
    }

    /// A terminal with 10×20 px cells.
    private func terminal(cols: UInt16 = 20, rows: UInt16 = 6) -> Terminal {
        let terminal = Terminal(cols: cols, rows: rows) { _ in }
        terminal.resize(cols: cols, rows: rows, cellWidth: 10, cellHeight: 20)
        return terminal
    }

    private func placements(_ terminal: Terminal) -> [ImagePlacement] {
        let state = RenderState()
        state.update(from: terminal)
        return state.imagePlacements()
    }

    @Test func placementHasPositionSizeAndSource() throws {
        let t = terminal()
        // 30×20 px of red at row 3, column 5 (1-based), offset 4×6 px into the cell.
        t.write(Array("\u{1b}[3;5H".utf8) + apc("a=T,f=32,s=30,v=20,i=1,X=4,Y=6,C=1,q=2", rgba(30, 20, [255, 0, 0, 255])))
        let p = try #require(placements(t).first)
        #expect((p.imageID, p.col, p.row, p.layer, p.z) == (1, 4, 2, .aboveText, 0))
        #expect((p.offsetX, p.offsetY, p.width, p.height) == (4, 6, 30, 20))
        #expect((p.sourceX, p.sourceY, p.sourceWidth, p.sourceHeight) == (0, 0, 30, 20))
        let image = try #require(t.kittyImage(id: 1))
        #expect(image.generation == p.generation)
        #expect((image.width, image.height) == (30, 20))
        #expect(Array(image.rgba.prefix(4)) == [255, 0, 0, 255])
        #expect(t.cellPixelSize == (10, 20))

        // A cropped, scaled placement below the text: source rect and size come through.
        t.write(Array("\u{1b}[1;1H".utf8) + apc("a=p,i=1,p=2,x=10,y=5,w=10,h=10,c=4,r=1,z=-5,C=1,q=2"))
        let cropped = try #require(placements(t).first { $0.z == -5 })
        #expect((cropped.col, cropped.row, cropped.layer) == (0, 0, .belowText))
        #expect((cropped.sourceX, cropped.sourceY, cropped.sourceWidth, cropped.sourceHeight) == (10, 5, 10, 10))
        #expect((cropped.width, cropped.height) == (40, 20))
    }

    @Test func rgbAndPNGImagesBecomeRGBA() throws {
        let t = terminal()
        t.write(apc("a=T,f=24,s=2,v=1,i=2,q=2", [1, 2, 3, 4, 5, 6]))
        #expect(try #require(t.kittyImage(id: 2)).rgba == Data([1, 2, 3, 255, 4, 5, 6, 255]))

        t.write(apc("a=T,f=100,i=3,q=2", try png(width: 3, height: 2, pixel: [0, 128, 255, 255])))
        let image = try #require(t.kittyImage(id: 3))
        #expect((image.width, image.height) == (3, 2))
        #expect(Array(image.rgba.prefix(4)) == [0, 128, 255, 255])
    }

    @Test func scrollingMovesTheImageAboveTheViewport() throws {
        let t = terminal()
        // Four rows tall at the top, then output scrolls the screen by two rows.
        t.write(apc("a=T,f=32,s=1,v=1,i=4,c=2,r=4,q=2", [9, 9, 9, 255]))
        t.write(Array("\u{1b}[6;1Hx\r\ny\r\nz".utf8))
        let p = try #require(placements(t).first)
        #expect((p.row, p.height) == (-2, 80))
    }

    @Test func deletingRemovesPlacementsAndImage() throws {
        let t = terminal()
        t.write(apc("a=T,f=32,s=1,v=1,i=5,q=2", [1, 1, 1, 255]))
        #expect(placements(t).count == 1)
        t.write(apc("a=d,d=I,i=5,q=2"))
        #expect(placements(t).isEmpty)
        #expect(t.kittyImage(id: 5) == nil)
    }

    @Test func restoredImagesWaitForTheirPixels() throws {
        let host = terminal()
        host.write(Array("\u{1b}[2;3H".utf8) + apc("a=T,f=32,s=4,v=4,i=6,q=2", rgba(4, 4, [0, 255, 0, 255])))
        let snapshot = try #require(host.encodeSnapshot())

        // READY alone: the image is known but nothing is drawn until its pixels are here.
        let (ready, rest) = try #require(Terminal.splitSnapshot(snapshot, images: false))
        let client = Terminal(cols: 80, rows: 24) { _ in }
        try client.restore(snapshot: ready)
        #expect(placements(client).isEmpty)
        #expect(client.kittyImage(id: 6) == nil)
        let before = client.kittyStorageGeneration

        // Then it appears where the host has it, at its final size.
        try client.appendHistory(rest)
        #expect(client.kittyStorageGeneration != before)
        let arrived = try #require(placements(client).first)
        #expect((arrived.col, arrived.row, arrived.width, arrived.height) == (2, 1, 4, 4))
        #expect(placements(host) == [arrived].map { var p = $0; p.generation = placements(host)[0].generation; return p })
        #expect(Array(try #require(client.kittyImage(id: 6)).rgba.prefix(4)) == [0, 255, 0, 255])

        // The prefix the daemon sends carries them: complete at once.
        let (screen, _) = try #require(Terminal.splitSnapshot(snapshot))
        #expect(screen.count > ready.count)
        let other = Terminal(cols: 80, rows: 24) { _ in }
        try other.restore(snapshot: screen)
        #expect(other.kittyImage(id: 6) != nil)
    }

    @Test func mirrorsLeaveRepliesToTheHost() {
        let replies = Mutex<[UInt8]>([])
        let t = Terminal(cols: 20, rows: 4) { bytes in replies.withLock { $0 += bytes } }
        t.answersQueries = false
        t.write(apc("i=31,s=1,v=1,a=q,t=d,f=24", [0, 0, 0]) + Array("\u{1b}[6n".utf8))
        #expect(replies.withLock { $0 }.isEmpty)
        // Pastes still go out.
        #expect(t.paste("hi") == .written)
        #expect(replies.withLock { $0 } == Array("hi".utf8))

        t.answersQueries = true
        replies.withLock { $0 = [] }
        t.write(apc("i=31,s=1,v=1,a=q,t=d,f=24", [0, 0, 0]))
        #expect(String(decoding: replies.withLock { $0 }, as: UTF8.self) == "\u{1b}_Gi=31;OK\u{1b}\\")
    }

    private func png(width: Int, height: Int, pixel: [UInt8]) throws -> [UInt8] {
        let pixels = Data(rgba(width, height, pixel))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return [UInt8](out as Data)
    }
}
