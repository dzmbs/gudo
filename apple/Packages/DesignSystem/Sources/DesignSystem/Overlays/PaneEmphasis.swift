import SwiftUI

/// The opt-in ring around the active pane (`pane-active-border`): one physical pixel of the
/// accent's ring tint inside the pane's edge, the accent itself and two pixels under Increase
/// Contrast. It fades in and out with focus on `micro`.
public struct ActivePaneRing: View {
    let isActive: Bool
    let cornerRadius: CGFloat
    @Environment(\.chromeAccessibility) private var accessibility
    @Environment(\.displayScale) private var displayScale

    public init(isActive: Bool, cornerRadius: CGFloat = 0) {
        self.isActive = isActive
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle.rounded(cornerRadius)
            .strokeBorder(accessibility.ring, lineWidth: DS.Size.hairline(scale: displayScale) * accessibility.ringPixels)
            .opacity(isActive ? 1 : 0)
            .animation(DS.Motion.micro, value: isActive)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
