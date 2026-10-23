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
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(DS.Palette.raised, in: shape)
            .overlay {
                shape.strokeBorder(isFocused ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.hairline), lineWidth: isFocused ? 1 : 0.5)
            }
            .background {
                shape
                    .stroke(DS.Palette.accent.opacity(isFocused ? 0.25 : 0), lineWidth: 4)
                    .padding(-1)
            }
            .animation(DS.Motion.quick, value: isFocused)
    }
}
