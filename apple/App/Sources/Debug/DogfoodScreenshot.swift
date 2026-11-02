#if DEBUG && os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Window captures without Screen Recording permission. AppKit draws the window's views (the
/// SwiftUI chrome) into a bitmap with `cacheDisplay`; a `CAMetalLayer` does not draw that way, so
/// each visible pane's frame is rendered again offscreen by its own renderer
/// (`TerminalSurface.snapshot`, an `MTLTexture` read back) and composited at the pane's frame.
@MainActor
enum DogfoodScreenshot {
    struct PaneInk: Codable {
        var pane: String
        /// Fraction of the pane's pixels that differ clearly from its background: > 0 means
        /// glyphs were drawn.
        var ink: Double
    }

    struct Result {
        var image: CGImage
        var panes: [PaneInk]
    }

    static func capture(window: NSWindow, panes: [Pane]) -> Result? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        let bounds = root.bounds
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        root.cacheDisplay(in: bounds, to: bitmap)
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        let scale = CGFloat(width) / bounds.width
        guard let chrome = bitmap.cgImage,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(chrome, in: CGRect(x: 0, y: 0, width: width, height: height))

        var inks: [PaneInk] = []
        for pane in panes where pane.view.window === window && !pane.view.isHiddenOrHasHiddenAncestor {
            pane.view.surface.renderIfDirty(offscreen: true)
            guard let image = pane.view.surface.snapshot() else { continue }
            var rect = pane.view.convert(pane.view.bounds, to: root)
            if root.isFlipped { rect.origin.y = bounds.height - rect.maxY }
            let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            context.draw(image, in: pixelRect)
            inks.append(PaneInk(pane: pane.id.description, ink: ink(image)))
        }
        guard let image = context.makeImage() else { return nil }
        return Result(image: image, panes: inks)
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Share of pixels far (> 48 in some channel) from the colour at the top-left corner (padding,
    /// i.e. the background).
    static func ink(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        guard width > 4, height > 4,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let background = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
        var count = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let distance = max(abs(Int(pixels[i]) - background.0), abs(Int(pixels[i + 1]) - background.1), abs(Int(pixels[i + 2]) - background.2))
            if distance > 48 { count += 1 }
        }
        return Double(count) / Double(width * height)
    }
}
#endif
