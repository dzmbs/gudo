import Foundation
import Metal
import Testing
import TerminalCore
@testable import TerminalRenderer

@Suite struct GPULayoutTests {
    /// The Swift `Uniforms` must match the MSL struct byte for byte; ask Metal where each member
    /// of the runtime-compiled shader lives.
    @Test func uniformsMatchShaderReflection() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: MetalRenderer.shaderSource(), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cell_text_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cell_text_fragment")
        descriptor.vertexDescriptor = MetalRenderer.cellTextVertexDescriptor()
        descriptor.colorAttachments[0].pixelFormat = MetalRenderer.pixelFormat
        let (_, reflection) = try device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo, .bufferTypeInfo])
        let binding = try #require(reflection?.vertexBindings.first { $0.name == "uniforms" } as? MTLBufferBinding)
        let members = try #require(binding.bufferStructType?.members)
        let offsets = Dictionary(uniqueKeysWithValues: members.map { ($0.name, $0.offset) })

        let swift: [(String, PartialKeyPath<Uniforms>)] = [
            ("projection_matrix", \.projectionMatrix), ("screen_size", \.screenSize), ("cell_size", \.cellSize),
            ("grid_size", \.gridSize), ("grid_padding", \.gridPadding), ("padding_extend", \.paddingExtend),
            ("min_contrast", \.minContrast), ("cursor_pos", \.cursorPos), ("cursor_color", \.cursorColor),
            ("bg_color", \.bgColor), ("cursor_wide", \.cursorWide), ("use_display_p3", \.useDisplayP3),
            ("use_linear_blending", \.useLinearBlending), ("use_linear_correction", \.useLinearCorrection),
        ]
        for (name, keyPath) in swift {
            #expect(offsets[name] == MemoryLayout<Uniforms>.offset(of: keyPath), "\(name)")
        }
        #expect(binding.bufferDataSize == MemoryLayout<Uniforms>.stride)
    }

    @Test func cellTextIs32Bytes() {
        #expect(MemoryLayout<CellText>.stride == 32)
    }
}

@Suite struct AtlasTests {
    @Test func packsWithoutOverlapAndGrows() {
        var atlas = Atlas(format: .grayscale, size: 64)
        let pixels = [UInt8](repeating: 0xFF, count: 20 * 20)
        let regions = (0..<12).map { _ in pixels.withUnsafeBytes { atlas.insert(width: 20, height: 20, data: $0) } }
        #expect(atlas.size == 128)
        #expect(atlas.takePendingUploads() == nil)  // grew: re-upload everything
        for (i, a) in regions.enumerated() {
            #expect(a.x >= 1 && a.y >= 1 && a.x + a.width < atlas.size && a.y + a.height < atlas.size)
            for b in regions[(i + 1)...] {
                let disjoint = a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y
                #expect(disjoint)
            }
        }
        let next = pixels.withUnsafeBytes { atlas.insert(width: 20, height: 20, data: $0) }
        #expect(atlas.takePendingUploads() == [next])
        #expect(atlas.pixels[next.y * atlas.size + next.x] == 0xFF)
    }
}

@MainActor
@Suite struct FrameBuilderTests {
    @Test func reusesCleanRowsByIdAndRebuildsDirtyOnes() {
        let terminal = Terminal(cols: 40, rows: 10) { _ in }
        let state = RenderState()
        let fonts = FontGrid(pixelSize: 26)
        let builder = FrameBuilder()
        var frame = FrameContents()

        terminal.write(Array("hello\r\nworld".utf8))
        state.update(from: terminal)
        var stats = builder.build(state, fonts: fonts, overlay: FrameOverlay(), into: &frame)
        state.markClean()
        #expect(stats.rowsRebuilt == 10 && stats.rowsReused == 0)
        #expect(frame.bgCells.count == 400)
        #expect(frame.blockCursor?.pos == SIMD2(5, 1))
        // 10 glyphs + the block cursor, drawn first.
        #expect(frame.text.count == 11)
        #expect(frame.text[0].flags == CellText.Flags.isCursorGlyph.rawValue)

        terminal.write(Array("!".utf8))
        state.update(from: terminal)
        stats = builder.build(state, fonts: fonts, overlay: FrameOverlay(), into: &frame)
        #expect(stats.rowsRebuilt == 1 && stats.rowsReused == 9)
        #expect(frame.text.filter { $0.gridPos.y == 1 && $0.flags == 0 }.count == 6)
    }

    @Test func inverseAndColorsResolveToCellBackgrounds() {
        let terminal = Terminal(cols: 4, rows: 1) { _ in }
        let state = RenderState()
        let builder = FrameBuilder()
        var frame = FrameContents()
        terminal.write(Array("\u{1b}[41mA\u{1b}[0;7mB".utf8))
        state.update(from: terminal)
        _ = builder.build(state, fonts: FontGrid(pixelSize: 26), overlay: FrameOverlay(focused: false), into: &frame)
        #expect(frame.bgCells[0].w == 255 && frame.bgCells[0].x > frame.bgCells[0].y)  // red
        #expect(frame.bgCells[1] == SIMD4(255, 255, 255, 255))  // inverse: default fg as bg
        #expect(frame.bgCells[2].w == 0)  // default background
        #expect(frame.blockCursor == nil)  // unfocused: hollow cursor, no inverted text
    }
}
