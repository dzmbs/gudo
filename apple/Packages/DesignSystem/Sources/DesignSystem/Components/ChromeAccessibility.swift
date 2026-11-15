import SwiftUI

/// The accessibility settings every hand-drawn control honours, read together from the
/// environment (`@Environment(\.chromeAccessibility)`), so a toast, a switcher and a pane ring
/// answer them the same way.
nonisolated public struct ChromeAccessibility: Equatable, Sendable {
    public var reduceMotion: Bool
    public var reduceTransparency: Bool
    public var increaseContrast: Bool
    public var differentiateWithoutColor: Bool

    public init(reduceMotion: Bool = false, reduceTransparency: Bool = false, increaseContrast: Bool = false, differentiateWithoutColor: Bool = false) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.differentiateWithoutColor = differentiateWithoutColor
    }

    public static let standard = ChromeAccessibility()

    /// The transition as shown: under Reduce Motion only its fade, on the same spring.
    public func transition(_ transition: MotionTransition) -> MotionTransition {
        guard reduceMotion else { return transition }
        return MotionTransition(anchor: transition.anchor, role: transition.role, waitsForArrival: transition.waitsForArrival)
    }

    /// The animation for something that travels (a highlight sliding between rows): none under
    /// Reduce Motion, where it changes in place.
    public func travel(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// A floating surface's fill: themed glass, or the surface opaque under Reduce Transparency.
    public func surface(for chrome: ChromePalette) -> GlassSurface {
        GlassSurface.choose(for: chrome, reduceTransparency: reduceTransparency)
    }

    /// The token drawn for `token`: under Increase Contrast the next stronger one.
    public func style(_ token: ChromeStyle.Token) -> ChromeStyle {
        ChromeStyle(increaseContrast ? token.increasedContrast : token)
    }

    /// The ring around what is active: the accent's ring tint, the accent itself under Increase
    /// Contrast.
    public var ring: ChromeStyle { increaseContrast ? DS.Palette.accent : DS.Palette.accentRing }

    /// How many physical pixels a ring or edge is: one, two under Increase Contrast.
    public var ringPixels: CGFloat { increaseContrast ? 2 : 1 }

    /// A state carried by a hue also carries its own shape and word.
    public var marksStateWithShape: Bool { differentiateWithoutColor }
}

public extension EnvironmentValues {
    var chromeAccessibility: ChromeAccessibility {
        ChromeAccessibility(
            reduceMotion: accessibilityReduceMotion,
            reduceTransparency: accessibilityReduceTransparency,
            increaseContrast: colorSchemeContrast == .increased,
            differentiateWithoutColor: accessibilityDifferentiateWithoutColor)
    }
}
