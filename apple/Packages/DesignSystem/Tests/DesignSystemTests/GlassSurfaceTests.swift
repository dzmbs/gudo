import Testing
@testable import DesignSystem

/// Glass surfaces carry the theme's surface, and turn opaque under Reduce Transparency.
struct GlassSurfaceTests {
    @Test func darkChromeTintsGlassWithItsRaisedSurface() {
        let chrome = ChromePalette(theme: .ghosttyDefault)
        #expect(GlassSurface.choose(for: chrome, reduceTransparency: false) == .glass(tint: chrome.raised, opacity: 0.55))
    }

    @Test func lightChromeTintsGlassWithItsPaper() {
        let chrome = ChromePalette(theme: .ghosttyDefault, scheme: .light)
        #expect(GlassSurface.choose(for: chrome, reduceTransparency: false) == .glass(tint: chrome.base, opacity: 0.88))
    }

    @Test func reduceTransparencyDrawsTheSameSurfaceOpaque() {
        let dark = ChromePalette(theme: .ghosttyDefault)
        let light = ChromePalette(theme: .ghosttyDefault, scheme: .light)
        #expect(GlassSurface.choose(for: dark, reduceTransparency: true) == .opaque(dark.raised))
        #expect(GlassSurface.choose(for: light, reduceTransparency: true) == .opaque(light.base))
    }
}
