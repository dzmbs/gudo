import QuartzCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Never-ending indicators (the working spinner, the shimmer on a working title) run as Core
// Animation on a layer: the render server draws every frame, the main thread does nothing, and
// the app reaches idle (XCUITest waits for that). The animation is added while the view is in a
// window and removed when it leaves, so nothing runs off screen.

/// A layer-backed view that keeps one repeating animation installed while it is in a window.
@MainActor
class RepeatingLayerView: PlatformLayerView {
    let animated: CALayer
    var animation: CAAnimation? {
        didSet { refreshAnimation() }
    }
    private static let key = "repeating"

    init(layer animated: CALayer) {
        self.animated = animated
        super.init(frame: .zero)
        hostLayer.addSublayer(animated)
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lays `animated` out in `bounds` (subclasses).
    func layoutAnimatedLayer() {
        animated.frame = bounds
    }

    /// Installs `animation` while in a window (once: a running one is not restarted), removes
    /// it otherwise.
    func refreshAnimation() {
        let wanted = isInWindow ? animation : nil
        if let wanted, wanted === installed, animated.animation(forKey: Self.key) != nil { return }
        animated.removeAnimation(forKey: Self.key)
        installed = wanted
        if let wanted { animated.add(wanted, forKey: Self.key) }
    }

    private var installed: CAAnimation?

    /// Changes layer properties without their implicit animations.
    func quietly(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    private func relayout() {
        quietly { layoutAnimatedLayer() }
        refreshAnimation()
    }

    #if canImport(UIKit)
    private var hostLayer: CALayer { layer }
    private var isInWindow: Bool { window != nil && bounds.width > 0 }
    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshAnimation()
    }
    #else
    private var hostLayer: CALayer {
        wantsLayer = true
        return layer!
    }
    private var isInWindow: Bool { window != nil && bounds.width > 0 }
    // y down, as on iOS and in SwiftUI: the same geometry and turning direction on both.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        relayout()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAnimation()
    }
    #endif
}

#if canImport(UIKit)
typealias PlatformLayerView = UIView
#else
typealias PlatformLayerView = NSView
#endif

// MARK: - Spinner

/// The 3/4 arc that turns once per second (`Spinner`).
final class SpinnerLayerView: RepeatingLayerView {
    private let arc = CAShapeLayer()

    init() {
        super.init(layer: arc)
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.72
    }

    func update(color: CGColor, lineWidth: CGFloat, turning: Bool) {
        quietly {
            arc.strokeColor = color
            arc.lineWidth = lineWidth
        }
        guard turning != (animation != nil) else { return }
        animation = turning ? Self.turn : nil
    }

    override func layoutAnimatedLayer() {
        arc.frame = bounds
        // `Circle().stroke` centres the line on the circle that fits the bounds.
        let side = min(bounds.width, bounds.height)
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        arc.path = CGPath(ellipseIn: rect, transform: nil)
    }

    static let turn: CAAnimation = {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        return turn
    }()
}

struct SpinnerLayer: PlatformViewRepresentable {
    let color: CGColor
    let lineWidth: CGFloat
    let turning: Bool

    func makeView() -> SpinnerLayerView { SpinnerLayerView() }
    func updateView(_ view: SpinnerLayerView) { view.update(color: color, lineWidth: lineWidth, turning: turning) }
}

// MARK: - Shimmer band

/// Where the shimmer's band is and how bright, in points, for a run of `glyphs` glyphs laid out
/// over `width`: the same sweep as `ShimmerMath` (one glyph is `width / glyphs`), as one layer
/// that slides from `startX` to `endX` once per period.
nonisolated struct ShimmerBand: Equatable {
    var width: CGFloat
    /// The band's centre at the start and at the end of a sweep.
    var startX: CGFloat
    var endX: CGFloat

    init(textWidth: CGFloat, glyphs: Int, config: ShimmerMath.Config = .standard) {
        let glyphWidth = textWidth / CGFloat(max(glyphs, 1))
        let span = Double(max(glyphs - 1, 0)) + 2 * config.padding
        width = 2 * config.radius * glyphWidth
        // Glyph `i`'s centre is at `(i + 0.5) * glyphWidth`.
        startX = (0.5 - config.padding) * glyphWidth
        endX = startX + span * glyphWidth
    }

    /// The band's centre `elapsed` seconds into the clock (all bands share one phase).
    func centerX(elapsed: Double, config: ShimmerMath.Config = .standard) -> CGFloat {
        let progress = (elapsed / config.period).truncatingRemainder(dividingBy: 1)
        return startX + (endX - startX) * progress
    }

    /// The band's brightness across it, 0…1, at `count` evenly spaced points: the cosine of
    /// `ShimmerMath.intensity`, peaking in the middle.
    static func profile(count: Int) -> [Double] {
        (0..<count).map { index in
            let distance = abs(Double(index) / Double(count - 1) * 2 - 1)
            return (cos(distance * .pi) + 1) / 2
        }
    }
}

/// Full-strength ink in a band that sweeps across the view; shown masked by the text it lights.
final class ShimmerBandView: RepeatingLayerView {
    private let band = CAGradientLayer()
    private var ink: CGColor?
    private var glyphs = 0
    private var config = ShimmerMath.Config.standard
    private static let stops = 13

    init() {
        super.init(layer: band)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = (0..<Self.stops).map { NSNumber(value: Double($0) / Double(Self.stops - 1)) }
    }

    func update(ink: CGColor, glyphs: Int, config: ShimmerMath.Config = .standard) {
        if ink != self.ink {
            self.ink = ink
            quietly { band.colors = ShimmerBand.profile(count: Self.stops).map { ink.copy(alpha: ink.alpha * $0) ?? ink } }
        }
        guard glyphs != self.glyphs || config != self.config else { return }
        self.glyphs = glyphs
        self.config = config
        laidOut = nil
        quietly { layoutAnimatedLayer() }
    }

    /// The size and glyph count the band was laid out for.
    private var laidOut: (size: CGSize, glyphs: Int)?

    override func layoutAnimatedLayer() {
        guard bounds.width > 0, glyphs > 0 else {
            animation = nil
            return
        }
        if let laidOut, laidOut.size == bounds.size, laidOut.glyphs == glyphs { return }
        laidOut = (bounds.size, glyphs)
        let geometry = ShimmerBand(textWidth: bounds.width, glyphs: glyphs, config: config)
        band.bounds = CGRect(x: 0, y: 0, width: geometry.width, height: bounds.height)
        band.position = CGPoint(x: geometry.startX, y: bounds.midY)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = geometry.startX
        sweep.toValue = geometry.endX
        sweep.duration = config.period
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        // Every band on screen in the same phase, from the wall clock.
        let phase = Date.now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: config.period)
        sweep.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) - phase
        animation = sweep
    }
}

struct ShimmerBandLayer: PlatformViewRepresentable {
    let ink: CGColor
    let glyphs: Int

    func makeView() -> ShimmerBandView { ShimmerBandView() }
    func updateView(_ view: ShimmerBandView) { view.update(ink: ink, glyphs: glyphs) }
}

// MARK: - Representable

@MainActor
protocol PlatformViewRepresentable: PlatformRepresentable {
    associatedtype Layered: PlatformLayerView
    func makeView() -> Layered
    func updateView(_ view: Layered)
}

#if canImport(UIKit)
typealias PlatformRepresentable = UIViewRepresentable
extension PlatformViewRepresentable {
    func makeUIView(context: Context) -> Layered { makeView() }
    func updateUIView(_ view: Layered, context: Context) { updateView(view) }
}
#else
typealias PlatformRepresentable = NSViewRepresentable
extension PlatformViewRepresentable {
    func makeNSView(context: Context) -> Layered { makeView() }
    func updateNSView(_ view: Layered, context: Context) { updateView(view) }
}
#endif
