import Testing
@testable import DesignSystem

// The cases of Warp's `shimmer_math_tests.rs` (MIT), on the Swift port.
private let config = ShimmerMath.Config(period: 2, radius: 6, padding: 8)

@Test func shimmerCenterStartsBeforeTheTextAndSweepsAcrossIt() {
    #expect(ShimmerMath.center(glyphs: 7, elapsed: 0, config: config) == -8)
    // Half a period in: 0.5 * ((7 - 1) + 2 * 8) - 8 = 3.
    #expect(ShimmerMath.center(glyphs: 7, elapsed: 1, config: config) == 3)
    // It loops every period.
    #expect(ShimmerMath.center(glyphs: 7, elapsed: 2, config: config) == -8)
}

@Test func shimmerSingleGlyphKeepsTheCenterAtZero() {
    #expect(ShimmerMath.center(glyphs: 1, elapsed: 0.5, config: config) == 0)
    #expect(ShimmerMath.center(glyphs: 0, elapsed: 0.5, config: config) == 0)
}

@Test func shimmerIntensityPeaksAtTheCenterAndFadesAtTheRadius() {
    #expect(ShimmerMath.intensity(at: 3, center: 3, config: config) == 1)
    #expect(ShimmerMath.intensity(at: 9, center: 3, config: config) == 0)
    let near = ShimmerMath.intensity(at: 4, center: 3, config: config)
    let far = ShimmerMath.intensity(at: 5, center: 3, config: config)
    #expect(near > far)
    #expect(far > 0)
}

@Test func shimmerDefaultsAreWarps() {
    #expect(ShimmerMath.Config.standard == ShimmerMath.Config(period: 3, radius: 6, padding: 8))
}
