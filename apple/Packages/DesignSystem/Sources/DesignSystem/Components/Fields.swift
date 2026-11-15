import SwiftUI

public extension View {
    /// A text field's surface on a page (quick connect, an address to open): the raised surface,
    /// a hairline edge, and while focused the accent's edge with a soft halo (the system's focus
    /// ring, not a flat grey slab). Literals typed into it stay SF Mono; its prompt is prose.
    func fieldSurface(isFocused: Bool, cornerRadius: CGFloat = DS.Radius.control) -> some View {
        modifier(FieldSurface(isFocused: isFocused, cornerRadius: cornerRadius))
    }
}

private struct FieldSurface: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle.rounded(cornerRadius)
        content
            .background(DS.Palette.raised, in: shape)
            .overlay {
                if isFocused { shape.strokeBorder(DS.Palette.accent, lineWidth: 1) }
            }
            .hairlineBorder(shape, style: isFocused ? AnyShapeStyle(Color.clear) : AnyShapeStyle(DS.Palette.hairline))
            .background {
                shape
                    .stroke(DS.Palette.accentRing, lineWidth: 4)
                    .padding(-1)
                    .opacity(isFocused ? 1 : 0)
            }
            .animation(DS.Motion.micro, value: isFocused)
    }
}
