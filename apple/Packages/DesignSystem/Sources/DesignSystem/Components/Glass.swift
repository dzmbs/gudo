import SwiftUI

// Liquid Glass usage rules (docs/DESIGN.md "Materials"):
// 1. Glass is for the navigation layer that floats over content: toolbars, the sidebar, the tab
//    capsule, floating panels (palette, search, toasts), the key bar. Never on content itself:
//    the terminal grid, list rows, diff lines and file content stay opaque.
// 2. Never stack glass on glass; group neighbours in a `GlassEffectContainer` so they blend.
// 3. Tint glass only to carry state (the selected tab, a prominent primary action), never for
//    decoration.

public extension View {
    /// A floating panel over content: palette, search bar, reconnect card. The glass is tinted
    /// is `surface_2`), not the system's grey.
    func floatingPanel(cornerRadius: CGFloat = DS.Radius.panel) -> some View {
        modifier(ThemedGlass(shape: .rect(cornerRadius: cornerRadius), interactive: false))
    }

    /// A floating capsule: toasts, the resize readout on iPad, compact bars.
    func floatingCapsule(interactive: Bool = false) -> some View {
        modifier(ThemedGlass(shape: .capsule, interactive: interactive))
    }
}

/// Glass tinted with the chrome's raised surface.
private struct ThemedGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.chrome) private var chrome

    /// How much of the raised surface tints the glass: enough to carry the theme's hue, little
    /// enough that the glass still reads as glass.
    static var tint: Double { 0.55 }

    func body(content: Content) -> some View {
        let glass = Glass.regular.tint(chrome.raisedColor.opacity(Self.tint))
        content
            .glassEffect(interactive ? glass.interactive() : glass, in: shape)
    }
}

/// The one primary action on a screen: prominent glass tinted with the theme's selection colour
/// (its accent deepened until the label reads on it at 4.5:1). A pale accent (Dracula's lavender,
/// Ghostty's blue) under the system's white label would not.
public struct PrimaryGlassButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.glassProminent)
            .tint(DS.Palette.selection)
            // Its own label colour: content under `chromeContent()` carries the theme's ink.
            .foregroundStyle(DS.Palette.onSelection)
    }
}

public extension PrimitiveButtonStyle where Self == PrimaryGlassButtonStyle {
    static var primaryGlass: PrimaryGlassButtonStyle { PrimaryGlassButtonStyle() }
}

/// A plain, chrome-quiet button for bars: icon only, secondary until hovered or pressed, with
/// Ghostty's search-bar hover fill (primary 10 % hover, 20 % pressed, radius 6).
public struct BarButtonStyle: ButtonStyle {
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(isHovered || configuration.isPressed ? DS.Palette.text : DS.Palette.textSecondary)
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.field)
                    .fill(DS.Palette.ink.opacity(configuration.isPressed ? 0.2 : isHovered ? 0.1 : 0)))
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

    private func fill(_ pressed: Bool) -> AnyShapeStyle {
        if isSelected { return isProminent ? AnyShapeStyle(DS.Palette.selection) : AnyShapeStyle(DS.Palette.accent.opacity(0.2)) }
        if pressed { return AnyShapeStyle(DS.Palette.pressedFill) }
        if isHovered { return AnyShapeStyle(DS.Palette.hoverFill) }
        return AnyShapeStyle(Color.clear)
    }
}

public extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
    static func row(selected: Bool) -> RowButtonStyle { RowButtonStyle(isSelected: selected) }
    static func paletteRow(selected: Bool) -> RowButtonStyle {
        RowButtonStyle(isSelected: selected, isProminent: true, cornerRadius: DS.Radius.paletteRow)
    }
}

public extension View {
    /// A toolbar toggle that is on (Find while the search bar is open): lit with the terminal's
    /// accent. VoiceOver hears it as selected.
    func lit(_ isOn: Bool) -> some View {
        modifier(LitModifier(isOn: isOn))
    }
}

private struct LitModifier: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(DS.Palette.ink.opacity(isOn ? 0.2 : 0))
                    .padding(-DS.Space.xs)
            }
            .animation(DS.Motion.quick, value: isOn)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
