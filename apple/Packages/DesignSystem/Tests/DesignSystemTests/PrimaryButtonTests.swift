#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The primary button reads as the primary action in a window that is not key too: an approval
/// card shows over another app, where the system's glass would turn it grey under a pale label.
@MainActor
@Suite struct PrimaryButtonTests {
    /// Per channel, out of 255.
    private static let tolerance = 6
    private static let swatch = CGPoint(x: 10, y: 30)
    /// Inside the button, before its label starts.
    private static let buttonFill = CGPoint(x: 44, y: 30)

    /// The button beside a swatch of the theme's prominent colour, drawn in a window that is not
    /// key: the window's colour matching applies to both alike.
    private func drawn(_ chrome: ChromePalette, controlSize: ControlSize, isEnabled: Bool = true) async throws -> (swatch: ThemeColor, fill: ThemeColor) {
        let content = HStack(spacing: 0) {
            Rectangle().fill(chrome.prominent.color).frame(width: 20, height: 60)
            Button("Approve") {}
                .buttonStyle(.primaryGlass)
                .controlSize(controlSize)
                .disabled(!isEnabled)
                .fixedSize()
                .padding(20)
        }
        .background(chrome.base.color)
        .environment(\.chrome, chrome)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!window.isKeyWindow)
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
        func color(at point: CGPoint) throws -> ThemeColor {
            let color = try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
            return ThemeColor(color.redComponent, color.greenComponent, color.blueComponent)
        }
        return (try color(at: Self.swatch), try color(at: Self.buttonFill))
    }

    private func matches(_ shown: ThemeColor, _ expected: ThemeColor) -> Bool {
        Int((max(abs(shown.r - expected.r), abs(shown.g - expected.g), abs(shown.b - expected.b)) * 255).rounded()) <= Self.tolerance
    }

    @Test(arguments: [ColorScheme.dark, .light], [ControlSize.small, .regular])
    func theFillIsTheProminentColourInAWindowThatIsNotKey(scheme: ColorScheme, controlSize: ControlSize) async throws {
        let chrome = ChromePalette(theme: .ghosttyDefault, scheme: scheme)
        let shown = try await drawn(chrome, controlSize: controlSize)
        #expect(matches(shown.fill, shown.swatch), "\(scheme) \(controlSize): the button is \(shown.fill.hex), the prominent swatch \(shown.swatch.hex)")
        #expect(chrome.onProminent.contrast(with: chrome.prominent) >= 4.5)
    }

    @Test func disabledItDropsTheProminentFill() async throws {
        let shown = try await drawn(ChromePalette(theme: .ghosttyDefault), controlSize: .regular, isEnabled: false)
        #expect(!matches(shown.fill, shown.swatch))
    }
}
#endif
