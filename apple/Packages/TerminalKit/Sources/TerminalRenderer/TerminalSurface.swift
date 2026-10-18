import Foundation
import Metal
import QuartzCore
import Synchronization
import TerminalCore

/// Platform-neutral terminal view logic: owns the `CAMetalLayer`, the render loop and the grid
/// geometry. A thin host view (`TerminalView`: an AppKit `NSView` or a UIKit `UIView`) forwards layout, the
/// display link, focus, scrolling and keys.
///
/// Rendering only happens when the terminal reports dirty state: the display link pauses itself on
/// a clean frame and `setNeedsRender()` (callable from any thread, e.g. the PTY reader) resumes it.
@MainActor
public final class TerminalSurface {
    public struct Grid: Equatable, Sendable {
        public var cols: UInt16
        public var rows: UInt16
        public var cellWidth: UInt32
        public var cellHeight: UInt32
    }

    public let terminal: Terminal
    public let layer = CAMetalLayer()
    public let stats = FrameStats()
    /// Called when the cell grid changes size, e.g. to send TIOCSWINSZ to the PTY.
    public var onGridChange: ((Grid) -> Void)?
    public private(set) var grid: Grid?
    /// The cursor cell in view points as of the last rendered frame (IME candidate window and
    /// preedit placement); nil when the cursor is hidden or scrolled out of the viewport.
    public private(set) var cursorRect: CGRect?
    public var isFocused = true {
        didSet { invalidate() }
    }

    /// Ghostty's default `font-size` on macOS, in points.
    public let fontSize: CGFloat
    /// Ghostty's default `window-padding-x/y`, in points.
    private let padding: CGFloat = 2

    private let renderer: MetalRenderer
    private var fonts: FontGrid?
    private let state = RenderState()
    private var builder = FrameBuilder()
    private var frame = FrameContents()
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var pixelSize = CGSize.zero
    private var paddingPx = SIMD4<Float>.zero
    private var needsFullRender = true
    private var offscreenTexture: MTLTexture?
    private nonisolated let wakePending = Atomic<Bool>(false)

    public init(terminal: Terminal, fontSize: CGFloat = 13) throws {
        self.terminal = terminal
        self.fontSize = fontSize
        renderer = try MetalRenderer()
        layer.device = renderer.device
        layer.pixelFormat = MetalRenderer.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
    }

    /// Seconds spent compiling shaders.metal at startup.
    public var shaderCompileSeconds: Double { renderer.shaderCompileSeconds }

    /// Atlas edge lengths in pixels (grayscale, color).
    public var atlasSizes: (grayscale: Int, color: Int) {
        (fonts?.grayscale.size ?? 0, fonts?.color.size ?? 0)
    }

    /// Starts frame pacing. `make` creates a display link on the host platform
    /// (`NSView.displayLink(target:selector:)` or `CADisplayLink(target:selector:)`). Replaces a
    /// running link, e.g. when the host view moves to another window or screen.
    public func startDisplayLink(_ make: (_ target: Any, _ selector: Selector) -> CADisplayLink) {
        stopDisplayLink()
        let target = DisplayLinkTarget(surface: self)
        let link = make(target, #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLinkTarget = target
        displayLink = link
    }

    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }

    /// Sizes the drawable and the cell grid for a view of `size` points at `scale` pixels/point.
    public func layout(size: CGSize, scale: CGFloat) {
        if fonts == nil || layer.contentsScale != scale {
            layer.contentsScale = scale
            fonts = FontGrid(pixelSize: fontSize * scale)
            builder = FrameBuilder()
        }
        guard let fonts else { return }
        pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        layer.drawableSize = pixelSize

        let m = fonts.metrics
        let pad = Int((padding * scale).rounded())
        let cols = max(1, (Int(pixelSize.width) - 2 * pad) / m.cellWidth)
        let rows = max(1, (Int(pixelSize.height) - 2 * pad) / m.cellHeight)
        // Ghostty without padding balance: fixed top/left, the remainder goes right/bottom.
        paddingPx = SIMD4(
            Float(pad),
            Float(Int(pixelSize.width) - pad - cols * m.cellWidth),
            Float(Int(pixelSize.height) - pad - rows * m.cellHeight),
            Float(pad))

        let newGrid = Grid(cols: UInt16(cols), rows: UInt16(rows), cellWidth: UInt32(m.cellWidth), cellHeight: UInt32(m.cellHeight))
        if newGrid != grid {
            grid = newGrid
            terminal.resize(cols: newGrid.cols, rows: newGrid.rows, cellWidth: newGrid.cellWidth, cellHeight: newGrid.cellHeight)
            onGridChange?(newGrid)
        }
        invalidate()
    }

    /// Scrolls the viewport through scrollback; negative is up.
    public func scroll(rows: Int) {
        guard rows != 0 else { return }
        terminal.scrollViewport(by: rows)
        setNeedsRender()
    }

    /// Encodes a key press for the PTY and snaps the viewport back to the bottom, as Ghostty does.
    public func encode(_ key: KeyEvent) -> [UInt8] {
        let bytes = terminal.encode(key)
        if !bytes.isEmpty {
            terminal.scrollToBottom()
            setNeedsRender()
        }
        return bytes
    }

    /// Marks the terminal as changed. Safe to call from any thread; coalesces wakeups.
    public nonisolated func setNeedsRender() {
        guard !wakePending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Task { @MainActor in self.displayLink?.isPaused = false }
    }

    /// Forces a redraw of everything (resize, focus, scale changes).
    private func invalidate() {
        needsFullRender = true
        setNeedsRender()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        wakePending.store(false, ordering: .releasing)
        if !renderIfDirty() { link.isPaused = true }
    }

    /// Snapshots the terminal and, if anything changed, rebuilds dirty rows and presents a frame.
    /// Returns false when the frame was clean (the display link uses this to go idle).
    /// - Parameter offscreen: draw into an offscreen texture instead of a layer drawable (headless
    ///   benchmarks; a layer that is not on screen hands out drawables at an arbitrary cadence).
    @discardableResult
    public func renderIfDirty(offscreen: Bool = false) -> Bool {
        guard let fonts, pixelSize.width > 0 else { return false }
        let start = CACurrentMediaTime()
        state.update(from: terminal)
        guard state.dirty != .clean || needsFullRender else { return false }
        let rows = builder.build(state, fonts: fonts, focused: isFocused, into: &frame)
        cursorRect = cursorRect(state.cursor, metrics: fonts.metrics)
        state.markClean()
        needsFullRender = false
        let built = CACurrentMediaTime()

        let stats = stats
        let drawable = offscreen ? nil : layer.nextDrawable()
        if let target = drawable?.texture ?? (offscreen ? offscreenTarget() : nil) {
            renderer.draw(frame, uniforms: uniforms(fonts.metrics), fonts: fonts, to: target, present: drawable) {
                stats.recordGPU(seconds: $0)
            }
        }
        let encoded = CACurrentMediaTime()
        stats.recordFrame(at: encoded, build: built - start, encode: encoded - built, rows: rows, instances: frame.text.count)
        return true
    }

    /// Renders the last built frame into an offscreen texture and returns it as an image (Display
    /// P3, like the layer). Works without a window, for tests and headless captures.
    public func snapshot() -> CGImage? {
        guard let fonts, let texture = offscreenTarget() else { return nil }
        let done = DispatchSemaphore(value: 0)
        renderer.draw(frame, uniforms: uniforms(fonts.metrics), fonts: fonts, to: texture, present: nil) { _ in done.signal() }
        done.wait()

        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: layer.colorspace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func cursorRect(_ cursor: RenderState.Cursor, metrics m: CellMetrics) -> CGRect? {
        guard cursor.visible, let position = cursor.position else { return nil }
        let scale = layer.contentsScale
        let x = Int(position.x) - (cursor.onWideTail ? 1 : 0)
        // paddingPx is (top, right, bottom, left), as in Ghostty's uniforms.
        return CGRect(
            x: (CGFloat(paddingPx.w) + CGFloat(x * m.cellWidth)) / scale,
            y: (CGFloat(paddingPx.x) + CGFloat(Int(position.y) * m.cellHeight)) / scale,
            width: CGFloat(m.cellWidth) / scale,
            height: CGFloat(m.cellHeight) / scale)
    }

    private func offscreenTarget() -> MTLTexture? {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        guard width > 0 else { return nil }
        if let texture = offscreenTexture, texture.width == width, texture.height == height { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        offscreenTexture = renderer.device.makeTexture(descriptor: descriptor)
        return offscreenTexture
    }

    private func uniforms(_ m: CellMetrics) -> Uniforms {
        let screen = SIMD2(Float(pixelSize.width), Float(pixelSize.height))
        let cursor = frame.blockCursor
        return Uniforms(
            projectionMatrix: Uniforms.projection(screen: screen, padding: paddingPx),
            screenSize: screen,
            cellSize: SIMD2(Float(m.cellWidth), Float(m.cellHeight)),
            gridSize: SIMD2(UInt16(frame.cols), UInt16(frame.rows)),
            gridPadding: paddingPx,
            paddingExtend: 0,
            minContrast: 1,
            cursorPos: cursor?.pos ?? SIMD2(.max, .max),
            cursorColor: cursor?.textColor ?? .zero,
            bgColor: frame.background,
            cursorWide: cursor?.wide ?? false,
            useDisplayP3: false,
            useLinearBlending: false,
            useLinearCorrection: false)
    }
}

/// `CADisplayLink` needs an Objective-C target; this forwards to the surface without retaining it.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var surface: TerminalSurface?

    init(surface: TerminalSurface) {
        self.surface = surface
    }

    @objc func tick(_ link: CADisplayLink) {
        surface?.tick(link)
    }
}
