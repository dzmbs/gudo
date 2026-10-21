import CoreGraphics
import Foundation
import Metal
import TerminalCore

/// A stripe in the left gutter beside a run of viewport rows: a shell command's rows (OSC 133
/// marks), drawn by the renderer in the same frame as the cells so it never lags the text while
/// output scrolls. `row` is the first row (negative once its top scrolled above the viewport);
/// the host resolves it each frame from a pinned row.
public struct GutterMark: Equatable, Sendable {
    /// The host's id for the mark (hit testing, accessibility).
    public var id: UInt64
    public var row: Int
    public var rows: Int
    public var tint: Tint
    /// 0…1.
    public var opacity: Double
    /// colour at a few percent), 0 for none.
    public var rowTint: Double

    /// A colour of the terminal's current theme, so the stripe follows theme and OSC 4/10
    /// changes.
    public enum Tint: Hashable, Sendable {
        case foreground
        /// A palette entry (1 = ANSI red).
        case palette(UInt8)
        case rgb(RGB)
    }

    public init(id: UInt64, row: Int, rows: Int, tint: Tint, opacity: Double = 1, rowTint: Double = 0) {
        self.id = id
        self.row = row
        self.rows = rows
        self.tint = tint
        self.opacity = opacity
        self.rowTint = rowTint
    }

    func color(_ colors: RenderState.Colors) -> RGB {
        switch tint {
        case .foreground: colors.foreground
        case .palette(let index): colors.palette.indices.contains(Int(index)) ? colors.palette[Int(index)] : colors.foreground
        case .rgb(let rgb): rgb
        }
    }
}

extension TerminalSurface {
    /// Stripe width in pixels: up to 3 pt, inside the left padding, never touching the first
    /// column (at least 1 px of air), and at least 2 px so it shows at all.
    static func gutterWidth(paddingLeft: Int, scale: CGFloat) -> Int {
        max(2, min(Int((3 * scale).rounded()), paddingLeft - 1))
    }

    /// Vertical inset at each end of a stripe in pixels, so the stripes of two commands that
    /// follow each other read as two.
    static func gutterInset(cellHeight: Int, scale: CGFloat) -> Int {
        min(Int((1.5 * scale).rounded()), cellHeight / 6)
    }
}

/// 1×1 textures, one per stripe colour (sampled with clamp-to-edge, so a quad of any size is
/// that colour).
struct GutterTextures {
    private var textures: [UInt32: MTLTexture] = [:]

    mutating func texture(_ color: RGB, opacity: Double, device: MTLDevice) -> MTLTexture? {
        let alpha = UInt8((min(max(opacity, 0), 1) * 255).rounded())
        let key = UInt32(color.r) << 24 | UInt32(color.g) << 16 | UInt32(color.b) << 8 | UInt32(alpha)
        if let texture = textures[key] { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel = [color.r, color.g, color.b, alpha]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        // A handful of colours per theme; start over if theme switches pile them up.
        if textures.count > 32 { textures.removeAll() }
        textures[key] = texture
        return texture
    }
}
