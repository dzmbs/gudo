import SwiftUI

// `ShimmerMath` is ported from Warp's `crates/warpui_core/src/elements/shimmer_math.rs` (MIT):
//
//   Copyright (C) 2020-2026 Denver Technologies, Inc.
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
//   and associated documentation files (the "Software"), to deal in the Software without
//   restriction, including without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
//   Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
//   BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

/// A highlight band that sweeps across a run of glyphs: each glyph is lit by a cosine of its
/// distance from the band's centre.
nonisolated public enum ShimmerMath {
    public struct Config: Hashable, Sendable {
        /// One sweep, start of the track to its end.
        public var period: Double
        /// Glyphs farther than this from the centre are not lit.
        public var radius: Double
        /// Track padding on both sides (glyphs), so the band slides in and out of the text.
        public var padding: Double

        public init(period: Double = 3, radius: Double = 6, padding: Double = 8) {
            self.period = period
            self.radius = radius
            self.padding = padding
        }

        public static let standard = Config()
    }

    /// The band's centre as a fractional glyph index, `elapsed` seconds in. It starts `padding`
    /// glyphs before the first glyph and ends as far past the last one.
    public static func center(glyphs: Int, elapsed: Double, config: Config = .standard) -> Double {
        guard glyphs > 1 else { return 0 }
        let progress = (elapsed / config.period).truncatingRemainder(dividingBy: 1)
        let span = Double(glyphs - 1) + 2 * config.padding
        return progress * span - config.padding
    }

    /// How lit glyph `index` is, 0…1, with the band centred on `center`.
    public static func intensity(at index: Int, center: Double, config: Config = .standard) -> Double {
        let distance = abs(Double(index) - center)
        guard distance < config.radius else { return 0 }
        return (cos(distance / config.radius * .pi) + 1) / 2
    }
}

/// "Working" on a title: the text sits at the secondary level and a band of full-strength ink
/// sweeps across it every 3 s. Under Reduce Motion (or when inactive) it is plain text at the
/// level the caller gave it. The band is a gradient layer moved by Core Animation and masked by
/// the text: no body runs per frame, and it stops off screen.
private struct Shimmering: ViewModifier {
    let active: Bool
    let glyphs: Int
    @Environment(\.chrome) private var chrome
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active, !reduceMotion, glyphs > 0 {
            let ink = chrome.foreground.color
            content
                .foregroundStyle(ink.opacity(ChromePalette.textLevels.secondary))
                .overlay {
                    // Ink at the band's strength over ink at the secondary level is exactly the
                    // per-glyph mix the band stands for.
                    ShimmerBandLayer(ink: ink.resolve(in: environment).cgColor, glyphs: glyphs)
                        .mask { content.foregroundStyle(.black) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

public extension View {
    /// Sweeps a highlight across the text while `active` ("working"). `text` is what the view
    /// shows (its glyph count sets the band's track).
    func shimmering(_ active: Bool, text: String) -> some View {
        modifier(Shimmering(active: active, glyphs: text.count))
    }
}
