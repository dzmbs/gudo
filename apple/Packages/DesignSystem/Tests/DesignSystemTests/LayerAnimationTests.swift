#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The shimmer's band layer sweeps exactly as `ShimmerMath` says, and the never-ending
/// indicators leave the main thread idle.
@MainActor
@Suite struct LayerAnimationTests {
    @Test func theBandFollowsTheShimmerMath() {
        let config = ShimmerMath.Config.standard
        for glyphs in [2, 7, 40] {
            let width = CGFloat(glyphs) * 7.5
            let band = ShimmerBand(textWidth: width, glyphs: glyphs, config: config)
            let glyph = width / CGFloat(glyphs)
            #expect(abs(band.width - 2 * config.radius * glyph) < 0.001)
            for elapsed in stride(from: 0.0, to: 6, by: 0.37) {
                let center = ShimmerMath.center(glyphs: glyphs, elapsed: elapsed, config: config)
                #expect(abs(band.centerX(elapsed: elapsed, config: config) - (center + 0.5) * glyph) < 0.001, "\(glyphs) glyphs at \(elapsed) s")
            }
        }
    }

    @Test func theBandsBrightnessIsTheGlyphIntensity() {
        let count = 13
        let profile = ShimmerBand.profile(count: count)
        let config = ShimmerMath.Config.standard
        for (index, value) in profile.enumerated() {
            // Stop `index` sits this many glyphs from the band's centre.
            let offset = (Double(index) / Double(count - 1) * 2 - 1) * config.radius
            #expect(abs(value - ShimmerMath.intensity(at: 0, center: offset, config: config)) < 1e-9)
        }
    }

    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// How often the main run loop woke up while a sidebar's worth of working titles and
    /// spinners showed for `seconds`.
    private func wakeups(showing seconds: Double) async -> Int {
        let rows = VStack(alignment: .leading) {
            ForEach(0..<12, id: \.self) { row in
                HStack {
                    StatusIndicator(.working)
                    Text("Refactoring the parser \(row)").shimmering(true, text: "Refactoring the parser \(row)")
                }
            }
        }
        .padding()
        let frame = NSRect(x: -30000, y: -30000, width: 360, height: 420)
        let window = OffscreenWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rows)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try? await Task.sleep(for: .milliseconds(500))
        let count = WakeCounter()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
            count.value += 1
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        try? await Task.sleep(for: .seconds(seconds))
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        return count.value
    }

    private final class WakeCounter: @unchecked Sendable {
        var value = 0
    }

    @Test func workingIndicatorsLeaveTheMainThreadIdle() async {
        let woke = await wakeups(showing: 1)
        // A per-frame timeline wakes the main thread 30–120 times a second.
        #expect(woke < 15, "the main run loop woke \(woke) times in 1 s")
    }

    @Test func theAnimationsRunOnTheLayersWhileOnScreen() async throws {
        let spinner = SpinnerLayerView()
        spinner.update(color: CGColor(gray: 1, alpha: 1), lineWidth: 2, turning: true)
        let band = ShimmerBandView()
        band.update(ink: CGColor(gray: 1, alpha: 1), glyphs: 12)
        let frame = NSRect(x: -30000, y: -30000, width: 200, height: 40)
        let window = OffscreenWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = content
        spinner.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        band.frame = NSRect(x: 30, y: 0, width: 160, height: 20)
        #expect(spinner.animated.animationKeys() == nil, "nothing runs before it is in a window")
        content.addSubview(spinner)
        content.addSubview(band)
        content.layoutSubtreeIfNeeded()
        spinner.layout()
        band.layout()
        let turn = try #require(spinner.animated.animationKeys()?.first.flatMap(spinner.animated.animation(forKey:)))
        #expect(turn.repeatCount == .infinity)
        let sweep = try #require(band.animated.animationKeys()?.first.flatMap(band.animated.animation(forKey:)) as? CABasicAnimation)
        #expect(sweep.keyPath == "position.x")
        #expect(sweep.duration == ShimmerMath.Config.standard.period)
        spinner.removeFromSuperview()
        band.removeFromSuperview()
        #expect(spinner.animated.animationKeys() == nil, "off screen it stops")
        #expect(band.animated.animationKeys() == nil)
    }
}
#endif
