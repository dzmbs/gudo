import Foundation
import Metal
import QuartzCore

enum RendererError: Error {
    case noDevice
    case missingShaderSource
    case missingFunction(String)
}

/// Device, queue and compiled pipelines, shared by every `TerminalSurface` in the process so a new
/// pane costs neither a shader compile nor another command queue. Metal devices, queues and
/// pipeline states are thread-safe.
final class GPUContext: Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let bgColorPipeline: MTLRenderPipelineState
    let cellBgPipeline: MTLRenderPipelineState
    let cellTextPipeline: MTLRenderPipelineState
    /// Inline images (Ghostty's `image` pipeline): placements drawn above the text.
    let imagePipeline: MTLRenderPipelineState
    /// Runtime shader compile time, reported by the demo and the bench.
    let shaderCompileSeconds: Double

    /// Created on first use. A failure is kept, so every surface reports the same error.
    static let shared = Result { try GPUContext() }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noDevice
        }
        self.device = device
        self.queue = queue

        let source = try MetalRenderer.shaderSource()
        let start = CFAbsoluteTimeGetCurrent()
        let library = try device.makeLibrary(source: source, options: nil)
        shaderCompileSeconds = CFAbsoluteTimeGetCurrent() - start

        bgColorPipeline = try Self.pipeline(device, library, vertex: "full_screen_vertex", fragment: "bg_color_fragment", blending: false)
        cellBgPipeline = try Self.pipeline(device, library, vertex: "full_screen_vertex", fragment: "cell_bg_fragment", blending: true)
        cellTextPipeline = try Self.pipeline(
            device, library, vertex: "cell_text_vertex", fragment: "cell_text_fragment", blending: true,
            vertexDescriptor: MetalRenderer.cellTextVertexDescriptor())
        imagePipeline = try Self.pipeline(
            device, library, vertex: "image_vertex", fragment: "image_fragment", blending: true,
            vertexDescriptor: MetalRenderer.imageVertexDescriptor())
    }

    private static func pipeline(
        _ device: MTLDevice, _ library: MTLLibrary, vertex: String, fragment: String, blending: Bool,
        vertexDescriptor: MTLVertexDescriptor? = nil
    ) throws -> MTLRenderPipelineState {
        guard let vertexFn = library.makeFunction(name: vertex) else { throw RendererError.missingFunction(vertex) }
        guard let fragmentFn = library.makeFunction(name: fragment) else { throw RendererError.missingFunction(fragment) }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.vertexDescriptor = vertexDescriptor
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = MetalRenderer.pixelFormat
        // Ghostty always blends premultiplied alpha (metal/Pipeline.zig).
        attachment.isBlendingEnabled = blending
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// GPU side of one surface: Ghostty's Metal pipelines (`bg_color`, `cell_bg`, `cell_text`) driven
/// from `FrameContents`, with triple-buffered per-frame buffers like `renderer/Metal.zig`.
///
/// Presentation goes through `CAMetalLayer` drawables (the idiomatic iOS path) instead of Ghostty's
/// IOSurface layer.
final class MetalRenderer {
    /// Ghostty's default (`alpha-blending = native` on macOS): gamma-space blending into an
    /// 8-bit unorm target; sRGB colors converted to the layer's Display P3 in the shader.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    private static let maxFramesInFlight = 3

    private let gpu: GPUContext
    var device: MTLDevice { gpu.device }
    var shaderCompileSeconds: Double { gpu.shaderCompileSeconds }

    private struct FrameBuffers {
        var bgCells: MTLBuffer?
        var text: MTLBuffer?
        var images: MTLBuffer?
        var gutter: MTLBuffer?
    }

    private var frames = [FrameBuffers](repeating: FrameBuffers(), count: maxFramesInFlight)
    private var frameIndex = 0
    private let inFlight = DispatchSemaphore(value: maxFramesInFlight)

    private var grayscaleTexture: MTLTexture?
    private var colorTexture: MTLTexture?

    init() throws {
        gpu = try GPUContext.shared.get()
    }

    /// Ghostty's shaders.metal, shipped as a resource and compiled at runtime (no offline `metal`).
    static func shaderSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "shaders", withExtension: "metal", subdirectory: "Shaders") else {
            throw RendererError.missingShaderSource
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Encodes and commits one frame into `target`, presenting `drawable` if given.
    /// `onGPUComplete` receives the GPU execution time in seconds.
    func draw(
        _ frame: FrameContents, uniforms: Uniforms, fonts: FontGrid, to target: MTLTexture, present drawable: CAMetalDrawable?,
        images: [ImageDraw] = [], imageClip: MTLScissorRect? = nil,
        gutter: [ImageDraw] = [], gutterClip: MTLScissorRect? = nil,
        onGPUComplete: @escaping @Sendable (Double) -> Void
    ) {
        inFlight.wait()
        guard let commands = gpu.queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        frameIndex = (frameIndex + 1) % Self.maxFramesInFlight
        let bgCells = upload(frame.bgCells, into: &frames[frameIndex].bgCells)
        let text = upload(frame.text, into: &frames[frameIndex].text)
        grayscaleTexture = sync(&fonts.grayscale, texture: grayscaleTexture, format: .r8Unorm)
        colorTexture = sync(&fonts.color, texture: colorTexture, format: .bgra8Unorm_srgb)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        var uniforms = uniforms

        // 1. Background color: full-screen triangle, no blending.
        encoder.setRenderPipelineState(gpu.bgColorPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2. Cell backgrounds: full-screen fragment shader indexing the flat bg_cells buffer.
        encoder.setRenderPipelineState(gpu.cellBgPipeline)
        encoder.setFragmentBuffer(bgCells, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 3. Text, decorations and cursor: one instanced quad (triangle strip) per glyph.
        if !frame.text.isEmpty {
            encoder.setRenderPipelineState(gpu.cellTextPipeline)
            encoder.setVertexBuffer(text, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setVertexBuffer(bgCells, offset: 0, index: 2)
            encoder.setFragmentTexture(grayscaleTexture, index: 0)
            encoder.setFragmentTexture(colorTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: frame.text.count)
        }

        // 4. Inline images above the text (kitty's "above text" layer), clipped to the grid.
        if !images.isEmpty, let buffer = upload(images.map(\.vertex), into: &frames[frameIndex].images) {
            encoder.setRenderPipelineState(gpu.imagePipeline)
            if let imageClip { encoder.setScissorRect(imageClip) }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            for (index, image) in images.enumerated() {
                encoder.setVertexBuffer(buffer, offset: index * MemoryLayout<ImageVertex>.stride, index: 0)
                encoder.setFragmentTexture(image.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            }
        }

        // 5. Gutter stripes (shell command marks) in the left padding, through the image
        //    pipeline with 1×1 textures, clipped to the padding beside the grid's rows.
        if !gutter.isEmpty, let gutterClip, let buffer = upload(gutter.map(\.vertex), into: &frames[frameIndex].gutter) {
            encoder.setRenderPipelineState(gpu.imagePipeline)
            encoder.setScissorRect(gutterClip)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            for (index, stripe) in gutter.enumerated() {
                encoder.setVertexBuffer(buffer, offset: index * MemoryLayout<ImageVertex>.stride, index: 0)
                encoder.setFragmentTexture(stripe.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            }
        }
        encoder.endEncoding()

        let semaphore = inFlight
        commands.addCompletedHandler { buffer in
            onGPUComplete(buffer.gpuEndTime - buffer.gpuStartTime)
            semaphore.signal()
        }
        guard let drawable else {
            commands.commit()
            return
        }
        if drawable.layer.presentsWithTransaction {
            // In step with the Core Animation transaction that resizes the layer: the new size
            // never shows the previous frame stretched, or nothing.
            commands.commit()
            commands.waitUntilScheduled()
            drawable.present()
        } else {
            commands.present(drawable)
            commands.commit()
        }
    }

    private func upload<T>(_ items: [T], into slot: inout MTLBuffer?) -> MTLBuffer? {
        let length = max(MemoryLayout<T>.stride * items.count, MemoryLayout<T>.stride)
        if slot == nil || slot!.length < length {
            // Grow geometrically so steady-state frames never reallocate.
            slot = device.makeBuffer(length: length * 2, options: .storageModeShared)
        }
        guard let buffer = slot else { return nil }
        items.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return buffer
    }

    /// Uploads only the atlas regions written since the last frame; reallocates after a grow.
    ///
    /// New glyphs land in regions no in-flight frame samples, so writing them while earlier frames
    /// are on the GPU is safe; a grow allocates a fresh texture and leaves the old one to them.
    private func sync(_ atlas: inout Atlas, texture: MTLTexture?, format: MTLPixelFormat) -> MTLTexture? {
        var texture = texture
        var regions = atlas.takePendingUploads()
        if texture == nil || texture!.width != atlas.size {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: atlas.size, height: atlas.size, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
            regions = nil
        }
        guard let texture else { return nil }
        let depth = atlas.format.depth
        let size = atlas.size
        atlas.pixels.withUnsafeBytes { pixels in
            for region in regions ?? [Atlas.Region(x: 0, y: 0, width: size, height: size)] {
                texture.replace(
                    region: MTLRegionMake2D(region.x, region.y, region.width, region.height),
                    mipmapLevel: 0,
                    withBytes: pixels.baseAddress!.advanced(by: (region.y * size + region.x) * depth),
                    bytesPerRow: size * depth)
            }
        }
        return texture
    }

    /// Attribute layout of `CellTextVertexIn`, stepping once per instance.
    static func cellTextVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let layout: [(format: MTLVertexFormat, offset: Int)] = [
            (.uint2, MemoryLayout<CellText>.offset(of: \.glyphPos)!),
            (.uint2, MemoryLayout<CellText>.offset(of: \.glyphSize)!),
            (.short2, MemoryLayout<CellText>.offset(of: \.bearings)!),
            (.ushort2, MemoryLayout<CellText>.offset(of: \.gridPos)!),
            (.uchar4, MemoryLayout<CellText>.offset(of: \.color)!),
            (.uchar, MemoryLayout<CellText>.offset(of: \.atlas)!),
            (.uchar, MemoryLayout<CellText>.offset(of: \.flags)!),
        ]
        for (index, attribute) in layout.enumerated() {
            descriptor.attributes[index].format = attribute.format
            descriptor.attributes[index].offset = attribute.offset
            descriptor.attributes[index].bufferIndex = 0
        }
        descriptor.layouts[0].stride = MemoryLayout<CellText>.stride
        descriptor.layouts[0].stepFunction = .perInstance
        descriptor.layouts[0].stepRate = 1
        return descriptor
    }
}
