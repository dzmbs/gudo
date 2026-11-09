import SwiftUI

// Liquid Glass usage rules:
// 1. Glass is for the navigation layer that floats over content: toolbars, the sidebar, the tab
//    capsule, floating panels (palette, search, toasts), the key bar. Never on content itself:
//    the terminal grid, list rows, diff lines and file content stay opaque.
// 2. Never stack glass on glass; group neighbours in a `GlassEffectContainer` so they blend.
// 3. Tint glass only to carry state (the selected tab, a prominent primary action), never for
//    decoration.

public extension View {
    /// A floating panel over content. The glass is tinted with the chrome's own surface, so it
    /// reads as the theme's material, not the system's grey; `elevated` casts the deeper panel
    /// shadow for what sits above everything (the palette).
    func floatingPanel(cornerRadius: CGFloat = DS.Radius.panel, elevated: Bool = false) -> some View {
        modifier(ThemedGlass(shape: .rect(cornerRadius: cornerRadius), interactive: false, elevated: elevated))
    }

    func floatingCapsule(interactive: Bool = false) -> some View {
        modifier(ThemedGlass(shape: .capsule, interactive: interactive, elevated: false))
    }

    /// A lit rim on dark chrome, a faint ink line on light.
    func glassEdge(_ shape: some InsettableShape) -> some View {
        modifier(GlassEdge(shape: shape))
    }
}

private struct GlassEdge<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.chrome) private var chrome

    func body(content: Content) -> some View {
        let dark = chrome.scheme == .dark
        content.overlay {
            shape
                .strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08), lineWidth: 0.5)
                .blendMode(dark ? .plusLighter : .normal)
                .allowsHitTesting(false)
        }
    }
}

/// Glass tinted with the chrome's surface: the paper itself on light chrome (a raised grey there
/// reads as a flat grey card), the raised surface on dark. Under Reduce Transparency the surface
/// is opaque, as the system's own bars are.
private struct ThemedGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let elevated: Bool
    @Environment(\.chrome) private var chrome
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// How much of the surface tints the glass: enough to carry the theme's hue, little enough
    /// that the glass still reads as glass.
    static var tint: Double { 0.55 }

    func body(content: Content) -> some View {
        let light = chrome.scheme == .light
        let surface = light ? chrome.baseColor : chrome.raisedColor
        // Light chrome needs more of its paper: text under clear glass reads through it.
        let glass = Glass.regular.tint(surface.opacity(light ? 0.88 : Self.tint))
        Group {
            if reduceTransparency {
                content.background(surface, in: shape)
            } else {
                content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
            }
        }
        .glassEdge(shape)
        .shadow(elevated ? .panel : .float)
    }
}

/// The one primary action on a screen: prominent glass tinted with the theme's prominent colour
/// (its accent deepened until the label reads on it at 4.5:1). A pale accent under the system's
/// white label would not.
public struct PrimaryGlassButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.glassProminent)
            .tint(DS.Palette.prominent)
            // Its own label colour: content under `chromeContent()` carries the theme's ink.
            .foregroundStyle(DS.Palette.onProminent)
    }
}

public extension PrimitiveButtonStyle where Self == PrimaryGlassButtonStyle {
    static var primaryGlass: PrimaryGlassButtonStyle { PrimaryGlassButtonStyle() }
}

/// A plain, chrome-quiet button for bars: icon only, secondary until hovered or pressed.
public struct BarButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let isLit = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(isEnabled ? (isLit ? DS.Palette.text : DS.Palette.textSecondary) : DS.Palette.textSecondary.disabled)
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.field)
                    .fill(DS.Palette.ink.opacity(isLit ? (configuration.isPressed ? 0.2 : 0.1) : 0))
                    .animation(DS.Motion.hover, value: isLit))
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

/// A full-width list row with hover and pressed fills, for rows that are buttons.
public struct RowButtonStyle: ButtonStyle {
    var isSelected: Bool
    var cornerRadius = DS.Radius.control
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init(isSelected: Bool = false, cornerRadius: CGFloat = DS.Radius.control) {
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fill(configuration.isPressed))
                    .animation(DS.Motion.hover, value: isHovered))
            .onHover { isHovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
    }

    private func fill(_ pressed: Bool) -> AnyShapeStyle {
        if isSelected || (isEnabled && pressed) { return AnyShapeStyle(DS.Palette.selection) }
        if isEnabled && isHovered { return AnyShapeStyle(DS.Palette.hoverFill) }
        return AnyShapeStyle(Color.clear)
    }
}

public extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
    static func row(selected: Bool) -> RowButtonStyle { RowButtonStyle(isSelected: selected) }
    static func paletteRow(selected: Bool) -> RowButtonStyle {
        RowButtonStyle(isSelected: selected, cornerRadius: DS.Radius.paletteRow)
    }
}

/// A sidebar row as the platform draws a selected one, in the theme's accent: the solid accent
/// with its own label while the window is active, the soft accent tint once it is not (where the
/// system would turn grey).
public struct SidebarRowButtonStyle: ButtonStyle {
    var isSelected: Bool
    @State private var isHovered = false

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(configuration: configuration, isSelected: isSelected, isHovered: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct SidebarRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let isHovered: Bool
    @Environment(\.chrome) private var chrome
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #else
    private let appearsActive = true
    #endif

    var body: some View {
        let selection = chrome.rowSelection(on: chrome.sidebar, emphasized: appearsActive)
        configuration.label
            .foregroundStyle(isSelected ? AnyShapeStyle(selection.text.color) : AnyShapeStyle(DS.Palette.text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(fill(selection.fill.color)))
    }

    private func fill(_ selected: Color) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(selected) }
        if configuration.isPressed { return AnyShapeStyle(DS.Palette.selection) }
        if isHovered { return AnyShapeStyle(DS.Palette.hoverFill) }
        return AnyShapeStyle(Color.clear)
    }
}

public extension ButtonStyle where Self == SidebarRowButtonStyle {
    static func sidebarRow(selected: Bool) -> SidebarRowButtonStyle { SidebarRowButtonStyle(isSelected: selected) }
}

public extension View {
    /// A toolbar toggle that is on (Find while the search bar is open): lit with the terminal's
    /// ink behind the glyph, never the accent.
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

/// A text or icon button inside a row, a banner or a card: no chrome of its own, the label in the
/// theme's secondary ink (or the accent for the row's main verb), a soft fill under the pointer or
/// a finger. Glass stays on bars and floating surfaces: a glass capsule inside a list row reads as
/// a sticker.
public struct QuietButtonStyle: ButtonStyle {
    var prominent: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init(prominent: Bool = false) {
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.button)
            .foregroundStyle(foreground(configuration.isPressed))
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.field)
                    .fill(DS.Palette.ink.opacity(isEnabled ? (configuration.isPressed ? 0.15 : isHovered ? 0.08 : 0) : 0)))
            .contentShape(.rect(cornerRadius: DS.Radius.field))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.Motion.press, value: configuration.isPressed)
            .onHover { isHovered = $0 }
            #if os(iOS)
            .contentShape(.hoverEffect, .rect(cornerRadius: DS.Radius.field))
            .hoverEffect(.highlight)
            #endif
    }

    private func foreground(_ pressed: Bool) -> AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(prominent ? DS.Palette.accent.disabled : DS.Palette.textSecondary.disabled) }
        if prominent { return AnyShapeStyle(DS.Palette.accent) }
        return AnyShapeStyle(isHovered || pressed ? DS.Palette.text : DS.Palette.textSecondary)
    }
}

/// An action in a settings form (Forget Saved Passwords, Delete All Replays): on the Mac a push
/// button filled from the theme's ink, on touch a row's tinted label. A destructive one reads in
/// the theme's red; disabled, the label drops to the tertiary ink (≥ 3:1), never a faded tint.
public struct FormActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .foregroundStyle(foreground(configuration.role))
            .padding(.horizontal, DS.Space.gap10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Palette.ink.opacity(!isEnabled ? 0.06 : configuration.isPressed ? 0.20 : 0.12)))
            .contentShape(.rect(cornerRadius: 6))
        #else
        configuration.label
            .foregroundStyle(foreground(configuration.role))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
        #endif
    }

    private func foreground(_ role: ButtonRole?) -> AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(DS.Palette.textTertiary) }
        if role == .destructive { return AnyShapeStyle(DS.Palette.error) }
        #if os(macOS)
        return AnyShapeStyle(DS.Palette.text)
        #else
        return AnyShapeStyle(DS.Palette.accent)
        #endif
    }
}

public extension ButtonStyle where Self == FormActionButtonStyle {
    static var formAction: FormActionButtonStyle { FormActionButtonStyle() }
}

public extension ButtonStyle where Self == QuietButtonStyle {
    /// A secondary verb in a row (Reply, Open, Revoke).
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    /// The row's own main verb when it is not a decision (a banner's Undo).
    static var quietProminent: QuietButtonStyle { QuietButtonStyle(prominent: true) }
}
