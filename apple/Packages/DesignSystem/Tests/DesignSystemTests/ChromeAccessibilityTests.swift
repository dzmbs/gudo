#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
@Suite struct ChromeAccessibilityTests {
    @Test func readsEverySettingFromTheEnvironment() async throws {
        var read: ChromeAccessibility?
        let probe = AccessibilityProbe { read = $0 }
            .environment(\._accessibilityReduceMotion, true)
            .environment(\._accessibilityReduceTransparency, true)
            .environment(\._colorSchemeContrast, .increased)
            .environment(\._accessibilityDifferentiateWithoutColor, true)
        let hosting = NSHostingView(rootView: probe)
        hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(read == ChromeAccessibility(reduceMotion: true, reduceTransparency: true, increaseContrast: true, differentiateWithoutColor: true))
    }

    @Test func standardChangesNothing() async throws {
        var read: ChromeAccessibility?
        let hosting = NSHostingView(rootView: AccessibilityProbe { read = $0 })
        hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(read == .standard)
        let toast = MotionTransition.toast(from: .bottom)
        #expect(ChromeAccessibility.standard.transition(toast).away(reduceMotion: false) == toast.away(reduceMotion: false))
        #expect(ChromeAccessibility.standard.travel(DS.Motion.standard) == DS.Motion.standard)
        #expect(ChromeAccessibility.standard.ring == DS.Palette.accentRing)
        #expect(ChromeAccessibility.standard.ringPixels == 1)
    }

    @Test func reduceMotionOnlyFadesAndNeverTravels() {
        let reduced = ChromeAccessibility(reduceMotion: true)
        for transition in [MotionTransition.toast(from: .leading), .panel(from: .top), .pill(), .row, .card()] {
            let shown = reduced.transition(transition)
            #expect(shown.away(reduceMotion: false) == MotionFrame(opacity: 0, scale: 1, offset: .zero))
            #expect(shown.role == transition.role)
        }
        #expect(reduced.travel(DS.Motion.standard) == nil)
    }

    @Test func reduceTransparencyMakesSurfacesOpaque() {
        let chrome = ChromePalette(theme: .ghosttyDefault)
        guard case .opaque = ChromeAccessibility(reduceTransparency: true).surface(for: chrome) else {
            Issue.record("a glass surface under Reduce Transparency")
            return
        }
        guard case .glass = ChromeAccessibility.standard.surface(for: chrome) else {
            Issue.record("an opaque surface without Reduce Transparency")
            return
        }
    }

    @Test func increaseContrastStrengthensTheRingAndText() {
        let contrast = ChromeAccessibility(increaseContrast: true)
        #expect(contrast.ring == DS.Palette.accent)
        #expect(contrast.ringPixels == 2)
        #expect(contrast.style(.textTertiary) == DS.Palette.textSecondary)
        #expect(contrast.style(.hairline) == DS.Palette.border)
    }
}

private struct AccessibilityProbe: View {
    let report: (ChromeAccessibility) -> Void
    @Environment(\.chromeAccessibility) private var accessibility

    var body: some View {
        Color.clear.onAppear { report(accessibility) }
    }
}
#endif
