import SwiftUI

// Liquid Glass usage rules (docs/DESIGN.md "Materials"):
// 1. Glass is for the navigation layer that floats over content: toolbars, the sidebar, the tab
//    capsule, floating panels (palette, search, toasts), the key bar. Never on content itself:
//    the terminal grid, list rows, diff lines and file content stay opaque.
// 2. Never stack glass on glass; group neighbours in a `GlassEffectContainer` so they blend.
// 3. Tint glass only to carry state (the selected tab, a prominent primary action), never for
//    decoration.

public extension View {
    /// A floating panel over content: palette, search bar, reconnect card.
    func floatingPanel(cornerRadius: CGFloat = DS.Radius.panel) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// A floating capsule: toasts, the resize readout on iPad, compact bars.
    func floatingCapsule(interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }
}

/// A plain, chrome-quiet button for bars: icon only, secondary until hovered or pressed, with
/// Ghostty's search-bar hover fill (primary 10 % hover, 20 % pressed, radius 6).
public struct BarButtonStyle: ButtonStyle {
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.field)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.2 : isHovered ? 0.1 : 0)))
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
    }
}

public extension ButtonStyle where Self == BarButtonStyle {
    static var bar: BarButtonStyle { BarButtonStyle() }
}

/// A full-width list row with hover and pressed fills, for rows that are buttons (palette items,
/// inbox rows on Mac). On iPad the pointer gets the system lift/highlight effect.
public struct RowButtonStyle: ButtonStyle {
    var isSelected: Bool
    /// A solid accent selection (the palette) instead of the quiet 20 % one.
    var isProminent = false
    var cornerRadius = DS.Radius.control
    @State private var isHovered = false

    public init(isSelected: Bool = false, isProminent: Bool = false, cornerRadius: CGFloat = DS.Radius.control) {
        self.isSelected = isSelected
        self.isProminent = isProminent
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fill(configuration.isPressed)))
            .onHover { isHovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
    }

    private func fill(_ pressed: Bool) -> Color {
        if isSelected { return isProminent ? DS.Palette.selection : DS.Palette.accent.opacity(0.2) }
        if pressed { return DS.Palette.pressedFill }
        if isHovered { return DS.Palette.hoverFill }
        return .clear
    }
}

public extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
    static func row(selected: Bool) -> RowButtonStyle { RowButtonStyle(isSelected: selected) }
    static func paletteRow(selected: Bool) -> RowButtonStyle {
        RowButtonStyle(isSelected: selected, isProminent: true, cornerRadius: DS.Radius.paletteRow)
    }
}
