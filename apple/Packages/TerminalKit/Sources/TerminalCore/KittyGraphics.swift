import Accelerate
import Foundation
import GhosttyVt
import ImageIO

/// Kitty graphics (`kitty_graphics.h`): libghostty-vt keeps the images programs send, the render
/// state says where they go, and this reads their pixels for the renderer.
public enum KittyGraphics {
    /// Image storage per screen, the daemon's default (`ghostty_vt::KITTY_IMAGE_STORAGE_LIMIT`):
    /// a mirror with less could evict an image the daemon still places, and then lay out the
    /// text after it differently.
    public static let storageLimit: UInt64 = 64 << 20

    /// Installs the process-wide PNG decoder libghostty-vt needs to accept PNG images (`f=100`).
    static let installPNGDecoder: Void = {
        let decode: GhosttySysDecodePngFn = { _, allocator, data, length, out in
            guard let data, let out,
                  let (width, height, rgba) = decodePNG(UnsafeRawBufferPointer(start: data, count: length)),
                  let buffer = ghostty_alloc(allocator, rgba.count)
            else { return false }
            rgba.withUnsafeBytes { buffer.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: rgba.count) }
            out.pointee = GhosttySysImage(width: width, height: height, data: buffer, data_len: rgba.count)
            return true
        }
        ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decode, to: UnsafeRawPointer.self))
    }()

    /// Decodes a PNG to 8-bit straight-alpha RGBA, as Ghostty stores images.
    static func decodePNG(_ png: UnsafeRawBufferPointer) -> (UInt32, UInt32, [UInt8])? {
        guard let source = CGImageSourceCreateWithData(Data(png) as CFData, nil),
              CGImageSourceGetType(source).map({ $0 as String == "public.png" }) == true,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var buffer = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            return vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        return decoded ? (UInt32(width), UInt32(height), pixels) : nil
    }
}

/// An image's pixels as 8-bit straight-alpha RGBA, copied out of the terminal.
public struct KittyImagePixels: Sendable {
    public let id: UInt32
    /// Changes whenever the pixels may have changed (resent, next animation frame).
    public let generation: UInt64
    public let width: Int
    public let height: Int
    public let rgba: Data
}

extension Terminal {
    /// The pixels of image `id` on the active screen as RGBA, or nil when there is no such image
    /// or its pixels are still on the way (restored from a snapshot, the pixels behind).
    public func kittyImage(id: UInt32) -> KittyImagePixels? {
        withHandle { handle in
            guard let graphics = Self.kittyGraphics(handle), let image = ghostty_kitty_graphics_image(graphics, id) else { return nil }
            var width: UInt32 = 0, height: UInt32 = 0, generation: UInt64 = 0, length = 0
            var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
            var data: UnsafePointer<UInt8>?
            guard ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width) == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height) == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format) == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation) == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &data) == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length) == GHOSTTY_SUCCESS,
                  let data, width > 0, height > 0
            else { return nil }
            let count = Int(width) * Int(height)
            let source = UnsafeBufferPointer(start: data, count: length)
            let rgba: Data
            switch format {
            case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA where length >= count * 4:
                rgba = Data(source.prefix(count * 4))
            case GHOSTTY_KITTY_IMAGE_FORMAT_RGB where length >= count * 3:
                rgba = Self.expand(count) { i in (source[3 * i], source[3 * i + 1], source[3 * i + 2], 255) }
            case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA where length >= count * 2:
                rgba = Self.expand(count) { i in (source[2 * i], source[2 * i], source[2 * i], source[2 * i + 1]) }
            case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY where length >= count:
                rgba = Self.expand(count) { i in (source[i], source[i], source[i], 255) }
            default:
                return nil
            }
            return KittyImagePixels(id: id, generation: generation, width: Int(width), height: Int(height), rgba: rgba)
        }
    }

    /// Changes whenever the active screen's storage gains, loses or completes an image, or a
    /// placement (pending pixels arriving included); 0 while nothing was ever stored.
    public var kittyStorageGeneration: UInt64 {
        withHandle { handle in
            var generation: UInt64 = 0
            guard let graphics = Self.kittyGraphics(handle) else { return 0 }
            ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation)
            return generation
        }
    }

    /// Advances playing animations to `nowMs` (a monotonic clock in milliseconds); returns when
    /// the next frame is due, or nil when nothing plays.
    public func tickKittyAnimations(nowMs: UInt64) -> UInt64? {
        withHandle { handle in
            guard let graphics = Self.kittyGraphics(handle) else { return nil }
            var next: UInt64 = 0
            return ghostty_kitty_graphics_animation_tick(graphics, nowMs, &next) == GHOSTTY_SUCCESS ? next : nil
        }
    }

    /// The size of one cell in pixels as the terminal lays images out: the daemon's for a
    /// remote pane, which may differ from the cell the renderer draws.
    public var cellPixelSize: (width: UInt32, height: UInt32) {
        withHandle { handle in
            var cols: UInt16 = 0, rows: UInt16 = 0, width: UInt32 = 0, height: UInt32 = 0
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_WIDTH_PX, &width)
            ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_HEIGHT_PX, &height)
            return (width / UInt32(max(cols, 1)), height / UInt32(max(rows, 1)))
        }
    }

    static func kittyGraphics(_ handle: GhosttyTerminal) -> GhosttyKittyGraphics? {
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS else { return nil }
        return graphics
    }

    private static func expand(_ count: Int, _ pixel: (Int) -> (UInt8, UInt8, UInt8, UInt8)) -> Data {
        var out = Data(count: count * 4)
        out.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let (r, g, b, a) = pixel(i)
                bytes[4 * i] = r
                bytes[4 * i + 1] = g
                bytes[4 * i + 2] = b
                bytes[4 * i + 3] = a
            }
        }
        return out
    }
}

/// One rectangle of one image to draw, from the render state (`GhosttyRenderStateImageData`).
/// Positions are relative to the viewport; pixel values are in the terminal's cell pixels
/// (`Terminal.cellPixelSize`).
public struct ImagePlacement: Equatable, Sendable {
    /// Where it goes relative to the text; draw in this order.
    public enum Layer: Int, Comparable, Sendable {
        case belowBackground, belowText, aboveText

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var imageID: UInt32
    public var generation: UInt64
    public var layer: Layer
    public var z: Int32
    /// Top-left cell; either can be negative once the image starts above or left of the view.
    public var col: Int32
    public var row: Int32
    /// Offset into the top-left cell.
    public var offsetX: UInt32
    public var offsetY: UInt32
    /// Size drawn.
    public var width: UInt32
    public var height: UInt32
    /// The part of the image drawn, in image pixels.
    public var sourceX: UInt32
    public var sourceY: UInt32
    public var sourceWidth: UInt32
    public var sourceHeight: UInt32
}

extension RenderState {
    /// Changes whenever the placements the last update found changed; compare for equality only.
    public var imagePlacementsGeneration: UInt64 {
        var generation: UInt64 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION, &generation)
        return generation
    }

    /// The image placements the last update found (every kitty placement in the captured rows,
    /// Unicode placeholders resolved), in no particular order.
    public func imagePlacements() -> [ImagePlacement] {
        var iterator: GhosttyRenderStateImageIterator? = imageIterator
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &iterator) == GHOSTTY_SUCCESS else { return [] }
        var placements: [ImagePlacement] = []
        while ghostty_render_state_image_iterator_next(imageIterator) {
            func get<T: BitwiseCopyable>(_ key: GhosttyRenderStateImageData, _ initial: T) -> T {
                var value = initial
                ghostty_render_state_image_get(imageIterator, key, &value)
                return value
            }
            // Protocols added later are skipped, as render.h asks.
            guard get(GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL, GHOSTTY_IMAGE_PROTOCOL_MAX_VALUE) == GHOSTTY_IMAGE_PROTOCOL_KITTY
            else { continue }
            let layer: ImagePlacement.Layer = switch get(GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER, GHOSTTY_RENDER_STATE_IMAGE_LAYER_ABOVE_TEXT) {
            case GHOSTTY_RENDER_STATE_IMAGE_LAYER_BELOW_BACKGROUND: .belowBackground
            case GHOSTTY_RENDER_STATE_IMAGE_LAYER_BELOW_TEXT: .belowText
            default: .aboveText
            }
            placements.append(ImagePlacement(
                imageID: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID, 0),
                generation: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION, 0),
                layer: layer,
                z: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_Z, 0),
                col: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL, 0),
                row: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW, 0),
                offsetX: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X, 0),
                offsetY: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y, 0),
                width: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH, 0),
                height: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT, 0),
                sourceX: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X, 0),
                sourceY: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y, 0),
                sourceWidth: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH, 0),
                sourceHeight: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT, 0)))
        }
        return placements
    }
}
