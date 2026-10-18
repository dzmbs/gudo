import simd

// Swift mirrors of the structs in Resources/Shaders/shaders.metal, matching Ghostty's
// src/renderer/metal/shaders.zig. Field order and types reproduce the MSL layout exactly;
// TerminalRendererTests checks every offset against Metal's reflection of the compiled shader.

/// `struct Uniforms` (MSL). 144 bytes.
struct Uniforms {
    var projectionMatrix: simd_float4x4
    var screenSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var gridSize: SIMD2<UInt16>
    /// Top, right, bottom, left, in pixels.
    var gridPadding: SIMD4<Float>
    var paddingExtend: UInt8
    var minContrast: Float
    var cursorPos: SIMD2<UInt16>
    var cursorColor: SIMD4<UInt8>
    var bgColor: SIMD4<UInt8>
    var cursorWide: Bool
    var useDisplayP3: Bool
    var useLinearBlending: Bool
    var useLinearCorrection: Bool
}

/// One instanced quad of the `cell_text` pipeline (`CellTextVertexIn`). 32 bytes, like Ghostty's.
struct CellText {
    enum Atlas: UInt8 {
        case grayscale = 0
        case color = 1
    }

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let noMinContrast = Flags(rawValue: 1)
        static let isCursorGlyph = Flags(rawValue: 2)
    }

    var glyphPos: SIMD2<UInt32>
    var glyphSize: SIMD2<UInt32>
    var bearings: SIMD2<Int16>
    var gridPos: SIMD2<UInt16>
    var color: SIMD4<UInt8>
    var atlas: UInt8
    var flags: UInt8
}

extension Uniforms {
    /// Ghostty's `math.ortho2d(-pad.left, width + pad.right, height + pad.bottom, -pad.top)`:
    /// grid-space pixels (origin at the first cell) to clip space.
    static func projection(screen: SIMD2<Float>, padding: SIMD4<Float>) -> simd_float4x4 {
        let left = -padding.w, right = screen.x - padding.w
        let top = -padding.x, bottom = screen.y - padding.x
        return simd_float4x4(columns: (
            SIMD4(2 / (right - left), 0, 0, 0),
            SIMD4(0, 2 / (top - bottom), 0, 0),
            SIMD4(0, 0, -1, 0),
            SIMD4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), 0, 1)
        ))
    }
}
