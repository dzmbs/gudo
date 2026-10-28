import Accelerate
import CoreGraphics
import Foundation
import Metal
import simd

/// An image the host draws over the grid, such as a drawing placed inline (docs/DAEMON.md §7.10): it
/// covers `cols × rows` cells from column `col` of viewport row `row` (negative when its top
/// has scrolled above the viewport), in the layer above the text. The host resolves `row`
/// each frame from a pinned row, so the image scrolls with the output.
public struct InlineImagePlacement: Equatable, Sendable {
    /// The image's key in the surface (`setInlineImage(_:key:)`).
    public var key: String
    public var col: Int
    public var row: Int
    public var cols: Int
    public var rows: Int

    public init(key: String, col: Int, row: Int, cols: Int, rows: Int) {
        self.key = key
        self.col = col
        self.row = row
        self.cols = cols
        self.rows = rows
    }
}

/// Decoded RGBA pixels (straight alpha, sRGB) ready for a texture. Decode off the main thread
/// (`init?(image:)`), hand to the surface on it.
public struct InlineImagePixels: Sendable {
    public let width: Int
    public let height: Int
    let rgba: Data

    init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// Decodes `image` into 8-bit RGBA with straight alpha (the image shader premultiplies).
    public init?(image: CGImage, maxSide: Int = 4096) {
        var width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        width = max(1, Int((Double(width) * scale).rounded()))
        height = max(1, Int((Double(height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            return vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        rgba = Data(pixels)
    }
}

/// `struct ImageVertexIn` (MSL, Ghostty's image shader): one instance per placement.
struct ImageVertex {
    var gridPos: SIMD2<Float>
    var cellOffset: SIMD2<Float>
    var sourceRect: SIMD4<Float>
    var destSize: SIMD2<Float>
}

/// One image quad of a frame.
struct ImageDraw {
    var texture: MTLTexture
    var vertex: ImageVertex
}

extension MetalRenderer {
    static func imageVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let layout: [(format: MTLVertexFormat, offset: Int)] = [
            (.float2, MemoryLayout<ImageVertex>.offset(of: \.gridPos)!),
            (.float2, MemoryLayout<ImageVertex>.offset(of: \.cellOffset)!),
            (.float4, MemoryLayout<ImageVertex>.offset(of: \.sourceRect)!),
            (.float2, MemoryLayout<ImageVertex>.offset(of: \.destSize)!),
        ]
        for (index, attribute) in layout.enumerated() {
            descriptor.attributes[index].format = attribute.format
            descriptor.attributes[index].offset = attribute.offset
            descriptor.attributes[index].bufferIndex = 0
        }
        descriptor.layouts[0].stride = MemoryLayout<ImageVertex>.stride
        descriptor.layouts[0].stepFunction = .perInstance
        descriptor.layouts[0].stepRate = 1
        return descriptor
    }

    /// A texture for decoded pixels (sRGB, sampled as linear and re-encoded by the shader).
    func makeTexture(_ pixels: InlineImagePixels) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: pixels.width, height: pixels.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.rgba.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: pixels.width * 4)
        }
        return texture
    }
}
