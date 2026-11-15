import SwiftUI

public extension Shape where Self == RoundedRectangle {
    /// The one way chrome rounds a rectangle: continuous corners at a `DS.Radius`.
    static func rounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

public extension View {
    /// A one-physical-pixel line along the inside of `shape`, at any display scale.
    func hairlineBorder(_ shape: some InsettableShape, style: some ShapeStyle = DS.Palette.hairline) -> some View {
        modifier(HairlineBorder(shape: shape, style: style))
    }
}

private struct HairlineBorder<S: InsettableShape, Style: ShapeStyle>: ViewModifier {
    let shape: S
    let style: Style
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content.overlay {
            shape.strokeBorder(style, lineWidth: DS.Size.hairline(scale: scale)).allowsHitTesting(false)
        }
    }
}
