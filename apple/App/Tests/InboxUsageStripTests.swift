#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import XCTest
@testable import App

/// The Inbox's rows fade out on their way under its usage strip: no glyph is cut off in a hard
/// line by its rule.
@MainActor
final class InboxUsageStripTests: XCTestCase {
    func testRowsFadeOutAboveTheStrip() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "the fake usage report")
        let model = WindowModel(app: .shared)
        defer { model.close() }
        let ink = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let content = Color(nsColor: ink)
            .safeAreaInset(edge: .bottom, spacing: 0) { InboxUsageStrip() }
            .environment(model)
            .frame(width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.orderFrontRegardless()
        var stripTop: CGFloat?
        for _ in 0..<40 where stripTop == nil {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            stripTop = Self.stripTop(in: host)
        }
        let top = try XCTUnwrap(stripTop, "the strip shows the fake report")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        func redness(above distance: CGFloat) throws -> CGFloat {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(200 * scale), y: Int((top - distance) * scale))?.usingColorSpace(.sRGB))
            return color.redComponent - color.greenComponent
        }
        let whole = try redness(above: top - 10)
        XCTAssertGreaterThan(whole, 0.3, "the content shows")
        XCTAssertGreaterThan(try redness(above: DS.Space.xxl + 8), whole * 0.95, "rows show whole well above the strip")
        XCTAssertLessThan(try redness(above: 3), whole * 0.05, "nothing of a row right by the strip's rule")
        let halfway = try redness(above: DS.Space.xxl / 2)
        XCTAssertGreaterThan(halfway, whole * 0.05, "fading, not cut")
        XCTAssertLessThan(halfway, whole * 0.9, "fading, not cut")
    }

    /// Where the strip starts, in the host's flipped points: its rule, the first line up from
    /// the bottom (clear of its text) that is neither the strip's own fill nor the content.
    private static func stripTop(in host: NSView) -> CGFloat? {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        guard let fill = bitmap.colorAt(x: 4, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.sRGB), fill.redComponent < 0.5 else { return nil }
        for y in stride(from: bitmap.pixelsHigh - 2, to: 0, by: -1) {
            guard let color = bitmap.colorAt(x: 4, y: y)?.usingColorSpace(.sRGB) else { return nil }
            let difference = abs(color.redComponent - fill.redComponent) + abs(color.greenComponent - fill.greenComponent)
                + abs(color.blueComponent - fill.blueComponent)
            if difference > 0.03 { return CGFloat(y) / scale }
        }
        return nil
    }
}
#endif
