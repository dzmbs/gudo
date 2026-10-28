import Accelerate
import Foundation
import Metal
import TerminalCore

/// A kitty graphics image on the GPU, for one generation of its pixels.
struct KittyTexture {
    /// Larger images are scaled down on upload: no placement needs more, and it bounds memory.
    static let maxSide = 4096

    let generation: UInt64
    let texture: MTLTexture
    /// Texture pixels per image pixel (below 1 for a scaled-down image).
    let scale: Float

    init?(_ pixels: KittyImagePixels, renderer: MetalRenderer) {
        let fit = min(1, Double(Self.maxSide) / Double(max(pixels.width, pixels.height)))
        let width = max(1, Int((Double(pixels.width) * fit).rounded()))
        let height = max(1, Int((Double(pixels.height) * fit).rounded()))
        var rgba = pixels.rgba
        if width != pixels.width || height != pixels.height {
            var scaled = Data(count: width * height * 4)
            let error = rgba.withUnsafeMutableBytes { source in
                scaled.withUnsafeMutableBytes { destination in
                    var from = vImage_Buffer(
                        data: source.baseAddress, height: vImagePixelCount(pixels.height),
                        width: vImagePixelCount(pixels.width), rowBytes: pixels.width * 4)
                    var to = vImage_Buffer(
                        data: destination.baseAddress, height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width * 4)
                    return vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
                }
            }
            guard error == kvImageNoError else { return nil }
            rgba = scaled
        }
        guard let texture = renderer.makeTexture(InlineImagePixels(width: width, height: height, rgba: rgba)) else { return nil }
        generation = pixels.generation
        self.texture = texture
        scale = Float(width) / Float(pixels.width)
    }
}

/// A frame's kitty graphics quads by layer, each in drawing order.
struct KittyDraws {
    var belowBackground: [ImageDraw] = []
    var belowText: [ImageDraw] = []
    var aboveText: [ImageDraw] = []
}
